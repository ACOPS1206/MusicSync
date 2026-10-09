// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import AVFoundation
import MusicSyncCore

/// Serial scheduling, with output-device latency removed from the requested acoustic time.
final class PCMPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label:"MusicSync.PCM",qos:.userInteractive)
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    var volume: Float {
        get { queue.sync { node.volume } }
        set { queue.sync { node.volume = newValue.isFinite ? min(1,max(0,newValue)) : 0 } }
    }
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var isRunning = false
    var running: Bool { queue.sync { isRunning } }
    private var timeline = PlaybackTimeline()
    private var error = 0.0
    var schedulingError: Double { queue.sync { error } }
    var queuedUntil: Double? { queue.sync { timeline.queuedUntil } }
    private var trim = 0.0
    var calibration: Double { get { queue.sync { trim } } set { queue.sync { trim = newValue } } }
    private var selection = OutputChannel.stereo
    var channel: OutputChannel { get { queue.sync { selection } } set { queue.sync { selection = newValue } } }
    var outputLatency: Double { queue.sync { latencyOnQueue } }
    private var latencyOnQueue: Double {
        #if os(iOS)
        return AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration
        #else
        return engine.outputNode.presentationLatency
        #endif
    }
    init() { engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format) }
    func start() throws { try queue.sync { try startOnQueue() } }
    private func startOnQueue() throws {
        guard !isRunning else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        #endif
        try engine.start(); node.play(); isRunning = true
    }
    func stop() { queue.sync { node.stop(); engine.stop(); isRunning = false; timeline = PlaybackTimeline(); error = 0 } }
    @discardableResult func schedule(_ packet: Message, offset: Double) -> Bool { queue.sync { scheduleOnQueue(packet,offset:offset) } }
    private func scheduleOnQueue(_ packet: Message, offset: Double) -> Bool {
        guard isRunning, packet.validAudio, let frames = packet.frames, let data = packet.payload, let pts = packet.pts,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return false }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { bytes in
            for f in 0..<frames {
                for c in 0..<2 {
                    let sourceChannel = selection.sourceIndex(forOutput: c)
                    let raw = bytes.loadUnaligned(fromByteOffset: (f * 2 + sourceChannel) * 4, as: UInt32.self)
                    let value = Float(bitPattern: UInt32(littleEndian: raw))
                    channels[c][f] = value.isFinite ? max(-1, min(1, value)) : 0
                }
            }
        }
        let renderTime = pts - offset - latencyOnQueue + trim
        let now = SyncClock.now
        guard renderTime > now + 0.003 else { error = max(0, now + 0.003 - renderTime); return false }
        let previousEnd = timeline.queuedUntil
        let anchor = timeline.schedule(sequence: packet.sequence!, epoch: packet.epoch!, desired: renderTime, duration: Double(frames) / 48_000, now: SyncClock.now)
        error = abs((anchor ?? previousEnd ?? renderTime) - renderTime)
        let time = anchor.map { AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: $0)) }
        node.scheduleBuffer(buffer, at: time, options: [])
        return true
    }
}
