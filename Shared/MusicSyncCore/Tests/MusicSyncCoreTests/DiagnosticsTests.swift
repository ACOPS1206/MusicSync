// SPDX-License-Identifier: MIT
import XCTest
@testable import MusicSyncCore
final class DiagnosticsTests: XCTestCase {
    func testBoundedHistoryKeepsLatestAndClearRemovesExports() {
        var history = DiagnosticHistory(capacity:3)
        for n in 0..<10 { history.append(role:"Host",text:"Event \(n)") }
        XCTAssertEqual(history.entries.map(\.text),["Event 7","Event 8","Event 9"])
        history.clear(); XCTAssertTrue(history.entries.isEmpty); XCTAssertEqual(history.plainText,"")
    }
    func testEventFloodDeduplicationPreservesDifferentSeverityAndLaterRepeats() {
        var history = DiagnosticHistory(); let now = Date(timeIntervalSince1970:100)
        XCTAssertTrue(history.append(role:"Listen",text:"Disconnected",date:now))
        XCTAssertFalse(history.append(role:"Listen",text:"Disconnected",date:now.addingTimeInterval(1)))
        XCTAssertTrue(history.append(role:"Listen",level:.error,text:"Disconnected",date:now.addingTimeInterval(1)))
        XCTAssertTrue(history.append(role:"Listen",level:.error,text:"Disconnected",date:now.addingTimeInterval(3)))
        XCTAssertEqual(history.entries.count,3)
    }
    func testExportBoundsAndNeutralizesMultilineMessages() {
        var history = DiagnosticHistory()
        XCTAssertFalse(history.append(role:"Host",text:"\n\t"))
        history.append(role:"Host",level:.warning,text:"line1\nline2\u{1b}",date:Date(timeIntervalSince1970:0))
        XCTAssertEqual(history.entries.first?.text,"line1 line2 ")
        XCTAssertTrue(history.plainText.contains("1970-01-01T00:00:00.000Z [Host] [warning] line1 line2 "))
        history.append(role:"Host",text:String(repeating:"x",count:10000))
        XCTAssertEqual(history.entries.last?.text.count,600)
    }
}
