#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/web-interop
swift build --package-path Shared/MusicSyncCore
CORE_BIN=$(swift build --package-path Shared/MusicSyncCore --show-bin-path)
xcrun swiftc -I "$CORE_BIN/Modules" scripts/WebInteropHost.swift "$CORE_BIN"/MusicSyncCore.build/*.swift.o -o dist/web-interop/swift-host
dist/web-interop/swift-host > dist/web-interop/swift-host.log 2>&1 &
SWIFT_PID=$!
trap 'kill "$SWIFT_PID" 2>/dev/null || true' EXIT
for i in $(seq 1 30); do
    if rg -q 'READY' dist/web-interop/swift-host.log; then break; fi
    if ! kill -0 "$SWIFT_PID" 2>/dev/null; then cat dist/web-interop/swift-host.log; exit 1; fi
    sleep 1
done
(cd web && MUSICSYNC_WEB_EXTERNAL_HOST=127.0.0.1:49557 npm run test:browser)
wait "$SWIFT_PID"
cat dist/web-interop/swift-host.log
