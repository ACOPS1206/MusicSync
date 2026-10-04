// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation
import Network

public final class Peer {
    public let connection: NWConnection
    public let id = UUID()
    public var onMessage: ((Message) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?
    private let queue: DispatchQueue
    private var framer = Framer()
    private var queuedBytes = 0
    private var closed = false
    public init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection; self.queue = queue
    }
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onState?(state)
        }
        connection.start(queue: queue)
        receive()
    }
    /// All calls and callbacks are serialized on the supplied queue.
    public func send(_ message: Message) {
        guard !closed, let data = try? Framer.encode(message) else { return }
        // A stalled receiver must not accumulate seconds of stale audio.
        guard queuedBytes + data.count < 512 * 1024 else { cancel(); return }
        queuedBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queuedBytes -= data.count
            if error != nil { self.cancel() }
        })
    }
    public func cancel() {
        guard !closed else { return }
        closed = true; connection.cancel()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data {
                do { for message in try self.framer.consume(data) { self.onMessage?(message) } }
                catch { self.cancel(); return }
            }
            if complete || error != nil { self.cancel() } else { self.receive() }
        }
    }
}
public enum LAN {
    public static let service = "_musicsync._tcp"
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}
