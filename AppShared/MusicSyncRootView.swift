import SwiftUI

struct MusicSyncRootView: View {
    @StateObject private var host = HostModel()
    @StateObject private var client = ClientModel()
    #if os(macOS)
    @State private var role = 1
    #else
    @State private var role = 0
    #endif
    var body: some View {
        TabView(selection: $role) {
            Tab("Listen", systemImage: "speaker.wave.2", value: 0) { ClientView(model: client) }
            Tab("Host", systemImage: "antenna.radiowaves.left.and.right", value: 1) { HostView(model: host) }
        }
        .disabled(host.busy)
        .onChange(of: role) { _, newRole in
            if newRole == 0 { host.stopHost() }
            else { client.disconnect(); client.stopDiscovery() }
        }
    }
}
