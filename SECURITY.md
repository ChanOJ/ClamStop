# Security

ClamStop installs a background service that runs as root, and updates itself. Reports about
either are especially welcome.

## Reporting a vulnerability

Please report privately, not in a public issue or discussion:
[report a vulnerability](https://github.com/ChanOJ/ClamStop/security/advisories/new)
(repository **Security** tab, then **Report a vulnerability**).

Include the ClamStop and macOS versions, what an attacker needs (for example a local account),
what they gain, and the steps to reproduce.

ClamStop is maintained in spare time: expect a first answer within two weeks. A fix ships in a
new release, and the advisory is published after it.

## Supported versions

Only the [latest release](https://github.com/ChanOJ/ClamStop/releases/latest) receives fixes.

## In scope

- The root service and who can talk to it (XPC), including the AI agent hooks.
- Software updates (Sparkle), code signing and notarization.
- The build and release workflows of this repository.
