// SPDX-License-Identifier: MIT
import Foundation
import MusicSyncCore

/// PCM packetization and local playback never run on the UI actor.
final class HostAudioPipeline: @unchecked Sendable {
    struct Snapshot {
        var traffic = TrafficSnapshot()
        var drops = 0
        var error = 0.0
        var lastAudio = 0.0
    }
    private let queue = DispatchQueue(label:"MusicSync.host.audio",qos:.userInteractive)
    private let player: PCMPlayer
    private var active = false
    private var epoch: UInt64 = 0
    private var sequence: UInt64 = 0
    private var timeline = HostPresentationTimeline()
    private var delay = 0.18
    private var peers: [Peer] = []
    private var monitor = false
    private var remoteChannel = OutputChannel.stereo
    private var meter = TrafficMeter()
    private var snapshot = Snapshot()
    private var toneTimer: DispatchSourceTimer?
    private var phase = 0.0
    private var layout = SpeakerLayout.stereo
    init(player: PCMPlayer) { self.player = player }
    func start(epoch: UInt64, monitor: Bool, testTone: Bool) {
        queue.sync {
            toneTimer?.cancel(); toneTimer = nil
            self.epoch = epoch; self.monitor = monitor; sequence = 0
            timeline = HostPresentationTimeline(); meter = TrafficMeter(); snapshot = Snapshot(); phase = 0
            active = true
            if testTone {
                let timer = DispatchSource.makeTimerSource(queue:queue)
                timer.schedule(deadline:.now(),repeating:.milliseconds(10),leeway:.milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tone() }
                toneTimer = timer; timer.resume()
            }
        }
    }
    func configure(peers: [Peer], delay: Double, trim: Double, layout: SpeakerLayout) {
        queue.async { [self] in
            self.peers = peers; self.delay = delay; self.layout = layout
            remoteChannel = layout.remoteChannel; player.calibration = trim; player.channel = layout.localChannel
        }
    }
    func submit(_ data: Data, frames: Int, captureTime: Double, epoch: UInt64) {
        queue.async { [self] in
            guard active, self.epoch == epoch else { return }
            process(data,frames:frames,captureTime:captureTime)
        }
    }
    func stop() { queue.sync { active = false; toneTimer?.cancel(); toneTimer = nil; peers = []; player.stop() } }
    func sample() -> Snapshot { queue.sync {
        var result = snapshot; result.traffic = meter.sample(now:SyncClock.now,drops:snapshot.drops)
        snapshot.error = 0; return result
    } }
    private func tone() {
        var samples = [Float](repeating:0,count:960)
        for frame in 0..<480 {
            let pulse = (phase/48000).truncatingRemainder(dividingBy:1)
            let value: Float = pulse < 0.1 ? Float(sin(phase*2*Double.pi*880/48000)) * 0.12 : 0
            var left = value, right = value
            if layout != .stereo {
                if (0.25..<0.35).contains(pulse) { left = Float(sin(phase*2*Double.pi*440/48000))*0.12 }
                if (0.5..<0.6).contains(pulse) { right = Float(sin(phase*2*Double.pi*660/48000))*0.12 }
            }
            samples[frame*2] = left; samples[frame*2+1] = right; phase += 1
        }
        process(samples.withUnsafeBytes { Data($0) },frames:480,captureTime:SyncClock.now)
    }
    private func process(_ data: Data, frames: Int, captureTime: Double) {
        guard active, frames > 0, data.count == frames*8 else { return }
        let now = SyncClock.now; snapshot.lastAudio = now
        _ = timeline.begin(captureTime:captureTime,now:now,delay:delay)
        var cursor = 0
        while cursor < frames {
            let count = min(480,frames-cursor)
            var message = Message("audio")
            message.sequence = sequence; sequence += 1; message.epoch = epoch
            message.pts = timeline.nextTime; message.sampleRate = 48000; message.channels = 2; message.frames = count
            message.latency = delay; message.monitor = monitor; message.outputChannel = remoteChannel.rawValue
            message.payload = data.subdata(in:(cursor*8)..<((cursor+count)*8))
            timeline.advance(frames:count); cursor += count; meter.record(bytes:count*8)
            if player.running {
                if !player.schedule(message,offset:0) { snapshot.drops += 1 }
                snapshot.error = max(snapshot.error,player.schedulingError)
            }
            for peer in peers { peer.send(message) }
        }
    }
}

/// Authorization and clock readiness gate the transport fast path. All state stays on this queue.
final class ClientAudioPipeline: @unchecked Sendable {
    struct Snapshot {
        var drops = 0
        var error = 0.0
        var count = 0
        var queuedUntil: Double?
        var lastAudio = 0.0
        var epoch: UInt64?
        var monitor = false
        var latency = 0.18
        var channel = OutputChannel.stereo
        var traffic = TrafficSnapshot()
        var failure: String?
    }
    private let queue = DispatchQueue(label:"MusicSync.client.audio",qos:.userInteractive)
    private let player: PCMPlayer
    private var buffer = JitterQueue()
    private var offset = 0.0
    private var enabled = false
    private var session: UUID?
    private var clockReady = false
    private var interrupted = false
    private var selection = ChannelSelection.automatic
    private var meter = TrafficMeter()
    private var snapshot = Snapshot()
    private var timer: DispatchSourceTimer?
    init(player: PCMPlayer) { self.player = player }
    func begin(session: UUID) { queue.sync {
        clearOnQueue(); enabled = true; self.session = session
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(5),leeway:.milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }; self.timer = timer; timer.resume()
    } }
    func configure(ready: Bool, offset: Double, selection: ChannelSelection, hostChannel: OutputChannel, trim: Double) {
        queue.async { [self] in
            clockReady = ready; self.offset = offset; self.selection = selection
            if snapshot.epoch == nil { snapshot.channel = hostChannel }; player.calibration = trim
        }
    }
    func receive(_ packet: Message, session: UUID) { queue.async { [self] in
        guard enabled, self.session == session else { return }
        if packet.kind == "stop" { stopStreamOnQueue(); return }
        guard clockReady, !interrupted, packet.validAudio else { return }
        if let epoch = snapshot.epoch, packet.epoch! < epoch { return }
        if snapshot.epoch != packet.epoch {
            player.stop(); buffer = JitterQueue(); snapshot.epoch = packet.epoch
            do { try player.start() } catch { snapshot.failure = error.localizedDescription; return }
        }
        if let channel = packet.outputChannel.flatMap(OutputChannel.init(rawValue:)) { snapshot.channel = channel }
        snapshot.monitor = packet.monitor ?? false
        if let latency = packet.latency, latency.isFinite, (0.18...0.5).contains(latency) { snapshot.latency = latency }
        buffer.insert(packet); snapshot.lastAudio = SyncClock.now; meter.record(bytes:packet.payload!.count)
    } }
    private func stopStreamOnQueue() { player.stop(); buffer = JitterQueue(); snapshot.lastAudio = 0; snapshot.epoch = nil; snapshot.monitor = false }
    func interrupt(_ value: Bool) { queue.sync { interrupted = value; player.stop(); buffer = JitterQueue(); snapshot.epoch = nil } }
    func end() { queue.sync { clearOnQueue() } }
    private func clearOnQueue() {
        enabled = false; session = nil; clockReady = false; interrupted = false; timer?.cancel(); timer = nil
        player.stop(); buffer = JitterQueue(); snapshot = Snapshot(); meter = TrafficMeter()
    }
    func sample() -> Snapshot { queue.sync {
        var result = snapshot; result.count = buffer.count; result.drops += buffer.drops
        result.queuedUntil = player.queuedUntil; result.traffic = meter.sample(now:SyncClock.now,drops:result.drops)
        snapshot.error = 0; return result
    } }
    private func drain() {
        guard enabled, clockReady, !interrupted else { return }
        let now = SyncClock.now; let lead = max(0.025,player.outputLatency+abs(player.calibration)+0.01)
        for packet in buffer.take(now:now,offset:offset,horizon:max(0.13,lead+0.04),minimumLead:lead) {
            player.channel = selection.channel ?? snapshot.channel
            if !player.schedule(packet,offset:offset) { snapshot.drops += 1 }
            snapshot.error = max(snapshot.error,player.schedulingError)
        }
    }
}
