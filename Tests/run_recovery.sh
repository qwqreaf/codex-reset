#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
sources=()
for source in Sources/CodexReset/*.swift; do
    case "$source" in
        */main.swift|*/ContentView.swift|*/SettingsPanelView.swift|*/MenuBarController.swift) ;;
        *) sources+=("$source") ;;
    esac
done
swiftc -parse-as-library -module-cache-path /tmp/codexreset-module-cache -lsqlite3 "${sources[@]}" Tests/Recovery/Test.swift -o "$test_dir/recovery-tests"
"$test_dir/recovery-tests"
