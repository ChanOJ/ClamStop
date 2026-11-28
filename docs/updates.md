# Updates (Sparkle)

The full edition updates itself with [Sparkle 2](https://sparkle-project.org) (pinned in
`Package.swift`). The Mac App Store edition is built without it (`CLAMSTOP_EDITION=appstore`).

## How it works

- Each `v*` tag runs `release.yml`. After notarization, `scripts/make-appcast.sh` signs the DMG
  with the EdDSA private key (GitHub secret `SPARKLE_ED_PRIVATE_KEY`) and writes `appcast.xml`,
  uploaded with the DMG to the GitHub Release.
- The app reads `https://github.com/ChanOJ/ClamStop/releases/latest/download/appcast.xml`
  (`SUFeedURL` in `Resources/Info.plist`): GitHub redirects it to the newest release that is not
  a pre-release. No website needed.
- The app accepts an update only if its EdDSA signature matches `SUPublicEDKey` (from
  `Resources/sparkle-public-ed-key.txt`) **and** its code signature satisfies the installed app's
  designated requirement.
- Settings: "Automatically check for updates" (Sparkle asks once, at the second launch) and
  "Check for Updates…", also in the menu. Background checks never pop up a window: the menu shows
  "Update Available…" instead (Sparkle's gentle reminders). Sparkle sends no system profile.

## Requirements

- **Developer ID signing.** An ad-hoc signature's requirement is the exact hash of that build, so
  ad-hoc builds can never update each other (verified 2026-11-26: Sparkle refuses with "Code
  signature of the new version doesn't match the old version"). `make-appcast.sh` therefore writes
  no appcast for an app that is not Developer ID signed. The first Developer ID release must be
  installed by hand; later ones update automatically.
- **The EdDSA key pair** below. Without the public key file, builds have updates turned off (the
  Updates section and menu item are hidden). Without the secret, releases publish no appcast.

## Create the signing key (once)

Done on 2026-11-28: the steps below are only for a new key. The private key never goes into the
repository. It lives in Proton Pass and in a GitHub secret.

1. Build once so that SwiftPM downloads Sparkle and its tools:

   ```bash
   swift build
   ```

2. Generate the key pair. macOS asks to allow saving it in the login keychain: click
   **Always Allow** or **Allow**. The command prints the public key:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account clamstop
   ```

3. Export the private key to a file in `Downloads`:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account clamstop -x ~/Downloads/clamstop-sparkle-private-key.txt
   ```

4. In Proton Pass, create a **Note** item named `ClamStop Sparkle EdDSA key pair` and paste the
   content of that file (one line of base64), plus the public key from step 2.
5. Add the GitHub secret from the file:

   ```bash
   gh secret set SPARKLE_ED_PRIVATE_KEY --repo ChanOJ/ClamStop < ~/Downloads/clamstop-sparkle-private-key.txt
   ```

6. Check that the secret is listed:

   ```bash
   gh secret list --repo ChanOJ/ClamStop
   ```

7. Delete the exported file:

   ```bash
   rm ~/Downloads/clamstop-sparkle-private-key.txt
   ```

8. Give the public key (step 2) to Claude, or write it alone in
   `Resources/sparkle-public-ed-key.txt` and commit it (it is public).

The key also stays in the login keychain ("Private key for signing Sparkle updates", account
`clamstop`): you can delete it there once Proton Pass holds it. If the private key leaks or is
lost, generate a new pair and ship the new public key in a release signed with the old key
(Sparkle's key rotation); installed apps cannot be moved to a new key otherwise.

## Test an update locally

`scripts/make-appcast.sh` accepts `DOWNLOAD_URL` and `APPCAST_ANY_SIGNATURE=1` for local tests.
The end-to-end test of 2026-11-26 built 0.9.0 and 0.9.1 with a test bundle id
(`io.github.chanoj.clamstop.updatetest`, no daemon plist, so the installed ClamStop is never
touched), a throwaway key (`swift scripts/sparkle-key.swift generate`), a temporary self-signed
code signing certificate (stable requirement, like Developer ID), and a local feed served on
`http://127.0.0.1:<port>` (`SPARKLE_FEED_URL`). 0.9.0 found 0.9.1, checked the EdDSA signature
and replaced itself.
