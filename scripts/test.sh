#!/bin/bash
# Runs the tests, locally or in CI: scripts/test.sh [extra swift test arguments]
#
# With only the Command Line Tools (no Xcode), SwiftPM does not tell the compiler where the
# Swift Testing macro plugin lives, and every @Test fails with "plugin for module
# 'TestingMacros' not found". Pass the plugin folder explicitly in that case.
set -euo pipefail
cd "$(dirname "$0")/.."

args=()
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -f "$plugins/libTestingMacros.dylib" ] && [[ "$(xcode-select -p)" == */CommandLineTools ]]; then
    args+=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi
exec swift test ${args[@]+"${args[@]}"} "$@"
