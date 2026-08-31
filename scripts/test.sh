#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/moduleCache
xcrun clang tests/shutdownFixture.c -o build/codex-shutdown-fixture
xcrun swiftc -swift-version 5 -D SELF_TEST -module-cache-path "$PWD/build/moduleCache" \
  sources/authStore.swift sources/accountUsage.swift sources/usageMonitor.swift sources/clientShutdown.swift sources/processControl.swift \
  sources/macRuntime.swift tests/authTests.swift tests/shutdownTests.swift tests/usageTests.swift sources/main.swift \
  -o build/accountTests
build/accountTests
