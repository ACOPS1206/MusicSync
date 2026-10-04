// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
#if os(iOS)
import ActivityKit
import SwiftUI

struct LiveSessionSnapshot: Equatable {
    var role: String
    var peerName: String
    var sessionID: String
    var active: Bool
    var state: MusicSyncActivityAttributes.ContentState
}
@MainActor final class LiveActivityCoordinator: ObservableObject {
    @Published private(set) var availability = tr("Live Activity not started")
    private var activity: Activity<MusicSyncActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: MusicSyncActivityAttributes.ContentState?
    private var updateTask: Task<Void,Never>?
    private var generation = 0
    private var dismissedSession: String?
    private var lastAttempt = Date.distantPast
    init() {
        for old in Activity<MusicSyncActivityAttributes>.activities { Task { await old.end(nil,dismissalPolicy:.immediate) } }
    }
    func report(_ snapshot: LiveSessionSnapshot, enabled: Bool) {
        guard enabled, snapshot.active else { finish(); dismissedSession = nil; return }
        let identity = snapshot.role + ":" + snapshot.sessionID
        if dismissedSession == identity { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            finish(); availability = tr("Live Activities are unavailable or disabled"); return
        }
        if let activity, activity.activityState == .dismissed || activity.activityState == .ended {
            self.activity = nil; dismissedSession = identity
            availability = tr("Live Activity dismissed • restart the session to show it again")
            return
        }
        if let activity, activity.attributes.role != snapshot.role || activity.attributes.peerName != snapshot.peerName || activity.attributes.sessionID != snapshot.sessionID { finish() }
        let content = ActivityContent(state: snapshot.state, staleDate: Date().addingTimeInterval(15))
        if activity == nil {
            guard UIApplication.shared.applicationState == .active else {
                availability = tr("Open MusicSync to start the Live Activity"); return
            }
            guard Date().timeIntervalSince(lastAttempt) >= 15 else { return }
            lastAttempt = Date()
            do {
                // Remove stale activities left by an earlier process before starting this session.
                for old in Activity<MusicSyncActivityAttributes>.activities { Task { await old.end(nil,dismissalPolicy:.immediate) } }
                activity = try Activity.request(attributes: MusicSyncActivityAttributes(role:snapshot.role,sessionID:snapshot.sessionID,peerName:snapshot.peerName),content:content,pushType:nil)
                lastState = snapshot.state; lastUpdate = Date(); availability = tr("Live Activity active")
            } catch { availability = String(format:tr("Live Activity unavailable: %@"),error.localizedDescription) }
            return
        }
        let significant = lastState?.phase != snapshot.state.phase || lastState?.warning != snapshot.state.warning || lastState?.deviceCount != snapshot.state.deviceCount
        guard Date().timeIntervalSince(lastUpdate) >= (significant ? 1 : 5), let activity else { return }
        lastUpdate = Date(); lastState = snapshot.state
        updateTask?.cancel()
        let token = generation
        updateTask = Task { [weak self] in
            guard !Task.isCancelled, self?.generation == token else { return }
            await activity.update(content)
        }
    }
    func finish() {
        generation += 1; updateTask?.cancel(); updateTask = nil
        if let activity { Task { await activity.end(nil,dismissalPolicy:.immediate) } }
        activity = nil; lastState = nil; lastUpdate = .distantPast; lastAttempt = .distantPast
        availability = tr("Live Activity not started")
    }
}
extension ClientModel {
    var liveSnapshot: LiveSessionSnapshot {
        LiveSessionSnapshot(role:"Listen",peerName:selectedName ?? "MusicSync",sessionID:sessionID.uuidString,active:selectedName != nil && sessionPhase != "Stopped",state:.init(phase:sessionPhase,latencyMS:Int(latency * 1000),rttMS:Int(rtt * 1000),uncertaintyMS:Int(uncertainty * 1000),deviceCount:connected ? 1 : 0,dropped:dropped,warning:!syncIssues.isEmpty))
    }
}
extension HostModel {
    var liveSnapshot: LiveSessionSnapshot {
        let ready = devices.filter(\.ready)
        return LiveSessionSnapshot(role:"Host",peerName:"MusicSync",sessionID:sessionID.uuidString,active:active,state:.init(phase:sessionPhase,latencyMS:Int(latency * 1000),rttMS:Int((ready.map(\.rtt).max() ?? 0) * 1000),uncertaintyMS:Int((ready.map { $0.rtt / 2 + $0.jitter }.max() ?? 0) * 1000),deviceCount:devices.count,dropped:localDrops,warning:!syncIssues.isEmpty))
    }
}
#endif
