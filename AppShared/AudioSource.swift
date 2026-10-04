// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation
import AVFoundation

protocol AudioCapture: AnyObject {
    var onPCM: ((Data, Int, Double) -> Void)? { get set }
    func start() async throws
    func stop() async
}

/// Converts native tap/SCK format into interleaved little-endian Float32, 48 kHz stereo.
final class PCMEncoder {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    func encode(_ input: AVAudioPCMBuffer) -> (Data, Int)? {
        if sourceFormat != input.format {
            sourceFormat = input.format
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return pack(output)
    }
    func finish() -> (Data, Int)? {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 2048) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return pack(output)
    }
    private func pack(_ output: AVAudioPCMBuffer) -> (Data, Int)? {
        guard let channels = output.floatChannelData else { return nil }
        let count = Int(output.frameLength)
        var data = Data(count: count * 8)
        data.withUnsafeMutableBytes { bytes in
            for f in 0..<count {
                for c in 0..<2 {
                    bytes.storeBytes(of: channels[c][f].bitPattern.littleEndian, toByteOffset: (f * 2 + c) * 4, as: UInt32.self)
                }
            }
        }
        return (data, count)
    }
}

