// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation
import Darwin

public enum SyncClock {
    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    public static var now: Double { Double(mach_absolute_time()) * scale }
}

/// Host-domain seconds are monotonic, never wall-clock dates.
public struct Message: Codable {
    public var version = 1
    public var kind: String
    public var name: String?
    public var pairingVersion: Int?
    public var deviceID: String?
    public var hostID: String?
    public var hostAddress: String?
    public var serviceName: String?
    public var nonce: String?
    public var pairingCode: String?
    public var pairingProof: String?
    public var pairingSecret: String?
    public var channelSelection: String?
    public var requestID: String?
    public var accepted: Bool?
    public var playbackState: String?
    public var t1: Double?
    public var t2: Double?
    public var t3: Double?
    public var rtt: Double?
    public var offset: Double?
    public var jitter: Double?
    public var latency: Double?
    public var sequence: UInt64?
    public var epoch: UInt64?
    public var pts: Double?
    public var sampleRate: Double?
    public var channels: Int?
    public var frames: Int?
    public var syncWarning: String?
    public var dropped: Int?
    public var schedulingError: Double?
    public var bufferCount: Int?
    public var monitor: Bool?
    public var outputChannel: String?
    public var volumeControlVersion: Int?
    public var volume: Double?
    public var hostVolume: Double?
    public var volumeTarget: String?
    public var allowClientHostVolume: Bool?
    public var allowHostClientVolume: Bool?
    public var allowPeerClientVolume: Bool?
    public var targetPeerID: UUID?
    public var volumePeers: [VolumePeer]?
    public var payload: Data?
    public init(_ kind: String) { self.kind = kind }
    public var validAudio: Bool {
        guard kind == "audio", version == 1, let pts, pts.isFinite,
              sampleRate == 48_000, channels == 2, let frames, (1...4800).contains(frames),
              let payload, payload.count == frames * 2 * 4, sequence != nil, epoch != nil else { return false }
        return true
    }
}

public enum FramingError: Error { case oversized, invalid }
public struct Framer {
    public static let maximum = 128 * 1024
    private var pending = Data()
    public init() {}
    public static func encode(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= maximum else { throw FramingError.oversized }
        let count = UInt32(body.count)
        var data = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        data.append(body)
        return data
    }
    public mutating func consume(_ bytes: Data) throws -> [Message] {
        pending.append(bytes)
        var messages: [Message] = []
        while pending.count >= 4 {
            let head = Array(pending.prefix(4))
            let n = head.reduce(0) { ($0 << 8) | Int($1) }
            guard n > 0, n <= Self.maximum else { throw FramingError.oversized }
            guard pending.count >= n + 4 else { break }
            let message = try JSONDecoder().decode(Message.self, from: Data(pending.dropFirst(4).prefix(n)))
            guard message.version == 1 else { throw FramingError.invalid }
            messages.append(message)
            pending = Data(pending.dropFirst(n + 4))
        }
        return messages
    }
}

public struct ClockEstimate {
    private var samples: [(rtt: Double, offset: Double)] = []
    public private(set) var rtt = 0.0
    /// host minus client clock
    public private(set) var offset = 0.0
    public private(set) var jitter = 0.0
    public var ready: Bool { samples.count >= 8 }
    public var uncertainty: Double { rtt / 2 + jitter }
    public init() {}
    public mutating func observe(t1: Double, t2: Double, t3: Double, t4: Double) {
        guard [t1,t2,t3,t4].allSatisfy({ $0.isFinite }) else { return }
        let delay = (t4 - t1) - (t3 - t2)
        guard delay >= 0, delay < 1, t4 >= t1, t3 >= t2 else { return }
        samples.append((delay, ((t2 - t1) + (t3 - t4)) / 2))
        if samples.count > 32 { samples.removeFirst() }
        let best = samples.sorted { $0.rtt < $1.rtt }.prefix(8)
        rtt = best.map(\.rtt).reduce(0,+) / Double(best.count)
        let candidate = best.map(\.offset).reduce(0,+) / Double(best.count)
        offset = samples.count <= 8 ? candidate : offset * 0.9 + candidate * 0.1
        let mean = samples.map(\.rtt).reduce(0,+) / Double(samples.count)
        jitter = sqrt(samples.map { pow($0.rtt - mean, 2) }.reduce(0,+) / Double(samples.count))
    }
}

/// Shared delay is changed on the host, never independently on one speaker.
public struct DelayController {
    public private(set) var target = 0.180
    public init() {}
    public mutating func update(rtt: Double, jitter: Double, requested: Double) {
        guard [rtt,jitter,requested].allSatisfy({ $0.isFinite }) else { return }
        let desired = min(0.5, max(0.18, rtt / 2 + jitter * 4 + 0.08, requested))
        // Raising the common timeline creates a gap; do not overlap previously scheduled audio.
        target = max(target, desired)
    }
}

public struct JitterQueue {
    private var packets: [Message] = []
    private var epoch: UInt64?
    private var last: UInt64?
    public private(set) var drops = 0
    public var count: Int { packets.count }
    public init() {}
    public mutating func insert(_ packet: Message) {
        guard packet.validAudio else { return }
        if epoch != packet.epoch {
            if let epoch, let incoming = packet.epoch, incoming < epoch { return }
            packets.removeAll(); epoch = packet.epoch; last = nil
        }
        guard let seq = packet.sequence, last.map({ seq > $0 }) ?? true,
              !packets.contains(where: { $0.sequence == seq }) else { return }
        packets.append(packet)
        packets.sort { $0.sequence! < $1.sequence! }
        if packets.count > 100 { packets.removeFirst(); drops += 1 }
    }
    public mutating func take(now: Double, offset: Double, horizon: Double = 0.065, minimumLead: Double = 0.025) -> [Message] {
        var result: [Message] = []
        while let packet = packets.first, let pts = packet.pts {
            let local = pts - offset
            if local > now + horizon { break }
            packets.removeFirst(); last = packet.sequence
            if local < now + minimumLead { drops += 1 } else { result.append(packet) }
        }
        return result
    }
}

/// Both channels remain on the wire; each speaker selects locally.
public enum OutputChannel: String, CaseIterable, Sendable {
    case stereo, left, right
    public func sourceIndex(forOutput channel: Int) -> Int {
        switch self { case .stereo: return channel; case .left: return 0; case .right: return 1 }
    }
}
