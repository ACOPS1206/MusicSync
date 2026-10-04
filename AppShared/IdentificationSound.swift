// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import AVFoundation
import Foundation

/// A separate local engine overlays three short chirps only on the selected device.
@MainActor final class IdentificationSound {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate:48_000,channels:2)!
    private var generation = 0
    private var lastPlay = Date.distantPast
    init() { engine.attach(node); engine.connect(node,to:engine.mainMixerNode,format:format) }
    @discardableResult func play() throws -> Bool {
        guard Date().timeIntervalSince(lastPlay) >= 2 else { return false }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback { try session.setCategory(.playback,mode:.default) }
        try session.setActive(true)
        #endif
        guard let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:43_200), let channels = buffer.floatChannelData else { return false }
        buffer.frameLength = 43_200
        for frame in 0..<43_200 {
            let time = Double(frame) / 48_000
            let pulse = time.truncatingRemainder(dividingBy:0.3)
            let envelope = pulse < 0.15 ? min(1,pulse / 0.008,(0.15-pulse) / 0.008) : 0
            let sample = Float(sin(time * 2 * .pi * 1_040) * max(0,envelope) * 0.16)
            channels[0][frame] = sample; channels[1][frame] = sample
        }
        generation += 1; let token = generation
        node.stop(); try engine.start()
        node.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.node.stop(); self.engine.stop() }
        }
        node.play(); lastPlay = Date(); return true
    }
    func stop() { generation += 1; node.stop(); engine.stop() }
}
