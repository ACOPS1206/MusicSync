import AVFoundation
import MusicSyncCore

/// Serial scheduling, with output-device latency removed from the requested acoustic time.
final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private(set) var running = false
    private var timeline = PlaybackTimeline()
    var calibration = 0.0
    var outputLatency: Double {
        #if os(iOS)
        return AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration
        #else
        return engine.outputNode.presentationLatency
        #endif
    }
    init() { engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format) }
    func start() throws {
        guard !running else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        #endif
        try engine.start(); node.play(); running = true
    }
    func stop() { node.stop(); engine.stop(); running = false; timeline = PlaybackTimeline() }
    @discardableResult func schedule(_ packet: Message, offset: Double) -> Bool {
        guard running, packet.validAudio, let frames = packet.frames, let data = packet.payload, let pts = packet.pts,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return false }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { bytes in
            for f in 0..<frames {
                for c in 0..<2 {
                    let raw = bytes.loadUnaligned(fromByteOffset: (f * 2 + c) * 4, as: UInt32.self)
                    let value = Float(bitPattern: UInt32(littleEndian: raw))
                    channels[c][f] = value.isFinite ? max(-1, min(1, value)) : 0
                }
            }
        }
        let renderTime = pts - offset - outputLatency + calibration
        guard renderTime > SyncClock.now + 0.003 else { return false }
        let anchor = timeline.schedule(sequence: packet.sequence!, epoch: packet.epoch!, desired: renderTime, duration: Double(frames) / 48_000, now: SyncClock.now)
        let time = anchor.map { AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: $0)) }
        node.scheduleBuffer(buffer, at: time, options: [])
        return true
    }
}
