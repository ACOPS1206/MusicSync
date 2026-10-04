// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import SwiftUI
@main struct MusicSyncMacApp: App {
    var body: some Scene {
        WindowGroup("MusicSync") { MusicSyncRootView().frame(minWidth: 480, minHeight: 580) }
        .defaultSize(width: 540, height: 760)
    }
}
