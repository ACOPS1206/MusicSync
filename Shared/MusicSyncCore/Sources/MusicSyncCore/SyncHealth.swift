// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation

public enum SyncIssue: String, CaseIterable, Sendable {
    case clock, scheduling, drops, staleClock, stalledAudio, monitor
}
public struct SyncHealthInput {
    public var uncertainty = 0.0
    public var schedulingError = 0.0
    public var dropRate = 0.0
    public var clockAge = 0.0
    public var audioAge = 0.0
    public var streaming = false
    public var monitor = false
    public init() {}
}
/// Shared warning policy: upper threshold, lower recovery threshold and sustained duration.
public enum SyncHealthPolicy {
    public static func threshold(for issue: SyncIssue) -> Double {
        switch issue {
        case .clock: return 0.060
        case .scheduling: return 0.025
        case .drops: return 10
        case .staleClock: return 5
        case .stalledAudio: return 2
        case .monitor: return 0
        }
    }
    public static func recoveryThreshold(for issue: SyncIssue) -> Double {
        switch issue {
        case .clock: return 0.045
        case .scheduling: return 0.015
        case .drops: return 5
        case .staleClock: return 3
        case .stalledAudio: return 1
        case .monitor: return 0
        }
    }
    public static func sustainedDuration(for issue: SyncIssue) -> Double { issue == .clock ? 5 : 3 }
    public static let recoveryDuration = 3.0
}
/// This flags sustained observable risk, not acoustic speaker alignment.
/// Each issue has its own debounce and hysteresis; unrelated spikes cannot combine into a warning.
public struct SyncHealthMonitor {
    public private(set) var issues: [SyncIssue] = []
    private var badSince: [SyncIssue: Double] = [:]
    private var stableSince: [SyncIssue: Double] = [:]
    private var lastUpdate: Double?
    public init() {}
    public mutating func update(_ input: SyncHealthInput, now: Double) {
        // Missing observations do not establish continuous bad/good measurements.
        if let lastUpdate, now < lastUpdate || now - lastUpdate > 1.5 {
            badSince.removeAll(); stableSince.removeAll()
        }
        lastUpdate = now
        var active = Set(issues)
        for issue in SyncIssue.allCases {
            if issue == .monitor {
                if input.monitor { active.insert(issue) } else { active.remove(issue) }
                continue
            }
            let value: Double
            switch issue {
            case .clock: value = input.uncertainty
            case .scheduling: value = input.schedulingError
            case .drops: value = input.dropRate
            case .staleClock: value = input.clockAge
            case .stalledAudio: value = input.streaming ? input.audioAge : 0
            case .monitor: value = 0
            }
            if value > SyncHealthPolicy.threshold(for: issue) {
                stableSince[issue] = nil
                if badSince[issue] == nil { badSince[issue] = now }
                if now - badSince[issue]! >= SyncHealthPolicy.sustainedDuration(for: issue) { active.insert(issue) }
            } else {
                badSince[issue] = nil
                if value <= SyncHealthPolicy.recoveryThreshold(for: issue) {
                    if stableSince[issue] == nil { stableSince[issue] = now }
                    if now - stableSince[issue]! >= SyncHealthPolicy.recoveryDuration { active.remove(issue) }
                } else { stableSince[issue] = nil }
            }
        }
        issues = SyncIssue.allCases.filter { active.contains($0) }
    }
}
public struct TrafficSnapshot: Equatable, Sendable {
    public var packetsPerSecond = 0.0
    public var megabitsPerSecond = 0.0
    public var dropsPerSecond = 0.0
    public var totalPackets = 0
    public var totalBytes = 0
    public init() {}
}
public struct TrafficMeter {
    private var packets = 0
    private var bytes = 0
    private var lastPackets = 0
    private var lastBytes = 0
    private var lastDrops = 0
    private var lastTime: Double?
    public init() {}
    public mutating func record(bytes: Int) { packets += 1; self.bytes += max(0, bytes) }
    public mutating func sample(now: Double, drops: Int) -> TrafficSnapshot {
        var result = TrafficSnapshot(); result.totalPackets = packets; result.totalBytes = bytes
        if let time = lastTime, now > time {
            result.packetsPerSecond = Double(packets - lastPackets) / (now - time)
            result.megabitsPerSecond = Double(bytes - lastBytes) * 8 / (now - time) / 1_000_000
            result.dropsPerSecond = Double(max(0, drops - lastDrops)) / (now - time)
        }
        lastTime = now; lastPackets = packets; lastBytes = bytes; lastDrops = drops
        return result
    }
}
