// SPDX-License-Identifier: MIT
import XCTest
@testable import MusicSyncCore
final class HealthTests: XCTestCase {
    func testTransientDoesNotWarnAndSustainedRiskDoes() {
        var monitor = SyncHealthMonitor(); var input = SyncHealthInput()
        input.uncertainty = 0.04
        monitor.update(input,now:0); XCTAssertTrue(monitor.issues.isEmpty)
        monitor.update(input,now:0.5); XCTAssertTrue(monitor.issues.isEmpty)
        monitor.update(input,now:1); XCTAssertEqual(monitor.issues,[.clock])
        input.uncertainty = 0.002
        monitor.update(input,now:1.5); monitor.update(input,now:4); XCTAssertFalse(monitor.issues.isEmpty)
        monitor.update(input,now:4.5); XCTAssertTrue(monitor.issues.isEmpty)
    }
    func testSilenceWhenNotStreamingDoesNotWarnButStalledStreamDoes() {
        var monitor = SyncHealthMonitor(); var input = SyncHealthInput(); input.audioAge = 10
        for i in 0..<3 { monitor.update(input,now:Double(i)) }; XCTAssertTrue(monitor.issues.isEmpty)
        input.streaming = true
        for i in 3..<6 { monitor.update(input,now:Double(i)) }; XCTAssertEqual(monitor.issues,[.stalledAudio])
        input.monitor = true; monitor.update(input,now:6); XCTAssertTrue(monitor.issues.contains(.monitor))
    }
    func testTrafficRatesAndResettingDropCounters() {
        var meter = TrafficMeter(); _ = meter.sample(now:1,drops:8)
        for _ in 0..<50 { meter.record(bytes:3840) }
        let sample = meter.sample(now:1.5,drops:10)
        XCTAssertEqual(sample.packetsPerSecond,100)
        XCTAssertEqual(sample.megabitsPerSecond,3.072,accuracy:0.0001)
        XCTAssertEqual(sample.dropsPerSecond,4)
        XCTAssertEqual(meter.sample(now:2,drops:0).dropsPerSecond,0)
    }
}
