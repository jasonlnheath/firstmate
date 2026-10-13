import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
  firstmateShellInvocation,
} from "./lib/fm-operational-input.ts";

let guardFollowupActive = false;

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

// Pi's session_start reasons are startup | reload | new | resume | fork, and a
// separate session_compact event fires after a compaction. "new" is Pi's /new
// while reload, resume, and fork all keep prior context.
const sessionstartDeliveryBytes = 512 * 1024;

type SessionStartContext = {
  sessionManager?: {
    getHeader?: () => { timestamp?: unknown } | null | undefined;
    getSessionId?: () => unknown;
  };
};

function restoredSessionEvidence(ctx: SessionStartContext): boolean {
  try {
    const timestamp = ctx.sessionManager?.getHeader?.()?.timestamp;
    const createdAt = typeof timestamp === "string" ? Date.parse(timestamp) : Number.NaN;
    return Number.isFinite(createdAt) && createdAt < performance.timeOrigin;
  } catch {
    return false;
  }
}

function startupRebuildSource(ctx: SessionStartContext): "resume" | "fork" | undefined {
  const args = process.argv.slice(2);
  const restored = restoredSessionEvidence(ctx);
  for (const arg of args) {
    if (arg === "--fork" || arg.startsWith("--fork=")) return "fork";
    if (
      restored && (
        arg === "-c" || arg === "--continue" ||
        arg === "-r" || arg === "--resume" ||
        arg === "--session" || arg.startsWith("--session=") ||
        arg === "--session-id" || arg.startsWith("--session-id=")
      )
    ) return "resume";
  }
  return undefined;
}
const sessionstartTruncatedMarker =
  "\n\nPI SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";
const sessionstartManualFallback =
  "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.";
const sessionstartIneligibleExit = 3;
const sessionstartRetireTimeoutMs = 1000;

// One active generation owns native startup from child launch through context
// claim. Replacement activates first, serially retires every predecessor, and
// lets only the matching session id claim one persistent provider prerequisite.
type SessionstartSource = "startup" | "clear" | "resume" | "fork" | "compact";
type SessionstartResult =
  | { kind: "ready"; raw: string }
  | { kind: "empty" | "failed" | "ineligible" | "cancelled" };
type SessionstartMessage = {
  customType: "firstmate-sessionstart-nudge";
  content: string;
  display: false;
  details: { kind: "session-start" };
};
type SessionstartGeneration = {
  id: number;
  sessionId: string;
  source: SessionstartSource;
  stopping: boolean;
  delivered: boolean;
  child: ChildProcess | null;
  processGroupId: number | null;
  childClosed: boolean;
  childClose: Promise<void> | null;
  stopPromise: Promise<void> | null;
  result: Promise<SessionstartResult>;
};

let nextSessionstartGenerationId = 0;
let activeSessionstartGeneration: SessionstartGeneration | null = null;

function sessionIdFromContext(ctx: SessionStartContext): string {
  try {
    return String(ctx.sessionManager?.getSessionId?.() ?? "");
  } catch {
    return "";
  }
}

function sessionstartGenerationIsLive(generation: SessionstartGeneration): boolean {
  return activeSessionstartGeneration === generation && !generation.stopping;
}

function signalSessionstartChild(child: ChildProcess, signal: NodeJS.Signals): void {
  const pid = child.pid;
  if (!pid) return;
  if (process.platform === "win32") {
    const args = ["/pid", String(pid), "/t"];
    if (signal === "SIGKILL") args.push("/f");
    spawnSync("taskkill", args, { stdio: "ignore" });
    return;
  }
  try {
    process.kill(-pid, signal);
  } catch {
    try {
      child.kill(signal);
    } catch {
    }
  }
}

function sessionstartProcessGroupAlive(processGroupId: number): boolean {
  try {
    process.kill(-processGroupId, 0);
    return true;
  } catch {
    return false;
  }
}

function waitForSessionstartProcessGroupExit(
  processGroupId: number,
  timeoutMs: number,
): Promise<void> {
  return new Promise((resolveWait) => {
    const startedAt = Date.now();
    const poll = (): void => {
      if (!sessionstartProcessGroupAlive(processGroupId) || Date.now() - startedAt >= timeoutMs) {
        resolveWait();
        return;
      }
      setTimeout(poll, 10);
    };
    poll();
  });
}

function waitForSessionstartClose(generation: SessionstartGeneration, timeoutMs: number): Promise<void> {
  if (generation.childClosed || !generation.childClose) return Promise.resolve();
  return new Promise((resolveWait) => {
    const timer = setTimeout(resolveWait, timeoutMs);
    void generation.childClose?.then(() => {
      clearTimeout(timer);
      resolveWait();
    });
  });
}

function stopSessionstartGeneration(generation: SessionstartGeneration): Promise<void> {
  if (generation.stopPromise) return generation.stopPromise;
  generation.stopping = true;
  generation.stopPromise = (async () => {
    const child = generation.child;
    if (process.platform === "win32") {
      if (!child || generation.childClosed) {
        await generation.result;
        return;
      }
      signalSessionstartChild(child, "SIGTERM");
      await waitForSessionstartClose(generation, sessionstartRetireTimeoutMs);
      if (!generation.childClosed) {
        signalSessionstartChild(child, "SIGKILL");
        await waitForSessionstartClose(generation, sessionstartRetireTimeoutMs);
      }
      return;
    }
    const processGroupId = generation.processGroupId;
    if (!child || !processGroupId) {
      await generation.result;
      return;
    }
    try {
      process.kill(-processGroupId, "SIGTERM");
    } catch {
    }
    await waitForSessionstartProcessGroupExit(processGroupId, sessionstartRetireTimeoutMs);
    if (sessionstartProcessGroupAlive(processGroupId)) {
      try {
        process.kill(-processGroupId, "SIGKILL");
      } catch {
      }
      await waitForSessionstartProcessGroupExit(processGroupId, sessionstartRetireTimeoutMs);
    }
  })();
  return generation.stopPromise;
}

function runSessionstartHook(generation: SessionstartGeneration): Promise<SessionstartResult> {
  return new Promise((resolveResult) => {
    let settled = false;
    let closeChild: () => void = () => {};
    const settle = (result: SessionstartResult): void => {
      if (settled) return;
      settled = true;
      resolveResult(result);
    };
    const supervised = process.platform !== "win32";
    const runner = `${root}/bin/fm-sessionstart-run.sh`;
    const invocation = supervised
      ? {
          command: "node",
          args: [
            `${extensionDir}/lib/fm-sessionstart-supervisor.mjs`,
            runner,
            "--source",
            generation.source,
            "--pi-prerequisite",
          ],
        }
      : firstmateShellInvocation(
          runner,
          ["--source", generation.source, "--pi-prerequisite"],
        );
    let child: ChildProcess;
    try {
      child = spawn(
        invocation.command,
        invocation.args,
        {
          detached: supervised,
          stdio: supervised
            ? ["ignore", "pipe", "ignore", "ipc"]
            : ["ignore", "pipe", "ignore"],
        },
      );
    } catch {
      settle(generation.stopping ? { kind: "cancelled" } : { kind: "failed" });
      return;
    }
    generation.child = child;
    generation.processGroupId = child.pid ?? null;
    generation.childClose = new Promise<void>((resolveClose) => {
      closeChild = resolveClose;
    });
    const chunks: Buffer[] = [];
    let observedBytes = 0;
    let retainedBytes = 0;
    let truncated = false;
    let pendingCompletion: { code: number | null; bytes: number } | null = null;
    const unrefSupervisor = (): void => {
      if (!supervised) return;
      child.unref();
      child.channel?.unref?.();
      const stdout = child.stdout as (NodeJS.ReadableStream & { unref?: () => void }) | null;
      stdout?.unref?.();
    };
    const markClosed = (): void => {
      if (generation.childClosed) return;
      generation.childClosed = true;
      if (generation.child === child) generation.child = null;
      generation.processGroupId = null;
      closeChild();
    };
    const complete = (code: number | null): void => {
      unrefSupervisor();
      if (generation.stopping) {
        settle({ kind: "cancelled" });
        return;
      }
      if (code === sessionstartIneligibleExit) {
        settle({ kind: "ineligible" });
        return;
      }
      if (code !== 0) {
        settle({ kind: "failed" });
        return;
      }
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      if (!raw) {
        settle({ kind: "empty" });
        return;
      }
      settle({
        kind: "ready",
        raw: truncated ? `${raw}${sessionstartTruncatedMarker}` : raw,
      });
    };
    const completePending = (): void => {
      if (!pendingCompletion || observedBytes < pendingCompletion.bytes) return;
      complete(pendingCompletion.code);
      pendingCompletion = null;
    };
    child.stdout?.on("data", (chunk: Buffer) => {
      observedBytes += chunk.length;
      if (retainedBytes >= sessionstartDeliveryBytes) {
        truncated = true;
        completePending();
        return;
      }
      const remaining = sessionstartDeliveryBytes - retainedBytes;
      const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
      chunks.push(retained);
      retainedBytes += retained.length;
      if (retained.length !== chunk.length) truncated = true;
      completePending();
    });
    if (supervised) {
      child.on("message", (message: unknown) => {
        const result = message as { type?: unknown; code?: unknown; bytes?: unknown };
        if (result.type !== "result" ||
            (typeof result.code !== "number" && result.code !== null) ||
            typeof result.bytes !== "number") return;
        pendingCompletion = { code: result.code, bytes: result.bytes };
        completePending();
      });
    }
    child.on("error", () => {
      markClosed();
      settle(generation.stopping ? { kind: "cancelled" } : { kind: "failed" });
    });
    child.on("close", (code) => {
      markClosed();
      if (supervised) {
        settle(generation.stopping ? { kind: "cancelled" } : { kind: "failed" });
        return;
      }
      complete(code);
    });
  });
}

function createSessionstartGeneration(
  source: SessionstartSource,
  sessionId: string,
): SessionstartGeneration {
  const previous = activeSessionstartGeneration;
  const generation: SessionstartGeneration = {
    id: ++nextSessionstartGenerationId,
    sessionId,
    source,
    stopping: false,
    delivered: false,
    child: null,
    processGroupId: null,
    childClosed: false,
    childClose: null,
    stopPromise: null,
    result: Promise.resolve({ kind: "cancelled" }),
  };
  activeSessionstartGeneration = generation;
  generation.result = (async (): Promise<SessionstartResult> => {
    if (previous) await stopSessionstartGeneration(previous);
    if (!sessionstartGenerationIsLive(generation)) return { kind: "cancelled" };
    return runSessionstartHook(generation);
  })();
  return generation;
}

function sessionstartMessage(
  generation: SessionstartGeneration,
  result: SessionstartResult,
): SessionstartMessage | undefined {
  let raw = result.kind === "ready" ? result.raw : "";
  if (!raw && result.kind === "failed") {
    raw = sessionstartManualFallback;
  } else if (!raw && ["startup", "clear", "compact"].includes(generation.source) &&
      result.kind === "empty") {
    raw = sessionstartManualFallback;
  }
  if (!raw) return undefined;
  try {
    // The wrapper already returns an encoded nudge on a context-preserving
    // open, so only an unencoded digest or fallback needs the marker added.
    const content = classifyFirstmateCurrentOperationalText(raw)
      ? raw
      : encodeFirstmateOperationalInput("session-start", raw);
    return {
      customType: "firstmate-sessionstart-nudge",
      content,
      display: false,
      details: { kind: "session-start" },
    };
  } catch {
    return undefined;
  }
}

async function claimSessionstartMessage(
  generation: SessionstartGeneration,
  ctx?: SessionStartContext,
): Promise<SessionstartMessage | undefined> {
  const result = await generation.result;
  if (!sessionstartGenerationIsLive(generation) || generation.delivered) return undefined;
  const currentSessionId = ctx ? sessionIdFromContext(ctx) : "";
  if (generation.sessionId && currentSessionId && generation.sessionId !== currentSessionId) {
    return undefined;
  }
  generation.delivered = true;
  return sessionstartMessage(generation, result);
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const invocation = firstmateShellInvocation(`${root}/bin/fm-turnend-guard.sh`, []);
    let child: ChildProcess;
    try {
      child = spawn(invocation.command, invocation.args, {
        stdio: ["pipe", "ignore", "pipe"],
      });
    } catch {
      resolveResult({ code: 0, stderr: "" });
      return;
    }
    let stderr = "";
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin?.on("error", () => {});
    child.stdin?.end('{"stop_hook_active":false}');
  });
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra Pi -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block (verified 2026-07-09 against pi 0.80.5:
// returning {block: true} prevents the bash command from running). Each owner
// script owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const invocation = firstmateShellInvocation(
      `${root}/bin/${script}`,
      ["--command", command],
    );
    let child: ChildProcess;
    try {
      child = spawn(invocation.command, invocation.args, {
        stdio: ["ignore", "ignore", "pipe"],
      });
    } catch {
      resolveResult({ code: 0, stderr: "" });
      return;
    }
    let stderr = "";
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

// Jev damage-control gate (docs/jev-gate.md). Third seatbelt in this same
// tool_call handler. Inert unless config/jev-gate exists in this home; the
// transport re-verifies scope independently, and a foreign lock holder (a
// second Pi session in this home) is never gated. The dangerous-mode override
// window opens only through the operator's /jev-override command below and
// lives in this process's memory - never in a file, so nothing a bash call
// can reach opens or fakes it. Command acquisition is on stdin, and the child
// runs under a hard wall-clock kill so a hung gate can never wedge the tool
// path.
const jevGateConfigPath = `${process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`}/jev-gate`;
type JevOverrideWindow = { openedAt: number; expiresAt: number; reason: string };

function runJevGateCheck(
  command: string,
  window: JevOverrideWindow | null,
  cache: Map<string, { choice: string; confidence: number }>,
  recordAction?: { action: string; reason: string },
): Promise<{ code: number; stderr: string; stdout: string }> {
  return new Promise((resolveResult) => {
    if (!existsSync(jevGateConfigPath)) {
      resolveResult({ code: 0, stderr: "", stdout: "" });
      return;
    }
    if (lockOwnership() === "other") {
      resolveResult({ code: 0, stderr: "", stdout: "" });
      return;
    }
    const script = process.env.FM_JEV_GATE_CHECK || `${root}/bin/fm-jev-pretool-check.sh`;
    const args = recordAction
      ? ["record-override", recordAction.action, recordAction.reason]
      : [];
    const invocation = firstmateShellInvocation(script, args);
    const env = { ...process.env };
    if (!recordAction) {
      const sha = createHash("sha256").update(command).digest("hex");
      const cached = cache.get(sha);
      env.FM_JEV_GATE_OVERRIDE = window ? "1" : "";
      env.FM_JEV_GATE_CACHE = cached ? `${cached.choice},${cached.confidence}` : "";
      env.FM_JEV_GATE_CACHE_OUT = "1";
    }
    let wallMs = Number(process.env.FM_JEV_GATE_WALL_MS ?? "");
    if (!Number.isFinite(wallMs) || wallMs <= 0) wallMs = 12000;
    let child: ChildProcess;
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let killTimer: ReturnType<typeof setTimeout> | null = null;
    const finish = (result: { code: number; stderr: string; stdout: string }) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      resolveResult(result);
    };
    const killGroup = () => {
      if (!child || child.pid === undefined) return;
      try {
        if (process.platform === "win32") child.kill("SIGKILL");
        else process.kill(-child.pid, "SIGTERM");
      } catch {
      }
      killTimer = setTimeout(() => {
        try {
          if (process.platform !== "win32" && child?.pid !== undefined) {
            process.kill(-child.pid, "SIGKILL");
          }
        } catch {
        }
      }, 500);
      killTimer.unref();
    };
    try {
      child = spawn(invocation.command, invocation.args, {
        stdio: ["pipe", "pipe", "pipe"],
        env,
        detached: process.platform !== "win32",
      });
    } catch {
      finish({ code: 0, stderr: "", stdout: "" });
      return;
    }
    let stderr = "";
    let stdout = "";
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stdin?.on("error", () => {});
    child.on("error", () => finish({ code: 0, stderr: "", stdout: "" }));
    child.on("close", (code) => finish({ code: code ?? 0, stderr, stdout }));
    if (!recordAction) child.stdin?.end(command);
    else child.stdin?.end();
    timer = setTimeout(() => {
      killGroup();
      finish({ code: 0, stderr: "", stdout: "" });
    }, wallMs);
    timer.unref();
  });
}

export default function (pi: ExtensionAPI) {
  let sessionstartGeneration: SessionstartGeneration | null = null;
  let sessionstartExitListenerRegistered = false;
  let jevOverrideWindow: JevOverrideWindow | null = null;
  const jevDecisionCache = new Map<string, { choice: string; confidence: number }>();
  const jevOverrideViewPath = `${state}/jev-gate/override-status`;
  const clearJevOverride = async (closeAction: string): Promise<void> => {
    if (!jevOverrideWindow) return;
    jevOverrideWindow = null;
    try {
      rmSync(jevOverrideViewPath, { force: true });
    } catch {
    }
    await runJevGateCheck("", null, jevDecisionCache, {
      action: closeAction,
      reason: closeAction === "expire" ? "ttl expired" : "session ended",
    });
  };
  const expireJevOverrideIfDue = (): void => {
    if (jevOverrideWindow && Date.now() >= jevOverrideWindow.expiresAt) {
      clearJevOverride("expire");
    }
  };
  const openJevOverride = async (reason: string, ttlMinutes: number): Promise<void> => {
    const now = Date.now();
    const ttl = Math.max(1, Math.min(60, Math.floor(ttlMinutes || 15)));
    jevOverrideWindow = { openedAt: now, expiresAt: now + ttl * 60_000, reason };
    try {
      mkdirSync(`${state}/jev-gate`, { recursive: true, mode: 0o700 });
      writeFileSync(
        jevOverrideViewPath,
        `${JSON.stringify({
          reason,
          opened_at: now,
          expires_at: jevOverrideWindow.expiresAt,
          ttl_minutes: ttl,
        })}\n`,
        { mode: 0o600 },
      );
    } catch {
    }
    await runJevGateCheck("", null, jevDecisionCache, {
      action: "open",
      reason,
    });
  };
  const cleanupSessionstartOnProcessExit = (): void => {
    const generation = sessionstartGeneration;
    if (!generation) return;
    if (process.platform === "win32") {
      if (generation.child) signalSessionstartChild(generation.child, "SIGKILL");
      return;
    }
    const processGroupId = generation.processGroupId;
    if (!processGroupId) {
      if (generation.child) signalSessionstartChild(generation.child, "SIGKILL");
      return;
    }
    try {
      process.kill(-processGroupId, "SIGKILL");
    } catch {
    }
  };
  const registerSessionstartExitListener = (): void => {
    if (sessionstartExitListenerRegistered) return;
    process.once("exit", cleanupSessionstartOnProcessExit);
    sessionstartExitListenerRegistered = true;
  };
  const removeSessionstartExitListener = (): void => {
    if (!sessionstartExitListenerRegistered) return;
    process.removeListener("exit", cleanupSessionstartOnProcessExit);
    sessionstartExitListenerRegistered = false;
  };
  registerSessionstartExitListener();

  pi.on?.("session_start", (event, ctx) => {
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const source = reason === "startup"
      ? startupRebuildSource(ctx) ?? "startup"
      : { new: "clear", resume: "resume", fork: "fork" }[reason];
    markLoaded();
    if (!source) return;
    registerSessionstartExitListener();
    sessionstartGeneration = createSessionstartGeneration(
      source as SessionstartSource,
      sessionIdFromContext(ctx),
    );
  });

  pi.on?.("before_agent_start", async (_event, ctx) => {
    const generation = sessionstartGeneration;
    if (!generation) return;
    const message = await claimSessionstartMessage(generation, ctx);
    return message ? { message } : undefined;
  });

  // Pi's compaction equivalent. Manual compaction is idle and auto-compaction
  // may retry without another before_agent_start, so the event keeps its
  // existing delivery path while sharing generation ownership and cancellation.
  pi.on?.("session_compact", async (_event, ctx) => {
    registerSessionstartExitListener();
    const generation = createSessionstartGeneration("compact", sessionIdFromContext(ctx));
    sessionstartGeneration = generation;
    const message = await claimSessionstartMessage(generation, ctx);
    if (!message || !sessionstartGenerationIsLive(generation)) return;
    try {
      pi.sendMessage(message);
    } catch {
      generation.delivered = false;
    }
  });

  pi.on?.("session_shutdown", async () => {
    await clearJevOverride("close");
    const generation = sessionstartGeneration;
    try {
      if (generation) await stopSessionstartGeneration(generation);
    } finally {
      if (sessionstartGeneration === generation) sessionstartGeneration = null;
      removeSessionstartExitListener();
    }
  });

  // Operator-only dangerous-mode window. Typed at the TUI by the operator;
  // the model has no channel that reaches it, and no file confers authority.
  pi.registerCommand?.("jev-override", {
    handler: async (args: string) => {
      const text = String(args ?? "").trim();
      if (text === "off" || text === "--off") {
        await clearJevOverride("close");
        return;
      }
      const ttlMatch = text.match(/--ttl\s+(\d+)/);
      const reason = text
        .replace(/--ttl\s+\d+/, "")
        .replace(/--reason/, "")
        .trim();
      if (!reason) return;
      await openJevOverride(reason, ttlMatch ? Number(ttlMatch[1]) : 15);
    },
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code === 2) {
      return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
    }
    expireJevOverrideIfDue();
    const gate = await runJevGateCheck(command, jevOverrideWindow, jevDecisionCache);
    const cacheMatch = gate.stdout.match(/^cache\t(\S+)\t([0-9.]+)$/m);
    if (cacheMatch) {
      const sha = createHash("sha256").update(command).digest("hex");
      jevDecisionCache.set(sha, { choice: cacheMatch[1], confidence: Number(cacheMatch[2]) });
    }
    if (gate.code !== 2) {
      return {};
    }
    return { block: true, reason: gate.stderr.trim() || "denied by the Jev damage-control gate" };
  });

  pi.on("agent_settled", async () => {
    if (guardFollowupActive) {
      guardFollowupActive = false;
      return;
    }

    const result = await runGuard();
    if (result.code !== 2) return;

    guardFollowupActive = true;
    try {
      const content = encodeFirstmateOperationalInput(
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          result.stderr,
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch {
      guardFollowupActive = false;
    }
  });

  markLoaded();
}
