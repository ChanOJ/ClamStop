# ClamStop functional specification

Version 2, 2026-11-26 (everything free, donation links; version 1 had a Pro tier). Built from a survey of about 120 macOS tools that deal with sleep, the lid
and clamshell mode (GitHub projects, Mac App Store and Setapp apps, command line tools; list in the
appendix). Goal: one app that replaces all of them for everything that happens when a MacBook lid
closes, when it sleeps and when it should stay awake, usable by a non-technical person and by a
developer alike.

## 1. Principles

1. **One question at a time.** The default window answers one question in plain words: "What
   should happen when I close the lid?". Everything else sits behind "More options".
2. **Safe by default.** The app never leaves the Mac in a state the user did not choose: every
   system setting it changes is restored on quit, crash, uninstall and reboot. Safety guards
   (battery, heat, crash recovery) are free and on by default.
3. **No jargon in the interface.** No "clamshell", "hibernatemode", "assertion", "dark wake".
   Say what the user sees: "Sleep when I close the lid, even with a screen plugged in",
   "Save the session to disk after 1 hour so the battery lasts".
4. **Event-driven, no polling** for the lid and power state (IOKit notifications), so reactions
   are immediate and cost no battery.
5. **Private.** No account, no analytics. Network use is limited to update checks, documented.
6. **Everything free.** No tiers, no license, no purchase, in both editions. The full edition
   asks for support with a discreet "Buy me a coffee" link (About tab, bottom of the first
   settings tab, website); the Store edition has no donation link (guideline 3.1.1).

### Positioning

What sets ClamStop apart:

1. **One app instead of many.** It replaces the tools that manage what the lid does (sleep despite
   a screen, stay awake on battery) and the tools that block sleep by hand (KeepingYouAwake,
   Amphetamine, Caffeine) or while something runs: AI coding agents, video encoding and exports
   (HandBrake, Final Cut Pro, Compressor, DaVinci Resolve, ffmpeg), renders, builds, downloads.
2. **Simple, yet complete.** A first-time user answers one question and is done; every case found
   in other tools is still reachable through sessions and rules, without a separate setting for
   each.

## 2. Personas

| Persona | Situation | Needs |
|---|---|---|
| **Monique, 72, retired** | MacBook Air on a desk with a big screen; closes it at night. Finds it warm in the morning. | Install, answer one question, forget it. Large clear labels, no Terminal, nothing to maintain. |
| **Karim, office worker** | Docked at work with a monitor; closes the lid to go home, Mac stays awake in the bag. | Sleep on close, hibernate so the battery is full the next day; keep awake during a presentation. |
| **Léa, developer** | Runs Claude Code and builds; wants the Mac to keep working with the lid closed, then sleep. | Keep awake while agents work, lid-closed sessions, CLI, hotkeys, Shortcuts, logs. |
| **Sam, home server user** | Old MacBook used as a server with the lid closed. | Stay awake on power, sleep on battery, scheduled wake, notifications. |

## 3. Concepts

- **Lid action**: what happens when the lid closes. One of: *Sleep* (default), *Stay awake*,
  *Stay awake, then sleep after a delay*, *Turn the screens off only*, *Do what macOS does*.
- **Hibernation**: after the Mac has been asleep for a delay, its memory is saved to disk and
  power is cut, so the battery does not drain. Delay: never, immediately, 5 min to 4 h, custom.
- **Session**: a temporary "stay awake" period (now, for a duration, until a time, while
  something runs). Sessions override the lid action until they end.
- **Rule**: "When *conditions*, use *these settings*". Conditions: power source, battery level,
  external display, Wi-Fi network, app running, time of day, device connected... Rules are how
  every trigger found in other apps is expressed, without a separate feature for each.
- **Safety guard**: a limit that ends any session and lets the Mac sleep (battery floor, heat,
  power unplugged, maximum duration, crash recovery).

## 4. Features

Columns: **Ed.** F = full edition (Developer ID, root helper), S = Store
edition (sandbox), F+S = both. **Prio** M = first public release, 1 = next releases,
L = later or to be validated. **Tech** notes requirements: root (daemon), private API, hardware.
"Seen in" names tools from the appendix that offer the feature.

### A. Lid close (core)

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| A1 | Sleep when the lid closes, even with an external display, keyboard and power connected | F+S | M (exists) | IOKit lid notification; `pmset sleepnow` or `IOPMSleepSystem` (verified sandboxed) | noclamshell, Lidsleep (Royal-lobster), Lid-sleep (tyilo), no-clamshell, lidwatch, Clamshell (App Store), Sleep Control Centre |
| A2 | Choose the lid action: Sleep / Keep working when a screen is plugged in, even on battery / Stay awake / Turn the screens off only / Do what macOS does | F (stay awake on battery), S (on power only) | M | Stay awake with lid closed: `pmset disablesleep` (root) or assertions (power + display only) | LidSleepToggle (Sufxx), lidawake (richardlinq), continuity-control, hendrilee/lidsleep, Sleep Control Centre |
| A3 | Delay before sleeping after the lid closes (30 s to 2 h), to carry the Mac to a meeting or finish a task | F | 1 | `disablesleep` during the delay | lidsleep (DerekYeh), PeachPocket, Lid Close Sleep Delay (Windows) |
| A4 | Re-sleep guard: if the Mac wakes while the lid is still closed (Bluetooth, network, glitch), put it back to sleep after a short grace period | F+S | M | Lid state + wake reason | lid-sleep-app (wood-sheep), noclamshell |
| A5 | "Sleep now" in the menu, which also works while a lid hold is active (Apple menu > Sleep does not) | F+S | M | | double-shot, Sleep Expert, turnintoserver |
| A6 | Lid sensor fallback: use the hinge angle (or light sensor) when the lid magnet sensor misreports (macOS 27 false-closed bug, broken sensor) | F | L | Lid angle HID sensor, private APIs | hendrilee/lidsleep, macbook-lid-sleep-fix, macbook-clamshell-fix, lid-sleep-app |
| A7 | Partly closed lid: dim the built-in screen and keyboard below an angle, restore when reopened | F | L | Lid angle sensor | lidoff, Dimmer, Latch |

### B. Hibernation and battery

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| B1 | Hibernate after a delay while asleep: never, 5 min to 4 h, custom; default 1 h | F | M (exists) | Scheduled wake + `hibernatemode 25` (root). Unique on Apple Silicon, where `standbydelay` is ignored | none (Keyboard Maestro macro on MacPowerUsers) |
| B2 | Hibernate immediately on lid close | F | M (exists) | `hibernatemode 25` before sleep | HsOjo SleeperX (Hackintosh) |
| B3 | Hibernate (or sleep) when the battery falls below a level | F | M | Battery level on wakes | SleeperX, Sleepless, double-shot |
| B4 | Separate settings on power and on battery (lid action, hibernation delay) | F+S | M | | MacMiniMode, turnintoserver, Clapet, mac-lid-mode-adjuster |
| B5 | Morning report: battery used during the night, how long it slept, whether it hibernated | F+S | 1 | Sleep log (H3) | Latch (lid journal), LidSleepToggle (dashboard), adrafinil |
| B6 | Low Power Mode during lid-closed sessions, restored after | F | 1 | `pmset lowpowermode` (root) | Insomnia (krishhgg), Pilot Light, ClamDown |

### C. Staying awake (sessions)

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| C1 | Stay awake now ("Activate for duration"): until turned off (default), 5, 10, 15, 30 min, 1, 2, 5, 8 h, custom, or until a time; default duration in settings; left-click on the icon toggles it (option), right-click opens the menu. Lid open: idle sleep only; lid closed: see C2 | F+S | M | Power assertions | KeepingYouAwake, Amphetamine, Caffeine, Insomnio, Sleep Expert, InsomniaZ, Tazzina, Awayke |
| C2 | Keep working with the lid closed during a session (on power; on battery in the full edition) | F (S: power only, to verify) | M | `disablesleep` (root); Lidwork claims a sandboxed method, to verify | Insomnia (krishhgg), Lidless, Sleepless, ClamDown, double-shot, Lidwork, NeverFold, InsomniaZ, MacMiniMode, dozens more |
| C3 | Screen policy during a session: let screens sleep, keep them on, or switch the built-in screen off when the lid is closed | F+S | M | Display assertions; brightness 0 | Amphetamine, Capsomnia, MacMiniMode, agent-lid-closed, LidSleepToggle |
| C4 | Session end: reminder 5 min before, "+30 min" button, optional sleep at the end if the lid is closed | F+S | 1 | | Insomnio, Insomnia (krishhgg), Capsomnia |
| C5 | Stay awake while a chosen app or command works (by name, path or PID): it is busy when it keeps the Mac awake on its own (power assertion) or uses more than 5 % of the processor (starting value, to tune); then the Mac stays awake, even with the lid closed, until neither is true, with a ready-made list of known long jobs: HandBrake, Final Cut Pro, Compressor, DaVinci Resolve, Premiere Pro, Blender, ffmpeg, Xcode builds, Ollama, LM Studio | F+S | M | Process list (sandbox: to verify for CLI processes) | Amphetamine, Lchika, Fermata, Insomnio, LidAwake (Vladimir-Podgornyi) |
| C6 | Stay awake while a download or upload is in progress | F+S | 1 | Network throughput | Amphetamine, Insomnio, LidAwake (Vladimir-Podgornyi) |
| C7 | Stay awake while AI coding agents work, then sleep when they all wait or finish: hooks for Claude Code, Codex, Gemini CLI, Antigravity, Cursor, Copilot CLI, OpenCode (not yet); Aider, without a hook for the start of a task, through C5; leases that expire if an agent is killed | F (S: to verify) | M (in progress) | Agent hooks + process activity | clamshut, adrafinil, double-shot, LidSleepToggle, agent-lid-closed, Lidless, Lockpaw, No Sleep for AI, Keep Awake: AI Agents, lidsleep (DerekYeh) |
| C8 | "Sleep when idle" ending: stay awake while work happens (processor busy, another app holding sleep, input), then sleep | F+S | 1 | Load, assertions, HID idle | LidAwake (Vladimir-Podgornyi), Sleep Expert (Force Sleep) |
| C9 | Physical switch: Caps Lock or a hotkey turns a session on and off | F+S | L | Event tap (Accessibility permission) | Capsomnia, CapsAwake, No Sleep for AI, PeachPocket |

### D. Rules and schedules

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| D1 | Rules: when conditions are true, apply a lid action, a hibernation delay or a session. Conditions: power adapter, battery level, external display connected or mirrored, Wi-Fi network, IP/VPN/DNS, USB or Bluetooth device, app running or frontmost, audio output in use, day and time | F+S | 1 (M: power, display, time) | | Amphetamine (triggers), Sleep Control Centre, Tazzina, Insomnio, Latch (conditions), Clapet |
| D2 | ~~Exceptions to forced sleep during calls, presentations or a chosen app~~ dropped after the mockup review (2026-11-26): choosing "Do what macOS does" as the lid action, or a rule (D1), covers it | - | - | | Fermata, Amphetamine |
| D3 | Schedules: sleep at a time, wake or turn on at a time (Apple removed this from System Settings) | F | 1 | `IOPMSchedulePowerEvent` (root) | LidAwake (Vladimir-Podgornyi), goguma, `pmset repeat` |
| D4 | Wake before scheduled jobs (launchd, cron) and let the Mac sleep after | F | L | Job discovery | goguma |
| D5 | Presets that create rules in one click: "Desk with a screen", "Overnight work on power", "AI agents", "Home server" | F+S | 1 | | MacMiniMode modes, continuity-control |

### E. Safety guards (on by default)

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| E1 | Battery floor: end any session and sleep below a level on battery (default 20 %, minimum 5 %) | F+S | M | | nearly all keep-awake tools |
| E2 | Heat guard: end a lid-closed session when the Mac gets hot (first warm level when the lid is closed) | F+S | M | `ProcessInfo.thermalState` | clamshut, double-shot, ClamDown, Lidless, Lidwork |
| E3 | Only while charging: end a lid-closed session when the power adapter is disconnected (option, default on) | F+S | M | | MacMiniMode, Lidless, turnintoserver, Insomnio |
| E4 | Crash recovery: a watchdog in the daemon restores normal sleep within seconds if the app quits, crashes or hangs; the next launch undoes leftovers | F | M | Daemon heartbeat | Lidless, double-shot, Insomnia (krishhgg), ClamshellToggle, StayAwake, PeachPocket, Lidwork |
| E5 | Maximum session length (option, off by default) | F+S | 1 | | ClamshellToggle |
| E6 | ~~"Mac in a bag" warning~~ dropped after the mockup review (2026-11-26): a bag cannot be told from a desk, and the heat guard (E2) and battery floor (E1) already cover the risk | - | - | | double-shot |
| E7 | Restore every system setting the app changed (`hibernatemode`, `disablesleep`, Low Power Mode, scheduled wakes) on quit, uninstall and reboot | F | M (exists) | Persisted state | ClamStop, ClamDown, Insomnia (krishhgg) |

### F. Actions on lid close, sleep and wake

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| F1 | Pause audio and video while the Mac sleeps, resume on wake: automatic and hidden (no setting), only to avoid the half second of sound during the wake that leads to hibernation | F | M (exists) | MediaRemote (private) | ClamStop, Insomnia (krishhgg, mute), Latch |
| F2 | Lock the screen when the lid closes during a session | F+S | 1 | Private lock call, fallback display sleep | ClamshellToggle, ClamDown, SleeperX, mac-autolock, Lockpaw |
| F3 | Run a Shortcut or a script on lid close, lid open, sleep, wake | F+S | 1 | Shortcuts; scripts sandbox-limited | sleepwatcher, Latch, clamshell (treydempsey), Fermata |
| F4 | Disconnect chosen Bluetooth devices on sleep, reconnect on wake | F | L | | BlueBed |

### G. Displays

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| G1 | Turn the built-in screen off while the lid is open and an external display is connected; restore on unplug or quit | F | L | Private display API | OpenClamshell, clamOpen, ClamshellOpen |
| G2 | Built-in screen at zero brightness during lid-closed sessions, restored when opened | F+S | M (with C3) | | agent-lid-closed, MacMiniMode, turnintoserver, Insomnia (krishhgg) |

### H. Visibility and diagnostics

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| H1 | Menu bar icon with clear states (normal, staying awake, lid hold, paused), optional remaining time; can be hidden | F+S | M (exists) | | all |
| H2 | "What keeps my Mac awake?": apps and processes holding sleep off now, and since when | F+S | 1 | `IOPMCopyAssertionsByProcess` | Sleep Expert (Sleep Inspector), LidSleepToggle (Awake Radar) |
| H3 | Sleep journal: lid opened and closed, slept, woke (with reason), hibernated, battery used | F+S | M | Unified log + own records | Latch, LidSleepToggle, LidAwake (Vladimir-Podgornyi) |
| H4 | Health check, "Copy diagnostics" and "Report a problem" (prefilled GitHub issue or e-mail, sent by the user) for support (service state, settings, recent events) | F+S | 1 | | MacMiniMode |
| H5 | Notifications: session ended, safety stop and why, background service needs approval | F+S | M | | double-shot, Insomnio, clamshut |
| H6 | Phone notifications through ntfy, Pushover or a webhook | F+S | L | Network | Lockpaw, LidSleepToggle, continuity-control, turnintoserver |

### I. Control for advanced users

| ID | Feature | Ed. | Prio | Tech | Seen in |
|---|---|---|---|---|---|
| I1 | Global keyboard shortcuts: start or stop a session, sleep now | F+S | 1 | | Clapet, InsomniaZ, Insomnio, PeachPocket, turnintoserver |
| I2 | URL scheme: `clamstop://awake?minutes=30`, `clamstop://sleep`, `clamstop://off` | F+S | 1 | | Tazzina, Lidwork |
| I3 | Command line: `clamstop status`, `clamstop sleep`, `clamstop awake --for 30m`, `clamstop hook claude` | F | 1 | App binary as CLI (exists for hooks) | MacMiniMode, adrafinil, Insomnia (krishhgg) |
| I4 | Shortcuts actions, Siri, Spotlight, Control Center control | F+S | 1 | App Intents | Insomnio, Latch, No Sleep for AI, Lockpaw |
| I5 | One-click installation of agent hooks (Claude Code, Codex...), with a preview of the change | F | M | | double-shot, agent-lid-closed, No Sleep for AI |

### J. App basics

| ID | Feature | Ed. | Prio |
|---|---|---|---|
| J1 | First-run assistant (section 5) and background service approval with an illustrated step | F+S | M (exists, extend) |
| J2 | Open at login; reopening the app shows the window when the icon is hidden | F+S | M (exists) |
| J3 | Menu bar icon styles (laptop, clam, more) | F+S | M (exists) |
| J4 | Languages: English, Simplified Chinese, Japanese, German, French, Spanish | F+S | 1 |
| J5 | Automatic updates (Sparkle) | F | M |
| J6 | "Buy me a coffee" link in the About tab and at the bottom of the first settings tab, "Donate…" in the menu bar menu; never a pop-up or a reminder. A donation gives nothing in return (no feature, no support priority, no listing) and no tax receipt: said next to the link in the app's windows (the menu item opens the donation page without it, decided 2026-11-27), and in full in the website's Support section and the README | F | M |
| J7 | Uninstall from the app: restore all settings, remove the service and preferences | F | M (exists) |
| J8 | Light and dark mode, VoiceOver labels on every control, full keyboard navigation | F+S | M |

## 5. User experience

### First run (under a minute: 3 screens in the full edition, 1 in the Store edition)

Most tools on the market solve the opposite need (stay awake with the lid closed), so the first
screen offers both directions instead of assuming one.

1. "What should happen when you close the lid?" Large choices, each with one line of
   explanation:
   - *Sleep, even when a screen is plugged in* (recommended);
   - *Keep working when a screen is plugged in, even on battery* (macOS alone requires the
     power adapter; full edition only, it needs the background service);
   - *Stay awake while AI agents work, then sleep* (Claude Code, Codex...).
   The choice becomes the lid action (A2) or a preset (D5).
   One-off needs ("stay awake for 2 hours while this runs") are not asked here: they live in the
   menu bar (C1).
2. "Allow ClamStop in System Settings": illustration of the switch, button that opens the right
   pane, automatic detection when it is done. **Full edition only** (the Store edition has no
   background service).
3. "When the Mac has been asleep for a while, should it save everything to disk to keep the
   battery full?" Choices: *After 1 hour (recommended)*, *Never*. **Full edition only**
   (hibernation needs the background service). Done.

### Main window

- Top: one sentence that says what will happen now, for example "When you close the lid, your Mac
  goes to sleep. After 1 hour it hibernates." Updated live when rules or sessions apply.
- **Simple settings** (always visible): *When I close the lid* (picker), *Hibernate*
  (picker), *Show in the menu bar*, *Open at login*.
- **More options** (tabs): Sessions (with the agent hooks, shortcuts and automation), Rules and
  presets, Safety (with the low battery action), Diagnostics (health check, sleep journal, problem
  reports). Full edition: a discreet "Buy me a coffee" link at the bottom of
  the first tab, never a pop-up interrupting the user.
- Every option has a one-line footnote in plain words and an ⓘ help popover with an example.

### Menu bar menu

Status line, *Stay awake* submenu (Until I turn it off, 5, 10, 15, 30 min, 1, 2, 5, 8 h,
Until..., While an app runs...), *Sleep now*, *Settings...*, *Donate...* (full edition),
*Quit ClamStop*. Optional: left-click on the icon starts or stops a session with the default duration, as in KeepingYouAwake. Remaining time shown when a session
runs. Quitting while a session or lid hold is active asks once and restores normal sleep.

### Wording and accessibility

- Short sentences, verbs first, the user's point of view ("your Mac", "you close the lid").
- Say the consequence of risky choices next to them: "Your Mac will stay awake with the lid
  closed. Do not put it in a bag."
- Minimum text size: system default; no information carried by color alone; all controls reachable
  by keyboard and VoiceOver.

## 6. Edition differences

| | Full edition (website) | Store edition |
|---|---|---|
| Sleep on lid close | yes | yes |
| Hibernation (B1, B2, B3) | yes | no (needs root) |
| Keep working with a screen on battery, lid-closed sessions on battery, delay after close (A2, A3, C2) | yes (`pmset disablesleep`, root) | no on battery (tested 2026-11-26: no sandboxed method works); on power, assertions while a display is connected |
| Schedules, wake at a time (D3, D4) | yes | no |
| Low Power Mode, crash watchdog in a daemon (B6, E4) | yes | no (sessions use assertions, released by macOS when the app quits) |
| CLI, agent hook installer (I3, I5) | yes | no (URL scheme and Shortcuts instead) |
| Price | free | free |
| "Buy me a coffee" link | About tab, bottom of the first settings tab, menu bar menu, website | none in the app (guideline 3.1.1: tips only through In-App Purchase); no mention of the full edition |
| Link to the website | anywhere | App Store listing (marketing and support URLs) may point to the home page; inside the app only a neutral "Help" link to a help page, never to a download or donation page, and no text pointing to the full edition |

## 7. Non-functional requirements

- macOS 14 or later, Apple Silicon and Intel (hibernation behavior differs on Intel:
  `standbydelay*` restored on uninstall).
- Reaction to lid close under 1 s; no polling; idle CPU near zero.
- Every root-level change goes through the daemon, which persists what it changed and restores it.
- Network: update check (Sparkle, signed appcast) only; listed in the
  privacy page and the README.
- Logs in the unified log (subsystem `io.github.chanoj.clamstop`); journal kept locally, 30 days.
- Tests: pure decision logic (lid action, rules, guards, sessions) in the shared target with fake
  clock and effects; real-Mac verification for each new system interaction.

## 8. Out of scope (and why)

| Seen in | Feature | Reason |
|---|---|---|
| ClamDown | Fan control | Writes to private SMC keys; hardware risk |
| Amphetamine, InsomniaZ, Sleep Control Centre | Fake mouse movement, "look active in Teams" | Misleads presence tools; not about sleep |
| Latch, Softclose, bendd, ClamShell (nthanhtin), Dimmer | Lid animations, blur, privacy veil | Cosmetic, unrelated |
| Lockpaw | Lock screen replacement with Touch ID | Security-sensitive, separate product |
| detach, muxbar, claude-code-server-syncer, iroowu/lid-closed-awake | Agent dashboards, tmux, file sync, remote control | Separate products; ClamStop only keeps the Mac awake for them |
| turnintoserver, continuity-control, Insomnia (kbortov-oss), mac-wifi-sleep-fix | Network routing, Wi-Fi recovery, hotspot | Networking, not power |
| mac-clamshell-iphone-mic | Switch microphone in clamshell mode | Audio routing; could be a Shortcut via F3 |
| agent-lid-closed | Switch AI accounts at usage limits | Unrelated to power |
| nosleep (kext), InsomniaT, Insomnia (Frizlab) | Kernel extensions | Obsolete, blocked on Apple Silicon |
| Kovrazhkin Clamshell, LidSleepToggle | iPhone companion app | Large effort; reconsider after launch |

## Appendix: tools surveyed (2026-11-26)

Stars are GitHub stars on 2026-11-26. "Force sleep" tools solve ClamStop's core problem; most
others do the opposite (stay awake).

### Force sleep on lid close (direct competitors)

| Tool | Type | What it does |
|---|---|---|
| pirj/noclamshell (580★) | Shell, Homebrew service | Polls `ioreg`, `pmset sleepnow` when the lid is closed with a display |
| Clamshell (Alexander Kovrazhkin) | Mac App Store, free, + iOS app | Disables clamshell mode, sleeps on lid close; iPhone shows Macs' lid and sleep status |
| Royal-lobster/Lidsleep | App + LaunchAgent | Polls every few seconds, forces sleep with a display connected |
| tyilo/Lid-sleep | Xcode project (2015) | Sleep on lid close with an external screen |
| vinceplusplus/no-clamshell | App | Sleeps when the built-in display disconnects |
| KristijanKocev/lidwatch | App | Sleep a docked MacBook when its lid closes |
| sickn33/macbook-lid-sleep-fix, hendrilee/lidsleep, wood-sheep/lid-sleep-app, bordeux/macbook-clamshell-fix | Scripts, apps | Lid detection from light or hinge-angle sensors when the magnet sensor fails; re-sleep after false wakes |
| Sleep Control Centre | Mac App Store | Trigger "Close Lid" among many keep-awake and sleep triggers |
| Sleep Expert | Mac App Store | Sleep now, Force Sleep after idle despite blockers, Sleep Inspector |

### Homonyms

- **Lidsleep / lid-sleep**: Royal-lobster (force sleep with a display), DerekYeh (stay awake N
  minutes after close, sleep when Claude sessions finish, root daemon), hendrilee (hinge-angle
  sleep or clamshell), Yeyito777, shepherd2047, longsail313, Sufxx LidSleepToggle (three modes +
  agents + iPhone app), sonofmagic (Homebrew tap), Jellouse/LidSleepFix, aapolipponen.
- **Clamshell**: Kovrazhkin (App Store, force sleep), Setapp Clamshell (stay awake when closing
  with Option held, heat and battery disarm), laplaces42 ClamshellToggle (stay awake, lock on close,
  safety stops), treydempsey (run a command on lid open/close), wang-junjian (toggle with low-battery
  guard), matabar (desktop widget), nthanhtin (fold animation).
- **Insomnia**: krishhgg/Insomnia (2162★, timed lid-closed sessions, display off, mute, Low Power
  Mode, app freezing, recovery agent), michalptacekcz, kbortov-oss (hotspot recovery), Frizlab
  (kext); InsomniaZ (App Store, 14.99 USD); InsomniaX (abandoned).
- **LidAwake / lidawake**: Vladimir-Podgornyi (notarized; sleep when idle, wake at a time, heat and
  battery stops, 10 languages), richardlinq (keep running vs let it sleep, battery reserve model),
  deezeddd, TurboKach, thuongtin.

### Stay awake with the lid closed (opposite need, crowded)

Amphetamine (free, triggers), InsomniaZ, Lidwork (sandboxed, 9.99 USD), NeverFold, NEVER SLEEP,
Insomnio (Pro: lid closed, agents, schedules), Keep Awake: AI Agents (subscription), No Sleep: Stay
Awake for AI (Caps Lock switch), Lchika (while registered apps or commands run), Tazzina
(sessions, triggers, URL scheme), Capsomnia (453★, Caps Lock switch), adrafinil (532★, agent hooks
and MCP), Lidless (190★, SMAppService helper, watchdog, Sparkle), Sleepless (136★, battery floor),
double-shot (112★, agents, heat stop in a bag), ClamDown (fans, lock, cut-offs), MacMiniMode (210★,
automatic on power), Pilot Light (Low Power Mode, display off), Awayke, StayAwake, Clapet (106★,
automatic with an external display), Fermata (199★, while a music app runs), clamshut (agent
leases), agent-lid-closed, goguma (wake for scheduled jobs), and about 60 smaller projects.

### System and command line tools

`pmset` (sleepnow, disablesleep, hibernatemode, schedule and repeat, lowpowermode), `caffeinate`
(idle sleep only, not lid close), sleepwatcher and SleepWatcher 3 (run scripts on sleep, wake, idle,
lock, power changes), KeepingYouAwake, Caffeine and Theine (idle sleep only), Keyboard Maestro and
Hammerspoon recipes, Shortcuts.
