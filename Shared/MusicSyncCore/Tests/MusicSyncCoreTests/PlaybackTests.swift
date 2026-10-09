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
    func testEverySharedDelayIncrementMovesThePresentationTimeline() {
        var t = HostPresentationTimeline()
        XCTAssertEqual(t.begin(captureTime:10,now:10,delay:0.18),10.18,accuracy:1e-9)
        t.advance(frames:480)
        XCTAssertEqual(t.begin(captureTime:10.01,now:10.01,delay:0.20),10.21,accuracy:1e-9)
        t.advance(frames:480)
        XCTAssertEqual(t.begin(captureTime:10.02,now:10.02,delay:0.21),10.23,accuracy:1e-9)
    }
    func testSharedDelayNeverMovesAlreadyScheduledAudioBackwards() {
        var t = HostPresentationTimeline()
        _ = t.begin(captureTime:10,now:10,delay:0.3); t.advance(frames:480)
        XCTAssertEqual(t.begin(captureTime:10.01,now:10.01,delay:0.18),10.31,accuracy:1e-9)
        XCTAssertEqual(t.begin(captureTime:11,now:11,delay:0.18),11.18,accuracy:1e-9)
    }
}
