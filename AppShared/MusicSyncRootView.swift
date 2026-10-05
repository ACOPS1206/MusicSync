// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import SwiftUI

struct MusicSyncRootView: View {
    @AppStorage("appLanguage") private var appLanguage = "system"
    @StateObject private var host = HostModel()
    @StateObject private var client = ClientModel()
    #if os(iOS)
    @StateObject private var liveActivity = LiveActivityCoordinator()
    @AppStorage("liveActivitiesEnabled") private var liveEnabled = true
    @Environment(\.scenePhase) private var scenePhase
    private var liveSnapshot: LiveSessionSnapshot { role == 1 ? host.liveSnapshot : client.liveSnapshot }
    #endif
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
        .onReceive(Timer.publish(every:1,on:.main,in:.common).autoconnect()) { _ in host.refreshOutputVolume(); client.refreshOutputVolume() }
        #if os(iOS)
        .onReceive(Timer.publish(every:5,on:.main,in:.common).autoconnect()) { _ in liveActivity.report(liveSnapshot,enabled:liveEnabled) }
        .onChange(of: liveSnapshot) { _, snapshot in liveActivity.report(snapshot,enabled:liveEnabled) }
        .onChange(of: liveEnabled) { _, _ in liveActivity.report(liveSnapshot,enabled:liveEnabled) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { liveActivity.report(liveSnapshot,enabled:liveEnabled) } }
        .safeAreaInset(edge: .bottom) {
            if liveEnabled && liveSnapshot.active { Text(liveActivity.availability).font(.caption2).foregroundStyle(.secondary).padding(.vertical,4) }
        }
        #endif
        .environment(\.locale, appLanguage == "system" ? Locale.current : Locale(identifier: appLanguage))
        .disabled(host.busy)
        .onChange(of: role) { _, newRole in
            if newRole == 0 { host.stopHost() }
            else { client.disconnect(); client.stopDiscovery() }
        }
    }
}
