// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation
import Network
import Security

public final class Peer: @unchecked Sendable {
    public let connection: NWConnection
    public let id = UUID()
    public var onMessage: ((Message) -> Void)?
    /// Audio-only fast path on the transport queue; the receiver must enforce authorization.
    public var onAudioMessage: ((Message) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?
    public var onFailure: ((String) -> Void)?
    private var session: TLSSessionInfo?
    public var tlsSession: TLSSessionInfo? { serialized { session } }
    private let sessionReader: (NWConnection) -> TLSSessionInfo?
    private var deferredMessages: [Message] = []
    private var deferredBytes = 0
    private var failureReported = false
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label:"MusicSync.transport",qos:.userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var framer = Framer()
    private let submissionLock = NSLock()
    private var submittedBytes = 0
    private var queuedBytes = 0
    private var closed = false
    public init(_ connection: NWConnection, queue: DispatchQueue, sessionReader: @escaping (NWConnection) -> TLSSessionInfo? = TLSSessionInfo.read) {
        self.connection = connection; self.callbackQueue = queue; self.sessionReader = sessionReader
        self.queue.setSpecific(key:queueKey,value:true)
    }
    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key:queueKey) == true { return try body() }
        return try queue.sync(execute:body)
    }
    private func state(_ value: NWConnection.State) { callbackQueue.async { [weak self] in self?.onState?(value) } }
    private func deliver(_ message: Message) {
        if message.kind == "audio", let audio = onAudioMessage { audio(message) }
        else if message.kind == "stop", let audio = onAudioMessage {
            audio(message); callbackQueue.async { [weak self] in self?.onMessage?(message) }
        }
        else { callbackQueue.async { [weak self] in self?.onMessage?(message) } }
    }
    public func start() { queue.async { [self] in startOnQueue() } }
    private func startOnQueue() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if self.closed { if case .cancelled = state { self.state(state) }; return }
            if case .ready = state { self.prepareSecurity(attempt:0); return }
            if case .failed(let error) = state { self.reportFailure("TLS/network failed: \(error)") }
            if case .waiting(let error) = state { self.reportFailure("TLS/network waiting: \(error)") }
            self.state(state)
            if case .waiting = state { self.cancel() }
        }
        connection.start(queue: queue)
        receive()
    }
    private func prepareSecurity(attempt: Int) {
        guard !closed else { return }
        if let session = sessionReader(connection) {
            self.session = session
            state(.ready)
            guard !closed else { return }
            let pending = deferredMessages; deferredMessages.removeAll(); deferredBytes = 0
            for message in pending { guard !closed else { return }; deliver(message) }
        } else if attempt < 20 {
            queue.asyncAfter(deadline:.now()+0.1) { [weak self] in self?.prepareSecurity(attempt:attempt+1) }
        } else {
            reportFailure("TLS session preparation timed out after 2 seconds; " + TLSSessionInfo.diagnostic(connection))
            cancel()
        }
    }
    private func reportFailure(_ reason: String) {
        guard !failureReported else { return }; failureReported = true; callbackQueue.async { [weak self] in self?.onFailure?(reason) }
    }
    /// Encoding and network I/O stay off the callback/UI queue; FIFO ordering is preserved.
    public func send(_ message: Message) {
        // Bound work awaiting JSON encoding as well as bytes already passed to Network.framework.
        let cost = (message.payload?.count ?? 0)*4/3+1024
        submissionLock.lock()
        if submittedBytes+cost > (message.kind == "audio" ? 96*1024 : 512*1024) {
            submissionLock.unlock()
            if message.kind != "audio" { queue.async { [self] in reportFailure("Outgoing submission queue exceeded 512 KiB"); cancelOnQueue() } }
            return
        }
        submittedBytes += cost; submissionLock.unlock()
        queue.async { [self] in
            sendOnQueue(message)
            submissionLock.lock(); submittedBytes -= cost; submissionLock.unlock()
        }
    }
    private func sendOnQueue(_ message: Message) {
        guard !closed, let data = try? Framer.encode(message) else { return }
        // A stalled receiver must not accumulate seconds of stale audio.
        if message.kind == "audio", queuedBytes + data.count > 96 * 1024 { return }
        guard queuedBytes + data.count < 512 * 1024 else { reportFailure("Outgoing control queue exceeded 512 KiB"); cancel(); return }
        queuedBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queuedBytes -= data.count
            if let error { self.reportFailure("Send failed: \(error)"); self.cancel() }
        })
    }
    public func cancel() { queue.async { [self] in cancelOnQueue() } }
    private func cancelOnQueue() {
        guard !closed else { return }
        closed = true; connection.cancel()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data {
                do {
                    let messages = try self.framer.consume(data)
                    if self.session == nil {
                        self.deferredBytes += data.count
                        guard self.deferredBytes <= 128 * 1024 else { self.reportFailure("TLS bootstrap receive queue exceeded 128 KiB"); self.cancel(); return }
                        self.deferredMessages.append(contentsOf:messages)
                    } else { for message in messages { guard !self.closed else { return }; self.deliver(message) } }
                }
                catch { self.reportFailure("Invalid protocol framing: \(error)"); self.cancel(); return }
            }
            if complete || error != nil {
                if let error { self.reportFailure("Receive failed: \(error)") }
                else { self.reportFailure("The remote device closed the connection") }
                self.cancel()
            } else { self.receive() }
        }
    }
}
public enum LAN {
    public static let service = "_musicsync._tcp"
    private static func parameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions,.TLSv13)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions,false)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions,false)
        let parameters = NWParameters(tls:tls,tcp:tcp); parameters.includePeerToPeer = false
        return parameters
    }
    public static func hostParameters(identity: TLSIdentity) throws -> NWParameters {
        guard let local = sec_identity_create(identity.identity) else { throw TLSError.identity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions,local)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions,false)
        return parameters(tls:tls)
    }
    public static func clientParameters(trust: TLSClientTrust) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions,{ _, value, complete in complete(trust.verify(value)) },DispatchQueue(label:"MusicSync.TLS.verify"))
        return parameters(tls:tls)
    }
    /// Browsing never establishes an audio connection.
    public static func discoveryParameters() -> NWParameters { NWParameters.tcp }
}
