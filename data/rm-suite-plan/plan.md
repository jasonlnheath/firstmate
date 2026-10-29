# Resource Monitor Suite — Design Plan

**Date:** 2026-10-29 · **Author:** scout worker (rm-suite-plan) · **Status:** proposal for captain review
**Trigger:** the silent menu-failure incident (Strata held 12.9GB of a 16GB card; the Omarchy menu could not create a graphics context and failed silently).

---

## 0. Executive summary — the captain's questions, answered

| Question | Answer |
|---|---|
| Does Omarchy give us the monitoring skills we need, or build our own? | **Split.** Omarchy (quickshell) gives us the platform — bar-widget API and the desktop notification service — and our own Mount Monitor already proves the pattern. It ships **no** RAM or VRAM bar visualizer, and no pressure-aware alerting. We build two widgets in Mount Monitor's image and extend Mount Monitor itself; no new daemons are needed. |
| Desktop toast at hardware limits? | Yes — `notify-send` into Omarchy's notification service (actions, persisted history, critical persistence all proven by Mount Monitor v1), with **Dial Strata down / Pause Strata / Dismiss** choice buttons on pressure toasts. Crucially, toasts are blind when the shell itself is the victim (the incident), so the **fleet-side VRAM check remains the guaranteed channel**; both are kept. |
| RAM thresholds / standards? | No universal standard exists, but the kernel ships the right signals: **MemAvailable** (not used%) and **PSI memory pressure**. The closest published default is systemd-oomd's (verified in systemd source): memory pressure ≥ 60% sustained 30s → kill. We propose available-anchored bands 15%/5% with PSI escalators at 2%/10% (§4.2). |
| VRAM thresholds? | No standard exists (no kernel PSI for VRAM). Bands in **absolute free MiB**, anchored to measured desktop appetite on this rig: green ≥ 2500, amber 1200–2499, red < 1200 (= the fleet-check floor, 2× the ~600MiB incident kill line), with the **GL-context-failure journal signature** as an always-fire escalation trigger (§4.3). |
| Disk? | Keep the shipped 80/90/98 convention; add the new VU-meter colors on top (§4.1). |
| Who yields under pressure? | Captain's ruling: **OS/desktop first, Strata yields**. Ladder: raise Strata's VRAM reserve → pause Strata → suggest other lanes (never auto-kill). Auto-**relax** toward baseline when pressure stays clear (reversible, informational toast); **ask-on-tighten** (captain chooses at pressure) (§6). |
| One design? | One **RingKit** design module — shared palette, ring painter, icon badges, band/hysteresis logic, tooltip builder — shipped as a compatible **Mount Monitor v2** plus two new sibling plugins (§3, §5). |

---

## 1. Live rig evidence (measured today, 2026-10-29)

Everything below was read off the machine; the plan's numbers are anchored to it.

### RAM
- 62Gi total; `used` 58Gi; **MemAvailable 4.1Gi (6.6%)**; buff/cache only 5.2Gi.
- **PSI memory `some`/`full`: 0.00 across avg10/60/300** — the kernel reports zero stall pressure *right now*, while raw used% would read 94% alarm.
- Swap: zram0 119Mi used (prio 100) + 62.6G swapfile untouched; swappiness 10.
- **Top consumer is Strata: the engine's RSS is 46Gi = 70% of RAM** (pid 1858, `--vram-elastic --kv-resident 32768 --kv int8 --expert-cache auto`). Then a QtWebEngine renderer (2.3Gi), the desktop `paris-layer` (1.6Gi), `strata-vision` (975Mi).
- No systemd-oomd (`systemd-oomd.service could not be found`), no earlyoom — **the OS has no memory-pressure guard at all**; our monitor + agent are the guard.

### VRAM
- RTX 5070 Ti, 16303MiB total; **free 1856MiB**.
- Consumers: `strata` 11402MiB; **`paris-layer` (the desktop shell) 1818MiB**; `voxtype-osd` 12MiB.
- Incident kill line: menu GL-context failure **below ~600MiB free**.
- Fleet check `state/vram.check.sh` (live, tier-1): floor **1200MiB** + fresh GL-context-failure signature from the user journal, slow-poll 300s.
- Strata elasticity: `POST /v1/vram reserve_mib` (confirmed endpoint); **config JSON says 2000 but the running process was launched with `--vram-reserve-mib 1500`** — a live config drift the doctrine must handle (§6.4). Note also: free (1856) sits *below* the configured reserve (2000) — **the reserve is a soft target, not a hard guarantee**, and the monitor must not assume it is enforced.

### Platform
- Kernel 7.2.11-1-cachyos-bore; `/proc/pressure/{memory,io,cpu}` live and populated.
- Notification surface: `notify-send` → Omarchy's notification service hosted by quickshell (pid 2238, `/usr/share/omarchy/shell`). Mount Monitor v1 proves actions, exec hints, persisted history, and never-expiring criticals all work through it.
- Mount Monitor v1 (`io.github.jasonlnheath.mount-monitor`): rings with bright used-arc + dim available track, **percentage text in the center** (to be replaced by the icon badge), 60s poll, 80/90/98 bands in testable `mounts.js`, tooltip builder, alert queue with severity dedup, `primed` baseline logic (no re-toast of existing bands on restart), untrusted-device-data discipline for agent prompts, and a `tests/run.sh` node:test rig.

---

## 2. Design language — one ring, one badge, one palette

Every resource gets **one ring**: bright arc = used fraction, dim full ring = available track, exactly as Mount Monitor draws today. Changes:

1. **No percentage text anywhere on the ring.** The center instead holds an **icon badge** identifying the resource:
   - Disk → drive glyph (e.g. `nf-md-hard_disk`)
   - RAM → memory-chip glyph (e.g. `nf-md-memory`)
   - VRAM → GPU-card glyph (e.g. `nf-md-expansion_card`)
   Exact glyphs picked from Omarchy's icon set at implementation; they must be visually distinct at 22px optical size.
2. **Color carries the state; the badge carries the identity.** The whole arc takes the band color the moment the band is entered (VU-meter behavior: green → yellow → red as thresholds pass), rather than coloring only the segment beyond the threshold — at bar scale, band-wide color is legible, segmented color is mush. Faint **threshold tick marks** at the resource's amber/red fractions keep the DB-meter mental model visible ("how far into the band am I"). *Rejected alternative:* segmented arc coloring — offered again at popup scale if the captain misses it.
3. **One shared palette** (RingKit tokens, proposed):
   - Green `#4ade80` — nominal
   - Amber `#fbbf24` — guardrail territory: surfaced, choice offered
   - Red `#ff2d2d` — Mount Monitor v1's existing `alertRed`, kept for continuity
   - Red + 0.5 Hz pulse + soft halo — emergency (v1's critical treatment, reused verbatim)
   Track/arc alphas inherited from v1 (0.25 track, 1.0 used; pulse modulated when critical).
4. **Hover tooltip carries the detail** (the captain's "percentage used, what's available, etc."):
   - Common: resource name + band word, used/total and available in absolute units, percentage.
   - RAM adds: PSI `some`/`full` avg60 line.
   - VRAM adds: current Strata reserve (read live) and top GPU consumers.
   - Disk keeps its existing tooltip (mount, %, used, free, fstype, read-only) — v2 changes presentation, not content.
5. **Icons + color are redundant coding**: color-blind users still get the pulse (red state) and distinct glyphs; the tooltip always carries numbers in text.

---

## 3. Shipping shape: Mount Monitor v2 + two new siblings, one RingKit

### The one-plugin-or-three decision

Mount Monitor is a **shipped marketplace plugin** (`io.github.jasonlnheath.mount-monitor`, marketplace: `omacom/omarchy-plugin-marketplace`). Marketplace facts (verified from the marketplace repo): one public GitHub repo per plugin; installs clone mutable upstream HEAD; updates go through the verify-plugin flow (listed-snapshot SHA or newer upstream commit passing compatibility validation + Automated Security Baseline + maintainer approval); a new listing needs a fresh exact-commit scan and explicit `approved-and-verified`.

**Recommendation: three plugins sharing one RingKit.**

- **Mount Monitor v2** — a *compatible upgrade* of the existing repo and id: same settings schema (additive only: colors, icon, optional threshold overrides), same 80/90/98 bands (`bandFor` untouched), new palette + icon badge replacing the % text. Ship via the newer-commit verify path.
- **RAM Monitor** (`io.github.jasonlnheath.ram-monitor`) and **VRAM Monitor** (`io.github.jasonlnheath.vram-monitor`) — new submissions, each a self-contained repo (installs clone repo HEAD, so nothing may be imported across installed plugins).
- **RingKit is a single source of truth**: the pure-decision module (palette tokens, band resolver, hysteresis state machine, ring-paint parameters, tooltip builder — the `mounts.js` pattern: plain top-level functions, `node:vm` testable, no imports) lives in the Mount Monitor repo's test rig and is **vendored into the sibling repos at release by a sync script**, with each repo's tests pinning the vendored copy against drift. Consistency by construction; each plugin still verifies and installs independently.
- **Why not one combined plugin:** folding RAM/VRAM into Mount Monitor silently changes the scope of a plugin marketplace users installed as a disk monitor; it couples unrelated monitors' bugs and review surface; and it blocks independent enablement/placement. The captain's "one design" requirement is satisfied by RingKit, not by bundling.

---

## 4. Thresholds and standards

### 4.1 Disk — keep the shipped convention, add color

Bands stay **80 / 90 / 98** (`bandFor` unchanged; the convention the plugin already ships, and a common ops convention elsewhere). New color mapping, applied identically across all three resources:

| Band | Color | Signal |
|---|---|---|
| < 80 | green | nominal |
| 80–89 | amber | warn (v1 thickened the stroke; v2 colors it) |
| 90–97 | red | critical |
| 98+ | red + pulse + halo | emergency (v1's treatment, kept) |

### 4.2 RAM — available-memory anchored, PSI escalated

**Standards answer, honestly stated:** there is no single universal standard for "when is RAM yellow". Raw used% is not a standard — it is the known-misleading signal (page cache/`Inactive` anon pages make used% read ~94% while the kernel reports zero stalls, exactly today's rig). The kernel's own documented signals are:

- **MemAvailable** (`/proc/meminfo`; kernel `proc.rst`): "an estimate of how much memory is available for starting new applications, without swapping" — introduced precisely because used% misleads.
- **PSI** (`/proc/pressure/memory`; kernel `psi.rst`, since 4.20): `some` = at least one task stalled on memory; `full` = all non-idle tasks stalled simultaneously; avg10/60/300 windows. This is the kernel's own definition of *memory pressure*, independent of cache accounting.
- **Closest published threshold default** (verified in systemd's source, `src/oom/oomd.conf`): systemd-oomd kills under cgroup memory pressure ≥ **60%** sustained **30s** (also `SwapUsedLimit=90%`). **systemd-oomd is not installed on this rig** — nothing consumes these signals at OS level today; our widget gives the numbers a human (and the agent) can act on. Prior art for banded availability: Android's `lmkd` kills by availability bands rather than used%.

**Proposed bands (defaults, all settings-tunable):** primary signal = available% of total RAM; escalators = PSI.

| Band | Condition |
|---|---|
| green | available ≥ 15% **and** `some` avg60 < 2% |
| amber | available < 15% **or** `some` avg60 ≥ 2% |
| red | available < 5% **or** `some` avg60 ≥ 10% **or** `full` avg60 ≥ 1% |
| red + pulse | `full` avg60 ≥ 10% or available < 2% (imminent OOM territory) |

Rationale: availability answers "is the desktop about to starve"; PSI answers "is anything actually suffering". Either alone lies — availability alone cries wolf when cache dips; PSI alone can miss a slow squeeze with no stalls yet.

**Honest note, flagged for the captain:** on this rig, *baseline-with-Strata is amber* (6.6% available today, PSI quiet). That is arguably correct — 46Gi committed to Strata *is* a hardware-allocation fact the captain said he wants surfaced — but it means the amber band fires once per boot. Mitigations: one-toast-per-band-ascent-per-boot (§5.3), and §8's open question offers a stall-anchored alternative (amber only when PSI moves) if he prefers a quieter idle. The widget will show amber-at-idle as fact, not noise, because the toast names the consumer (Strata, 46Gi) and the lever (§6.3).

**Never:** "drop caches" as a remedy (MemAvailable already nets reclaimable cache in), and page cache is never the enemy — Strata's RSS is the consumer.

### 4.3 VRAM — absolute free MiB, GL-signature escalation

No kernel PSI exists for VRAM, and percentage is the wrong primary for a **fixed** card whose consumer (the desktop's GL contexts) has an **absolute** appetite. Bands are therefore in **absolute free MiB**, anchored to this rig:

| Band | Free VRAM | Anchor |
|---|---|---|
| green | ≥ 2500 MiB | reserve (2000) + ~500 desktop slack |
| amber | 1200–2499 MiB | below the reserve target → guardrail territory, choice offered |
| red | < 1200 MiB | **equals the live fleet-check floor**, 2× the ~600MiB incident kill line |
| red + pulse | < 700 MiB | inside the incident's kill margin |
| **any → red toast + agent wake** | GL-context-failure signature in the user journal | the silent killer itself; fires regardless of what the counter says |

The GL signature reuses the fleet check's journal pattern (`Failed to create graphics context | Failed to create RHI | eglError`), tightened to context-creation failures where possible (`eglError` alone over-fires — see §7), with the same cursor-marker dedupe.

Ring fill still shows the used fraction (visual consistency with the other two rings), but the **band color derives from free MiB**; the tooltip carries both plus the live reserve.

---

## 5. Notification model

### 5.1 Surface

`notify-send` → Omarchy's notification service (quickshell-hosted). Mount Monitor v1 already exercises every feature we need: action buttons, the exec-hint + libnotify dual click path (survives shell restart via persisted history), urgency levels, never-expiring criticals, one-alert-at-a-time queueing with severity dedup, and the `primed` baseline rule (a shell restart does not re-toast every already-amber resource; true emergencies always fire).

### 5.2 Toast anatomy

- **Title:** `<icon> RAM crossed into amber` / `VRAM critical: 980MiB free` (resource + band + headline number).
- **Body:** the numbers (available, total, percentage; PSI line for RAM; reserve line for VRAM) + **top consumers** (top-3 by RSS or GPU allocation).
- **Choice buttons** (the captain's pause/shrink/dismiss), agent-mediated rather than widget-executed:
  - amber: `[Dial Strata down]` `[Dismiss]`
  - red: `[Dial Strata down]` `[Pause Strata]` `[Dismiss]`
  - GL-signature red: `[Pause Strata]` `[Dismiss]`, never-expiring critical.
- Buttons launch the v1 `agentCommand` pattern: a typed prompt naming the resource, its numbers, the suggested ladder rung and exact knob (e.g. "raise Strata VRAM reserve to 3000MiB via POST /v1/vram"), with consumer names carried as a delimited **explicitly untrusted data block** (v1's device-data discipline — process names come from `/proc` and nvidia-smi and are written by whoever ran them). **The agent performs the API call, not the widget** — this keeps the control plane out of a marketplace plugin and matches "no new control-plane daemons".

### 5.3 Dedup, hysteresis, fatigue

- Toast on **band ascent only**; once per ascent per boot; re-arm only after a genuine descent (with §7's hysteresis margins).
- Ring color tracks continuously; toasts do not.
- Amber-at-idle-with-Strata is expected on this rig (§4.2); ascent-only firing plus the consumer/lever in the body is what keeps it information rather than noise.

### 5.4 Composition with the firstmate pipeline

`state/vram.check.sh` stays exactly as it is — **and that is the point**: during the incident, the shell itself was the victim, so **in-shell toasts cannot fire in precisely the worst case**. The fleet check runs outside the shell and is the only guaranteed channel; the widget toast is the healthy-shell convenience with choice buttons. Therefore:

- Keep both channels independent — **no cross-suppression** (independent failure domains; suppression would couple the widget's death to the guard's silence).
- Align thresholds: widget red band = check floor (1200MiB); identical GL signature. Double delivery on the same event is accepted and documented; the agent dedupes logically (if already handling, it responds calmly).
- Same pattern extends naturally if the captain wants RAM wakes in the fleet too (a `ram.check.sh` reading the same bands) — noted as optional follow-up, not proposed now.

---

## 6. Priority and elasticity doctrine — "who yields"

**Captain's ruling: OS/desktop first; Strata is the natural yield lever.**

### 6.1 VRAM yield ladder (on amber/red)

1. **Raise Strata's reserve** — `POST /v1/vram reserve_mib` (the one confirmed endpoint): amber → propose 3000; red → propose 4000. Raising the reserve dials Strata *down*; it is reversible and surgical. Applied by the agent via the toast button, or directly by the captain.
2. **Pause Strata** — unload/stop the engine (the bigger hammer; agent-mediated; exact command outside plugin scope).
3. **Other lanes** — named non-essential consumers (browser renderers etc.): *suggest only, in the toast/agent*, **never auto-kill** (scope note §8).

### 6.2 Relief ladder (auto-relax, informational only)

When free VRAM holds ≥ 3000 MiB for a sustained window (10 min) with no GL signature:

- Lower the reserve back toward its baseline (2000) in **one step**.
- **Informational toast**: "Guardrail eased: Strata reserve back to 2000MiB."
- Clamps: relax only toward the recorded pre-pressure baseline, never below it; one relaxation per pressure window; never while a GL signature fired in the window; **auto-relax never auto-tightens** — tightening is always the captain's choice at pressure (ask-on-tighten per his words).

Executor: the agent via the toast flow when present; the same clamp rules are what make agent-mediated relax safe when the captain is away. (If the captain later wants fully unattended relax, that is a bounded fleet-check extension — deliberately *not* proposed here to keep scope tight.)

### 6.3 RAM side

- Strata's 46Gi RSS is **deliberate residency**, not a leak: the monitor surfaces it as the top consumer; the doctrine's lever list for RAM relief lives in Strata's own knobs visible on the running process (`--kv-resident`, `--expert-cache`) — **endpoints not yet confirmed** (§8, open question), so RAM relief actions stay agent-mediated with a "confirm Strata's RAM knob" step rather than a hardcoded call.
- Page-cache interaction: MemAvailable already accounts reclaimable cache; the doctrine never targets cache; OS-first holds absolutely for the desktop (paris-layer at 1.6Gi RSS / 1818MiB VRAM is protected territory).

### 6.4 Config drift guard (found during research)

The running engine was launched with `--vram-reserve-mib 1500` while `~/Work/Strata/strata-iq3_xxs.json` says `2000`. Doctrine: **read the effective reserve from the live process/API, never from the JSON**, and treat reconciling the two as part of applying any ladder action. Which file is canonical is §8's question for the captain.

---

## 7. Adversarial analysis

Attacks on the design above, and the defenses, stated so the captain can judge both.

1. **"Your toast can't fire when it matters most."** The incident killed the shell — the thing that draws toasts. *Defense:* the fleet check outside the shell remains the guaranteed channel (§5.4); toasts are explicitly the convenience layer. Worst-case coverage predates this design and is kept, not replaced.
2. **"Amber will cry wolf on this rig — it's amber at idle forever."** True by default (6.6% available). *Defense:* ascent-only, per-boot suppression, top-consumer + lever in every body so amber reads as "Strata holds 46Gi — your allocation choice", not noise; §8 offers the stall-anchored default as an alternative; thresholds are settings.
3. **"MemAvailable can lie optimistic while PSI spikes"** (reclaimable cache counted as available under real pressure). *Defense:* PSI escalators cover exactly this — a spike moves the band without waiting for availability to fall.
4. **"PSI fires on transient compile spikes; amber flaps."** *Defense:* 60s windows (`avg60`) as the band input, sustained-band state machine, and ascent/descent hysteresis (descend only +5pp / +300MiB above the ascent threshold, held 3 polls).
5. **"PSI could be unavailable"** (`psi=0` cmdline, exotic kernels). *Defense:* degrade to available-only bands; widget never bricks; a one-time log notes the missing input.
6. **"nvidia-smi polling cost in a bar widget."** Single `--query-gpu=...` call per 30–60s poll (v1 precedent: 60s `df`); compute-apps query only on band ascent when composing the toast. No persistence-mode requirement; measured call cost stays sub-second.
7. **"VRAM free jitters across band edges; red/amber flaps."** *Defense:* absolute-MiB hysteresis margins and the sustained rule; instantaneous free never triggers a toast alone.
8. **"The GL signature over-fires — any app can log `eglError`."** *Defense:* tighten the pattern to context-creation failures; cursor-marker dedupe (fleet-check precedent); GL signature is escalation *on top of* the counter bands, not the primary.
9. **"The reserve will protect us anyway — why alert?"** Because 1856MiB free < 2000MiB configured reserve *today*: the reserve is a soft target (§1). Bands are computed independent of the reserve; the reserve is shown in the tooltip and used by the doctrine, never assumed enforced.
10. **"Mount Monitor v2 breaks marketplace users."** *Defense:* same id, additive settings only, `bandFor` untouched, colors are presentation; shipped via the newer-commit verify path (compatibility validation + security baseline). New plugins are separate submissions, so nothing in a disk-monitor install changes under their feet.
11. **"RingKit drifts across three repos and 'one design' rots."** *Defense:* single source of truth + release-time vendor script + per-repo drift-pinning tests — the same two-consumer discipline mounts.js already uses.
12. **"Color-only state excludes color-blind users."** *Defense:* pulse/halo affordance for red, distinct glyphs per resource, tooltip numbers; palette checked for contrast on the dark bar at implementation.
13. **"Process names in tooltips/toasts are attacker-controlled."** *Defense:* v1's untrusted-data discipline extended: sanitized for display; delimited untrusted block (never instructions) in agent prompts.
14. **"Auto-relax hands memory back mid-squeeze."** *Defense:* relax requires sustained green + no GL signature in window; clamped to the pre-pressure baseline; one step per window; informational toast; never auto-tightens.
15. **"Two monitors double-fire."** Accepted and documented (§5.4): independent failure domains; agent-side logical dedupe.

---

## 8. Open questions for the captain

1. **RAM band anchoring:** available-anchored default (amber at idle-with-Strata, as proposed) vs stall-anchored (amber only when PSI moves; quieter idle, later warning). Recommendation: available-anchored with §5.3 suppression.
2. **Strata RAM knobs:** confirm the API for kv-resident / expert-cache changes before RAM relief buttons hardcode anything.
3. **Canonical reserve:** JSON (2000) vs running (1500) — which is source of truth for the baseline the relief ladder relaxes to?
4. **Three plugins vs one** (§3): recommendation is three + RingKit; this affects the marketplace presence he owns.
5. **Segmented-arc VU look** vs band-wide color + threshold ticks (§2.2) — his "DB meter" image vs bar-scale legibility; his visual call at review.

---

## 9. Implementation sketch (phases — no code in this plan)

1. **RingKit** — extract palette tokens, band resolver, hysteresis state machine, ring-paint params, tooltip builder as a pure testable module in the Mount Monitor repo (mounts.js pattern + node:test rig).
2. **Mount Monitor v2** — icon badge replaces % text; palette + band colors + ticks; additive settings; tests updated; verify-plugin flow for release.
3. **RAM Monitor** — poll `/proc/meminfo` + `/proc/pressure/memory` (cheap file reads, 30s); bands per §4.2; toast actions per §5.
4. **VRAM Monitor** — poll nvidia-smi (30–60s); bands per §4.3; journal GL signature with cursor marker; toast actions per §5.
5. **Fleet alignment** — confirm `vram.check.sh` floor stays 1200 and signature wording matches; optional `ram.check.sh` deferred to captain.
6. **Skills** — extend the agent-side skill set in Mount Monitor's install pattern (disk-prune precedent) with the Strata dial-down / pause prompts the toast buttons invoke.

*Scope guard: everything above is design. No implementation, no commits to plugin repos, no marketplace submissions from this task.*
