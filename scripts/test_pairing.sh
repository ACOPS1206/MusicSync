#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 ACOPS1206
set -euo pipefail
cd "$(dirname "$0")/.."
pair_test_dir=$(mktemp -d)
trap 'rm -rf "$pair_test_dir"' EXIT
pair_sdk=$(xcrun --sdk macosx --show-sdk-path)
pair_target="$(uname -m)-apple-macos26.0"
xcrun swiftc -sdk "$pair_sdk" -target "$pair_target" -emit-library -emit-module -module-name MusicSyncCore \
  Shared/MusicSyncCore/Sources/MusicSyncCore/*.swift \
  -emit-module-path "$pair_test_dir/MusicSyncCore.swiftmodule" -o "$pair_test_dir/libMusicSyncCore.dylib"
xcrun swiftc -sdk "$pair_sdk" -target "$pair_target" -parse-as-library \
  -I "$pair_test_dir" -L "$pair_test_dir" -lMusicSyncCore -Xlinker -rpath -Xlinker "$pair_test_dir" \
  AppShared/*.swift macOS/MusicSyncMac/Capture.swift scripts/PairingSmoke.swift -o "$pair_test_dir/PairingSmoke"
"$pair_test_dir/PairingSmoke"
