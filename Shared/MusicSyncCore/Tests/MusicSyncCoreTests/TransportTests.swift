// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import XCTest
import Network
@testable import MusicSyncCore

/// Exercises the real Network.framework peer and framing over loopback, without Bonjour permission.
final class TransportTests: XCTestCase {
    func testClockProbeAndPCMOverTLS() throws {
        let harness = LoopbackHarness()
        let received = expectation(description: "PCM and clock response received")
        harness.onComplete = { received.fulfill() }
        try harness.start()
        wait(for: [received], timeout: 10)
        harness.stop()
    }
    func testAudioBurstDoesNotDisconnectAndFollowingClockControlSurvives() throws {
        let harness=LoopbackHarness(burst:true)
        let received=expectation(description:"Audio congestion preserves following ping")
        harness.onComplete={received.fulfill()}
        harness.onFailure={reason in XCTFail("Audio burst closed connection: \(reason)")}
        try harness.start();wait(for:[received],timeout:10);harness.stop()
    }
    func testDelayedTLSSessionDoesNotDisconnectOrDeliverMessagesBeforeReady() throws {
        let harness = LoopbackHarness(delayed:true)
        let received = expectation(description:"Delayed TLS bootstrap recovered")
        harness.onComplete = { received.fulfill() }
        try harness.start(); wait(for:[received],timeout:10); harness.stop()
    }

    func testMissingTLSSessionReportsReasonAndStops() throws {
        let harness = LoopbackHarness(unavailable:true)
        let stopped = expectation(description:"Unavailable exporter has a bounded failure")
        harness.onFailure = { reason in
            XCTAssertTrue(reason.contains("TLS session preparation timed out"))
            XCTAssertFalse(reason.contains("binding="))
            stopped.fulfill()
        }
        try harness.start(); wait(for:[stopped],timeout:8); harness.stop()
    }

}

private final class LoopbackHarness: @unchecked Sendable {
    var onComplete: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "MusicSync.test.loopback")
    private var listener: NWListener?
    private var host: Peer?
    private var client: Peer?
    private var pong = false
    private var pcm = false
    private let delayed: Bool
    private let unavailable: Bool
    private let burst: Bool
    private var hostReads = 0
    private var clientReads = 0
    private var hostReady = false
    private var clientReady = false
    init(delayed: Bool = false, unavailable: Bool = false, burst:Bool = false) { self.delayed = delayed; self.unavailable = unavailable; self.burst=burst }
    func start() throws {
        let identity = try TLSIdentity.create()
        let parameters = try LAN.hostParameters(identity:identity)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let peer = Peer(connection, queue:self.queue,sessionReader:{ [weak self] connection in
                guard let self else { return nil }; self.hostReads += 1
                return self.delayed && self.hostReads < 5 ? nil : TLSSessionInfo.read(connection)
            })
            peer.onState = { [weak self] state in if case .ready = state { self?.hostReady = true } }
            self.host = peer
            peer.onMessage = { [weak peer, weak self] request in
                XCTAssertTrue(self?.hostReady == true,"Do not deliver bootstrap messages before TLS session preparation")
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
            let peer = Peer(NWConnection(host: .ipv4(.loopback), port: port, using:LAN.clientParameters(trust:TLSClientTrust(expectedPin:identity.publicKeyPin))), queue:self.queue,sessionReader:{ [weak self] connection in
                guard let self else { return nil }; self.clientReads += 1
                return self.unavailable || (self.delayed && self.clientReads < 2) ? nil : TLSSessionInfo.read(connection)
            })
            self.client = peer
            peer.onFailure = { [weak self] reason in self?.onFailure?(reason) }
            peer.onState = { [weak peer, weak self] state in
                if case .failed(let error) = state { XCTFail("Loopback client failed: \(error)") }
                guard case .ready = state else { return }
                self?.clientReady = true
                var ping = Message("ping"); ping.t1 = SyncClock.now; if self?.burst != true { peer?.send(ping) }
                XCTAssertNotNil(peer.flatMap { TLSSessionInfo.read($0.connection) })
                var audio = Message("audio"); audio.sequence = 42; audio.epoch = 1; audio.pts = SyncClock.now + 0.18
                audio.sampleRate = 48000; audio.channels = 2; audio.frames = 480
                audio.payload = Data(repeating: 0, count: 3840)
                for _ in 0..<(self?.burst == true ? 200 : 1) { peer?.send(audio) }
                if self?.burst == true { peer?.send(ping) }
            }
            peer.onMessage = { [weak self] message in
                guard let self else { return }
                XCTAssertTrue(self.clientReady)
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
