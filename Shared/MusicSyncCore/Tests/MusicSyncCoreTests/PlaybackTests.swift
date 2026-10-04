// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import XCTest
@testable import MusicSyncCore
final class PlaybackTests: XCTestCase {
    func testContinuousPacketsIgnoreSmallClockNoise() {
        var timeline = PlaybackTimeline()
        XCTAssertEqual(timeline.schedule(sequence:0,epoch:1,desired:1,duration:0.01,now:0.8),1)
        XCTAssertNil(timeline.schedule(sequence:1,epoch:1,desired:1.0105,duration:0.01,now:0.81))
        XCTAssertNil(timeline.schedule(sequence:2,epoch:1,desired:1.0195,duration:0.01,now:0.82))
    }
    func testLossDelayChangesAndRestartReanchor() {
        var t = PlaybackTimeline()
        _ = t.schedule(sequence:0,epoch:1,desired:1,duration:0.01,now:0.8)
        XCTAssertEqual(t.schedule(sequence:2,epoch:1,desired:1.02,duration:0.01,now:0.81),1.02)
        XCTAssertEqual(t.schedule(sequence:3,epoch:1,desired:1.1,duration:0.01,now:0.82),1.1)
        XCTAssertEqual(t.schedule(sequence:0,epoch:2,desired:2,duration:0.01,now:1.8),2)
    }
}
