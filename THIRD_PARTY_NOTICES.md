# Third-party notices

## clamshut

ClamStop's AI agent keep-awake feature adapts the design and rules of clamshut: one lease per
agent session opened and closed by the agents' lifecycle hooks; leases kept by independent
evidence of work (live subagents, transcript and subagent transcript writes, CPU used by the
agent's process tree) and released on positive evidence that nothing runs (process gone, 90 s
grace period after a turn, 30 min without activity); `pmset disablesleep` to hold lid-close
sleep; battery floor and thermal guard; merging the hook into the agents' settings without
touching other hooks. The code is a Swift rewrite (`Sources/ClamStopShared/AgentTracker.swift`,
`Sources/ClamStopShared/AgentHookSettings.swift`, `Sources/ClamStop/AgentHookInstaller.swift`).
clamshut's logo and artwork are not used.

Source: https://github.com/IshaanChamoli/clamshut

```
MIT License

Copyright (c) 2026 Ishaan Chamoli

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
