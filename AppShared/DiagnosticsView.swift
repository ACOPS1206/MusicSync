// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync
import SwiftUI
import MusicSyncCore

enum AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—" }
    static var display: String { version + " (" + build + ")" }
}
@MainActor final class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published private(set) var entries: [DiagnosticEntry] = []
    private var history = DiagnosticHistory()
    private init() { record("MusicSync", "MusicSync " + AppVersion.display) }
    func record(_ role: String, _ text: String, level: DiagnosticLevel = .info) {
        if history.append(role:role,level:level,text:text) { entries = history.entries }
    }
    func clear() { history.clear(); entries = [] }
    var export: String { "MusicSync " + AppVersion.display + "\n" + ProcessInfo.processInfo.operatingSystemVersionString + "\n\n" + history.plainText }
}
struct AppVersionView: View {
    var body: some View {
        Text(String(format:tr("Version %@ · Build %@"),AppVersion.version,AppVersion.build)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
}
struct DiagnosticsView: View {
    @ObservedObject private var log = AppLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var problemsOnly = false
    @State private var copied = false
    private var visible: [DiagnosticEntry] { log.entries.filter { !problemsOnly || $0.level != .info }.reversed() }
    var body: some View {
        NavigationStack {
            VStack(alignment:.leading,spacing:12) {
                AppVersionView()
                HStack {
                    Button { copyLogs() } label: { Label(copied ? "Copied" : "Copy Logs",systemImage:copied ? "checkmark" : "doc.on.doc") }.buttonStyle(.glass).disabled(log.entries.isEmpty)
                    Button("Clear Logs",role:.destructive) { log.clear(); copied = false }.buttonStyle(.glass).disabled(log.entries.isEmpty)
                }
                Toggle("Warnings and errors only",isOn:$problemsOnly)
                Text("Latest 300 events, newest first. Logs remain in memory until the app closes. Audio and pairing secrets are not logged. Copied logs may contain device names or LAN addresses; review before sharing.").font(.caption).foregroundStyle(.secondary)
                if visible.isEmpty {
                    ContentUnavailableView("No logs to display",systemImage:"list.bullet.rectangle")
                } else {
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:12) {
                            ForEach(visible) { entry in
                                VStack(alignment:.leading,spacing:4) {
                                    HStack {
                                        Text(entry.date,format:.dateTime.hour().minute().second()).monospacedDigit()
                                        Text(tr(entry.role)); Spacer(); Text(tr(entry.level.rawValue.capitalized))
                                    }.font(.caption).foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .secondary)
                                    Text(entry.text).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                                }
                                Divider()
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
            }.padding().navigationTitle("Logs")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of:log.entries.count) { _, _ in copied = false }
        }
        #if os(macOS)
        .frame(minWidth:560,minHeight:500)
        #endif
    }
    private func copyLogs() {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log.export,forType:.string)
        #else
        UIPasteboard.general.string = log.export
        #endif
        copied = true
    }
}
