#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audio_test_dir=$(mktemp -d)
trap 'rm -rf "$audio_test_dir"' EXIT
xcrun swiftc -emit-library -emit-module -module-name MusicSyncCore \
  Shared/MusicSyncCore/Sources/MusicSyncCore/*.swift \
  -emit-module-path "$audio_test_dir/MusicSyncCore.swiftmodule" \
  -o "$audio_test_dir/libMusicSyncCore.dylib"
xcrun swiftc -parse-as-library -I "$audio_test_dir" -L "$audio_test_dir" -lMusicSyncCore \
  -Xlinker -rpath -Xlinker "$audio_test_dir" \
  AppShared/AudioSource.swift AppShared/FileAudioSource.swift AppShared/Localization.swift scripts/AudioSmoke.swift \
  -o "$audio_test_dir/AudioSmoke"
"$audio_test_dir/AudioSmoke"
