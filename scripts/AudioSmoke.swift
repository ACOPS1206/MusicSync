import Foundation
import AVFoundation
import MusicSyncCore
@main struct Smoke {
    static func main() async throws {
        for (rate, sourceChannels) in [(44_100.0, 2), (48_000.0, 2), (44_100.0, 1)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(sourceChannels))!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 0.2))!
            buffer.frameLength = buffer.frameCapacity
            for f in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][f] = 0.25; if sourceChannels == 2 { buffer.floatChannelData![1][f] = -0.75 } }
            do { let output = try AVAudioFile(forWriting: url, settings: format.settings); try output.write(from: buffer) }
            let source = FileAudioSource(url: url)
            let done = DispatchSemaphore(value: 0)
            var frames = 0; var previousTime: Double?; var failure: String?
            source.onPCM = { data, count, time in
                if let previousTime { precondition(abs(time - previousTime) < 0.000_001) }
                previousTime = time + Double(count) / 48_000
                precondition(data.count == count * 8)
                data.withUnsafeBytes { bytes in
                    let middle = count / 2
                    let left = Float(bitPattern: bytes.loadUnaligned(fromByteOffset: middle * 8, as: UInt32.self))
                    let right = Float(bitPattern: bytes.loadUnaligned(fromByteOffset: middle * 8 + 4, as: UInt32.self))
                    precondition(abs(left - 0.25) < 0.01 && abs(right - (sourceChannels == 2 ? -0.75 : 0.25)) < 0.01)
                }
                frames += count
            }
            source.onEnd = { error in failure = error; done.signal() }
            try await source.start()
            precondition(done.wait(timeout: .now() + 3) == .success)
            await source.stop()
            precondition(failure == nil && frames == 9600)
            print("File decoder \(Int(rate)) Hz / \(sourceChannels) channels: \(frames) frames, distinct stereo and continuous timestamps passed")
            try FileManager.default.removeItem(at: url)
        }
    }
}
