// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import SwiftUI
import Network
import MusicSyncCore
import AVFoundation
#if os(macOS)
import SystemConfiguration
#else
import UIKit
#endif

struct ConnectedDevice: Identifiable {
    let id: UUID
    var name = "iPhone"
    var ready = false
    var playbackState = "Synchronizing"
    var rtt = 0.0
    var offset = 0.0
    var jitter = 0.0
    var request = 0.18
    var syncIssues: [SyncIssue] = []
    var dropped = 0
    var lastStats = 0.0
    var gate = PairingGate()
    var rejected = false
    var deviceID: String?
    var nonce = UUID().uuidString
    var pairingCode: String?
    var clientConfirmed = false
    var supportsVolumeControl = false
    var volumeScope = "app"
    var volume = 1.0
    var permissions = VolumePermissions()
    var pendingVolume: Double?
    var volumeRequestID: String?
    var volumeRequester: UUID?
    var channelSelection = ChannelSelection.automatic
    var effectiveChannel = OutputChannel.stereo
    var pendingChannel: ChannelSelection?
    var channelRequestID: String?
    var channelRequester: UUID?
    var identifyRequester: UUID?
    var identifyingUntil = Date.distantPast
    var lastIdentify = Date.distantPast
}

@MainActor final class HostModel: ObservableObject {
    @Published var sessionID = UUID()
    @Published var sessionPhase = "Waiting" { didSet { if sessionPhase != oldValue { AppLog.shared.record("Host",tr(sessionPhase)) } } }
    @Published var syncIssues: [SyncIssue] = [] { didSet {
        guard syncIssues != oldValue else { return }
        AppLog.shared.record("Host",syncIssues.isEmpty ? tr("Sync warnings cleared") : String(format:tr("Sync warnings: %@"),syncIssues.map(\.rawValue).joined(separator:", ")),level:syncIssues.isEmpty ? .info : .warning)
    } }
    @Published var syncWarmupRemaining = SyncHealthPolicy.warmupDuration
    @Published var healthInput = SyncHealthInput()
    @Published var traffic = TrafficSnapshot()
    @Published var schedulingErrorMS = 0.0
    @Published var localDrops = 0
    @Published var lastUpdated = Date()
    private var health = SyncHealthMonitor()
        private var statusTimer: Timer?
    private var peakScheduleError = 0.0
    private var lastPCM = 0.0
    private var isMonitor = false
    @Published var active = false
    @Published var directOnly = false
    @Published private(set) var listeningPort: UInt16?
    @Published var connectionAddress = ""
    @Published var serviceName = ""
    @Published var pairingNotice: String? { didSet { if let pairingNotice, pairingNotice != oldValue { AppLog.shared.record("Host",pairingNotice,level:.warning) } } }
    private var tlsIdentity: TLSIdentity?
    @Published var encryptionPin = ""
    private let hostID = PairingStore.identity("host")
    private var sessionSecrets: [String:String] = [:]
    private var revokedIDs: Set<String> = []
    private let identifierSound = IdentificationSound()
    @Published var streaming = false
    @Published var busy = false
    @Published var status = tr("Ready") { didSet { if status != oldValue { AppLog.shared.record("Host",status) } } }
    @Published var error: String? { didSet { if let error, error != oldValue { AppLog.shared.record("Host",error,level:.error) } } }
    @Published var devices: [ConnectedDevice] = []
    @Published var latency = 0.18
    @Published var mode = 0 { didSet { if mode == 1 { layout = .stereo } } }
    @Published var fileURL: URL?
    @Published var fileName = ""
    @Published var layout = SpeakerLayout.stereo { didSet { player.channel = layout.localChannel; sendLayout() } }
    private let volumeEndpoint: VolumeEndpoint
    private var refreshingVolume = false
    @Published private(set) var volumeAvailable = true
    var volumeScope: String { volumeEndpoint.scope }
    func refreshOutputVolume() {
        guard volumeScope == "system" else { return }
        let reading = volumeEndpoint.read(); volumeAvailable = reading?.writable ?? false
        if let value = reading?.value, abs(value-outputVolume) > 0.001 { refreshingVolume = true; outputVolume = value; refreshingVolume = false }
    }
    @Published var outputVolume = 1.0 { didSet {
        let safe = min(1,max(0,outputVolume.isFinite ? outputVolume : 0))
        if outputVolume != safe { outputVolume = safe; return }
        if volumeScope == "system", !refreshingVolume {
            guard volumeEndpoint.set(outputVolume) else {
                refreshingVolume = true; outputVolume = volumeEndpoint.read()?.value ?? oldValue; refreshingVolume = false
                error = tr("System volume is unavailable for this output device."); return
            }
            if let actual = volumeEndpoint.read()?.value, abs(actual-outputVolume) > 0.001 {
                refreshingVolume = true; outputVolume = actual; refreshingVolume = false; return
            }
        }
        player.volume = volumeScope == "system" ? 1 : Float(outputVolume)
        identifierSound.volume = volumeScope == "system" ? 1 : Float(outputVolume)
        broadcastHostVolume()
    } }
    private var volumeTasks: [UUID:DispatchWorkItem] = [:]
    @Published var calibrationMS = 0.0 { didSet { configureAudio() } }
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var capture: AudioCapture?
    private let player = PCMPlayer()
    private lazy var audio = HostAudioPipeline(player:player)
    private var delay = DelayController()
    private var epoch: UInt64 = 0
    private var observer: NSObjectProtocol?
    init(volumeEndpoint: VolumeEndpoint = VolumeEndpoint()) {
        self.volumeEndpoint = volumeEndpoint
        refreshOutputVolume()
        #if os(macOS)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            // Restore tapped process output before the application exits.
            if let capture = self.capture {
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached { await capture.stop(); semaphore.signal() }
                _ = semaphore.wait(timeout: .now() + 1)
            }
         } }
        #else
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
            _ = Task { await self?.stopStreaming() }
        } }
        #endif
    }
    func startHost(localEndpoint: NWEndpoint? = nil) {
        guard !active else { return }
        error = nil; sessionID = UUID(); sessionPhase = "Connecting"
        do {
            if tlsIdentity == nil {
                let stored = PairingStore.read("tls.host.key")
                if let stored, Data(base64Encoded:stored) == nil { throw TLSError.identity }
                let identity = try TLSIdentity.create(privateRepresentation:stored.flatMap { Data(base64Encoded:$0) })
                tlsIdentity = identity; encryptionPin = identity.publicKeyPin
                if stored == nil {
                    do { try PairingStore.write(identity.privateRepresentation.base64EncodedString(),account:"tls.host.key") }
                    catch { pairingNotice = error.localizedDescription }
                }
            }
            guard let identity = tlsIdentity else { throw TLSError.identity }
            let parameters = try LAN.hostParameters(identity:identity)
            parameters.requiredLocalEndpoint = localEndpoint
            let listener = try NWListener(using:parameters)
            #if os(macOS)
            let name = Host.current().localizedName ?? "MusicSync Mac"
            #else
            let name = UIDevice.current.name + " · MusicSync"
            #endif
            serviceName = name
            if !directOnly { listener.service = NWListener.Service(name: name, type: LAN.service) }
            listener.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated { self?.accept(connection)  } }
            listener.stateUpdateHandler = { [weak self, weak listener] state in MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.listeningPort = listener?.port?.rawValue
                    self.active = true; self.status = tr("Host available on LAN"); self.sessionPhase = "Waiting"; self.startStatusTimer()
                    #if os(macOS)
                    if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, let port = listener?.port {
                        self.connectionAddress = "\(name).local:\(port.rawValue)"
                    }
                    #else
                    if let port = listener?.port, let address = LocalAddress.wifi {
                        self.connectionAddress = "\(address):\(port.rawValue)"
                    }
                    #endif
                case .failed(let error): self.error = error.localizedDescription; self.stopHost()
                default: break
                }
             } }
            self.listener = listener; listener.start(queue: .main)
            status = tr("Starting Bonjour…")
        } catch { self.error = error.localizedDescription }
    }
    func stopHost() {
        Task { await stopStreaming() }
        listener?.cancel(); listener = nil; connectionAddress = ""; listeningPort = nil
        identifierSound.stop()
        for peer in peers.values { peer.cancel() }
        for task in volumeTasks.values { task.cancel() }; volumeTasks.removeAll()
        peers.removeAll(); devices.removeAll(); active = false; status = tr("Stopped"); sessionPhase = "Stopped"
        statusTimer?.invalidate(); statusTimer = nil; syncIssues = []
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 16 else { connection.cancel(); return }
        AppLog.shared.record("Host",tr("Incoming device connection"))
        let peer = Peer(connection, queue: .main)
        peers[peer.id] = peer; devices.append(ConnectedDevice(id: peer.id))
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.handle(message, from: peer)
        }
        peer.onFailure = { [weak self, weak peer] reason in
            guard let self, let peer else { return }
            AppLog.shared.record("Host",reason,level:.error)
            guard self.devices.first(where: { $0.id == peer.id })?.gate.approved == false else { return }
            self.error = String(format:tr("Connection ended before pairing: %@"),reason)
        }
        peer.onState = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready:
                guard peer.tlsSession != nil else { peer.cancel(); return }
                AppLog.shared.record("Host",tr("TLS 1.3 connection ready"))
            case .cancelled, .failed:
                AppLog.shared.record("Host",tr("Device connection ended"))
                self.volumeTasks.removeValue(forKey:peer.id)?.cancel()
                self.peers.removeValue(forKey: peer.id); self.devices.removeAll { $0.id == peer.id }; self.broadcastVolumePeers()
            default: break
            }
        }
        peer.start()
        DispatchQueue.main.asyncAfter(deadline:.now()+60) { [weak self, weak peer] in
            guard let self, let peer, let device = self.devices.first(where: { $0.id == peer.id }), !device.gate.approved else { return }
            self.rejectDevice(peer.id)
        }
    }
    private func hostInfo(_ kind: String) -> Message {
        var message = Message(kind); message.pairingVersion = 2; message.hostID = hostID
        message.name = serviceName; message.serviceName = directOnly ? nil : serviceName; message.hostAddress = connectionAddress
        return message
    }
    private func handle(_ message: Message, from peer: Peer) {
        guard let index = devices.firstIndex(where: { $0.id == peer.id }), !devices[index].rejected, devices[index].gate.permits(message.kind) else { return }
        if ["setHostVolume","setPeerVolume","setPeerChannel","identifyPeer","pairRequest","pairConfirm"].contains(message.kind) { AppLog.shared.record("Host",String(format:tr("Device control received: %@"),message.kind)) }
        if message.kind == "hello" {
            guard !devices[index].gate.approved, devices[index].deviceID == nil else { return }
            guard message.pairingVersion == 2, let id = message.deviceID, UUID(uuidString:id) != nil else { rejectDevice(peer.id); return }
            devices[index].supportsVolumeControl = message.volumeControlVersion == 1
            devices[index].volume = VolumeControl.valid(message.volume) ?? 1
            devices[index].volumeScope = message.volumeScope == "system" ? "system" : "app"
            if let data = PairingStore.read(volumePolicyKey(id)).flatMap({ $0.data(using:.utf8) }), let policy = try? JSONDecoder().decode(VolumePermissions.self,from:data) { devices[index].permissions = policy }
            devices[index].deviceID = id; devices[index].name = String((message.name ?? "MusicSync Client").prefix(80))
            devices[index].channelSelection = ChannelSelection(rawValue:message.channelSelection ?? "automatic") ?? .automatic
            var challenge = hostInfo("pairChallenge"); challenge.nonce = devices[index].nonce; peer.send(challenge)
        } else if message.kind == "pairRequest" {
            requestApproval(peer.id)
        } else if message.kind == "pairProof" {
            guard !devices[index].gate.approved, let id = devices[index].deviceID else { return }
            let secret = sessionSecrets[id] ?? PairingStore.read("host.tls2." + id)
            if !revokedIDs.contains(id), let secret, let proof = message.pairingProof,
               PairingProof.verify(proof,secret:secret,nonce:devices[index].nonce,hostID:hostID,clientID:id,binding:peer.tlsSession?.binding ?? "") {
                authorize(peer.id,secret:nil)
            } else { requestApproval(peer.id) }
        } else if message.kind == "pairConfirm" {
            guard !devices[index].gate.approved, let code = devices[index].pairingCode,
                  message.pairingCode == code else { rejectDevice(peer.id); return }
            devices[index].clientConfirmed = true
        } else if message.kind == "setHostVolume" {
            var result = Message("volumeResult"); result.requestID = message.requestID; result.volumeTarget = "host"
            if devices[index].supportsVolumeControl, devices[index].permissions.clientMayControlHost, let volume = VolumeControl.valid(message.volume) {
                let previousError = error; error = nil; outputVolume = volume; result.accepted = error == nil
                if error == nil { error = previousError }
            } else { result.accepted = false }
            result.volumeScope = volumeScope; result.hostVolume = outputVolume; peer.send(result)
        } else if message.kind == "setPeerVolume" {
            if let target = message.targetPeerID, let volume = VolumeControl.valid(message.volume), permitsPeerVolume(peer.id,target:target) {
                setClientVolume(target,volume:volume,requester:peer.id)
            } else { var denied = Message("peerVolumeDenied"); denied.targetPeerID = message.targetPeerID; peer.send(denied) }
        } else if message.kind == "setPeerChannel" || message.kind == "identifyPeer" {
            guard let target = message.targetPeerID, permitsPeerDeviceControl(peer.id,target:target) else { denyPeerControl(peer.id,target:message.targetPeerID); return }
            if message.kind == "setPeerChannel", let raw = message.channelSelection, let selection = ChannelSelection(rawValue:raw) { setChannel(target,selection:selection,requester:peer.id) }
            else if message.kind == "identifyPeer", let targetDevice = devices.first(where: { $0.id == target }), Date().timeIntervalSince(targetDevice.lastIdentify) >= 2 { identifyDevice(target,requester:peer.id) }
            else { denyPeerControl(peer.id,target:target) }
        } else if message.kind == "volumeReport", devices[index].supportsVolumeControl, let volume = VolumeControl.valid(message.volume) {
            devices[index].volume = volume
            if let request = message.requestID, request == devices[index].volumeRequestID { devices[index].pendingVolume = nil; devices[index].volumeRequestID = nil; devices[index].volumeRequester = nil }
            broadcastVolumePeers()
        } else if message.kind == "volumeResult", message.volumeTarget == "client", message.accepted == false {
            if let request = message.requestID, request == devices[index].volumeRequestID { notifyVolumeDenied(index); devices[index].pendingVolume = nil; devices[index].volumeRequestID = nil; devices[index].volumeRequester = nil; error = tr("The Client declined the volume change.") }
        } else if message.kind == "ping", let t1 = message.t1 {
            var response = Message("pong"); response.t1 = t1
            response.t2 = SyncClock.now; response.t3 = SyncClock.now; peer.send(response)
        } else if message.kind == "channelReport" {
            updatePlaybackState(message, index:index)
            if let raw = message.channelSelection, let selection = ChannelSelection(rawValue:raw) { devices[index].channelSelection = selection }
            if let raw = message.outputChannel, let channel = OutputChannel(rawValue:raw) { devices[index].effectiveChannel = channel }
            if let request = message.requestID, request == devices[index].channelRequestID { devices[index].pendingChannel = nil; devices[index].channelRequestID = nil; devices[index].channelRequester = nil }
            broadcastVolumePeers()
        } else if message.kind == "peerControlResult", message.accepted == false {
            if let source = devices[index].channelRequester { denyPeerControl(source,target:peer.id) }; devices[index].channelRequester = nil; devices[index].pendingChannel = nil; devices[index].channelRequestID = nil
        } else if message.kind == "identifyResult" {
            if message.accepted == true { devices[index].identifyingUntil = Date().addingTimeInterval(1) }
            else if let text = message.name {
                if let source = devices[index].identifyRequester { denyPeerControl(source,target:peer.id) }; error = String(format:tr("Identification tone unavailable: %@"),String(text.prefix(200))) }
        } else if message.kind == "identifyHost" {
            identifyHost()
        } else if message.kind == "stats",
                  let rtt = message.rtt, let offset = message.offset, let jitter = message.jitter,
                  let requested = message.latency, [rtt,offset,jitter,requested].allSatisfy({ $0.isFinite }),
                  rtt >= 0, rtt < 1, jitter >= 0, requested >= 0.18, requested <= 0.5 {
            let previousChannel = devices[index].effectiveChannel; let previousSelection = devices[index].channelSelection; let previousState = devices[index].playbackState
            updatePlaybackState(message,index:index)
            devices[index].ready = true; devices[index].rtt = rtt; devices[index].offset = offset
            devices[index].jitter = jitter; devices[index].request = requested; devices[index].lastStats = SyncClock.now
            if let raw = message.syncWarning { devices[index].syncIssues = raw.split(separator:",").compactMap { SyncIssue(rawValue:String($0)) } }
            if let count = message.dropped, (0...1_000_000).contains(count) { devices[index].dropped = count }
            if let raw = message.channelSelection, let selection = ChannelSelection(rawValue:raw) { devices[index].channelSelection = selection }
            if let raw = message.outputChannel, let channel = OutputChannel(rawValue:raw) { devices[index].effectiveChannel = channel }
            if previousChannel != devices[index].effectiveChannel || previousSelection != devices[index].channelSelection || previousState != devices[index].playbackState { broadcastVolumePeers() }
            let previous = delay.target
            delay.update(rtt:rtt,jitter:jitter,requested:requested); latency = delay.target; configureAudio()
            if delay.target - previous > 0.001 { AppLog.shared.record("Host",String(format:tr("Shared buffer increased to %.0f ms"),latency * 1000)) }
            var timeline = Message("timeline"); timeline.latency = latency; peer.send(timeline)
        }
    }
    private func updatePlaybackState(_ message: Message, index: Int) {
        if let state = message.playbackState, ["Waiting","Streaming","Interrupted","Synchronizing"].contains(state) { devices[index].playbackState = state }
    }
    private func requestApproval(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].deviceID != nil, !devices[index].gate.approved else { return }
        guard let session = peers[id].flatMap({ $0.tlsSession }) else { rejectDevice(id); return }
        if devices[index].pairingCode == nil { devices[index].pairingCode = session.pairingCode; devices[index].clientConfirmed = false }
        var pending = hostInfo("pairPending"); pending.pairingCode = devices[index].pairingCode
        peers[id]?.send(pending)
    }
    func approveDevice(_ id: UUID) {
        guard let device = devices.first(where: { $0.id == id }), let clientID = device.deviceID, device.pairingCode != nil, device.clientConfirmed, !device.gate.approved, !device.rejected else { return }
        let secret = PairingProof.newSecret(); sessionSecrets[clientID] = secret; revokedIDs.remove(clientID)
        do { try PairingStore.write(secret,account:"host.tls2." + clientID) }
        catch { pairingNotice = error.localizedDescription }
        // A replaced pairing invalidates any other live socket claiming this device identity.
        for other in devices where other.id != id && other.deviceID == clientID { rejectDevice(other.id) }
        authorize(id,secret:secret)
    }
    private func authorize(_ id: UUID, secret: String?) {
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].rejected else { return }
        AppLog.shared.record("Host",tr(secret == nil ? "Remembered pairing authenticated" : "New device pairing approved"))
        devices[index].gate.approve(); devices[index].pairingCode = nil
        if secret != nil {
            devices[index].permissions = VolumePermissions()
            if let clientID = devices[index].deviceID { try? PairingStore.remove(volumePolicyKey(clientID)) }
        }
        var approved = hostInfo("pairApproved"); approved.pairingSecret = secret
        approved.outputChannel = layout.remoteChannel.rawValue
        approved.volumeScope = volumeScope; approved.volumeControlVersion = 1; approved.hostVolume = outputVolume
        approved.allowClientHostVolume = devices[index].permissions.clientMayControlHost
        approved.allowHostClientVolume = devices[index].permissions.hostMayControlClient
        approved.allowPeerDeviceControl = devices[index].permissions.peersMayControlClientDevice
        approved.allowPeerClientVolume = devices[index].permissions.peersMayControlClient
        peers[id]?.send(approved); broadcastVolumePeers()
    }
    func rejectDevice(_ id: UUID) {
        guard let peer = peers[id], let index = devices.firstIndex(where: { $0.id == id }) else { return }
        AppLog.shared.record("Host",tr("Pairing rejected or removed"),level:.warning)
        devices[index].rejected = true; devices[index].ready = false; devices[index].gate = PairingGate()
        peer.send(Message("pairRejected")); broadcastVolumePeers()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak peer] in peer?.cancel() }
    }
    func forgetDevice(_ id: UUID) {
        guard let device = devices.first(where: { $0.id == id }), let clientID = device.deviceID else { return }
        do { try PairingStore.remove("host.tls2." + clientID) }
        catch { pairingNotice = error.localizedDescription }
        revokedIDs.insert(clientID); sessionSecrets[clientID] = nil
        try? PairingStore.remove(volumePolicyKey(clientID))
        for other in devices where other.deviceID == clientID { rejectDevice(other.id) }
    }
    private func volumePolicyKey(_ clientID: String) -> String { "volumePolicy." + hostID + "." + clientID }
    func setVolumePermissions(_ id: UUID, clientMayControlHost: Bool? = nil, hostMayControlClient: Bool? = nil, clientMayControlPeers: Bool? = nil, peersMayControlClient: Bool? = nil, clientMayControlPeerDevices: Bool? = nil, peersMayControlClientDevice: Bool? = nil) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].gate.approved, let clientID = devices[index].deviceID else { return }
        AppLog.shared.record("Host",tr("Device volume permissions changed"))
        if let value = clientMayControlHost { devices[index].permissions.clientMayControlHost = value }
        if let value = hostMayControlClient { devices[index].permissions.hostMayControlClient = value }
        if let value = clientMayControlPeers { devices[index].permissions.clientMayControlPeers = value }
        if let value = peersMayControlClient { devices[index].permissions.peersMayControlClient = value }
        if let value = clientMayControlPeerDevices { devices[index].permissions.clientMayControlPeerDevices = value }
        if let value = peersMayControlClientDevice { devices[index].permissions.peersMayControlClientDevice = value }
        if let data = try? JSONEncoder().encode(devices[index].permissions) { try? PairingStore.write(String(decoding:data,as:UTF8.self),account:volumePolicyKey(clientID)) }
        if devices[index].volumeRequester == nil && !devices[index].permissions.hostMayControlClient {
            volumeTasks.removeValue(forKey:id)?.cancel(); devices[index].pendingVolume = nil; devices[index].volumeRequestID = nil
        }
        var policy = Message("volumePolicy")
        policy.allowClientHostVolume = devices[index].permissions.clientMayControlHost
        policy.allowHostClientVolume = devices[index].permissions.hostMayControlClient
        policy.allowPeerDeviceControl = devices[index].permissions.peersMayControlClientDevice
        policy.allowPeerClientVolume = devices[index].permissions.peersMayControlClient
        policy.volumeScope = volumeScope; policy.hostVolume = outputVolume; peers[id]?.send(policy)
        // Recheck queued relays immediately when either endpoint loses permission.
        for target in devices where target.volumeRequester != nil {
            if !permitsPeerVolume(target.volumeRequester!,target:target.id), let i = devices.firstIndex(where: { $0.id == target.id }) {
                notifyVolumeDenied(i); volumeTasks.removeValue(forKey:target.id)?.cancel()
                devices[i].pendingVolume = nil; devices[i].volumeRequestID = nil; devices[i].volumeRequester = nil
            }
        }
        broadcastVolumePeers()
    }
    private func broadcastHostVolume() {
        var update = Message("hostVolume"); update.volumeScope = volumeScope; update.hostVolume = outputVolume
        for device in devices where device.gate.approved && device.supportsVolumeControl { peers[device.id]?.send(update) }
    }
    private func permitsPeerVolume(_ source: UUID, target: UUID) -> Bool {
        guard source != target,
              let sender = devices.first(where: { $0.id == source }), let receiver = devices.first(where: { $0.id == target }) else { return false }
        return sender.gate.approved && receiver.gate.approved && sender.supportsVolumeControl && receiver.supportsVolumeControl && sender.permissions.clientMayControlPeers && receiver.permissions.peersMayControlClient
    }
    private func permitsPeerDeviceControl(_ source: UUID, target: UUID) -> Bool {
        guard source != target, let sender = devices.first(where: { $0.id == source }), let receiver = devices.first(where: { $0.id == target }) else { return false }
        return sender.gate.approved && receiver.gate.approved && !sender.rejected && !receiver.rejected && sender.permissions.clientMayControlPeerDevices && receiver.permissions.peersMayControlClientDevice
    }
    private func denyPeerControl(_ source: UUID, target: UUID?) {
        var denied = Message("peerControlDenied"); denied.targetPeerID = target; peers[source]?.send(denied)
    }
    private func broadcastVolumePeers() {
        configureAudio()
        let approved = devices.filter { $0.gate.approved && !$0.rejected && $0.supportsVolumeControl }
        for recipient in approved {
            var roster = Message("volumePeers")
            roster.volumePeers = approved.filter { $0.id != recipient.id }.prefix(32).map {
                VolumePeer(id:$0.id,name:$0.name,volume:$0.volume,canControl:permitsPeerVolume(recipient.id,target:$0.id),volumeScope:$0.volumeScope,outputChannel:$0.effectiveChannel.rawValue,channelSelection:$0.channelSelection.rawValue,playbackState:$0.playbackState,canControlDevice:permitsPeerDeviceControl(recipient.id,target:$0.id))
            }
            peers[recipient.id]?.send(roster)
        }
    }
    private func notifyVolumeDenied(_ index: Int) {
        guard let requester = devices[index].volumeRequester else { return }
        var denied = Message("peerVolumeDenied"); denied.targetPeerID = devices[index].id; peers[requester]?.send(denied)
    }
    func setClientVolume(_ id: UUID, volume: Double, requester: UUID? = nil) {
        guard let value = VolumeControl.valid(volume), let index = devices.firstIndex(where: { $0.id == id }),
              devices[index].gate.approved, devices[index].supportsVolumeControl,
              requester.map({ permitsPeerVolume($0,target:id) }) ?? devices[index].permissions.hostMayControlClient else { return }
        if devices[index].volumeRequester != requester { notifyVolumeDenied(index) }
        devices[index].volumeRequester = requester; devices[index].pendingVolume = value; devices[index].volumeRequestID = nil; volumeTasks[id]?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.sendClientVolume(id) }
        volumeTasks[id] = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:task)
    }
    private func sendClientVolume(_ id: UUID) {
        volumeTasks[id] = nil
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].gate.approved,
              devices[index].volumeRequester.map({ permitsPeerVolume($0,target:id) }) ?? devices[index].permissions.hostMayControlClient,
              let volume = devices[index].pendingVolume else { return }
        let request = UUID().uuidString; devices[index].volumeRequestID = request
        AppLog.shared.record("Host",String(format:tr("Client volume requested: %.0f%%"),volume * 100))
        var message = Message("setClientVolume"); message.targetPeerID = devices[index].volumeRequester; message.volume = volume; message.requestID = request; peers[id]?.send(message)
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self, let index = self.devices.firstIndex(where: { $0.id == id }), self.devices[index].volumeRequestID == request else { return }
            self.notifyVolumeDenied(index); self.devices[index].pendingVolume = nil; self.devices[index].volumeRequestID = nil; self.devices[index].volumeRequester = nil
            self.error = tr("The Client did not confirm the volume change.")
        }
    }
    func setChannel(_ id: UUID, selection: ChannelSelection, requester: UUID? = nil) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].gate.approved else { return }
        if let requester, !permitsPeerDeviceControl(requester,target:id) { return }
        devices[index].channelRequester = requester
        AppLog.shared.record("Host",String(format:tr("Client channel requested: %@"),selection.title))
        let request = UUID().uuidString; devices[index].pendingChannel = selection; devices[index].channelRequestID = request
        var message = Message("setChannel"); message.targetPeerID = requester; message.channelSelection = selection.rawValue
        message.outputChannel = layout.remoteChannel.rawValue; message.requestID = request; peers[id]?.send(message)
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self, let index = self.devices.firstIndex(where: { $0.id == id }), self.devices[index].channelRequestID == request else { return }
            self.devices[index].pendingChannel = nil; self.devices[index].channelRequestID = nil
            if let source = self.devices[index].channelRequester { self.denyPeerControl(source,target:id) }; self.devices[index].channelRequester = nil
            self.error = tr("The Client did not confirm the channel change. Check its connection.")
        }
    }
    private func sendLayout() {
        configureAudio()
        var message = Message("hostChannel"); message.outputChannel = layout.remoteChannel.rawValue
        for device in devices where device.gate.approved { peers[device.id]?.send(message) }
    }
    func identifyDevice(_ id: UUID, requester: UUID? = nil) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].gate.approved,
              Date().timeIntervalSince(devices[index].lastIdentify) >= 2 else { return }
        if let requester, !permitsPeerDeviceControl(requester,target:id) { return }
        devices[index].identifyRequester = requester
        AppLog.shared.record("Host",tr("Client identification requested"))
        devices[index].lastIdentify = Date(); var command = Message("identify"); command.targetPeerID = requester; peers[id]?.send(command)
    }
    func identifyHost() {
        do { _ = try identifierSound.play() } catch { self.error = error.localizedDescription }
    }
    func startStreaming(testTone: Bool = false) async {
        guard active, !streaming, !busy else { return }
        busy = true; defer { busy = false }
        error = nil; delay = DelayController(); latency = delay.target
        epoch += 1
        isMonitor = mode == 1 && !testTone && fileURL == nil
        lastPCM = SyncClock.now; localDrops = 0; peakScheduleError = 0; health = SyncHealthMonitor(startedAt:SyncClock.now); syncWarmupRemaining = SyncHealthPolicy.warmupDuration
        sessionPhase = "Synchronizing"
        do {
            #if os(macOS)
            if mode == 0 || testTone || fileURL != nil { try player.start() }
            #else
            try player.start()
            #endif
            configureAudio()
            audio.start(epoch:epoch,monitor:isMonitor,testTone:testTone)
            if testTone {
                streaming = true; status = tr("Synchronized test tone"); sessionPhase = "Streaming"
            } else {
                let sourceEpoch = epoch
                let source: AudioCapture
                if let url = fileURL {
                    let file = FileAudioSource(url: url)
                    file.onEnd = { [weak self] failure in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard let self, self.epoch == sourceEpoch, self.streaming else { return }
                        if let failure { self.error = failure }
                        Task { await self.stopStreaming() }
                    } }
                    source = file
                } else {
                #if os(macOS)
                if mode == 0 { source = TapCapture() } else {
                    let screen = ScreenCapture()
                    screen.onError = { [weak self] text in DispatchQueue.main.async {
                        guard let self, self.epoch == sourceEpoch else { return }
                        self.error = text; Task { await self.stopStreaming() }
                    } }
                    source = screen
                }
                #else
                throw AudioSourceFailure.noFile
                #endif
                }
                capture = source
                let pipeline = audio
                source.onPCM = { data, frames, time in pipeline.submit(data,frames:frames,captureTime:time,epoch:sourceEpoch) }
                streaming = true
                try await source.start()
                guard active, capture === source else { await source.stop(); streaming = false; return }
                sessionPhase = "Streaming"
                status = fileURL != nil ? tr("Streaming music file") : mode == 0 ? tr("Synchronized system audio") : tr("ScreenCaptureKit monitor • original Mac output is ahead")
            }
        } catch {
            self.error = error.localizedDescription
            streaming = false; sessionPhase = active ? "Waiting" : "Stopped"
            await capture?.stop(); capture = nil; audio.stop()
        }
    }
    func stopStreaming() async {
        streaming = false; audio.stop()
        await capture?.stop(); capture = nil
        var message = Message("stop"); message.epoch = epoch
        for device in devices where device.gate.approved { peers[device.id]?.send(message) }
        status = active ? tr("Host available on LAN") : tr("Stopped")
        sessionPhase = active ? "Waiting" : "Stopped"; health = SyncHealthMonitor(); syncIssues = []; isMonitor = false
    }
    private func configureAudio() {
        let ready = devices.filter { $0.ready && $0.gate.approved && !$0.rejected }
        audio.configure(peers:ready.compactMap { peers[$0.id] },delay:delay.target,trim:calibrationMS/1000,layout:layout)
    }
    var timingDevice: ConnectedDevice? { devices.filter(\.ready).max { $0.rtt / 2 + $0.jitter < $1.rtt / 2 + $1.jitter } }
    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshStatus() } }
        if let statusTimer { RunLoop.main.add(statusTimer, forMode: .common) }
    }
    private func refreshStatus() {
        let now = SyncClock.now
        let snapshot = audio.sample()
        traffic = snapshot.traffic; localDrops = snapshot.drops; peakScheduleError = snapshot.error; lastPCM = snapshot.lastAudio
        schedulingErrorMS = peakScheduleError * 1000
        var input = SyncHealthInput()
        input.uncertainty = devices.filter(\.ready).map { $0.rtt / 2 + $0.jitter }.max() ?? 0
        input.clockAge = devices.filter(\.ready).map { now - $0.lastStats }.max() ?? 0
        input.streaming = streaming && sessionPhase == "Streaming"; input.audioAge = lastPCM > 0 ? now - lastPCM : 0
        input.dropRate = traffic.dropsPerSecond; input.schedulingError = peakScheduleError; input.monitor = isMonitor
        healthInput = input
        health.update(input,now:now)
        syncWarmupRemaining = health.warmupRemaining(now:now)
        syncIssues = syncWarmupRemaining > 0 ? [] : SyncIssue.allCases.filter { issue in health.issues.contains(issue) || devices.contains { $0.syncIssues.contains(issue) } }
        peakScheduleError = 0; lastUpdated = Date()
    }

}
