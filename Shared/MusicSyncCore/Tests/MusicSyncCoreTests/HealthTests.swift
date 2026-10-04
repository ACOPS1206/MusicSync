// SPDX-License-Identifier: MIT
import XCTest
@testable import MusicSyncCore
final class HealthTests: XCTestCase {
    func testOrdinaryClockVariationAndShortSpikeDoNotWarn() {
        var monitor = SyncHealthMonitor(warmupDuration:0); var input = SyncHealthInput()
        input.uncertainty = 0.04
        for i in 0...20 { monitor.update(input,now:Double(i) / 2) }
        XCTAssertTrue(monitor.issues.isEmpty)
        input.uncertainty = 0.09
        for i in 21...28 { monitor.update(input,now:Double(i) / 2) }
        XCTAssertTrue(monitor.issues.isEmpty)
        input.uncertainty = 0.04; monitor.update(input,now:14.5)
        XCTAssertTrue(monitor.issues.isEmpty)
    }
    func testSustainedClockRiskAndRecoveryHysteresis() {
        var monitor = SyncHealthMonitor(warmupDuration:0); var input = SyncHealthInput(); input.uncertainty = 0.08
        for i in 0..<10 { monitor.update(input,now:Double(i) / 2) }
        XCTAssertTrue(monitor.issues.isEmpty)
        monitor.update(input,now:5); XCTAssertEqual(monitor.issues,[.clock])
        // Falling below the warning threshold alone is insufficient to clear a warning.
        input.uncertainty = 0.05
        for i in 11...20 { monitor.update(input,now:Double(i) / 2) }
        XCTAssertEqual(monitor.issues,[.clock])
        input.uncertainty = 0.04
        for i in 21...26 { monitor.update(input,now:Double(i) / 2) }
        XCTAssertEqual(monitor.issues,[.clock])
        monitor.update(input,now:13.5); XCTAssertTrue(monitor.issues.isEmpty)
    }
    func testAlternatingUnrelatedSpikesCannotAccumulate() {
        var monitor = SyncHealthMonitor(warmupDuration:0)
        for i in 0...30 {
            var input = SyncHealthInput()
            if i.isMultiple(of:2) { input.schedulingError = 0.1 } else { input.dropRate = 30 }
            monitor.update(input,now:Double(i) / 2)
        }
        XCTAssertTrue(monitor.issues.isEmpty)
    }
    func testOneIssueCannotImmediatelyPromoteAnother() {
        var monitor = SyncHealthMonitor(warmupDuration:0); var input = SyncHealthInput(); input.schedulingError = 0.05
        for i in 0...6 { monitor.update(input,now:Double(i) / 2) }
        XCTAssertEqual(monitor.issues,[.scheduling])
        input.uncertainty = 0.1; monitor.update(input,now:3.5)
        XCTAssertFalse(monitor.issues.contains(.clock))
        for i in 8...17 { monitor.update(input,now:Double(i) / 2) }
        XCTAssertTrue(monitor.issues.contains(.clock))
    }
    func testGapInObservationsDoesNotCountAsSustainedRisk() {
        var monitor = SyncHealthMonitor(warmupDuration:0); var input = SyncHealthInput(); input.uncertainty = 0.1
        monitor.update(input,now:0); monitor.update(input,now:20)
        XCTAssertTrue(monitor.issues.isEmpty)
    }
    func testSilenceWhenNotStreamingDoesNotWarnButStalledStreamDoes() {
        var monitor = SyncHealthMonitor(warmupDuration:0); var input = SyncHealthInput(); input.audioAge = 10
        for i in 0...8 { monitor.update(input,now:Double(i) / 2) }; XCTAssertTrue(monitor.issues.isEmpty)
        input.streaming = true
        for i in 9...15 { monitor.update(input,now:Double(i) / 2) }; XCTAssertEqual(monitor.issues,[.stalledAudio])
        input.monitor = true; monitor.update(input,now:8); XCTAssertTrue(monitor.issues.contains(.monitor))
        input.monitor = false; monitor.update(input,now:8.5); XCTAssertFalse(monitor.issues.contains(.monitor))
    }
    func testThirtySecondWarmupDoesNotAccumulateStartupErrors() {
        var monitor = SyncHealthMonitor(startedAt:100)
        var input = SyncHealthInput(); input.uncertainty = 0.1; input.dropRate = 50; input.monitor = true
        for i in 0..<60 { monitor.update(input,now:100+Double(i)/2) }
        XCTAssertTrue(monitor.issues.isEmpty)
        XCTAssertEqual(monitor.warmupRemaining(now:129),1)
        monitor.update(input,now:130)
        XCTAssertEqual(monitor.issues,[.monitor])
        for i in 1...5 { monitor.update(input,now:130+Double(i)/2) }
        XCTAssertFalse(monitor.issues.contains(.drops))
        monitor.update(input,now:133); XCTAssertTrue(monitor.issues.contains(.drops))
        for i in 7...10 { monitor.update(input,now:130+Double(i)/2) }
        XCTAssertTrue(monitor.issues.contains(.clock))
    }
    func testNewSyncSessionGetsAnotherWarmup() {
        var monitor = SyncHealthMonitor(startedAt:0); var input = SyncHealthInput(); input.schedulingError = 0.1
        for i in 0...66 { monitor.update(input,now:Double(i)/2) }
        XCTAssertTrue(monitor.issues.contains(.scheduling))
        monitor = SyncHealthMonitor(startedAt:40)
        monitor.update(input,now:69.5); XCTAssertTrue(monitor.issues.isEmpty)
        monitor.update(input,now:70); XCTAssertTrue(monitor.issues.isEmpty)
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
