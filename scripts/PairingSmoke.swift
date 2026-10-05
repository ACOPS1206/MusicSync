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
    func hello() { var message = Message("hello"); message.pairingVersion = 2; message.deviceID = deviceID; message.name = "Pairing CI probe"; message.channelSelection = "automatic"; message.volumeControlVersion = 1; message.volume = 1; peer.send(message) }
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
        try verifySystemVolumeEndpoint()
        try await clientRejectsUnverifiedApproval(wrongCode:false)
        try await clientRejectsUnverifiedApproval(wrongCode:true)
        let host = HostModel(volumeEndpoint:VolumeEndpoint(playbackOnly:true)); host.outputVolume = .nan; try require(host.outputVolume == 0,"Nonfinite local volume must clamp without recursion"); host.outputVolume = 1; host.directOnly = true; host.startHost(localEndpoint:.hostPort(host:.ipv4(.loopback),port:.any))
        defer { for device in host.devices where device.gate.approved { host.forgetDevice(device.id) }; host.stopHost() }
        try await wait("listener") { host.active && host.listeningPort != nil }
        let number = try unwrap(host.listeningPort)
        let port = try unwrap(NWEndpoint.Port(rawValue:number))
        let first = Probe(port:port)
        defer { first.peer.cancel() }
        try await wait("first ready") { first.ready }; first.hello()
        try await wait("challenge") { first.last("pairChallenge") != nil }
        let challenge = try unwrap(first.last("pairChallenge"))
        var premature = Message("setHostVolume"); premature.volume = 0.2; first.peer.send(premature)
        first.stats(); first.peer.send(Message("identifyHost"))
        try await Task.sleep(nanoseconds:100_000_000)
        try require(!host.devices.contains { $0.ready },"Unauthenticated stats must not authorize audio")
        try require(host.outputVolume == 1 && first.last("volumePeers") == nil,"Unpaired devices must not alter gain or receive roster")
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
        try await verifyHostVolume(host,probe:first,id:firstID,volume:0.2,accepted:false)
        host.setVolumePermissions(firstID,clientMayControlHost:true)
        try await verifyHostVolume(host,probe:first,id:firstID,volume:0.35,accepted:true)
        try require(host.outputVolume == 0.35,"Permitted volume must apply to the Host")
        try await verifyHostVolume(host,probe:first,id:firstID,volume:2,accepted:false)
        host.setVolumePermissions(firstID,clientMayControlHost:false)
        try await verifyHostVolume(host,probe:first,id:firstID,volume:0.9,accepted:false)
        try require(host.outputVolume == 0.35,"Revocation and invalid gain must leave Host volume unchanged")
        host.setClientVolume(firstID,volume:0.42)
        try await wait("volume command") { first.last("setClientVolume") != nil }
        let volumeCommand = try unwrap(first.last("setClientVolume"))
        var volumeAck = Message("volumeReport"); volumeAck.volume = 0.42; volumeAck.requestID = volumeCommand.requestID; first.peer.send(volumeAck)
        try await wait("volume acknowledgment") { host.devices.first(where: { $0.id == firstID })?.volume == 0.42 && host.devices.first(where: { $0.id == firstID })?.pendingVolume == nil }
        host.setClientVolume(firstID,volume:0.5)
        try await wait("first overlapping command") { first.last("setClientVolume")?.requestID != volumeCommand.requestID }
        let earlierVolume = try unwrap(first.last("setClientVolume"))
        host.setClientVolume(firstID,volume:0.65)
        var earlierAck = Message("volumeReport"); earlierAck.volume = 0.5; earlierAck.requestID = earlierVolume.requestID; first.peer.send(earlierAck)
        try await wait("newer queued volume survives old ack") { first.last("setClientVolume")?.volume == 0.65 }
        var latestAck = Message("volumeReport"); latestAck.volume = 0.65; latestAck.requestID = first.last("setClientVolume")?.requestID; first.peer.send(latestAck)
        try await wait("latest volume ack") { host.devices.first(where: { $0.id == firstID })?.volume == 0.65 && host.devices.first(where: { $0.id == firstID })?.pendingVolume == nil }
        host.setVolumePermissions(firstID,hostMayControlClient:false)
        let before = first.messages.filter { $0.kind == "setClientVolume" }.count
        host.setClientVolume(firstID,volume:0.8); try await Task.sleep(nanoseconds:150_000_000)
        try require(first.messages.filter { $0.kind == "setClientVolume" }.count == before,"Disabled Host permission must block commands")
        host.setChannel(firstID,selection:.right)
        try await wait("channel command") { first.last("setChannel") != nil }
        let command = try unwrap(first.last("setChannel"))
        var ack = Message("channelReport"); ack.channelSelection = "right"; ack.outputChannel = "right"; ack.requestID = command.requestID
        first.peer.send(ack)
        try await wait("channel ack") { host.devices.first(where: { $0.id == firstID })?.effectiveChannel == .right && host.devices.first(where: { $0.id == firstID })?.pendingChannel == nil }
        let second = Probe(port:port); defer { second.peer.cancel() }
        try await wait("second ready") { second.ready }; second.hello()
        try await wait("second challenge") { second.last("pairChallenge") != nil }
        second.peer.send(Message("pairRequest"))
        try await wait("second pairing") { second.last("pairPending") != nil }
        let secondID = try unwrap(host.devices.first(where: { $0.deviceID == second.deviceID })?.id)
        var secondConfirmation = Message("pairConfirm"); secondConfirmation.pairingCode = second.peer.tlsSession?.pairingCode; second.peer.send(secondConfirmation)
        try await wait("second confirmation") { host.devices.first(where: { $0.id == secondID })?.clientConfirmed == true }
        host.approveDevice(secondID); try await wait("second approval") { second.last("pairApproved") != nil }
        var relay = Message("setPeerVolume"); relay.targetPeerID = secondID; relay.volume = 0.25
        first.peer.send(relay); try await wait("peer denied by default") { first.last("peerVolumeDenied") != nil }
        try require(second.last("setClientVolume") == nil,"Default permissions must prevent Client-to-Client control")
        host.setVolumePermissions(firstID,clientMayControlPeers:true)
        first.peer.send(relay); try await Task.sleep(nanoseconds:150_000_000)
        try require(second.last("setClientVolume") == nil,"Sender permission alone is insufficient")
        host.setVolumePermissions(secondID,peersMayControlClient:true)
        try await wait("permitted roster") { first.last("volumePeers")?.volumePeers?.contains(where: { $0.id == secondID && $0.canControl }) == true }
        first.peer.send(relay); try await wait("relayed volume") { second.last("setClientVolume") != nil }
        let forwarded = try unwrap(second.last("setClientVolume"))
        try require(forwarded.volume == 0.25 && forwarded.targetPeerID == firstID,"Relay must identify origin and target only the selected Client")
        var relayAck = Message("volumeReport"); relayAck.volume = 0.25; relayAck.requestID = forwarded.requestID; second.peer.send(relayAck)
        try await wait("acknowledged roster") { first.last("volumePeers")?.volumePeers?.contains(where: { $0.id == secondID && $0.volume == 0.25 }) == true }
        // Revoke during the 100 ms queue window; no second command may escape.
        let relayCount = second.messages.filter { $0.kind == "setClientVolume" }.count
        host.setClientVolume(secondID,volume:0.8,requester:firstID)
        try require(host.devices.first(where: { $0.id == secondID })?.pendingVolume == 0.8,"Relay must be queued before revocation")
        host.setVolumePermissions(firstID,clientMayControlPeers:false)
        try await Task.sleep(nanoseconds:150_000_000)
        try require(second.messages.filter { $0.kind == "setClientVolume" }.count == relayCount,"Permission revocation must cancel a queued relay")
        host.identifyDevice(firstID)
        try await wait("targeted identification") { first.last("identify") != nil }
        try require(second.last("identify") == nil,"Identification must not be broadcast to another device")
        var peerChannel = Message("setPeerChannel"); peerChannel.targetPeerID = secondID; peerChannel.channelSelection = "left"
        first.peer.send(peerChannel); try await wait("peer channel denied by default") { first.last("peerControlDenied") != nil }
        try require(second.last("setChannel") == nil,"Peer channel control requires both permissions")
        host.setVolumePermissions(firstID,clientMayControlPeerDevices:true)
        host.setVolumePermissions(secondID,peersMayControlClientDevice:true)
        try await wait("peer control roster") { first.last("volumePeers")?.volumePeers?.contains(where: { $0.id == secondID && $0.canControlDevice == true }) == true }
        first.peer.send(peerChannel); try await wait("relayed channel") { second.last("setChannel")?.channelSelection == "left" }
        var peerChannelAck = Message("channelReport"); peerChannelAck.channelSelection = "left"; peerChannelAck.outputChannel = "left"; peerChannelAck.playbackState = "Streaming"; peerChannelAck.requestID = second.last("setChannel")?.requestID; second.peer.send(peerChannelAck)
        try await wait("reported channel roster") { first.last("volumePeers")?.volumePeers?.contains(where: { $0.id == secondID && $0.outputChannel == "left" && $0.playbackState == "Streaming" }) == true }
        let firstIdentifyCount = first.messages.filter { $0.kind == "identify" }.count
        var peerIdentify = Message("identifyPeer"); peerIdentify.targetPeerID = secondID; first.peer.send(peerIdentify)
        try await wait("peer identification") { second.last("identify")?.targetPeerID == firstID }
        try require(first.messages.filter { $0.kind == "identify" }.count == firstIdentifyCount,"Peer identification must target only the requested device")
        host.setVolumePermissions(firstID,clientMayControlPeerDevices:false)
        let secondChannelCount = second.messages.filter { $0.kind == "setChannel" }.count
        peerChannel.channelSelection = "right"; first.peer.send(peerChannel); try await Task.sleep(nanoseconds:150_000_000)
        try require(second.messages.filter { $0.kind == "setChannel" }.count == secondChannelCount,"Revoked peer channel permission must block relays")
        try require(!AppLog.shared.entries.contains(where: { $0.text.contains(secret) || $0.text.contains(confirmation.pairingCode ?? "not-a-code") }),"Diagnostics must not record pairing secrets or codes")
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
        try require(reconnect.last("pairApproved")?.allowHostClientVolume == false,"Remembered pairing must retain Host-owned volume policy")
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
        print("Verified system-volume read/write/failure, secret-free logs, peer channel/identify permissions, volume relay and queued revocation; real TLS 1.3, exporter code confirmation, Host approval gate, channel acknowledgment, targeted identify, remembered reconnect and revocation.")
    }
    @MainActor static func verifySystemVolumeEndpoint() throws {
        var hardware = 0.4; var writes = 0; var writable = true
        let endpoint = VolumeEndpoint(read:{ (hardware,writable) },write:{ value in guard writable else { return false }; writes += 1; hardware = value; return true })
        let model = HostModel(volumeEndpoint:endpoint)
        try require(model.volumeScope == "system" && model.outputVolume == 0.4 && writes == 0,"Initial hardware volume must be read without changing it")
        model.outputVolume = 0.7
        try require(hardware == 0.7 && writes == 1,"System slider must change hardware through its endpoint")
        hardware = 0.2; model.refreshOutputVolume()
        try require(model.outputVolume == 0.2 && writes == 1,"Hardware button changes must refresh without a feedback write")
        writable = false; model.refreshOutputVolume(); model.outputVolume = 0.9
        try require(!model.volumeAvailable && model.outputVolume == 0.2 && hardware == 0.2 && model.error != nil,"Unsupported system volume must fail visibly without claiming success")
    }
    @MainActor static func verifyHostVolume(_ host: HostModel, probe: Probe, id: UUID, volume: Double, accepted: Bool) async throws {
        let request = UUID().uuidString
        var command = Message("setHostVolume"); command.volume = volume; command.requestID = request; probe.peer.send(command)
        try await wait("Host volume result") { probe.messages.contains { $0.kind == "volumeResult" && $0.requestID == request } }
        try require(probe.messages.last(where: { $0.requestID == request })?.accepted == accepted,"Host must enforce volume permissions and bounds")
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
