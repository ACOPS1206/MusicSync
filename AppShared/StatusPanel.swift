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
    var input: SyncHealthInput
    var rtt: Double
    var jitter: Double
    var remoteIssues: [SyncIssue] = []
    var body: some View {
        if !issues.isEmpty {
            Section("Sync warning") {
                ForEach(issues, id: \.rawValue) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(issue.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        if remoteIssues.contains(issue) {
                            Text("A Client reported this warning. Open that Client for its current values and reason.").font(.caption).foregroundStyle(.secondary)
                        }
                        if !remoteIssues.contains(issue) || issue == .clock {
                            Text(details(issue)).font(.caption).monospacedDigit().textSelection(.enabled)
                        }
                    }
                }
                Text("Most warnings appear after three consecutive checks and clear after three stable seconds. Current values may already be recovering.").font(.caption).foregroundStyle(.secondary)
                Text("These warnings indicate synchronization risk, not a measured speaker-to-speaker error. Check Wi-Fi, use built-in speakers, and try the test tone with timing trim.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func details(_ issue: SyncIssue) -> String {
        switch issue {
        case .clock:
            let values = String(format: tr("Current uncertainty %.1f ms = RTT %.1f ms / 2 + jitter %.1f ms. Warning threshold: > 25 ms."), input.uncertainty * 1000, rtt * 1000, jitter * 1000)
            let cause = rtt / 2 > 0.025 && jitter > 0.025 ? tr("Both RTT and jitter are high.") : (jitter > rtt / 2 ? tr("Jitter contributes more than half the RTT.") : tr("Half the RTT contributes more than jitter."))
            return values + "\n" + cause + " " + tr("Wi-Fi congestion, weak signal, retransmissions or device scheduling may contribute. These metrics cannot identify the exact cause or one-way delay.")
        case .scheduling:
            return String(format: tr("Current scheduling error %.1f ms. Warning threshold: > 10 ms. Late audio or a busy audio scheduling thread can miss the presentation time."), input.schedulingError * 1000)
        case .drops:
            return String(format: tr("Current packet drop rate %.1f /s. Warning threshold: > 3 /s. Late packets or an overfilled queue may be discarded."), input.dropRate)
        case .staleClock:
            return String(format: tr("Last clock update %.1f s ago. Warning threshold: > 3 s. Clock replies or Client status reports have stopped arriving."), input.clockAge)
        case .stalledAudio:
            return String(format: tr("Last audio packet %.1f s ago. Warning threshold: > 1 s while streaming. Check the source, Host and network connection."), input.audioAge)
        case .monitor:
            return tr("ScreenCaptureKit leaves the original Mac output playing immediately. That output cannot follow the delayed Client timeline. Use synchronized CoreAudio capture to align both speakers.")
        }
    }
}
struct TimingSummaryView: View {
    var latency: Double
    var rtt: Double
    var offset: Double
    var jitter: Double
    var uncertainty: Double
    var drops: Int
    var peerName: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Latency & Synchronization").fontWeight(.medium)
            if let peerName { Text(String(format: tr("Timing for %@ (highest clock uncertainty)"), peerName)) }
            row("Shared buffer", latency)
            row("RTT", rtt)
            row("Clock offset (Host − Client)", offset, signed: true)
            row("Network jitter", jitter)
            row("Clock uncertainty estimate", uncertainty)
            Text(tr("Dropped frames") + ": " + String(drops))
            Text("Clock uncertainty is an estimate, not a measured speaker-to-speaker error. Keep both devices on built-in speakers.")
        }.font(.caption2).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
    }
    private func row(_ key: String, _ value: Double, signed: Bool = false) -> some View {
        Text(tr(key) + ": " + String(format: signed ? "%+.1f ms" : "%.1f ms", value * 1000))
    }
}
struct ProjectLinkView: View {
    var body: some View {
        Section {
            Link(destination: URL(string: "https://github.com/ACOPS1206/MusicSync")!) {
                Label("MusicSync on GitHub", systemImage: "link")
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
    var timing: TimingSummaryView
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
            timing
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
