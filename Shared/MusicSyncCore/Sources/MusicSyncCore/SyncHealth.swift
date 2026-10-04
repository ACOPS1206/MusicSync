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
/// This flags observable risk; it does not measure acoustic speaker alignment.
public struct SyncHealthMonitor {
    public private(set) var issues: [SyncIssue] = []
    private var badSamples = 0
    private var stableSince: Double?
    public init() {}
    public mutating func update(_ input: SyncHealthInput, now: Double) {
        var candidates: [SyncIssue] = []
        if input.uncertainty > 0.025 { candidates.append(.clock) }
        if input.schedulingError > 0.010 { candidates.append(.scheduling) }
        if input.dropRate > 3 { candidates.append(.drops) }
        if input.clockAge > 3 { candidates.append(.staleClock) }
        if input.streaming && input.audioAge > 1 { candidates.append(.stalledAudio) }
        if input.monitor { candidates.append(.monitor) }
        if !candidates.isEmpty {
            stableSince = nil; badSamples += 1
            if badSamples >= 3 || input.monitor { issues = candidates }
        } else {
            badSamples = 0
            if stableSince == nil { stableSince = now }
            if now - stableSince! >= 3 { issues = [] }
        }
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
