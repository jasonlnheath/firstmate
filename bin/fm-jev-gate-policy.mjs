#!/usr/bin/env node
// Sole decision owner for the Jev damage-control gate (docs/jev-gate.md).
//
// One command evaluation per invocation: the transport pipes the raw command
// text on stdin and passes the resolved roots as flags. This owner runs the
// judgment chain - tokenizer/normalizer, R-catalog deterministic blocks,
// M-catalog consult markers, the bounded Jev consult with circuit breaker and
// decision-cache hint, the confidence floor ladder, the shadow/enforce
// posture, and the redacted hash-chained pilot log - and prints exactly one
// tab-separated decision line on stdout:
//
//   allow<TAB>ok<TAB><reason>
//   block<TAB><deny-code<TAB><reason>
//   error<TAB>jev-gate-error<TAB><reason>
//
// plus an optional trailing "cache<TAB><choice><TAB><confidence>" line the
// extension seat uses to keep its per-session decision cache warm. The
// transport renders every decision except `block` as an allow.
//
// Deny codes are a closed list (adding one is an interface change that must
// update docs/jev-gate.md and its test in the same commit):
//   rm-protected git-push-force dd-device mkfs partition-write
//   chmod-recursive-root redirect-protected overwrite-protected power-op
//   git-discard-primary jev-destructive
//
// Threat model: the gate targets the model's honest catastrophic mistakes,
// not deliberate obfuscation. ANSI-C $'...'/locale $"..." decoder forms are
// not decoded here; COUPLING NOTE (copied from the arm-check precedent):
// extending any decoder set REQUIRES extending the transports' byte
// normalization in the same change.
//
// Usage:
//   printf '%s' "$CMD" | node bin/fm-jev-gate-policy.mjs \
//     --root <root> --home <home> --state <state> --config <config> \
//     --posture <shadow|enforce> [--override-active 1]
//     [--cached-choice <c> --cached-confidence <n>]
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";

// ---- pinned vocabularies -------------------------------------------------------

const CHOICE_VOCABULARY = new Set(["benign", "grey-reversible", "destructive", "uncertain"]);

const COUNTER_KEYS = [
  "allow_free",
  "consult_benign",
  "consult_grey",
  "consult_uncertain",
  "low_confidence_pass",
  "block_regex",
  "block_jev",
  "block_repeat",
  "near_miss",
  "jev_off",
  "jev_timeout",
  "jev_error",
  "jev_degraded",
  "override_opened",
  "override_pass",
  "overridden_block",
  "override_expired",
];

const SYSTEM_ROOTS = [
  "/boot", "/dev", "/etc", "/lib", "/lib64", "/bin", "/sbin",
  "/usr", "/var", "/sys", "/proc", "/run", "/opt", "/root",
];

const HOME_PROTECTED_CHILDREN = [
  ".ssh", ".local", ".config", ".pi", ".treehouse", ".gnupg", ".aws",
];

const FM_PROTECTED_CHILDREN = ["state", "data", "projects", "config", ".env"];

const WRAPPER_VERBS = new Set([
  "command", "builtin", "exec", "nohup", "time", "stdbuf", "ionice", "setsid",
]);

const NEAR_MISS_TOKENS = [
  "rm -", "rm --", "mkfs", "dd of=", "shred ", "wipefs", "truncate ",
  "shutdown", "reboot", "poweroff", "halt ", "--delete", "subvolume delete",
  "--no-preserve-root",
];

const EVENT_CAP_BYTES = 1024 * 1024;
const EVENT_KEEP_ROTATIONS = 3;
const CMD_EVENT_CAP_BYTES = 4096;
const SCREENER_INPUT_CAP_BYTES = 8192;
const BREAKER_FAILURE_THRESHOLD = 3;
const BREAKER_COOLDOWN_MS = 5 * 60 * 1000;
const BLOCK_SHA_CAP = 256;

// ---- CLI -----------------------------------------------------------------------

function parseArgs(argv) {
  const cfg = {
    root: "",
    home: "",
    state: "",
    config: "",
    posture: "enforce",
    overrideActive: false,
    cachedChoice: "",
    cachedConfidence: null,
    record: "",
    reason: "",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      return argv[i];
    };
    if (arg === "--root") cfg.root = next() ?? "";
    else if (arg === "--home") cfg.home = next() ?? "";
    else if (arg === "--state") cfg.state = next() ?? "";
    else if (arg === "--config") cfg.config = next() ?? "";
    else if (arg === "--posture") cfg.posture = next() ?? "enforce";
    else if (arg === "--override-active") cfg.overrideActive = (next() ?? "") === "1";
    else if (arg === "--cached-choice") cfg.cachedChoice = next() ?? "";
    else if (arg === "--cached-confidence") {
      const value = Number(next());
      cfg.cachedConfidence = Number.isFinite(value) ? value : null;
    } else if (arg === "--record") cfg.record = next() ?? "";
    else if (arg === "--reason") cfg.reason = next() ?? "";
  }
  return cfg;
}

// ---- small helpers -------------------------------------------------------------

const sha256Hex = (text) => createHash("sha256").update(text, "utf8").digest("hex");

const sleepMs = (ms) =>
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function normalizeBytes(text) {
  return text
    .replaceAll("\\", "")
    .replaceAll('"', "")
    .replaceAll("'", "")
    .replaceAll("\r", "")
    .replaceAll("\n", " ");
}

// Quote-aware split of one command string into simple-command segments on
// ; && || | and newlines. Deliberate deeper obfuscation stays out of scope.
function splitSegments(text) {
  const segments = [];
  let current = "";
  let single = false;
  let double = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === "'" && !double) {
      single = !single;
      current += ch;
    } else if (ch === '"' && !single) {
      double = !double;
      current += ch;
    } else if (!single && !double && ch === "\\" && i + 1 < text.length) {
      current += ch + text[i + 1];
      i += 1;
    } else if (!single && !double && (ch === ";" || ch === "|" || ch === "\n")) {
      if (ch === "|" && text[i + 1] === "|") i += 1;
      segments.push(current);
      current = "";
    } else if (!single && !double && ch === "&") {
      if (text[i + 1] === "&") i += 1;
      segments.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  segments.push(current);
  return segments.map((s) => s.trim()).filter((s) => s.length > 0);
}

// One token: the quote-stripped match text plus its raw spelling.
function makeToken(raw) {
  let text = "";
  let single = false;
  let double = false;
  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i];
    if (ch === "'" && !double) {
      single = !single;
    } else if (ch === '"' && !single) {
      double = !double;
    } else if (!single && !double && ch === "\\" && i + 1 < raw.length) {
      text += raw[i + 1];
      i += 1;
    } else {
      text += ch;
    }
  }
  return { text, raw };
}

// Tokenize one segment into words and redirect operations.
function tokenizeSegment(segment) {
  const words = [];
  const redirects = [];
  let raw = "";
  let single = false;
  let double = false;
  const flush = () => {
    if (raw.length > 0) {
      words.push(makeToken(raw));
      raw = "";
    }
  };
  for (let i = 0; i < segment.length; i += 1) {
    const ch = segment[i];
    if (ch === "'" && !double) {
      single = !single;
      raw += ch;
    } else if (ch === '"' && !single) {
      double = !double;
      raw += ch;
    } else if (!single && !double && (ch === " " || ch === "\t")) {
      flush();
    } else if (!single && !double && (ch === ">" || ch === "<")) {
      flush();
      let op = ch;
      i += 1;
      while (i < segment.length && "><&|".includes(segment[i])) {
        op += segment[i];
        i += 1;
      }
      while (i + 1 < segment.length && segment[i + 1] === " ") i += 1;
      let target = "";
      let tSingle = false;
      let tDouble = false;
      for (let j = i + 1; j < segment.length; j += 1) {
        const tch = segment[j];
        if (tch === "'" && !tDouble) {
          tSingle = !tSingle;
          target += tch;
        } else if (tch === '"' && !tSingle) {
          tDouble = !tDouble;
          target += tch;
        } else if (!tSingle && !tDouble && (tch === " " || tch === "\t")) {
          break;
        } else {
          target += tch;
        }
      }
      if (target.length > 0) redirects.push({ op, target: makeToken(target) });
      i += target.length;
    } else {
      raw += ch;
    }
  }
  flush();
  return { words, redirects };
}

// Operand resolution against the transport cwd: ~, $HOME, .., ., and one level
// of brace folding. Symlinks are not followed for classification.
function expandBraces(path) {
  const open = path.indexOf("{");
  const close = open === -1 ? -1 : path.indexOf("}", open + 1);
  if (open === -1 || close === -1) return [path];
  const prefix = path.slice(0, open);
  const suffix = path.slice(close + 1);
  const inner = path.slice(open + 1, close);
  if (inner.includes("{") || !inner.includes(",")) return [path];
  return inner.split(",").map((part) => `${prefix}${part}${suffix}`);
}

function resolveOperand(rawText, cwd, home) {
  const resolved = [];
  for (const candidate of expandBraces(rawText)) {
    let text = candidate;
    if (text === "~") {
      resolved.push(home);
      continue;
    }
    if (text.startsWith("~/")) {
      text = `${home}${text.slice(1)}`;
    }
    text = text.replaceAll("$HOME", home);
    if (!text.startsWith("/")) {
      text = `${cwd}/${text}`;
    }
    const parts = [];
    for (const part of text.split("/")) {
      if (part === "" || part === ".") continue;
      if (part === "..") parts.pop();
      else parts.push(part);
    }
    resolved.push(`/${parts.join("/")}`);
  }
  return resolved;
}

function isUnder(child, parent) {
  if (child === parent) return true;
  return child.startsWith(parent.endsWith("/") ? parent : `${parent}/`);
}

function looksLikePath(text) {
  return (
    text.startsWith("/") || text.startsWith("./") || text.startsWith("../") ||
    text === "." || text === ".." || text.startsWith("~") ||
    text.startsWith("$HOME") || text.startsWith("{") || text.includes("/")
  );
}

// ---- command analysis ----------------------------------------------------------

function classifyFlags(words) {
  const shortChars = new Set();
  const longs = new Set();
  const flags = [];
  for (const word of words.slice(1)) {
    const text = word.text;
    if (text.startsWith("--")) {
      longs.add(text.slice(2).split("=")[0]);
      flags.push(text);
    } else if (text.startsWith("-") && text.length > 1) {
      for (const ch of text.slice(1)) shortChars.add(ch);
      flags.push(text);
    }
  }
  return { shortChars, longs, flags };
}

function operandsOf(words) {
  const operands = [];
  for (let i = 1; i < words.length; i += 1) {
    if (!words[i].text.startsWith("-")) operands.push(words[i]);
  }
  return operands;
}

// Unwrap wrappers and one level of sh/bash/eval recursion. Returns the
// innermost simple commands plus every segment's redirect operations.
function analyzeCommand(command, cwd, home) {
  const simpleCommands = [];
  const allRedirects = [];
  let sudoSeen = false;

  const walk = (segments, depth) => {
    for (const segment of segments) {
      const { words, redirects } = tokenizeSegment(segment);
      if (redirects.length > 0) allRedirects.push(...redirects);
      if (words.length === 0) continue;
      let queue = words.slice();
      let segSudo = false;
      for (;;) {
        if (queue.length === 0) break;
        let argv0 = queue[0].text;
        if (argv0.startsWith("\\")) argv0 = argv0.slice(1);
        const base = basename(argv0);
        if (base === "sudo" || base === "doas") {
          segSudo = true;
          queue = queue.slice(1);
          continue;
        }
        if (WRAPPER_VERBS.has(base)) {
          queue = queue.slice(1);
          continue;
        }
        if (base === "env") {
          queue = queue.slice(1);
          while (queue.length > 0 && /^[A-Za-z_][A-Za-z0-9_]*=/.test(queue[0].text)) {
            queue = queue.slice(1);
          }
          continue;
        }
        if (base === "timeout") {
          queue = queue.slice(1);
          if (queue.length > 0 && !queue[0].text.startsWith("-")) queue = queue.slice(1);
          continue;
        }
        if (base === "nice") {
          queue = queue.slice(1);
          if (queue.length > 1 && queue[0].text === "-n") queue = queue.slice(2);
          continue;
        }
        if (base === "xargs") {
          queue = queue.slice(1);
          while (queue.length > 0 && queue[0].text.startsWith("-")) queue = queue.slice(1);
          continue;
        }
        if ((base === "sh" || base === "bash") && depth < 1 &&
          queue.slice(1).some((w) => /^-[a-zA-Z]*c/.test(w.text))) {
          const payload = queue.slice(1).filter((w) => !w.text.startsWith("-"))[0];
          if (payload) {
            walk(splitSegments(payload.text), depth + 1);
            queue = [];
            break;
          }
        }
        if (base === "eval" && depth < 1 && queue.length > 1) {
          const payload = queue.slice(1)[0];
          walk(splitSegments(payload.text), depth + 1);
          queue = [];
          break;
        }
        simpleCommands.push({ words: queue, sudoSeen: segSudo });
        break;
      }
      sudoSeen = sudoSeen || segSudo;
    }
  };

  walk(splitSegments(command), 0);
  return { simpleCommands, allRedirects, sudoSeen };
}

// Resolve every simple command's operands once and collect the resolved path
// operands that looked like paths in the source (for the screener annotation).
function resolveAnalysis(analysis, cwd, home, protectedPaths) {
  const commands = analysis.simpleCommands.map((cmd) => {
    const operands = operandsOf(cmd.words);
    const resolved = operands.flatMap((o) => resolveOperand(o.text, cwd, home));
    const anyProtected = resolved.some((p) => inProtectedSet(p, protectedPaths));
    return { cmd, operands, resolved, anyProtected };
  });
  const redirectTargets = analysis.allRedirects.map((redirect) => ({
    redirect,
    resolved: resolveOperand(redirect.target.text, cwd, home),
  }));
  const annotations = [];
  for (const entry of commands) {
    entry.cmd.words.forEach((word, index) => {
      if (index === 0 || word.text.startsWith("-")) return;
      if (looksLikePath(word.text)) annotations.push(...resolveOperand(word.text, cwd, home));
    });
  }
  return { commands, redirectTargets, annotations };
}

// ---- config ladders ------------------------------------------------------------

function readFloor(configDir) {
  try {
    const raw = readFileSync(join(configDir, "jev-gate-floor"), "utf8");
    const text = raw.replace(/\s/g, "");
    if (!/^[0-9.]+$/.test(text) || text.includes("..")) return 0.8;
    const value = Number(text);
    if (!Number.isFinite(value) || value < 0 || value > 1) return 0.8;
    return value;
  } catch {
    return 0.8;
  }
}

// ---- state store (counters, events, breaker, block shas) -----------------------

function existingLines(path) {
  try {
    return readFileSync(path, "utf8").split("\n").filter((l) => l.length > 0);
  } catch {
    return [];
  }
}

function extractSha(line) {
  const match = line.match(/"sha256":"([0-9a-f]{64})"/);
  return match ? match[1] : "0".repeat(64);
}

// The canonical hash covers the line with its own sha256 field emptied, so a
// reader can recompute it by string surgery alone.
function canonicalLine(object) {
  const withoutSha = { ...object, sha256: "" };
  const text = JSON.stringify(withoutSha);
  const digest = sha256Hex(text);
  return JSON.stringify({ ...withoutSha, sha256: digest });
}

class Store {
  constructor(stateDir) {
    this.dir = join(stateDir, "jev-gate");
    this.countersPath = join(this.dir, "counters");
    this.eventsPath = join(this.dir, "events.jsonl");
    this.breakerPath = join(this.dir, "breaker");
    this.blockShasPath = join(this.dir, "block-shas");
    this.lockPath = join(this.dir, ".lock");
    mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    chmodSync(this.dir, 0o700);
  }

  withLock(fn) {
    let acquired = false;
    for (let i = 0; i < 200 && !acquired; i += 1) {
      try {
        mkdirSync(this.lockPath, { mode: 0o700 });
        acquired = true;
      } catch {
        sleepMs(5);
      }
    }
    try {
      return fn();
    } finally {
      if (acquired) rmSync(this.lockPath, { force: true, recursive: true });
    }
  }

  bumpCounter(key, by = 1) {
    this.withLock(() => {
      const values = {};
      for (const k of COUNTER_KEYS) values[k] = 0;
      try {
        for (const line of readFileSync(this.countersPath, "utf8").split("\n")) {
          const [k, v] = line.split(" ");
          if (k in values && v) values[k] = Number(v);
        }
      } catch {}
      values[key] += by;
      const body = `${COUNTER_KEYS.map((k) => `${k} ${values[k]}`).join("\n")}\n`;
      const tmp = `${this.countersPath}.tmp`;
      writeFileSync(tmp, body, { mode: 0o600 });
      chmodSync(tmp, 0o600);
      renameSync(tmp, this.countersPath);
    });
  }

  readCounter(key) {
    try {
      for (const line of readFileSync(this.countersPath, "utf8").split("\n")) {
        const [k, v] = line.split(" ");
        if (k === key && v) return Number(v);
      }
    } catch {}
    return 0;
  }

  appendLine(line) {
    appendFileSync(this.eventsPath, `${line}\n`, { mode: 0o600 });
    try {
      chmodSync(this.eventsPath, 0o600);
    } catch {}
  }

  rotate() {
    const stamp = Date.now();
    let name = `events-${stamp}.jsonl`;
    let attempt = 0;
    while (existsSync(join(this.dir, name))) {
      attempt += 1;
      name = `events-${stamp}-${attempt}.jsonl`;
    }
    try {
      renameSync(this.eventsPath, join(this.dir, name));
    } catch {
      return;
    }
    const rotations = readdirSync(this.dir)
      .filter((n) => /^events-\d+.*\.jsonl$/.test(n))
      .sort((a, b) => (Number(a.match(/\d+/)[0]) - Number(b.match(/\d+/)[0])));
    while (rotations.length > EVENT_KEEP_ROTATIONS) {
      const oldest = rotations.shift();
      try {
        unlinkSync(join(this.dir, oldest));
      } catch {}
    }
  }

  recordEvent(fields) {
    this.withLock(() => {
      try {
        if (statSync(this.eventsPath).size >= EVENT_CAP_BYTES) this.rotate();
      } catch {}
      const lines = existingLines(this.eventsPath);
      if (lines.length === 0) {
        this.appendLine(canonicalLine({
          type: "chain-header",
          ts: new Date().toISOString(),
          seq: 0,
          prev_sha256: "0".repeat(64),
        }));
      }
      const current = existingLines(this.eventsPath);
      const prevSha = current.length > 0 ? extractSha(current[current.length - 1]) : "0".repeat(64);
      const event = {
        ts: new Date().toISOString(),
        seq: current.length,
        prev_sha256: prevSha,
        sha256: "",
        ...fields,
      };
      this.appendLine(canonicalLine(event));
    });
  }

  readBreaker() {
    try {
      const parsed = JSON.parse(readFileSync(this.breakerPath, "utf8"));
      return {
        consecutive_failures: Number(parsed.consecutive_failures) || 0,
        open_since: Number(parsed.open_since) || 0,
        cooldown_until: Number(parsed.cooldown_until) || 0,
      };
    } catch {
      return { consecutive_failures: 0, open_since: 0, cooldown_until: 0 };
    }
  }

  writeBreaker(state) {
    const tmp = `${this.breakerPath}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(state)}\n`, { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, this.breakerPath);
  }

  blockRepeat(sha) {
    let repeat = false;
    this.withLock(() => {
      let shas = [];
      try {
        shas = readFileSync(this.blockShasPath, "utf8").split("\n").filter((s) => s.length > 0);
      } catch {}
      if (shas.includes(sha)) {
        repeat = true;
      } else {
        shas.push(sha);
        while (shas.length > BLOCK_SHA_CAP) shas.shift();
        const tmp = `${this.blockShasPath}.tmp`;
        writeFileSync(tmp, `${shas.join("\n")}\n`, { mode: 0o600 });
        chmodSync(tmp, 0o600);
        renameSync(tmp, this.blockShasPath);
      }
    });
    return repeat;
  }
}

// ---- screener consult ----------------------------------------------------------

function screenerTimeouts() {
  let timeoutS = Number(process.env.FM_JEV_GATE_TIMEOUT_S ?? "");
  if (!Number.isFinite(timeoutS) || timeoutS <= 0) timeoutS = 3;
  let wallS = Number(process.env.FM_JEV_GATE_WALL_S ?? "");
  if (!Number.isFinite(wallS) || wallS <= 0) wallS = timeoutS + 5;
  return { timeoutMs: timeoutS * 1000, wallMs: wallS * 1000 };
}

function runScreener(inputText, cfg) {
  return new Promise((resolveResult) => {
    const screener =
      process.env.FM_JEV_COMMAND_SCREENER || join(cfg.root, "bin", "fm-jev-command-screen.sh");
    const { timeoutMs, wallMs } = screenerTimeouts();
    const truncated = Buffer.byteLength(inputText, "utf8") > SCREENER_INPUT_CAP_BYTES;
    let fileText = inputText;
    if (truncated) {
      fileText = Buffer.from(inputText, "utf8").subarray(0, SCREENER_INPUT_CAP_BYTES).toString("utf8");
    }
    const tmp = join(tmpdir(), `jev-gate-input-${process.pid}-${Math.random()}`);
    writeFileSync(tmp, fileText, { mode: 0o600 });
    let child;
    let settled = false;
    let timer = null;
    let alarm = null;
    let timedOut = false;
    let alarmed = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (alarm) clearTimeout(alarm);
      try {
        rmSync(tmp, { force: true });
      } catch {}
      resolveResult(result);
    };
    const killGroup = () => {
      if (!child || child.pid === undefined) return;
      try {
        process.kill(-child.pid, "SIGTERM");
      } catch {}
      setTimeout(() => {
        try {
          process.kill(-child.pid, "SIGKILL");
        } catch {}
      }, 300).unref();
    };
    try {
      child = spawn(screener, [tmp], {
        stdio: ["ignore", "pipe", "pipe"],
        detached: true,
      });
    } catch {
      finish({ outcome: "error" });
      return;
    }
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => finish({ outcome: "error" }));
    child.on("close", (code) => {
      if (alarmed) {
        finish({ outcome: "alarm" });
        return;
      }
      if (timedOut) {
        finish({ outcome: "timeout" });
        return;
      }
      if (code !== 0) {
        finish({ outcome: "error" });
        return;
      }
      if (stdout.trim().length === 0 && stderr.trim().startsWith("command: off")) {
        finish({ outcome: "off" });
        return;
      }
      const status = stdout.match(/^ {2}status: (.*)$/m)?.[1]?.trim();
      const choice = stdout.match(/^ {2}choice: (.*)$/m)?.[1]?.trim();
      const confidence = Number(stdout.match(/^ {2}confidence: ([0-9.]+)$/m)?.[1]);
      if (status !== "clear" || !choice || !Number.isFinite(confidence) ||
        !CHOICE_VOCABULARY.has(choice)) {
        finish({ outcome: "error" });
        return;
      }
      finish({ outcome: "clear", choice, confidence, });
    });
    timer = setTimeout(() => {
      timedOut = true;
      killGroup();
    }, timeoutMs);
    timer.unref();
    alarm = setTimeout(() => {
      alarmed = true;
      timedOut = true;
      killGroup();
    }, wallMs);
    alarm.unref();
  });
}

// ---- protected set -------------------------------------------------------------

function buildProtectedPaths(fmHome, home) {
  const fmResolved = resolve(fmHome);
  const exact = new Set(["/", fmResolved, home]);
  const prefix = [
    ...SYSTEM_ROOTS,
    `${fmResolved}/.env`,
    ...FM_PROTECTED_CHILDREN.map((child) => `${fmResolved}/${child}`),
    ...HOME_PROTECTED_CHILDREN.map((child) => `${home}/${child}`),
  ].map((p) => resolve(p));
  return { exact, prefix };
}

function inProtectedSet(path, protectedPaths) {
  if (protectedPaths.exact.has(path)) return true;
  return protectedPaths.prefix.some((p) => isUnder(path, p));
}

// ---- markers -------------------------------------------------------------------

function findMarker(cmds, analysis, primaryCwd, cwd, home, protectedPaths) {
  for (const entry of cmds) {
    const { cmd, resolved, anyProtected } = entry;
    const words = cmd.words;
    const argv0 = basename(words[0].text);
    const { longs, flags } = classifyFlags(words);
    const fmName = argv0.replace(/\.sh$/, "");

    if (analysis.sudoSeen || cmd.sudoSeen) return "sudo";
    if (["rm", "rmdir", "unlink", "mv", "cp", "ln", "chmod", "chown", "chgrp",
      "kill", "pkill", "killall"].includes(argv0)) return argv0;
    if (argv0 === "dd" && words.some((w) => w.text.startsWith("of="))) return "dd";
    if (["truncate", "shred"].includes(argv0) && words.length > 1 && !anyProtected) return argv0;
    if (argv0 === "tee" && words.length > 1 &&
      words.slice(1).some((w) => !w.text.startsWith("-"))) return "tee";
    if (argv0 === "sed" && flags.some((f) => f === "-i" || /^-i[^-]/.test(f) ||
      f === "--in-place" || f.startsWith("--in-place="))) return "sed -i";
    if (argv0 === "find" && (words.some((w) => w.text === "-delete") ||
      words.some((w, i) => (w.text === "-exec" || w.text === "-execdir") &&
        ["rm", "unlink"].includes(words[i + 1]?.text)))) return "find";
    if (argv0 === "rsync" && longs.has("delete")) return "rsync";
    if (argv0 === "btrfs" &&
      ((words[1]?.text === "subvolume" && words[2]?.text === "delete") ||
        (words[1]?.text === "device" && words[2]?.text === "remove"))) return "btrfs";
    if (argv0 === "git" && words[1]?.text === "push") return "git push";
    if (argv0 === "git" &&
      ((words[1]?.text === "reset" && longs.has("hard")) ||
        (words[1]?.text === "clean" && words.slice(2).some((w) => /^-f|^--force/.test(w.text)))) &&
      !primaryCwd) return "git discard";
    if (argv0 === "git" && words[1]?.text === "checkout" &&
      words.slice(2).some((w) => w.text === "--")) return "git checkout --";
    if (argv0 === "git" && words[1]?.text === "restore") return "git restore";
    if (fmName === "fm-teardown") return "fm-teardown";
    if (fmName.startsWith("fm-") &&
      flags.some((f) => ["--force", "--discard", "--allow-red"].includes(f))) return fmName;
    if (resolved.length > 0 && argv0 === "sh" && false) return "shell-file";
  }
  const argv0s = cmds.map((c) => basename(c.cmd.words[0].text));
  const downloaders = argv0s.filter((a) => ["curl", "wget"].includes(a));
  const shells = argv0s.filter((a) => ["sh", "bash", "zsh", "dash", "ksh"].includes(a));
  if (downloaders.length > 0 && shells.length > 0) return "pipe-to-shell";
  return null;
}

function eventCmd(command) {
  const bytes = Buffer.from(command, "utf8");
  const capped = bytes.length <= CMD_EVENT_CAP_BYTES
    ? command
    : bytes.subarray(0, CMD_EVENT_CAP_BYTES).toString("utf8");
  return redactSecrets(capped);
}

function redactSecrets(text) {
  return text
    .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=~-]{6,}/g, "$1 [REDACTED]")
    .replace(/(authorization[ :]{1,3})\S+/gi, "$1[REDACTED]");
}

function buildScreenerInput(command, annotations) {
  const unique = [...new Set(annotations.filter((p) => p.length > 0))];
  if (unique.length === 0) return command;
  return `${command}\nresolved path operands: ${unique.join(" ")}`;
}

// ---- consult failure / breaker -------------------------------------------------

function recordConsultFailure(store, cmdSha, command) {
  const breaker = store.readBreaker();
  const failures = breaker.consecutive_failures + 1;
  if (failures >= BREAKER_FAILURE_THRESHOLD && breaker.cooldown_until <= Date.now()) {
    store.writeBreaker({
      consecutive_failures: failures,
      open_since: Date.now(),
      cooldown_until: Date.now() + BREAKER_COOLDOWN_MS,
    });
    store.bumpCounter("jev_degraded");
    store.recordEvent({
      stage: "jev",
      event: "breaker_open",
      cmd_sha256: cmdSha,
      cmd: eventCmd(command),
    });
    return;
  }
  store.writeBreaker({ ...breaker, consecutive_failures: failures });
}

// ---- audit record action (override lifecycle events; confers no authority) -----

function recordOverride(cfg) {
  const store = new Store(cfg.state);
  const event = cfg.record === "open" ? "override_open"
    : cfg.record === "close" || cfg.record === "expire" ? "override_close"
    : null;
  if (!event) return;
  if (cfg.record === "open") store.bumpCounter("override_opened");
  if (cfg.record === "expire") store.bumpCounter("override_expired");
  store.recordEvent({
    stage: "override",
    event,
    cmd_sha256: sha256Hex(cfg.reason || cfg.record),
    cmd: eventCmd(cfg.reason || cfg.record),
  });
}

// ---- main evaluation -----------------------------------------------------------

async function main() {
  const cfg = parseArgs(process.argv.slice(2));
  if (cfg.record) {
    recordOverride(cfg);
    return;
  }
  const command = readFileSync(0, "utf8");
  const cmdSha = sha256Hex(command);
  const cwd = process.cwd();
  const home = homedir();
  const posture = cfg.posture === "shadow" ? "shadow" : "enforce";
  const store = new Store(cfg.state);
  const floor = readFloor(cfg.config);
  const protectedPaths = buildProtectedPaths(cfg.home, home);

  const rawBytes = Buffer.byteLength(command, "utf8");
  const emit = (fields) =>
    store.recordEvent({
      posture,
      cmd_sha256: cmdSha,
      cmd: eventCmd(command),
      ...(rawBytes > CMD_EVENT_CAP_BYTES ? { truncated: true } : {}),
      ...fields,
    });

  if (command.trim().length === 0) {
    process.stdout.write("allow\tok\tcommand allowed\n");
    return;
  }

  const analysis = analyzeCommand(command, cwd, home);
  const primaryCwd = isUnder(resolve(cwd), resolve(cfg.root));
  const resolved = resolveAnalysis(analysis, cwd, home, protectedPaths);

  // R-catalog: deterministic blocks at confidence 1.00. Under an open override
  // window every hit becomes a logged pass instead of a block.
  const regexHit = findRegexHit(resolved, protectedPaths, primaryCwd);
  if (regexHit) {
    if (cfg.overrideActive) {
      store.bumpCounter("override_pass");
      store.bumpCounter("overridden_block");
      emit({ stage: "override", event: "override_pass", would_be: "regex", overridden: true });
      process.stdout.write("allow\tok\tcommand allowed\n");
      return;
    }
    store.bumpCounter("block_regex");
    if (store.blockRepeat(cmdSha)) store.bumpCounter("block_repeat");
    emit({ stage: "regex", event: posture === "shadow" ? "would_block" : "block", pattern: regexHit.code });
    if (posture === "shadow") {
      process.stdout.write("allow\tok\tcommand allowed\n");
    } else {
      process.stdout.write(`block\t${regexHit.code}\t${regexHit.reason}\n`);
    }
    return;
  }

  const marker = findMarker(resolved.commands, analysis, primaryCwd, cwd, home, protectedPaths);

  if (cfg.overrideActive) {
    if (marker) {
      store.bumpCounter("override_pass");
      emit({ stage: "override", event: "override_pass", would_be: "unknown-consult-skipped", overridden: true });
    } else {
      store.bumpCounter("allow_free");
    }
    process.stdout.write("allow\tok\tcommand allowed\n");
    return;
  }

  if (!marker) {
    const normalized = normalizeBytes(command);
    if (NEAR_MISS_TOKENS.some((token) => normalized.includes(token))) {
      store.bumpCounter("near_miss");
      emit({ stage: "near-miss", event: "near_miss" });
    }
    store.bumpCounter("allow_free");
    process.stdout.write("allow\tok\tcommand allowed\n");
    return;
  }

  // Cached verdict shortcut (the seat's per-session decision cache).
  if (cfg.cachedChoice && CHOICE_VOCABULARY.has(cfg.cachedChoice) && cfg.cachedConfidence !== null) {
    applyVerdict(store, posture, cmdSha, command, cfg.cachedChoice, cfg.cachedConfidence, floor, emit);
    return;
  }

  const breaker = store.readBreaker();
  if (breaker.consecutive_failures >= BREAKER_FAILURE_THRESHOLD &&
    breaker.cooldown_until > Date.now()) {
    store.bumpCounter("jev_degraded");
    emit({ stage: "jev", event: "degraded" });
    process.stdout.write("allow\tok\tcommand allowed\n");
    return;
  }

  const screenerInput = buildScreenerInput(command, resolved.annotations);
  const result = await runScreener(screenerInput, cfg);
  if (result.outcome === "timeout") {
    store.bumpCounter("jev_timeout");
    emit({ stage: "jev", event: "timeout" });
    process.stdout.write("allow\tok\tcommand allowed\n");
    return;
  }
  if (result.outcome === "alarm") {
    emit({ stage: "jev", event: "error", reason: "self-alarm wall clock hit" });
    process.stdout.write("error\tjev-gate-error\tthe gate evaluation exceeded its wall-clock bound\n");
    return;
  }
  if (result.outcome === "off") {
    store.bumpCounter("jev_off");
    emit({ stage: "jev", event: "off" });
    process.stdout.write("allow\tok\tcommand allowed\n");
    return;
  }
  if (result.outcome !== "clear") {
    emit({ stage: "jev", event: "error" });
    recordConsultFailure(store, cmdSha, command);
    store.bumpCounter("jev_error");
    process.stdout.write("allow\tok\tcommand allowed\n");
    return;
  }

  const breakerNow = store.readBreaker();
  if (breakerNow.consecutive_failures >= BREAKER_FAILURE_THRESHOLD) {
    store.writeBreaker({ consecutive_failures: 0, open_since: 0, cooldown_until: 0 });
    emit({ stage: "jev", event: "breaker_close" });
  }

  applyVerdict(store, posture, cmdSha, command, result.choice, result.confidence, floor, emit);
}

function findRegexHit(resolved, protectedPaths, primaryCwd) {
  for (const entry of resolved.commands) {
    const words = entry.cmd.words;
    const argv0 = basename(words[0].text);
    const { shortChars, longs } = classifyFlags(words);
    const anyProtected = entry.anyProtected;

    if (argv0 === "rm" &&
      ((shortChars.has("r") && shortChars.has("f")) ||
        (shortChars.has("r") && longs.has("force")) ||
        (longs.has("recursive") && shortChars.has("f")) ||
        (longs.has("recursive") && longs.has("force"))) && anyProtected) {
      const operand = entry.resolved.find((p) => inProtectedSet(p, protectedPaths)) ?? "/";
      return {
        code: "rm-protected",
        reason: `[JG-R1] rm -rf against a protected path (${operand}) — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).`,
      };
    }
    if (argv0 === "git" && words[1]?.text === "push") {
      const force = longs.has("force") || words.slice(2).some((w) => w.text === "-f");
      const refspec = entry.operands.some((o) => o.text.startsWith("+"));
      if (force || refspec) {
        return {
          code: "git-push-force",
          reason: "[JG-R2] forced git push — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).",
        };
      }
    }
    if (argv0 === "dd") {
      const sink = words.map((w) => w.text).find((t) => t.startsWith("of="));
      if (sink) {
        const target = sink.slice(3);
        const carveOut = ["/dev/null", "/dev/stdout", "/dev/stderr"].includes(target);
        if (target.startsWith("/dev/") && !carveOut) {
          return {
            code: "dd-device",
            reason: `[JG-R3] dd write to a device (${target}) — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).`,
          };
        }
      }
    }
    if (argv0.startsWith("mkfs") || argv0 === "mke2fs") {
      return {
        code: "mkfs",
        reason: "[JG-R4] filesystem creation — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).",
      };
    }
    if (["wipefs", "blkdiscard"].includes(argv0) ||
      (["fdisk", "sfdisk", "parted", "gdisk", "sgdisk"].includes(argv0) &&
        entry.resolved.some((p) => p.startsWith("/dev/")))) {
      return {
        code: "partition-write",
        reason: "[JG-R5] partition-table write — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).",
      };
    }
    if (argv0 === "chmod" && (shortChars.has("R") || longs.has("recursive")) &&
      words.some((w) => w.text === "777" || w.text === "000") && anyProtected) {
      return {
        code: "chmod-recursive-root",
        reason: "[JG-R6] recursive permission rewrite on a protected path — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).",
      };
    }
    if (["shred", "truncate"].includes(argv0) && anyProtected) {
      return {
        code: "overwrite-protected",
        reason: "[JG-R8] overwrite of a protected path — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).",
      };
    }
    if (["shutdown", "reboot", "halt", "poweroff"].includes(argv0) ||
      (argv0 === "systemctl" && ["poweroff", "reboot"].includes(words[1]?.text)) ||
      (argv0 === "init" && ["0", "6"].includes(words[1]?.text))) {
      return {
        code: "power-op",
        reason: "[JG-R9] power state change — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).",
      };
    }
    if (argv0 === "git" &&
      ((words[1]?.text === "reset" && longs.has("hard")) ||
        (words[1]?.text === "clean" && words.slice(2).some((w) => /^-f|^--force/.test(w.text)))) &&
      primaryCwd) {
      return {
        code: "git-discard-primary",
        reason: "[JG-R10] discard-shaped git operation in the primary checkout — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).",
      };
    }
  }
  for (const entry of resolved.redirectTargets) {
    if (!entry.redirect.op.includes(">")) continue;
    const hit = entry.resolved.find((p) => inProtectedSet(p, protectedPaths));
    if (hit) {
      return {
        code: "redirect-protected",
        reason: `[JG-R7] output redirection into a protected path (${hit}) — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).`,
      };
    }
  }
  return null;
}

function applyVerdict(store, posture, cmdSha, command, choice, confidence, floor, emit) {
  if (choice === "destructive" && confidence >= floor) {
    store.bumpCounter("block_jev");
    if (store.blockRepeat(cmdSha)) store.bumpCounter("block_repeat");
    const reason = `[JG-J1] classified destructive (confidence: ${confidence.toFixed(2)}, floor: ${floor.toFixed(2)}) — blocked by the Jev damage-control gate (stage: jev).`;
    if (posture === "shadow") {
      emit({ stage: "jev", event: "would_block", choice, confidence, floor });
      process.stdout.write("allow\tok\tcommand allowed\n");
    } else {
      emit({ stage: "jev", event: "block", choice, confidence, floor });
      process.stdout.write(`block\tjev-destructive\t${reason}\n`);
    }
    process.stdout.write(`cache\t${choice}\t${confidence}\n`);
    return;
  }
  if (choice === "destructive") {
    store.bumpCounter("low_confidence_pass");
    emit({ stage: "jev", event: "low_confidence", choice, confidence, floor });
    process.stdout.write("allow\tok\tcommand allowed\n");
    process.stdout.write(`cache\t${choice}\t${confidence}\n`);
    return;
  }
  const counterKey = {
    benign: "consult_benign",
    "grey-reversible": "consult_grey",
    uncertain: "consult_uncertain",
  }[choice];
  if (counterKey) store.bumpCounter(counterKey);
  emit({ stage: "jev", event: "allow", choice, confidence, floor });
  process.stdout.write("allow\tok\tcommand allowed\n");
  process.stdout.write(`cache\t${choice}\t${confidence}\n`);
}

main().catch(() => {
  process.stdout.write("error\tjev-gate-error\tunexpected policy failure\n");
});
