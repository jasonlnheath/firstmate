# Boot Camp hibernate-after-sleep + early backlight fire - execution record

Machine: jason@192.168.1.220 (MacBookPro13,3, Windows 11 Pro build 26200.9711,
Boot Camp, T1/iBridge). Date: 2026-11-03 ~08:55-10:00 box-local (UTC-5).
Executor: crewmate via elevated SSH. No reboot performed, no test power cycles;
the captain tests naturally and verification from logs follows his next cycles.
Delivery: local-only branch `fm/bootcamp-hibernate-auto` (this report is the
deliverable; scripts live on-box under `C:\touchbar-fix\`).

## What the captain asked
- Lid-close sleep must still wake instantly on lid-open (the standing victory), but
  after the grace window (DC 1800 s / AC 3600 s) the box must become true hibernate.
  Overnight 2026-11-02/03 it stayed in S3 all night (battery 77 -> 75%): user/lid-
  initiated sleep ignores the HIBERNATEIDLE timer on build 26200.9711.
- Scope add (live): keyboard+screen backlight must fire EARLY - he cannot see his
  keyboard at the login screen in low light (boot and wake); third wake-reinit gap.
- Check the ambient light sensor / Boot Camp auto-illuminate angle.

## Evidence (overnight defect, from the System log)
- Kernel-Power 42 (Button or Lid) 01:48:37; kernel clock froze at 01:48:43.9 and no
  further power events until the captain's manual 08:31 restart (Kernel-Boot 27
  boot type 0x0 = cold, NOT 0x2 = hibernate-resume). No hibernate attempt occurred;
  HIBERNATEIDLE DC 1800 s never fired for lid sleep. Battery 77 -> 75% = S3 drain.
- Build quirk (documented, load-bearing): this box logs 107 ("resumed") ~6 s after
  the 42, then truly suspends with the OS clock frozen; real wakes log no fresh 107.
  The ~6 s gap between 42 and real suspend is the arming window used below.

## What was done

### 1. Native lever ruled out by evidence, wake-timer recipe implemented
HIBERNATEIDLE stays 1800/3600 (inert for lid sleep on this build; STANDBYIDLE 0/0
unchanged). The recipe:
- **Wake-timer policy**: RTCWAKE (Allow wake timers) AC 2 -> 1, DC 0 -> 1, applied
  and read-back verified; logged with revert in
  `logs\rtcwake-enable-20261103-094704.log`.
- **Task `ArmHibernateAfterSleep`** (SYSTEM, Kernel-Power 42 trigger, NO delay):
  `bin\hibernate-arm.ps1` arms only user/lid S3 entries - TargetState=3 AND reason
  "Button or Lid" AND event age < 60 s; hibernate entries (TargetState=4) and
  unattended re-sleeps are refused (live-tested against the real 09:01:48 hibernate
  entry: correct ARM-SKIP). Writes `state\hibernate-arm.json`, rewrites the fire
  task's trigger to now+grace (DC 1800 / AC 3600 by power source at arm) via
  Schedule.Service COM (round-trip verified; fits the ~6 s pre-suspend window).
- **Task `HibernateAfterSleepWake`** (SYSTEM, WakeToRun, once trigger):
  `bin\hibernate-fire.ps1` hibernates via `shutdown /h` only when unused. Guards,
  all logged: no arm stamp; input since arm (GetLastInputInfo); OS start since arm
  (boot/S4-resume path is never re-hibernated); window stale >30 min or ran early;
  90 s settle with input polling (lets the SPI heal finish, user appearing = no-op);
  system held awake during settle via SetThreadExecutionState. `-DryRun` switch.
- **Verified without power cycles**: `powercfg /waketimers` shows the hardware RTC
  timer for `NT TASK\HibernateAfterSleepWake`; fire guard chain exercised live via
  -DryRun (idle 78 min -> "would run shutdown /h now", then safe stop).
- First real cycle: next lid close arms; fire wakes the box at +30 min (battery) /
  +60 min (AC) of unused lid-closed time and hibernates it. Rolling log:
  `logs\hibernate-after-sleep.log` (ARM-*/FIRE-* lines per cycle).

### 2. Keyboard/screen backlight early fire (scope add)
- Research: no Windows-side keyboard-backlight set API exists on this box. Checked
  WMI classes, Apple registry keys, HID caps of every Apple collection (keyboard
  MI_01 COL02 feature report is buttons-only and unreadable; the T1 0xFF12 feature
  channel is an opaque 116-byte protocol, report ID 100, GetFeature fails; no
  usable output report anywhere), and device restarts of every SPI child (the
  healer already ran those every wake and the backlight stayed dark). The T1
  (iBridge) drives the backlight and takes illumination commands only from the SPI
  keyboard on the bus.
- Root gap found: the healer's iBridge COMPOSITE restart is permanently
  reboot-pending (pnputil rc=50 every run), so the T1's function children were
  never re-initialized at wake. The children restart cleanly: MI_02 (touch bar)
  rc=0 live-verified; MI_03 (HID+ALS) rc=3010 (deferred, lands at the next power
  cycle - i.e., exactly the next wake).
- **Task `EarlyBacklightKick`** (SYSTEM; Boot + Power-Troubleshooter 1 + Kernel-Boot
  27 triggers, NO delay): `bin\EarlyBacklightKick.ps1` = screen WmiSetBrightness
  re-apply (proven screen kick) + T1 function-children restart (MI_02, MI_03).
  Non-fatal, logs to `logs\earlykick-<ts>.log`. End-to-end tested 09:47:56.
- **Task `EarlyBacklightUnlock`** (SYSTEM; SessionUnlock trigger): same script with
  `-ScreenOnly` - screen re-apply only, no device restarts while the user is active.
- **`RecoverAppleSpiStack.ps1` extended**: iBridge function children
  (`USB\VID_05AC&PID_8600&MI_0[23]*`) added to the restart pass after the composite.
  Backup: `RecoverAppleSpiStack.ps1.bak3`. Everything else in the healer unchanged.
- **Ambient light sensor**: present and healthy - `HID Ambient Light Sensor` on
  `USB\VID_05AC&PID_8600&MI_03&COL01`, live instance Status OK (plus one ghost
  instance, the known dead-generation pattern). Not wedged. Keyboard
  auto-illuminate-in-darkness is T1/macOS-side; no Boot Camp control exists under
  Windows (no illum keys found in Apple registry trees).

## Honest limitation + what verification remains
- The login-screen keyboard backlight cannot be forced directly from Windows; the
  T1-children kick is the achievable lever. Its effect is the captain's eyes on the
  next natural wake (and next boot): if the keyboard is still dark at login, the
  next lead is the T1 0xFF12 protocol (deep research, out of scope here).
- The recipe's first real hibernate lands after his next >=30 min lid-closed stretch:
  expect `FIRE ... shutdown /h rc=0` in the rolling log, then a normal S4 resume on
  his power-button press. If the wake timer does not fire (firmware refuses), the
  box stays in S3 exactly as before (status quo), visible as an absent FIRE line.

## Revert (exact)
1. Recipe: `schtasks /delete /tn ArmHibernateAfterSleep /f`;
   `schtasks /delete /tn HibernateAfterSleepWake /f`; delete
   `C:\touchbar-fix\bin\hibernate-arm.ps1`, `hibernate-fire.ps1`, the four
   `task-*.xml`, `state\hibernate-arm.json`. HIBERNATEIDLE may stay (inert).
2. Wake timers: `powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0`;
   `powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 2`;
   `powercfg /setactive SCHEME_CURRENT`.
3. Backlight: `schtasks /delete /tn EarlyBacklightKick /f`;
   `schtasks /delete /tn EarlyBacklightUnlock /f`;
   `copy /y C:\touchbar-fix\RecoverAppleSpiStack.ps1.bak3
   C:\touchbar-fix\RecoverAppleSpiStack.ps1`; delete
   `C:\touchbar-fix\bin\EarlyBacklightKick.ps1` and its task XMLs.

## Notes
- Nothing else touched: hibernate entry/resume victory, critical 5%=hibernate,
  STANDBYIDLE 0/0, HIBERNATEIDLE 1800/3600, hybrid sleep off, lid actions, BCD,
  drivers. Diagnostic scratch (Diag* tasks, scripts) removed; outputs kept in
  `logs\diag-*.out` and `logs\hibernate-auto-20261103-095520.log` (campaign log).
- With DC wake timers enabled, any application may schedule an overnight wake; the
  box then returns to sleep after the unattended timeout and the critical-battery
  5%=hibernate floor still applies. No non-recipe wake timers existed at install.
- Raw evidence (firstmate-private, outside this repo):
  `data/bootcamp-hibernate-auto/diagnosis/` (event logs, HID caps dumps, task
  exports, every on-box log).
