// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import XCTest
import Network
@testable import MusicSyncCore

/// Exercises the real Network.framework peer and framing over loopback, without Bonjour permission.
final class TransportTests: XCTestCase {
    func testClockProbeAndPCMOverTCP() throws {
        let harness = LoopbackHarness()
        let received = expectation(description: "PCM and clock response received")
        harness.onComplete = { received.fulfill() }
        try harness.start()
        wait(for: [received], timeout: 10)
        harness.stop()
    }
}

private final class LoopbackHarness: @unchecked Sendable {
    var onComplete: (() -> Void)?
    private let queue = DispatchQueue(label: "MusicSync.test.loopback")
    private var listener: NWListener?
    private var host: Peer?
    private var client: Peer?
    private var pong = false
    private var pcm = false
    func start() throws {
        let parameters = LAN.parameters()
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let peer = Peer(connection, queue: self.queue)
            self.host = peer
            peer.onMessage = { [weak peer] request in
                if request.kind == "ping" {
                    var reply = Message("pong"); reply.t1 = request.t1
                    reply.t2 = SyncClock.now; reply.t3 = SyncClock.now
                    peer?.send(reply)
                } else if request.validAudio { peer?.send(request) }
            }
            peer.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                XCTFail("Loopback listener failed: \(error)")
                self?.onComplete?(); self?.onComplete = nil
            }
            guard let self, case .ready = state, let port = self.listener?.port else { return }
            let peer = Peer(NWConnection(host: .ipv4(.loopback), port: port, using: LAN.parameters()), queue: self.queue)
            self.client = peer
            peer.onState = { [weak peer] state in
                if case .failed(let error) = state { XCTFail("Loopback client failed: \(error)") }
                guard case .ready = state else { return }
                var ping = Message("ping"); ping.t1 = SyncClock.now; peer?.send(ping)
                var audio = Message("audio"); audio.sequence = 42; audio.epoch = 1; audio.pts = SyncClock.now + 0.18
                audio.sampleRate = 48000; audio.channels = 2; audio.frames = 480
                audio.payload = Data(repeating: 0, count: 3840)
                peer?.send(audio)
            }
            peer.onMessage = { [weak self] message in
                guard let self else { return }
                if message.kind == "pong" { self.pong = message.t1 != nil && message.t2 != nil && message.t3 != nil }
                if message.validAudio { self.pcm = message.sequence == 42 && message.payload == Data(repeating: 0, count: 3840) }
                if self.pong && self.pcm { self.onComplete?(); self.onComplete = nil }
            }
            peer.start()
        }
        listener.start(queue: queue)
    }
    func stop() { queue.sync { client?.cancel(); host?.cancel(); listener?.cancel() } }
}
