// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import SwiftUI
import MusicSyncCore

extension SyncIssue {
    var title: String {
        switch self {
        case .clock: return tr("Clock synchronization is uncertain")
        case .scheduling: return tr("Audio missed its scheduled time")
        case .drops: return tr("Audio packets are being dropped")
        case .staleClock: return tr("Clock updates have stopped")
        case .stalledAudio: return tr("Audio stream has stalled")
        case .monitor: return tr("Monitor mode cannot align the original Mac output")
        }
    }
}
struct SyncWarningView: View {
    var issues: [SyncIssue]
    var body: some View {
        if !issues.isEmpty {
            Section("Sync warning") {
                ForEach(issues, id: \.rawValue) { issue in
                    Label(issue.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text("These warnings indicate synchronization risk, not a measured speaker-to-speaker error. Check Wi-Fi, use built-in speakers, and try the test tone with timing trim.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct RealtimeStatusView: View {
    var phase: String
    var traffic: TrafficSnapshot
    var drops: Int
    var schedulingErrorMS: Double
    var updated: Date
    var body: some View {
        Section("Real-time status") {
            LabeledContent("Session", value: tr(phase))
            LabeledContent("PCM packets", value: String(format: "%.0f /s", traffic.packetsPerSecond))
            LabeledContent("PCM bandwidth", value: String(format: "%.2f Mbps", traffic.megabitsPerSecond))
            LabeledContent("Total packets", value: String(traffic.totalPackets))
            LabeledContent("Recent drops", value: String(format: "%.1f /s", traffic.dropsPerSecond))
            LabeledContent("Total dropped packets", value: String(drops))
            LabeledContent("Scheduling error estimate", value: String(format: "%.1f ms", schedulingErrorMS))
            LabeledContent("Updated") { Text(updated,format:.dateTime.hour().minute().second()) }
            Text("In-app metrics refresh twice per second. PCM bandwidth excludes transport framing and counts one stream. Clock offset and buffering estimates do not measure physical speaker delay.").font(.caption).foregroundStyle(.secondary)
        }.monospacedDigit()
    }
}
struct LiveActivitySettingsView: View {
    @AppStorage("liveActivitiesEnabled") private var enabled = true
    var body: some View {
        #if os(iOS)
        Section("Live Activity & Dynamic Island") {
            Toggle("Show session on Lock Screen and Dynamic Island", isOn: $enabled)
            Text("Start a session while MusicSync is open. iOS controls visibility and update timing. LiveContainer may not register the widget extension; direct installation with signing is recommended for this feature.").font(.caption).foregroundStyle(.secondary)
        }
        #endif
    }
}
