# Mac App Store edition: feasibility

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

Go for a reduced Store edition, **after** the Developer ID release, from the same code with a
compile-time switch that leaves out the daemon:

- Contains: sleep on lid close (clamshell included), menu bar icon, open at login, Pro features
  that need no root (per-power-source on/off, schedules and exceptions, keep-awake if the agent
  detection works sandboxed), unlocked by an In-App Purchase (15 % with the Small Business Program).
- Leaves out: hibernation (delayed and immediate); the Store listing points to the free
  Developer ID build for it.
- Extra work: a Mac App Distribution certificate and provisioning profile, StoreKit 2 for the
  purchase, and upload with Transporter (Xcode is probably needed for StoreKit testing and upload).

Its value is discoverability and trust (Store search, no Gatekeeper warning), not features: the
Developer ID build stays the full product.
