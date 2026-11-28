# Mac App Store edition: feasibility

Status (2026-11-28): not built. `CLAMSTOP_EDITION=appstore swift build` (checked by CI) only leaves
out Sparkle and the private screen lock and brightness calls; `Edition.current` is still `.full`,
and there is no sandboxed bundle, power backend or Store packaging yet.

Tested 2026-11-26 on a MacBook Pro M5 Pro, macOS 27.2.1, with the spike in
`spike/store-sandbox/` (`build.sh`, then `StoreSpike --probe` or `StoreSpike --lid iokit|pmset`).
The test app was ad-hoc signed with **only** `com.apple.security.app-sandbox` and ran sandboxed
(`APP_SANDBOX_CONTAINER_ID` set, home = its container), as a normal user, no root helper.
The real ClamStop daemon was switched off (`enabled: false`) during the lid tests.

## Why a reduced edition

App Review Guideline 2.4.5 requires the App Sandbox (2.4.5(i)) and forbids requesting
escalation to root privileges or using setuid attributes (2.4.5(v)). ClamStop's root
LaunchDaemon (SMAppService) therefore cannot ship in a Store build.

## Results

| Capability | Sandboxed, no root | Notes |
|---|---|---|
| Lid close notification (`IOServiceAddInterestNotification` on `IOPMrootDomain`, `0xE0034100`) | **Works** | Fires at once on close. |
| Read `AppleClamshellState` | Works | |
| Sleep/wake notifications (`IORegisterForSystemPower`) | Works | |
| Open `RootDomainUserClient` (`IOPMFindPowerManagement`) | Works | No `iokit-user-client-class` exception needed. |
| **Force sleep in clamshell mode with `IOPMSleepSystem`** | **Works** | Lid test with external display + AC + keyboard: "Software Sleep" in `pmset -g log` within 5 s, despite sleep assertions held by other apps (Claude, coreaudiod). |
| Force sleep by spawning `/usr/bin/pmset sleepnow` | Works | The child inherits the sandbox; same result. Not needed since the IOKit call works. |
| Sleep assertions (`IOPMAssertionCreateWithName`, for a keep-awake feature) | Works | |
| Stay awake with the lid closed on battery with an external display (`kPMSetClamshellSleepState` = 1 on `RootDomainUserClient`, public selector 12 in `IOPMLibDefs.h`) | **Fails** | The call returns success sandboxed (and unsandboxed as a normal user), but the lid test on battery with an HDMI display still ended in "Clamshell Sleep" (2026-11-26, `StoreSpike --awake clamshell`). Power assertions are ignored on lid close on battery. The known working method, `pmset disablesleep 1`, needs root. |
| Scheduled wake (`IOPMSchedulePowerEvent`) | **Fails** | `kIOReturnNotPrivileged` (0xe00002c1). Same result unsandboxed: it needs root, not just outside the sandbox. |
| Change `hibernatemode` (`pmset -a hibernatemode`) | **Fails** | "must be run as root". |

So **delayed hibernation is impossible** in a Store build (it needs both a root-scheduled wake and
`hibernatemode 25`), and so is immediate hibernation. Asking users to run `sudo pmset` themselves
would work technically but would likely be read as working around 2.4.5(v); do not do it.

## Entitlements and review risk

- Only `com.apple.security.app-sandbox` is needed. No `temporary-exception` entitlement (those are
  often rejected and need a justification). Open at login via `SMAppService.mainApp` (user consent).
- All APIs used are public IOKit (`IOKit/pwr_mgt`), so 2.5.1 (public APIs only) is met.
- Remaining review risks, low to moderate: 2.4.5 reviewers may question an app that forces system
  sleep, so the review notes should explain the clamshell use case and that sleep only follows a
  user-enabled setting; 4.2 (minimum functionality) is met by the settings UI and menu bar item.
- Not tested: detecting AI agent CLIs (e.g. `claude`, `codex` processes) from the sandbox for the
  keep-awake feature. `NSWorkspace.runningApplications` only lists GUI apps; listing other
  processes may be restricted. Spike that before promising it in a Store build.

## Recommendation: go, later and small

Go for a reduced Store edition, **after** the Developer ID release, built from the same repository:

- One codebase, two builds selected by the build script (compile flag such as `-D APPSTORE`):
  - full edition: Developer ID, root daemon (SMAppService), Sparkle updates, "Buy me a coffee" link;
  - Store edition: App Sandbox entitlement only, no daemon in the bundle, lid handling and
    `IOPMSleepSystem` in the app itself, no donation link.
  Behind one small protocol (power backend), everything else (settings, UI, features) is shared. CI builds both variants so neither breaks unnoticed. Use a separate bundle id
  (for example `io.github.chanoj.clamstop.appstore`) so both can be installed and tested side by side.
- Both editions are free, with every feature (decided 2026-11-26; an earlier plan had a Pro tier).
  The Store edition has what needs no root: no hibernation, no stay-awake on battery with the lid
  closed, no schedules.
- The Store build must not mention the full edition, an external purchase or donations
  (guideline 3.1.1: tips only through In-App Purchase).
- Extra work: a Mac App Distribution certificate and provisioning profile, and upload with
  Transporter (Xcode is probably needed for upload).

Its value is discoverability and trust (Store search, no Gatekeeper warning), not features: the
Developer ID build stays the full product.
