#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/port-interop
swift build --package-path Shared/MusicSyncCore
CORE_BIN=$(swift build --package-path Shared/MusicSyncCore --show-bin-path)
xcrun swiftc -I "$CORE_BIN/Modules" scripts/PortsInterop.swift "$CORE_BIN"/MusicSyncCore.build/*.swift.o -o dist/port-interop/swift-client
(cd ports && gradle -PwithAndroid=false :desktop:interop --console=plain) > dist/port-interop/kotlin-host.log 2>&1 &
HOST_PID=$!
trap 'kill "$HOST_PID" 2>/dev/null || true' EXIT
# Compile/dependency resolution happens asynchronously; poll for the test listener, maximum 180 s.
for i in $(seq 1 90); do
    if nc -z 127.0.0.1 49555; then break; fi
    if ! kill -0 "$HOST_PID" 2>/dev/null; then cat dist/port-interop/kotlin-host.log; exit 1; fi
    sleep 2
done
dist/port-interop/swift-client
