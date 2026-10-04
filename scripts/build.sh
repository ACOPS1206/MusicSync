#!/bin/bash
# SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
# Copyright (c) 2026 ACOPS1206
# Source: https://github.com/ACOPS1206/MusicSync

set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
xcodebuild -project MusicSync.xcodeproj -scheme MusicSynciOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/iOS \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 | tee dist/iOS-build.log
xcodebuild -project MusicSync.xcodeproj -scheme MusicSyncMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/macOS \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 | tee dist/macOS-build.log
python3 scripts/package.py build/iOS/Build/Products/Release-iphoneos/MusicSync-iOS.app build/macOS/Build/Products/Release/MusicSync-macOS.app dist
