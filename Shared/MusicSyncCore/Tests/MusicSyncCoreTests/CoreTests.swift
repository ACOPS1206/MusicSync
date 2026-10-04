// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import XCTest
@testable import MusicSyncCore
final class CoreTests: XCTestCase {
    func testFragmentationAndCoalescing() throws {
        var framer = Framer()
        let encoded = try Framer.encode(Message("ping"))
        XCTAssertTrue(try framer.consume(encoded.prefix(3)).isEmpty)
        var rest = Data(encoded.dropFirst(3)); rest.append(encoded)
        XCTAssertEqual(try framer.consume(rest).map(\.kind), ["ping", "ping"])
    }
    func testOversizeRejected() {
        var framer = Framer()
        XCTAssertThrowsError(try framer.consume(Data([255,255,255,255])))
    }
    func testClockOffsetAndNetworkDelay() {
        var clock = ClockEstimate()
        for i in 0..<12 {
            let t = Double(i)
            clock.observe(t1:t, t2:t+5.01, t3:t+5.012, t4:t+0.022)
        }
        XCTAssertTrue(clock.ready)
        XCTAssertEqual(clock.offset,5,accuracy:0.000001)
        XCTAssertEqual(clock.rtt,0.02,accuracy:0.000001)
    }
    func testJitterDeadlineAndDuplicates() {
        var buffer = JitterQueue()
        var p = Message("audio"); p.sequence = 1; p.epoch = 1; p.pts = 5.05
        p.sampleRate = 48000; p.channels = 2; p.frames = 480; p.payload = Data(count:3840)
        buffer.insert(p); buffer.insert(p)
        XCTAssertEqual(buffer.count,1)
        XCTAssertEqual(buffer.take(now:0,offset:5).count,1)
        p.sequence = 2; p.pts = 5.01; buffer.insert(p)
        XCTAssertTrue(buffer.take(now:0,offset:5).isEmpty)
        XCTAssertEqual(buffer.drops,1)
    }
    func testSharedDelayNeverMovesBackwards() {
        var d = DelayController(); d.update(rtt:0.1,jitter:0.04,requested:0.25)
        let raised = d.target
        d.update(rtt:0.001,jitter:0,requested:0.18)
        XCTAssertEqual(d.target,raised)
    }
}
