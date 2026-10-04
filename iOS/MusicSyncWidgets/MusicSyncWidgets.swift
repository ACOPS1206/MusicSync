// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import ActivityKit
import WidgetKit
import SwiftUI

@main struct MusicSyncWidgets: WidgetBundle {
    var body: some Widget { MusicSyncLiveActivity() }
}
struct MusicSyncLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MusicSyncActivityAttributes.self) { context in
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Label(sessionTitle(context.isStale ? "Status may be outdated" : context.state.phase),systemImage:context.state.warning ? "exclamationmark.triangle.fill" : "waveform")
                    Spacer(); Text(tr(context.attributes.role))
                }.font(.headline)
                if context.attributes.peerName != "MusicSync" { Text(context.attributes.peerName).font(.caption).lineLimit(1) }
                Text(outputDescription(context.state)).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                timing(context.state)
                if context.state.warning { Text("Sync warning • check the app").font(.caption).foregroundStyle(.orange) }
            }.padding().activityBackgroundTint(.black.opacity(0.85)).activitySystemActionForegroundColor(.white).foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(sessionTitle(context.isStale ? "Status may be outdated" : context.state.phase)).font(.caption).lineLimit(1).minimumScaleFactor(0.7) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(String(format:"%d ms",context.state.latencyMS)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) { Text(tr(context.attributes.role)).font(.caption) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment:.leading,spacing:6) {
                        Text(outputDescription(context.state)).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                        timing(context.state)
                        if context.state.warning { Text("Sync warning • check the app").font(.caption).foregroundStyle(.orange) }
                    }
                }
            } compactLeading: {
                HStack(spacing:3) {
                    Image(systemName:context.state.warning ? "exclamationmark.triangle.fill" : "waveform").foregroundStyle(context.state.warning ? .orange : .primary)
                    Text(channelMark(context.state)).font(.caption2.bold())
                }.accessibilityLabel(outputDescription(context.state))
            } compactTrailing: {
                Text(String(format:"%d ms",context.state.latencyMS)).font(.caption2).monospacedDigit()
            } minimal: {
                if context.state.warning { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange) }
                else { Text(channelMark(context.state)).font(.caption2.bold()).accessibilityLabel(outputDescription(context.state)) }
            }
            .keylineTint(context.state.warning ? .orange : .accentColor)
        }
    }
    private func channelMark(_ state: MusicSyncActivityAttributes.ContentState) -> String {
        switch state.outputChannel {
        case "left": return tr("L")
        case "right": return tr("R")
        case "stereo": return tr("ST")
        default: return "—"
        }
    }
    private func outputDescription(_ state: MusicSyncActivityAttributes.ContentState) -> String {
        if let layout = state.speakerLayout {
            let title: String
            switch layout {
            case "hostLeft": title = tr("Host left · Client right")
            case "hostRight": title = tr("Host right · Client left")
            default: title = tr("Stereo on each device")
            }
            return String(format:tr("Host preset: %@"),title)
        }
        let title: String
        switch state.outputChannel {
        case "left": title = tr("Left channel")
        case "right": title = tr("Right channel")
        case "stereo": title = tr("Stereo")
        default: return tr("Output channel") + ": —"
        }
        return String(format:tr(state.followsHost == true ? "Follow Host · %@" : "Output · %@"),title)
    }
    private func timing(_ state: MusicSyncActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: tr("Buffer %d ms · RTT %d ms"), state.latencyMS, state.rttMS))
            Text(String(format: tr("Offset %@ ms · Jitter %@ ms"), state.offsetMS.map { String(format: "%+.1f", $0) } ?? "—", state.jitterMS.map { String(format: "%.1f", $0) } ?? "—"))
            Text(String(format: tr("Uncertainty %d ms · Drops %d · Devices %d"), state.uncertaintyMS, state.dropped, state.deviceCount))
        }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
    }
}
