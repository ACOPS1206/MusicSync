// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation

/// Preserve sample continuity while clock estimates move slightly; re-anchor real discontinuities.
public struct PlaybackTimeline {
    private var nextTime: Double?
    private var lastSequence: UInt64?
    private var epoch: UInt64?
    public var queuedUntil: Double? { nextTime }
    public init() {}
    /// nil means append after the preceding buffer; a value means schedule at that host time.
    public mutating func schedule(sequence: UInt64, epoch: UInt64, desired: Double, duration: Double, now: Double) -> Double? {
        let consecutive = self.epoch == epoch && lastSequence.map { $0 < UInt64.max && sequence == $0 + 1 } == true
        let append = consecutive && nextTime.map { $0 > now + 0.003 && abs(desired - $0) <= 0.002 } == true
        let start = append ? nextTime! : desired
        nextTime = start + duration; lastSequence = sequence; self.epoch = epoch
        return append ? nil : desired
    }
}

/// The common presentation delay must move by every positive increment, even below 30 ms.
public struct HostPresentationTimeline {
    public private(set) var nextTime: Double?
    private var appliedDelay = 0.18
    public init() {}
    public mutating func begin(captureTime: Double, now: Double, delay: Double) -> Double {
        if let nextTime {
            self.nextTime = nextTime + max(0, delay-appliedDelay)
        } else { nextTime = max(captureTime,now)+delay }
        appliedDelay = max(appliedDelay,delay)
        if nextTime! < now+0.06 { nextTime = now+delay }
        if captureTime+delay > nextTime!+0.03 { nextTime = captureTime+delay }
        return nextTime!
    }
    public mutating func advance(frames: Int) { nextTime! += Double(frames)/48000 }
}
