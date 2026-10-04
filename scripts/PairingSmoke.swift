// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation
import Network
import MusicSyncCore

struct SmokeFailure: Error { let message: String }
@MainActor final class Probe {
    let peer: Peer
    let deviceID: String
    var messages: [Message] = []
    var ready = false
    init(port: NWEndpoint.Port, deviceID: String = UUID().uuidString) {
        self.deviceID = deviceID
        peer = Peer(NWConnection(host:"127.0.0.1",port:port,using:LAN.clientParameters(trust:TLSClientTrust())),queue:.main)
        peer.onState = { [weak self] state in if case .ready = state { self?.ready = true } }
        peer.onMessage = { [weak self] message in self?.messages.append(message) }
        peer.start()
    }
    func hello() { var message = Message("hello"); message.pairingVersion = 2; message.deviceID = deviceID; message.name = "Pairing CI probe"; message.channelSelection = "automatic"; peer.send(message) }
    func stats() { var message = Message("stats"); message.rtt = 0.01; message.offset = 10; message.jitter = 0.002; message.latency = 0.18; message.outputChannel = "stereo"; message.playbackState = "Waiting"; peer.send(message) }
    func last(_ kind: String) -> Message? { messages.last { $0.kind == kind } }
}
@main struct PairingSmoke {
    @MainActor static func wait(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { throw SmokeFailure(message:"Timeout: " + description) }
            try await Task.sleep(nanoseconds:20_000_000)
        }
    }
    @MainActor static func require(_ condition: Bool, _ description: String) throws { if !condition { throw SmokeFailure(message:description) } }
    @MainActor static func main() async throws {
        try await clientRejectsUnverifiedApproval(wrongCode:false)
        try await clientRejectsUnverifiedApproval(wrongCode:true)
        let host = HostModel(); host.directOnly = true; host.startHost(localEndpoint:.hostPort(host:.ipv4(.loopback),port:.any))
        defer { for device in host.devices where device.gate.approved { host.forgetDevice(device.id) }; host.stopHost() }
        try await wait("listener") { host.active && host.listeningPort != nil }
        let number = try unwrap(host.listeningPort)
        let port = try unwrap(NWEndpoint.Port(rawValue:number))
        let first = Probe(port:port)
        defer { first.peer.cancel() }
        try await wait("first ready") { first.ready }; first.hello()
        try await wait("challenge") { first.last("pairChallenge") != nil }
        let challenge = try unwrap(first.last("pairChallenge"))
        first.stats(); first.peer.send(Message("identifyHost"))
        try await Task.sleep(nanoseconds:100_000_000)
        try require(!host.devices.contains { $0.ready },"Unauthenticated stats must not authorize audio")
        first.peer.send(Message("pairRequest"))
        try await wait("code") { first.last("pairPending") != nil }
        let firstID = try unwrap(host.devices.first(where: { $0.deviceID == first.deviceID })?.id)
        try require(first.last("pairPending")?.pairingCode?.count == 8,"Pairing code must have eight digits")
        try require(first.last("pairPending")?.pairingCode == TLSSessionInfo.read(first.peer.connection)?.pairingCode,"TLS exporter codes must match")
        host.approveDevice(firstID)
        try await Task.sleep(nanoseconds:100_000_000)
        try require(first.last("pairApproved") == nil,"Host must wait for Client code confirmation")
        var confirmation = Message("pairConfirm"); confirmation.pairingCode = TLSSessionInfo.read(first.peer.connection)?.pairingCode
        first.peer.send(confirmation)
        try await wait("client confirmation") { host.devices.first(where: { $0.id == firstID })?.clientConfirmed == true }
        host.approveDevice(firstID)
        try await wait("approval") { first.last("pairApproved") != nil }
        let secret = try unwrap(first.last("pairApproved")?.pairingSecret)
        first.stats(); try await wait("approved stats") { host.devices.first(where: { $0.id == firstID })?.ready == true }
        host.setChannel(firstID,selection:.right)
        try await wait("channel command") { first.last("setChannel") != nil }
        let command = try unwrap(first.last("setChannel"))
        var ack = Message("channelReport"); ack.channelSelection = "right"; ack.outputChannel = "right"; ack.requestID = command.requestID
        first.peer.send(ack)
        try await wait("channel ack") { host.devices.first(where: { $0.id == firstID })?.effectiveChannel == .right && host.devices.first(where: { $0.id == firstID })?.pendingChannel == nil }
        let second = Probe(port:port); defer { second.peer.cancel() }
        try await wait("second ready") { second.ready }; second.hello()
        try await wait("second challenge") { second.last("pairChallenge") != nil }
        host.identifyDevice(firstID)
        try await wait("targeted identification") { first.last("identify") != nil }
        try require(second.last("identify") == nil,"Identification must not be broadcast to another device")
        first.peer.cancel()
        try await wait("first closed") { !host.devices.contains { $0.id == firstID } }
        let reconnect = Probe(port:port,deviceID:first.deviceID); defer { reconnect.peer.cancel() }
        try await wait("reconnect ready") { reconnect.ready }; reconnect.hello()
        try await wait("reconnect challenge") { reconnect.last("pairChallenge") != nil }
        let fresh = try unwrap(reconnect.last("pairChallenge"))
        try require(fresh.nonce != challenge.nonce,"Reconnect must have a fresh nonce")
        var auth = Message("pairProof"); auth.pairingProof = PairingProof.make(secret:secret,nonce:try unwrap(fresh.nonce),hostID:try unwrap(fresh.hostID),clientID:first.deviceID,binding:TLSSessionInfo.read(reconnect.peer.connection)?.binding ?? "")
        reconnect.peer.send(auth)
        try await wait("remembered approval") { reconnect.last("pairApproved") != nil }
        try require(reconnect.last("pairApproved")?.pairingSecret == nil,"Reconnect must not resend the stored secret")
        try require(reconnect.last("pairPending") == nil,"Valid remembered pairing should not require another approval")
        reconnect.stats()
        try await wait("reconnected ready") { host.devices.contains { $0.deviceID == first.deviceID && $0.ready } }
        let liveID = try unwrap(host.devices.first(where: { $0.deviceID == first.deviceID })?.id)
        host.forgetDevice(liveID)
        try await wait("revocation") { reconnect.last("pairRejected") != nil }
        let revoked = Probe(port:port,deviceID:first.deviceID); defer { revoked.peer.cancel() }
        try await wait("revoked ready") { revoked.ready }; revoked.hello()
        try await wait("revoked challenge") { revoked.last("pairChallenge") != nil }
        let last = try unwrap(revoked.last("pairChallenge"))
        var invalid = Message("pairProof"); invalid.pairingProof = PairingProof.make(secret:secret,nonce:try unwrap(last.nonce),hostID:try unwrap(last.hostID),clientID:first.deviceID,binding:TLSSessionInfo.read(revoked.peer.connection)?.binding ?? "")
        revoked.peer.send(invalid)
        try await wait("revoked requires approval") { revoked.last("pairPending") != nil }
        try require(revoked.last("pairApproved") == nil,"Removed pairing must not authenticate")
        print("Verified real TLS 1.3, exporter code confirmation, Host approval gate, channel acknowledgment, targeted identify, remembered reconnect and revocation.")
    }
    @MainActor static func clientRejectsUnverifiedApproval(wrongCode: Bool) async throws {
        let identity = try TLSIdentity.create()
        let parameters = try LAN.hostParameters(identity:identity)
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener = try NWListener(using:parameters)
        let hostID = UUID().uuidString
        var port: NWEndpoint.Port?
        var serverPeer: Peer?
        listener.stateUpdateHandler = { state in if case .ready = state { port = listener.port } }
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection,queue:.main); serverPeer = peer
            peer.onMessage = { message in
                if message.kind == "hello" {
                    var challenge = Message("pairChallenge"); challenge.pairingVersion = 2
                    challenge.hostID = hostID; challenge.nonce = UUID().uuidString
                    peer.send(challenge)
                } else if message.kind == "pairRequest" {
                    var response = Message(wrongCode ? "pairPending" : "pairApproved"); response.hostID = hostID
                    if wrongCode {
                        let actual = TLSSessionInfo.read(peer.connection)?.pairingCode
                        response.pairingCode = actual == "00000000" ? "00000001" : "00000000"
                    } else { response.pairingSecret = PairingProof.newSecret() }
                    peer.send(response)
                }
            }
            peer.start()
        }
        listener.start(queue:.main)
        let client = ClientModel()
        defer { client.disconnect(); serverPeer?.cancel(); listener.cancel() }
        try await wait("negative test listener") { port != nil }
        client.directAddress = "127.0.0.1:" + String(try unwrap(port).rawValue); client.connectDirect()
        try await wait("Client security rejection") { client.status == tr("Security verification failed") }
        try require(!client.paired && !client.connected,"Unverified approval or different exporter code must never start playback")
        try require(client.error != nil,"Client must explain security rejection")
    }
    static func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw SmokeFailure(message:"Missing value") }; return value }
}
