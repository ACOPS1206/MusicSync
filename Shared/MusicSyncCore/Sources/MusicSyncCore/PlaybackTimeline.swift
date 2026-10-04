// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation

/// Preserve sample continuity while clock estimates move slightly; re-anchor real discontinuities.
public struct PlaybackTimeline {
    private var nextTime: Double?
    private var lastSequence: UInt64?
    private var epoch: UInt64?
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
