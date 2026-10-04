import XCTest
@testable import MusicSyncCore
final class StereoTests: XCTestCase {
    func testPairPreservesDistinctOriginalChannels() throws {
        let sample: [Float] = [0.25, -0.75]
        XCTAssertEqual((0..<2).map { sample[OutputChannel.left.sourceIndex(forOutput: $0)] }, [0.25, 0.25])
        XCTAssertEqual((0..<2).map { sample[OutputChannel.right.sourceIndex(forOutput: $0)] }, [-0.75, -0.75])
        XCTAssertEqual((0..<2).map { sample[OutputChannel.stereo.sourceIndex(forOutput: $0)] }, sample)
        var packet = Message("audio")
        packet.sequence = 0; packet.epoch = 1; packet.pts = 5
        packet.sampleRate = 48_000; packet.channels = 2; packet.frames = 1
        packet.payload = sample.withUnsafeBytes { Data($0) }; packet.outputChannel = "right"
        var reader = Framer()
        let received = try XCTUnwrap(reader.consume(Framer.encode(packet)).first)
        XCTAssertTrue(received.validAudio)
        XCTAssertEqual(received.outputChannel, "right")
        XCTAssertEqual(received.payload, packet.payload)
        packet.outputChannel = nil
        let legacy = try XCTUnwrap(reader.consume(Framer.encode(packet)).first)
        XCTAssertNil(legacy.outputChannel)
        XCTAssertTrue(legacy.validAudio)
    }
}
