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

5. Sandboxed app, no root (Mac App Store, `spike/store-sandbox/`, 2026-11-26): lid notification and
   `IOPMSleepSystem` work with only `com.apple.security.app-sandbox` (lid test passed in clamshell);
   `IOPMSchedulePowerEvent` and `hibernatemode` need root, so no hibernation. See `docs/app-store-edition.md`.

## Defaults to restore on uninstall

`hibernatemode 3`, cancel any wake the daemon scheduled, `disablesleep 0` only if ClamStop set it
(`PersistedState.sleepDisabledByClamStop`), and remove the agent hooks from
`~/.claude/settings.json` and `~/.codex/hooks.json` (done by the app). Do not write `standbydelay*` (no effect
on Apple Silicon); on Intel Macs restore `standbydelayhigh 86400`, `standbydelaylow 10800`.

## Distribution

Apple Developer Program: the user will enroll later. Until then CI builds unsigned (ad-hoc)
artifacts and the README documents opening the app despite Gatekeeper; signing (Developer ID) and
notarization are wired in CI behind secrets and skipped when they are absent.

## Appearance and images

- Menu bar icon: template images only (`MenuBarIconStyle` in `Sources/ClamStop/MenuBarIcon.swift`),
  so macOS tints them for light, dark, tinted and opaque ("Reduce transparency") menu bars. The
  clam is drawn in code (`ClamGlyph`, line art in isometric view); crossed-out variants mean "not working".
- No screenshots of System Settings in the app: `ApprovalIllustration` draws the row to turn on,
  so it follows the appearance and the language. The README PNGs in `docs/images/` are exports of
  it: `dist/ClamStop.app/Contents/MacOS/ClamStop --appearance light|dark --export-illustration <png>`.
- Check the settings window in both appearances with
  `--preview-approval --appearance light|dark --snapshot <png>` (no registration, no Screen
  Recording permission). `screencapture` from Claude's shell returns a black image: the menu bar
  itself must be checked by eye.

## Blockers for a sandboxed Mac App Store edition (not verified on a sandboxed build)

- No privileged helper: a sandboxed App Store app cannot install a root LaunchDaemon
  (`SMAppService.daemon`). Without root: no `pmset -a hibernatemode`, no
  `IOPMSchedulePowerEvent`, so no delayed hibernation; sleep-on-lid-close only.
- `pmset sleepnow` runs as a child process (inherits the sandbox, may be refused); a store
  edition would try `IOPMSleepSystem` instead. Lid notifications on `IOPMrootDomain` probably
  still work (IOKit registry reads), to verify.
- `AudioPauser` uses the private MediaRemote framework (`dlopen`): App Review rejects private API.
- Uninstall flow (restore power settings through the daemon) and the approval UI disappear.
- Agent keep-awake needs `disablesleep` (root) to hold a display-less lid close, and its hook
  talks to the root daemon: in a Store build it could only work with an external display
  (sleep assertions) and would need another hook-to-app channel.
- Ready: no network, `PrivacyInfo.xcprivacy` (UserDefaults CA92.1), `SMAppService.mainApp`
  login item, template menu bar icon, settings window. Sparkle must stay out of that edition.

## Pro features (2026-11-26)

- Free: sleep on lid close, hibernation after 1 h or never. Pro (`ProFeature` in
  `Sources/ClamStopShared/ProFeature.swift`): agent keep-awake, other delays, per power source,
  low battery hibernation, time range and display exceptions, sleep log. Every check goes through
  `Entitlement.isUnlocked` (licensing replaces its body); the daemon decides on
  `ClamStopSettings.effective()` only, through the pure `SleepPolicy.decide`.
- Settings window: tabs (`SettingsRootView`), General = `SettingsView`, Pro = `ProSettingsView`.
  Preview with `--preview-pro` (+ `--snapshot`, `--show-help agent|history`).
- Agent keep-awake, adapted from `IshaanChamoli/clamshut` (MIT, notice in
  `THIRD_PARTY_NOTICES.md`, copied into the app; never reuse its Noto Emoji logo): the app writes
  a hook (`ClamStop.app/Contents/MacOS/ClamStop --agent-hook claude|codex`, entry point
  `Sources/ClamStop/Main.swift`) into the agents' settings; the hook sends the event to the
  daemon over XPC (same binary, so it passes the cdhash requirement). `AgentTracker` keeps one
  lease per session; while a lease exists the daemon probes every 15 s (libproc: process alive,
  process tree CPU; transcript dates) and holds `pmset -a disablesleep 1`, which must be set
  before the lid closes (a Mac without display sleeps at once otherwise).
  `ClamStopDaemon --foreground --simulate-agent SECONDS` tests it without hooks.
- Hook stdout is added to Claude's context on UserPromptSubmit: the hook prints nothing and
  always exits 0. Process anchor: the nearest ancestor named `claude`/`codex`, never the outermost
  (the Claude desktop app, "Claude", hosts Code sessions and is always busy).
- External displays from IOKit: `IOMobileFramebufferShim` > `DisplayAttributes` >
  `ProductAttributes` > `ProductName` (Apple Silicon; "DELL S2719DM" here, same name as in
  System Settings). Wi-Fi exception dropped: the SSID is `<redacted>` without Location Services
  permission (checked on macOS 27.2 with `ipconfig getsummary en0`), not worth asking for it.
