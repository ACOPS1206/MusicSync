// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import PackageDescription
let package = Package(name: "MusicSyncCore", platforms: [.macOS("26.0"), .iOS("26.0")], products: [.library(name: "MusicSyncCore", targets: ["MusicSyncCore"])], targets: [.target(name: "MusicSyncCore"), .testTarget(name: "MusicSyncCoreTests", dependencies: ["MusicSyncCore"])], swiftLanguageModes: [.v5])
