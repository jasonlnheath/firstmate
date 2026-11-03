# Boot Camp keyboard-backlight wake wedge - live diagnosis, heal attempts, and veto-prevention fix

Machine: jason@192.168.1.220 (MacBookPro13,3, Windows 11 Pro build 26200.9711,
Boot Camp, T1/iBridge). Date: 2026-11-03 ~12:11-12:50 box-local (UTC-5).
Executor: crewmate via elevated SSH. NO reboot performed, no test power cycles.
Delivery: local-only branch `fm/bootcamp-kbd-backlight` (this report is the
deliverable; scripts live on-box under `C:\touchbar-fix\`, campaign log
`logs\kbd-backlight-20261103-124855.log`, all reverts inside).

## What the captain asked

Live test report: lid-open wake worked, touch bar healed, but the KEYBOARD
BACKLIGHT was dead on wake and did not heal - brightness keys/adjust and the
Boot Camp control panel OFF/ON both failed (manual recovery), while a full
restart cleared it. Diagnose the live wedged state first, find the heal recipe
with escalating kicks (no reboot), fold the winner into
`RecoverAppleSpiStack.ps1`, read the wake logs for S3-vs-hibernate and whether
the deployed wake-timer recipe fired, and profile/tighten the early boot
backlight trigger (scope add: boot fire is too slow).

## Live diagnosis of the wedged box (all reads before any mutation)

- Every Apple SPI/iBridge device read `OK problemCode=0`: **the wedge is
  invisible to PnP problem codes**. There was no device to heal by status.
- The wake under test was **pure S3**: Kernel-Power 42 (Button or Lid) at
  12:02:17, OS clock froze 12:02:23, resynced 12:05:44, Power-Troubleshooter
  wake 12:05:51 with `Wake Source: Device - Apple SPI Device`. No Kernel-Boot
  27, BootId 128 unchanged - **no hibernate occurred today**.
- **The deployed wake-timer recipe did NOT fire**: `ArmHibernateAfterSleep`
  ran 1 s after the sleep and logged `ARM-SKIP` - the 42 event's
  `targetState` read **4** (hibernate) on a lid sleep that really entered S3,
  so the guard classified it as a hibernate entry. A recipe gap to review
  (not changed today): lid sleeps whose TargetState reads 4 are never armed,
  so long closed-lid stretches stay S3 until the guard is fixed.
- Wake-side latency is already tight: wake event 12:05:51.4 → early-kick task
  start 12:05:52 (**0.6 s**). Wake latency was never the problem.
- Chronic (7 days, every boot): `WUDFRd failed to load` for
  `HID\VID_05AC&PID_8600&MI_03&Col01` (the T1 HID + ambient-light-sensor
  function), Status 0xC0000365. Not the direct wedge (it predates the defect),
  but it marks MI_03 as the fragile function.

## Root cause chain (established from this morning's logs)

1. 11:53:33 cold boot (captain's restart). Kernel → PIN/logonUI in ~15 s.
2. 11:54:09-14 the early-fire task restarted T1 MI_02+MI_03 cleanly
   (pre-Bootcamp.exe) - **the keyboard backlight lit** (captain saw it before
   the PIN screen).
3. 11:54:22 `Bootcamp.exe` (Boot Camp tray app) started.
4. 11:54:35 the boot-time healer (Kernel-Boot 27 trigger) restarted the whole
   stack - **`Bootcamp.exe` vetoed** the composite and MI_03 restarts
   (Kernel-PnP 225, "stopped the removal or ejection"), parking both in
   **reboot-pending limbo** (`pnputil /restart-device` → rc=50) for the rest
   of the day.
5. Every later kick inherited the limbo: early kick 12:05:56 (MI_03 rc=50),
   healer 12:06 (composite+MI_03 rc=50) - device restarts "succeeded" on the
   SPI side (rc=0) but the T1 function re-init never completed, and the
   keyboard backlight stayed dark. Manual brightness writes had no effect
   because the control path's carrier (MI_03 HID channel + composite state)
   was parked; a full reboot completes the pending operation, which is why
   the wedge cleared only on restart.

## Kick ladder (live, escalating, no reboot)

| Step | Action | Result |
|---|---|---|
| A 12:21 | Stop `Bootcamp.exe` (release veto), retry MI_03+composite restarts, restart `BootCampService`+`AppleOSSMgr` | restarts **still rc=50** - the limbo persists regardless of the veto; services restarted clean |
| B 12:23 | Restart USB `ROOT_HUB30` (parent re-enumeration), retry composite | hub restart flushed the limbo; **composite rc=0 at 12:23:31 - first clean restart since boot** |
| captain | Visual check | **touch bar knocked off by the hub reset** → hub reset reclassified as a **hazard, forbidden as a cure**; healer ordered |
| healer 12:37 | Full `RecoverAppleSpiStack` run | **all 8 Apple devices rc=0 including composite+MI_03 - first fully clean T1 re-init since boot**, aggregate SUCCESS |

**VERDICT (captain, 12:49 box-local): keyboard backlight AND touch bar are
BOTH BACK ON** after the 12:37 healer run - everything currently lit.

Revival correlation from `recover-20261103-123733.log`: **no disable/enable
ran** - every restart succeeded on first pass. The revivers were the
**composite restart rc=0 at 12:37:37** and **USB MI_03 restart rc=0 at
12:37:38** - the two devices parked rc=50 since 11:54 - plus **USB MI_02
rc=0 at 12:37:38** for the touch bar (dark since the 12:23 hub reset).

## What was deployed (both changes live, hash-verified)

### 1. `RecoverAppleSpiStack.ps1` - veto prevention + two-state recipe (v2, live)

The keyboard backlight has no Windows-side set API (researched yesterday:
no WMI class, no registry knob, HID COL02 feature is buttons-only, the T1
0xFF12 feature channel is opaque). Its only lever is a clean T1 function
re-init - which the veto-limbo made impossible at every wake. The healer now
runs the **two-state recipe** (captain-confirmed revival, folded per his
design):

- **Normal cycle first**: stop `Bootcamp.exe` (veto prevention, logged
  `VETO-PREVENT`, restore after) → restart SPI children, T1 composite and
  function children. With no parked devices - now guaranteed at future wakes
  since the limbo can no longer be created - this alone revives everything,
  exactly as the 12:37 run did.
- **On rc=50 (the at-wake-like state)**: `STRONG-KICK disable/enable` with
  dwell on that device - the only in-bounds stronger kick (the hub is
  forbidden). Composite disable is historically "Not supported" and is
  caught non-fatal.
- **Only if the strong kick fails too**: logged `REBOOT-NEEDED` - a full
  reboot (whose boot path lights everything pre-PIN) is the true limbo cure;
  never auto-forced, the captain's word.
- **Logs `REBOOT-NEEDED` loudly when a restart returns rc=50** (device
  parked in limbo) instead of the old soft `REBOOT-NOTE`.
- **Documents the HUB RULE in-header** (captain, live): never restart hub or
  controller ancestors - verified hazard.
- Screen-panel WMI kick unchanged (separate, still-working heal).
- Backup: `RecoverAppleSpiStack.ps1.bak4` (pre-campaign original); live MD5
  `FD9E0CEB01287B9F1B62F6D64C98E4B8`.
- **REVERT**: copy `C:\touchbar-fix\RecoverAppleSpiStack.ps1.bak4` over
  `C:\touchbar-fix\RecoverAppleSpiStack.ps1`.

### 2. `bin\EarlyBacklightKick.ps1` - T1 children kick first

- The T1 function kick now runs **before** the screen kick (the screen kick's
  WMI roundtrips + 2 s settle used to delay the keyboard-critical path by
  ~4-5 s). Screen kick still runs, still covers the panel defect.
- Boot-profile findings recorded in-header (below). Triggers unchanged -
  they are already the earliest practical forms: Boot + Power-Troubleshooter
  1 + Kernel-Boot 27.
- Backup: `EarlyBacklightKick.ps1.bak-20261103`; live MD5
  `B013AFC08A77E1FD9035DE1DF37B9DC7`.
- **REVERT**: copy `C:\touchbar-fix\bin\EarlyBacklightKick.ps1.bak-20261103`
  over `C:\touchbar-fix\bin\EarlyBacklightKick.ps1`.

### 3. Boot Camp tray cycle

`Bootcamp.exe` stopped 12:21:41 (kick ladder), restored 12:47:55 (pid 4796,
session 1, the interactive session) via a one-shot interactive scheduled task
created and deleted in the same minute. No reboot.

## Boot-fire timing profile (scope add) and what "tighter" can mean

Measured on the 11:53 restart:

| Milestone | Time | Delta from kernel boot |
|---|---|---|
| Kernel-Boot 27 (type 0x0) | 11:53:33.8 | 0 |
| PIN/logonUI ready (DWM-1) | 11:53:48.6 | **+15 s** |
| Jason logon / explorer | 11:53:50 / 11:53:52 | +16/+18 s |
| EarlyBacklightKick task start | 11:54:09 | **+35.6 s** |
| T1 kick complete (backlight lever) | 11:54:14 | +41 s |
| Bootcamp.exe starts (veto armed) | 11:54:22 | +48 s |

- The task **cannot beat the PIN screen**: its start floor is Task Scheduler
  service readiness (~+35 s), while the PIN appears at ~+15 s. The pre-PIN
  keyboard light the captain saw on cold boot is the **firmware's own boot
  path** (SMC/T1 boot state), not the task - the task owns wake and
  post-login relighting, which is exactly where the veto-limbo (now fixed)
  was killing it.
- The adopted tightening is the T1-first reorder (+~5 s to the lever) and the
  veto-free healer (which removes the post-kill re-darkening at ~+48 s).
- Going earlier than the scheduler floor would need a pre-scheduler host
  (a simple Windows service started by the service control manager before
  Task Scheduler). Out of today's no-reboot scope; noted as the only
  remaining lever if the captain ever needs the OS to light the keyboard
  before the firmware splash hands over.

## What the next natural wake should do

With the healer now veto-free, the next lid-close/lid-open cycle should run
the healer with `VETO-PREVENT stopped Bootcamp.exe` in its log, restart all
8 devices rc=0, and relight the touch bar and keyboard backlight - the first
wake in which the T1 re-init actually completes. If a future wake ever shows
`STRONG-KICK` lines, that is the parked-device path firing (means the veto
prevention did not hold and the limbo reappeared) - its success/failure line
says whether the box recovered without help; a `REBOOT-NEEDED` line means
the only cure is a reboot at wedge time, the captain's call, never forced.

Also worth a follow-up task: the `ArmHibernateAfterSleep` guard skips lid
sleeps whose 42 event reads `targetState=4` (like today's 12:02 sleep), which
leaves long closed-lid stretches in S3; the guard should verify the ACTUAL
power state after the ~6 s pre-suspend window before refusing to arm.
