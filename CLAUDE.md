# ClamStop: project notes

Open source (MIT) macOS menu bar app: on lid close, force sleep even in clamshell mode, then
hibernate after a configurable delay. GitHub: `ChanOJ/ClamStop` (public). Minimum macOS 14 Sonoma.
Public text (README, code comments, UI strings) uses neutral, inclusive wording.
UI is English only for now (other languages later, as `.lproj` folders).
The ⓘ help popover (`LidHelpView` in `Sources/ClamStop/SettingsView.swift`) and the opening
paragraphs of `README.md` carry the same text: change both together.

## Layout and identifiers (shared contract, do not rename without updating every user)

- SwiftPM package, built with `swift build` (no Xcode project). Targets:
  `ClamStop` (menu bar app, SwiftUI), `ClamStopDaemon` (root LaunchDaemon),
  `ClamStopShared` (XPC protocol, identifiers, settings model), `ClamStopTests`.
- Identifiers: `Sources/ClamStopShared/Identifiers.swift`.
  App bundle id `io.github.chanoj.clamstop`; daemon label `io.github.chanoj.clamstop.daemon`;
  XPC Mach service `io.github.chanoj.clamstop.daemon.xpc`.
- App bundle (assembled by `scripts/build-app.sh`, owned by the packaging work):
  `ClamStop.app/Contents/MacOS/ClamStop`, `Contents/MacOS/ClamStopDaemon`,
  `Contents/Library/LaunchDaemons/io.github.chanoj.clamstop.daemon.plist`
  (`BundleProgram` = `Contents/MacOS/ClamStopDaemon`, `MachServices` = the XPC name),
  `Contents/Info.plist` with `LSUIElement` = true, `LSMinimumSystemVersion` = 14.0.
  Templates live in `Resources/`.
- Local machine has only the Command Line Tools: run the tests with `scripts/test.sh`, not plain
  `swift test` (SwiftPM does not pass the Swift Testing macro plugin path with the CLT; the
  script adds it). Tests also run in CI (GitHub macOS runner, Xcode). The SwiftUI `@State`
  macro is unavailable with the CLT: keep view state in `AppModel`.

## Verified on MacBook Pro M5 Pro, macOS 27.2.1 (2026-11-26, `spike/probe.swift`)

1. Lid detection without polling works: `IOServiceAddInterestNotification` on `IOPMrootDomain`,
   message `kIOPMMessageClamshellStateChange` = `0xE0034100`, argument bit 0 = closed,
   bit 1 = clamshell causes sleep. Fires at once on close; two "open" messages on wake, no
   spurious close: react only to the open -> closed transition.
   IOKit `iokit_common_msg` macros are not imported into Swift: define constants by hand.
2. `pmset sleepnow` (even as a normal user, no root) puts the Mac to sleep in clamshell mode
   despite `caffeinate -i`, audio and Electron assertions ("Software Sleep" in `pmset -g log`).
   No need to kill or release assertions. No re-sleep loop after wake.
3. `standbydelayhigh/low` are NOT supported on Apple Silicon: `pmset` accepts them silently,
   they never show in `pmset -g`, and `HibernateStats` keeps `standbydelaylow=0 standbydelayhigh=0`.
   The Mac slept 566 s with a 120 s delay and never hibernated.
4. `hibernatemode 25` works: "Wake from Hibernate" after a lid-close sleep.
   => Delayed hibernation must be done by the daemon: on sleep, schedule a wake after the delay
   (`IOPMSchedulePowerEvent`, root), on that scheduled (dark) wake set `hibernatemode 25` and
   sleep again; on a user wake or after hibernation restore `hibernatemode 3`. NOT yet verified:
   scheduled wake while lid closed, and whether the re-sleep happens before the display wakes.

## Defaults to restore on uninstall

`hibernatemode 3`, cancel any wake the daemon scheduled. Do not write `standbydelay*` (no effect
on Apple Silicon); on Intel Macs restore `standbydelayhigh 86400`, `standbydelaylow 10800`.

## Distribution

Apple Developer Program: the user will enroll later. Until then CI builds unsigned (ad-hoc)
artifacts and the README documents opening the app despite Gatekeeper; signing (Developer ID) and
notarization are wired in CI behind secrets and skipped when they are absent.

## Later

Ideas from `IshaanChamoli/clamshut` (MIT, credit its copyright notice if code is reused; do not
reuse its logo, Apache 2.0 Noto Emoji): keep-awake while AI agents (Claude Code, Codex) run.
