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
  `ClamStopShared` (what the daemon needs: XPC protocol, identifiers, settings model, power
  logic), `ClamStopAppCore` (app-only logic, testable without the UI: health check, reports,
  journal, hooks, screen dimming), `ClamStopTests`. The daemon does not link `ClamStopAppCore`:
  changes there leave its code unchanged, so put app-only code there, not in `ClamStopShared`.
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
every file of `AgentHookTarget.all` (done by the app). Do not write `standbydelay*` (no effect
on Apple Silicon); on Intel Macs restore `standbydelayhigh 86400`, `standbydelaylow 10800`.

## Installing a new build on this Mac (ad-hoc signed)

First `codesign -dv --verbose=2 /Applications/ClamStop.app`: when a Developer ID release is there
(the case on 2026-11-28), ask the user before replacing it, whatever the daemon comparison says.
An ad-hoc build is signed differently, so expect the "Different" case below the first time (not
tried). Signing local builds with `SIGN_IDENTITY` (`docs/signing.md`) has not been tried either.

After `scripts/build-app.sh`, compare the daemons first:
`cmp dist/ClamStop.app/Contents/MacOS/ClamStopDaemon /Applications/ClamStop.app/Contents/MacOS/ClamStopDaemon`.
Any change in `ClamStopShared` changes the daemon.

- Identical: quit the app, `ditto dist/ClamStop.app /Applications/ClamStop.app`,
  `open /Applications/ClamStop.app`. No approval needed.
- Same code, other bytes: a build from another folder changes the debug paths in the daemon.
  When `otool -arch <arch> -tv` and the `uuid` load command match for both architectures, copy the
  installed daemon into `dist/ClamStop.app/Contents/MacOS/`, sign the bundle again
  (`codesign --force --sign - --identifier io.github.chanoj.clamstop dist/ClamStop.app`) and
  install as for an identical daemon.
- Different: same, with `open /Applications/ClamStop.app --args --reinstall-service` (always quit
  first: `open --args` passes nothing to a running app), then the user turns the switch on once
  (README "Updating an unsigned build"). The app registers a silent service again by itself
  (`ServiceWait`); green about 4 s after the switch (2026-11-28). Every such install needs the
  user's approval again, so batch daemon changes.

Check with `launchctl print system/io.github.chanoj.clamstop.daemon` and the log
(`/usr/bin/log show --predicate 'subsystem == "io.github.chanoj.clamstop"'`; the app's
`service` lines are `notice`, kept; `info` lines disappear within minutes). Do not run
`sfltool dumpbtm`: every call pops up an administrator prompt. End real-Mac tests with
`hibernatemode 3` and no stray ClamStop wake (`pmset -g`, `pmset -g sched`). Quitting the app to
install ends a running "Stay Awake" session and releases `disablesleep`.

## Pull requests

The repository has auto-merge disabled and no required check, and desktop sessions must not poll
CI: after opening a pull request, read its status once, then merge (squash) when the user asks
again and the check is green; sync `~/Code/ClamStop` (`git pull --ff-only`) and start the next
branch from `origin/main`.

## Distribution

- Developer ID signing and notarization work since 2026-11-28 (Apple Developer Program, company
  account). `release.yml` signs, notarizes and writes the Sparkle appcast on `v*` tags; "Run
  workflow" is a dry run (version 0.0.0) that publishes nothing. Ask the user before pushing a tag.
- `ci.yml` still builds ad-hoc artifacts, and so do local builds without `SIGN_IDENTITY`.
- Six secrets in GitHub Actions, copies in Proton Pass (`docs/signing.md`, `docs/updates.md`):
  never print or commit them; the user enters them. The certificate expires on 2027-12-28.
- First release: `v0.1.0` (2026-11-28). Versions stay `0.x`, without release candidates, while
  basic features are still being added (user's choice).
- Verified on 2026-11-28: `spctl` and `stapler` accept the downloaded DMG and app, hardened
  runtime on every executable, the appcast's EdDSA signature matches the public key. Installed on
  this Mac over an ad-hoc build, from a browser download: no Gatekeeper warning; the old daemon,
  still in memory, accepted the new app until `--reinstall-service`; then one switch, "not
  responding" until the app registered the service again by itself (about 45 s in all), and the
  new daemon requires the Team ID. Not verified: a Sparkle update between two signed releases.
- Website online since 2026-11-28: <https://chanoj.github.io/ClamStop/> (variable
  `PUBLISH_SITE`); a push to `main` touching `site/` deploys it.

## Updates

- Sparkle 2 (exact pin in `Package.swift`, full edition only; `CLAMSTOP_EDITION=appstore swift build`
  drops it and defines `APPSTORE`). `build-app.sh` embeds `Sparkle.framework` in
  `Contents/Frameworks` (adds the rpath) and signs its helpers inside out. Feed: `appcast.xml` asset
  of the latest GitHub Release, written by `scripts/make-appcast.sh` only for Developer ID builds
  (Sparkle cannot update ad-hoc builds: their requirement is a cdhash). Public key in
  `Resources/sparkle-public-ed-key.txt`; private key only in Proton Pass and the
  `SPARKLE_ED_PRIVATE_KEY` secret. See `docs/updates.md`.

## Appearance and images

- Menu bar icon: template images only (`MenuBarIconStyle` in `Sources/ClamStop/MenuBarIcon.swift`),
  so macOS tints them for light, dark, tinted and opaque ("Reduce transparency") menu bars. The
  clam is drawn in code (`ClamGlyph`, line art in isometric view); crossed-out variants mean "not working".
- No screenshots of System Settings in the app: `ApprovalIllustration` draws the row to turn on,
  so it follows the appearance and the language. The README PNGs in `docs/images/` are exports of
  it: `dist/ClamStop.app/Contents/MacOS/ClamStop --appearance light|dark --export-illustration <png>`.
- Development runs (`--preview-*`, `--snapshot`, exports) start without a menu bar item
  (`Main.swift`): they share the installed app's preferences, and a hidden item there made the
  installed app's icon disappear. Add new development flags to `developmentRunFlags`.
- Check the settings window in both appearances with
  `--preview-approval --appearance light|dark --snapshot <png>` (no registration, no Screen
  Recording permission). `screencapture` from Claude's shell returns a black image: the menu bar
  itself must be checked by eye.

- Accessibility: add `--dump-accessibility` to a `--snapshot` run to print the tree VoiceOver gets
  (controls may be named by `titled by`). Seen 2026-11-28: a `List` blocked VoiceOver and section
  headers were read last; keyboard shortcuts on digits must use key codes (French layout).

## Blockers for a sandboxed Mac App Store edition (not built; spike results in point 5 above)

- No privileged helper: a sandboxed App Store app cannot install a root LaunchDaemon
  (`SMAppService.daemon`). Without root: no `pmset -a hibernatemode`, no
  `IOPMSchedulePowerEvent`, so no delayed hibernation; sleep-on-lid-close only.
- Sleep on lid close works sandboxed (`IOPMSleepSystem`, lid notifications on `IOPMrootDomain`):
  the app would do it itself.
- Private APIs, which App Review rejects: `AudioPauser` (MediaRemote), `ScreenLocker`
  (`SACLockScreenImmediate`) and `BuiltInScreen` (DisplayServices). The last two are already
  left out with `-D APPSTORE`; `AudioPauser` is not.
- Uninstall flow (restore power settings through the daemon) and the approval UI disappear.
- Agent keep-awake needs `disablesleep` (root) to hold a display-less lid close, and its hook
  talks to the root daemon: in a Store build it could only work with an external display
  (sleep assertions) and would need another hook-to-app channel.
- Ready: no network, `PrivacyInfo.xcprivacy` (UserDefaults CA92.1), `SMAppService.mainApp`
  login item, template menu bar icon, settings window. Sparkle must stay out of that edition.

## Features and settings (2026-11-26)

- Everything is free (no Pro tier, no license). Full edition: "Buy me a coffee" (`Links.donation`)
  in the About tab and at the bottom of General, "Donate…" in the menu; `Edition.current` (`Sources/ClamStop/Edition.swift`)
  turns it off for a future Store build.
- Settings window: six tabs (`SettingsTab`, `SettingsRootView` in `SettingsView.swift`, the other
  tabs in `SettingsTabs.swift` and `DiagnosticsTab.swift`; rows and cards in `Components.swift`).
  Only settings with real behavior are shown; others arrive with their feature.
  Preview with `--preview-settings --tab general|sessions|rules|safety|diagnostics|about`
  (+ `--snapshot`, `--show-help agent|history`, `--welcome 1|2|3 [agents]`, `--until`).
- "Stay Awake" sessions from the menu (spec C1, C2): `PowerController.startSession(until:)`; an
  idle-sleep assertion while it runs, `disablesleep` with the lid closed within the agent guards
  (same path as agents, `LidDecision.keepAwake`); any sleep, Sleep Now or the battery floor ends it.
- Inactive without the app: the app's status poll is the XPC call `appStatus`; the daemon watches
  that process (`DaemonService.appConnected`, `DispatchSource` exit) and `PowerController.appRunning`
  makes `decide` return `leaveAlone` while no app runs (also after a daemon start, until the app
  connects; not in `--foreground`). The agent hook never calls `appStatus`.
- XPC callers: the system checks the signature (`ClientRequirement`: Developer ID and the daemon's
  Team ID, read once at start; ad-hoc builds: the exact cdhash), then `CallerPolicy` lets only
  root, the console user or the followed app's user change anything (other accounts read the
  status). Keep new XPC methods behind `XPCServer.control`. Limits: settings and agent message
  sizes, `AgentTracker.maxLeases`, only the sender's files count as transcript activity, and
  decoded settings are clamped in their `init(from:)`.
- Diagnostics (spec H4, 2026-11-28): checks in `HealthCheck`, report text in `DiagnosticsReport`
  (home folder as `~`, 60 000 characters at most for a GitHub issue), prefilled issue and e-mail in
  `ProblemReport`; the app sends nothing itself and holds no secret (no SMTP, no GitHub token).
  Reports by e-mail go to `Links.reportEmail`, an alias for ClamStop alone. A browser as mail
  app gets a short `mailto:` (Gmail answers "400" to a long one, seen 2026-11-28). `--export-diagnostics
  <file>` writes the real report without telling the daemon that the app runs (installed copy
  only: another build gets no XPC answer).
- What keeps my Mac awake (spec H2, 2026-11-28): the app alone reads
  `IOPMCopyAssertionsByProcess` (`AssertionReader`; no root), `AwakeList` groups by outermost app
  bundle, follows "on behalf of" and sets macOS services apart. Reports name the apps, never the
  assertions (they can hold titles or file names). Preview: `--preview-settings --awake
  --snapshot <png>`. Not verified in a sandboxed build.
- Session end (spec C4) and lock on lid close (F2), 2026-11-28: app only (`SessionEnd`,
  `LidLock` in `ClamStopAppCore`). The reminder is posted from
  the status poll; "+30 min" starts a new session through XPC. `ScreenLocker` calls the private
  `SACLockScreenImmediate` (`login.framework`, full edition only; falls back to
  `pmset displaysleepnow`). macOS asks the app to reopen when a notification is clicked: ignored
  for 2 s after a click.
- Sleep report (spec B5, 2026-11-28): app only. On `didWakeNotification` and on lid open, 5 s
  and 30 s later, `SleepReport.latest` reads the journal (newest sleep of 4 h or more, ended less
  than 1 h ago, once). Try it with
  `defaults write io.github.chanoj.clamstop sleepReportMinimumMinutes -int 2` (delete it after).
- Notifications (spec H5): the root daemon cannot post them, so `PowerController.notify` keeps the
  last `Notice`s in `DaemonStatus.notices` and the app's `Notifier` posts the new ones
  (`DefaultsKey.lastNoticeDate`); the approval notice comes from the app's service state.
- First launch opens the first-run assistant (`WelcomeView`); its choices reach the daemon once
  the service answers (`AppModel.applyPendingFirstRun`). Audio pause is automatic (spec F1).
- The daemon decides through the pure `SleepPolicy.decide`: `ClamStopSettings.lidPlan` (first
  matching rule, else the power-source profile), low battery hibernation, then agents, sessions
  and "stay awake" rules with the safety guards (time limit, heat, only on power adapter,
  battery floor). Menu Sleep Now / Hibernate Now go through XPC (`sleepNow`, `hibernateNow`).
- Rules (spec D1, `Rules.swift`, `RulesTab.swift`): conditions power, external screen, time
  window. The app reports the external screen in `appStatus` (CoreGraphics; the root daemon has no
  window server), the daemon hears power changes through `notify` and checks time windows each
  minute; `PowerController.conditionsChanged` waits 5 s (a screen can drop for a moment). A rule
  alone takes `disablesleep` only without screen + adapter, and never during a dark wake.
- Watched apps (spec C5, `WatchedApps.swift`, `AppMonitor.swift`, `WatchedAppsView.swift`): busy =
  power assertion (`IOPMCopyAssertionsByProcess`, "AssertionTrueType", on-behalf PID for audio)
  or over 5 % of a core for the app's process tree; probed every 15 s only while the list is not
  empty, 90 s grace. Same keep-awake path and guards as agents. Checked 2026-11-27 on real
  processes (Transmission, VLC, a busy command), about 5 ms per probe.
- Screens (spec C3, G2): `keepScreensOn` adds a display-sleep assertion during menu sessions.
  With the lid closed macOS leaves the built-in panel lit under `disablesleep` (verified
  2026-11-28), so the app (`ScreenDimmer`, `BuiltInScreen.swift`: private DisplayServices, user
  session only) sets it to 0 when the daemon says it keeps the Mac awake, saves the level in the
  app's defaults and restores it on lid open, quit, uninstall or next launch.
- Waiting for the service (`ServiceWait.reminderDelay`, 5 min): the app looks every second, posts
  the approval notification again after the delay if the switch is still off, and after twice the
  delay looks every 5 s (every second again after "Open Login Items Settings…"). Measured
  2026-11-28: waiting at 1 s costs about 2 % of a core more than running, mostly in macOS's
  `backgroundtaskmanagementd`.
- Windows are sized with `NSHostingController.sizeThatFits` (`FittedWindow`): `view.fittingSize`
  stays zero for them on macOS 27.2.
- Agent keep-awake, adapted from `IshaanChamoli/clamshut` (MIT, notice in
  `THIRD_PARTY_NOTICES.md`, copied into the app; never reuse its Noto Emoji logo): the app writes
  a hook (`ClamStop.app/Contents/MacOS/ClamStop --agent-hook <agent> [event]`, entry point
  `Sources/ClamStop/Main.swift`) into the agents' settings; the hook sends the event to the
  daemon over XPC (same binary, so it passes the cdhash requirement). `AgentTracker` keeps one
  lease per session; while a lease exists the daemon probes every 15 s (libproc: process alive,
  process tree CPU; transcript dates) and holds `pmset -a disablesleep 1`, which must be set
  before the lid closes (a Mac without display sleeps at once otherwise).
  `ClamStopDaemon --foreground --simulate-agent SECONDS` tests it without hooks.
- Hook stdout is added to Claude's context on UserPromptSubmit: the hook prints nothing and
  always exits 0. Process anchor: the nearest ancestor named `claude`/`codex`, never the outermost
  (the Claude desktop app, "Claude", hosts Code sessions and is always busy).
- Other agents (spec C7, 2026-11-28): `AgentHookTarget.all` (file, layout, events) and
  `AgentHookMessage.fromHookInput` / `hookReply` translate each agent's names to Claude Code's.
  Gemini CLI, Antigravity, Cursor, Copilot CLI follow their documentation only (none tried).
  Agents run by node are found by their script (`KERN_PROCARGS2`); the Cursor and Antigravity
  apps are not process anchors (always busy). Cursor `subagentStart` is not hooked (a wrong reply
  blocks the subagent). Aider: watched command (matched by script name). OpenCode: not yet, its
  plugin event names were not found. A scheduled task checks the agents' documentation monthly.
- Sleep journal (spec H3, 2026-11-28): the daemon's events (full wakes only), shown by day in
  `JournalView`, a resizable window (`--preview-settings --journal --snapshot <png>`). Wake reasons
  come from `IOPMrootDomain` "Wake Reason" / "Wake Type" (`WakeReason`, matched on strings seen on
  this Mac). Entries written by earlier versions show without a reason.
- Thermal level (2026-11-28): `ThermalLevel` follows macOS's pressure levels (notify key
  `com.apple.system.thermalpressurelevel`, 0 nominal to 4 sleeping, public header
  `libkern/OSThermalNotification.h`), the warmer of it and `ProcessInfo.thermalState`, which says
  "fair" for both moderate and heavy. Measured on the M5 Pro, lid closed in the open, CPU and GPU
  loaded: heavy after about 70 s, steady for over 5 min, never trapping. The user chose to sleep
  from "very hot" (trapping, or `serious`) only: heavy is the plateau of long jobs. Each journal
  event holds the level; the daemon logs every change, journals those while it stays awake with the
  lid closed, and the heat guard looks again after the 5 s settle delay. No temperature in degrees
  without private interfaces. Not verified: sleep on a very hot Mac (level never reached).
- Watchdog (spec E4, 2026-11-28): the app calls `appHeartbeat` every 5 s from a common-modes
  timer (and holds off App Nap while sleep is held off); 6 silent checks while awake make the
  daemon act as if the app quit, until it reports again. Quit, crash or stuck with the lid closed:
  the daemon requests sleep unless there is a screen and the power adapter. Freeze the app to test:
  `kill -STOP <pid>`, then `kill -CONT <pid>`.
- External display names, if a rule needs them: IOKit `IOMobileFramebufferShim` >
  `DisplayAttributes` > `ProductAttributes` > `ProductName` (Apple Silicon; "DELL S2719DM" here,
  same name as in System Settings). Wi-Fi condition dropped: the SSID is `<redacted>` without Location Services
  permission (checked on macOS 27.2 with `ipconfig getsummary en0`), not worth asking for it.
