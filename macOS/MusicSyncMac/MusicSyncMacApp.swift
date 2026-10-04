import SwiftUI
@main struct MusicSyncMacApp: App {
    var body: some Scene {
        WindowGroup("MusicSync") { MusicSyncRootView().frame(minWidth: 480, minHeight: 580) }
        .defaultSize(width: 540, height: 760)
    }
}
