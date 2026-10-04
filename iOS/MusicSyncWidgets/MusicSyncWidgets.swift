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
            VStack(alignment:.leading,spacing:10) {
                HStack {
                    Label("MusicSync",systemImage:context.state.warning ? "exclamationmark.triangle.fill" : "waveform")
                    Spacer(); Text(tr(context.attributes.role))
                }.font(.headline)
                Text(context.attributes.peerName).font(.caption).lineLimit(1)
                status(context)
                HStack {
                    Text(String(format:tr("Buffer %d ms"),context.state.latencyMS))
                    Spacer(); Text(String(format:tr("Devices %d"),context.state.deviceCount))
                }.font(.caption).monospacedDigit()
                if context.state.warning { Text("Sync warning • check the app").font(.caption).foregroundStyle(.orange) }
            }.padding().activityBackgroundTint(.black.opacity(0.85)).activitySystemActionForegroundColor(.white).foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("MusicSync",systemImage:"waveform").font(.caption) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(String(format:"%d ms",context.state.latencyMS)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) { Text(tr(context.attributes.role)).font(.caption) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment:.leading,spacing:6) {
                        status(context)
                        HStack {
                            Text(String(format:tr("RTT %d ms"),context.state.rttMS))
                            Spacer(); Text(String(format:tr("Clock ≥ %d ms"),context.state.uncertaintyMS))
                        }.font(.caption).monospacedDigit()
                        if context.state.warning { Text("Sync warning • check the app").font(.caption).foregroundStyle(.orange) }
                    }
                }
            } compactLeading: {
                Image(systemName:context.state.warning ? "exclamationmark.triangle.fill" : "waveform").foregroundStyle(context.state.warning ? .orange : .primary)
            } compactTrailing: {
                Text(String(format:"%d ms",context.state.latencyMS)).font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName:context.state.warning ? "exclamationmark.triangle.fill" : "waveform").foregroundStyle(context.state.warning ? .orange : .primary)
            }
            .keylineTint(context.state.warning ? .orange : .accentColor)
        }
    }
    private func status(_ context: ActivityViewContext<MusicSyncActivityAttributes>) -> some View {
        Label(context.isStale ? tr("Status may be outdated") : tr(context.state.phase),systemImage:context.isStale ? "clock.badge.exclamationmark" : "speaker.wave.2")
    }
}
