# Boot Camp three-finger tap = middle click - execution record

Machine: jason@192.168.1.220 (MacBookPro13,3, Windows 11 Pro build 26200.9711,
Boot Camp, Apple SPI trackpad). Date: 2026-11-02 ~23:05-23:25 box-local (UTC-5).
Executor: crewmate via elevated SSH. No reboot performed, none required.
No port binding, no power state changes.

## What the captain asked
Three-finger tap on the Boot Camp touchpad should act as middle mouse click.

## What was done
1. **Research pass** (kept in `data/bootcamp-3finger-middleclick/research.md`,
   outside this repo):
   - Lead alive: imbushuo/mac-precision-touchpad release 2105-3979, MS-signed
     (`Microsoft Windows Hardware Compatibility Publisher`, Get-AuthenticodeSignature
     Valid on-box). INF covers `SPI\VID_05AC&PID_0278&MI_02` - this machine's exact
     trackpad. Maintainer confirmed 13,3 support (issue #162). No test signing
     required (README + signed cat verified). No reboot documented; none needed.
   - HVCI/memory integrity off on the box - no signing-policy blocker on 26200.
2. **Installed the driver** over SSH: `pnputil /add-driver
   C:\touchbar-fix\mpt\extracted\drivers\amd64\AmtPtpDevice.inf /install`
   - staged as `oem112.inf`, installed directly onto the trackpad device,
     exit code 0. Zip hash verified both sides
     (CEA0449AA773DBBB70ABDFC787BE99335DABBD2719588CEBBB8806F397B4FAD2).
3. **Configured the gesture**: `ThreeFingerTapEnabled=1` (DWORD) under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad`
   = "Middle mouse button" in Settings > Bluetooth & devices > Touchpad >
   Three-finger gestures > Taps.

## Verification (all live, postinstall proof in task data dir)
- Trackpad device `SPI\VID_05AC&PID_0278&MI_02`: Status OK, problem code 0,
  driver `oem112.inf` (Bingxing Wang, 2021.3979.1.1000), device renamed
  "Apple SPI Precision Touchpad Device"; `AmtPtpDeviceSpiKm` filter running.
- Apple filter swap clean: device lower filter is now `AmtPtpDeviceSpiKm`
  only - `AppleSPITrackpad` no longer referenced by any device (service entry
  remains but is inert; Apple package `oem16.inf` stays in the store for revert).
- New precision-touchpad HID collections enumerated and started (Kernel-PnP
  event 410, inbox drivers, no errors):
  - `HID\VID_05AC&PID_0278&MI_02&COL01` = "HID-compliant touch pad"
  - `HID\VID_05AC&PID_0278&MI_02&COL02` = "Microsoft Input Configuration Device"
    (this is what Settings > Touchpad talks to - page now live)
- One/two-finger behavior unchanged from baseline (registry identical):
  TapsEnabled=1 (tap-to-click), TwoFingerTapEnabled=1 (two-finger tap = right
  click), TapAndDrag=1, ScrollDirection=0.
- Keyboard (Apple SPI Keyboard, MI_01) and Touch Bar (iBridge) untouched, OK.
- Existing scheduled task `RecoverAppleSpiStack` (restarts all SPI children on
  resume) also covers the new driver's device - mitigates the driver's known
  historical sleep-resume issue (upstream issue #203, A1707 same machine class).

## Revert (recorded, run over SSH)
1. `pnputil /delete-driver oem112.inf /uninstall` - removes package + unbinds;
   Apple's `oem16.inf` re-binds the trackpad on rescan automatically.
2. `reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad" /v ThreeFingerTapEnabled /f`
   (harmless without the PTP driver; delete for cleanliness).
3. Scratch: `rmdir /s /q C:\touchbar-fix\mpt` (driver zip + extracted files +
   baseline/postinstall text on box).
If the device ever misbinds before revert, force Apple re-bind:
`pnputil /restart-device "SPI\VID_05AC&PID_0278&MI_02\5&33D07321&0&02"`.

## Notes / residual risk
- Captain should physically confirm the feel: three-finger tap = middle click,
  one-finger tap = click, two-finger tap = right click (config verified live;
  actual pointing-device behavior is not observable over SSH).
- If the mapping does not apply until Settings is opened once, open Settings >
  Bluetooth & devices > Touchpad once - the value is stored and read there.
