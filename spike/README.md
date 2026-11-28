# Spikes

Standalone probes that checked macOS behavior before it was built into the app. They are not
part of the package build; results are recorded in `CLAUDE.md` and `docs/app-store-edition.md`.

- `probe.swift`: lid close detection through IOKit and forced sleep despite "prevent sleep"
  assertions (`swiftc spike/probe.swift -o spike/probe`, then `spike/probe [--sleep]`).
- `mediaremote.swift`: reads and pauses playback through the private MediaRemote framework,
  as `AudioPauser` does (`swift spike/mediaremote.swift [--watch]`).
- `store-sandbox/`: what a sandboxed Mac App Store build can do without root
  (`spike/store-sandbox/build.sh`).
