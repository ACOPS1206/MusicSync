// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import SwiftUI
import Network
import AVFoundation
import MusicSyncCore

struct NearbyMac: Identifiable {
    var id: String { name }
    let name: String
    let endpoint: NWEndpoint
}
@MainActor final class ClientModel: ObservableObject {
    @Published var sessionID = UUID()
    @Published var sessionPhase = "Waiting" { didSet { if sessionPhase != oldValue { AppLog.shared.record("Listen",tr(sessionPhase)) } } }
    @Published var syncIssues: [SyncIssue] = [] { didSet {
        guard syncIssues != oldValue else { return }
        AppLog.shared.record("Listen",syncIssues.isEmpty ? tr("Sync warnings cleared") : String(format:tr("Sync warnings: %@"),syncIssues.map(\.rawValue).joined(separator:", ")),level:syncIssues.isEmpty ? .info : .warning)
    } }
    @Published var syncWarmupRemaining = SyncHealthPolicy.warmupDuration
    @Published var healthInput = SyncHealthInput()
    @Published var traffic = TrafficSnapshot()
    @Published var bufferCount = 0
    @Published var bufferAheadMS = 0.0
    @Published var schedulingErrorMS = 0.0
    @Published var lastUpdated = Date()
    private var health = SyncHealthMonitor()
        private var lastPong = 0.0
    private var peakScheduleError = 0.0
    private var monitorMode = false
    private var audioInterrupted = false
    @Published var nearby: [NearbyMac] = []
    @Published var status = tr("Ready to search") { didSet { if status != oldValue { AppLog.shared.record("Listen",status) } } }
    @Published var connected = false
    @Published var paired = false
    @Published var pairingCode = ""
    @Published var codeConfirmed = false
    @Published var encrypted = false
    private var tlsTrust: TLSClientTrust?
    private var tlsSession: TLSSessionInfo?
    private var sentPairingProof = false
    private var receivedChallenge = false
    private var initialFailures = 0
    private var establishedSession = false
    private var connectionFailure: String?
    private var sessionPins: [String:String] = [:]
    @Published var connectedHostName = ""
    @Published var hostAddress = ""
    @Published var hostServiceName = ""
    @Published var pairingNotice: String? { didSet { if let pairingNotice, pairingNotice != oldValue { AppLog.shared.record("Listen",pairingNotice,level:.warning) } } }
    @Published var identifyingUntil = Date.distantPast
    private let deviceID = PairingStore.identity("client")
    private var pairingHostID: String?
    private var pairingNonce: String?
    private var sessionSecrets: [String:String] = [:]
    private var reconnectTarget: NearbyMac?
    private let identifierSound = IdentificationSound()
    @Published var searching = false
    @Published var selectedName: String?
    @Published var error: String? { didSet { if let error, error != oldValue { AppLog.shared.record("Listen",error,level:.error) } } }
    @Published var rtt = 0.0
    @Published var offset = 0.0
    @Published var jitter = 0.0
    @Published var latency = 0.18
    @Published var uncertainty = 0.0
    @Published var dropped = 0
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
        if !applyingVolumeCommand { reportVolume() }
    } }
    @Published var hostVolumeScope = "app"
    @Published var hostVolume = 1.0
    @Published var pendingHostVolume: Double?
    @Published var canControlHostVolume = false
    @Published var hostCanControlClientVolume = false
    @Published var supportsVolumeControl = false
    @Published var volumePeers: [VolumePeer] = []
    @Published var peersCanControlClientVolume = false
    @Published var pendingPeerVolumes: [UUID:Double] = [:]
    @Published var pendingPeerChannels: [UUID:ChannelSelection] = [:]
    private var peerChannelRequests: [UUID:UUID] = [:]
    private var lastPeerIdentify: [UUID:Date] = [:]
    private var acceptsPeerDeviceControl = false
    private var peerVolumeTasks: [UUID:DispatchWorkItem] = [:]
    private var applyingVolumeCommand = false
    private var hostVolumeTask: DispatchWorkItem?
    private var hostVolumeRequestID: String?
    @Published var calibrationMS = 0.0
    @Published var channelOverride = ChannelSelection.automatic { didSet { reportChannel() } }
    @Published var hostChannel = OutputChannel.stereo { didSet { reportChannel() } }
    @Published var directAddress = ""
    @Published var discoveryDenied = false
    private var directMac: NearbyMac?
    private var browser: NWBrowser?
    private var peer: Peer?
    private let player = PCMPlayer()
    private lazy var audio = ClientAudioPipeline(player:player)
    private var clock = ClockEstimate()
    private var pingTimer: Timer?
    private var drainTimer: Timer?
    private var retry: DispatchWorkItem?
    private var wantConnection = false
    private var pendingPings: [Double] = []
    private var pings = 0
    private var lastReport = 0.0
    private var lastUI = 0.0
    private var requestedLatency = 0.18
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var lastEpoch: UInt64?
    private var lastAudio = 0.0
    private var receivedLatency = 0.18
    init(volumeEndpoint: VolumeEndpoint = VolumeEndpoint()) {
        self.volumeEndpoint = volumeEndpoint
        refreshOutputVolume()
        #if os(iOS)
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.restartAudio()  } }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in MainActor.assumeIsolated {
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            if type == AVAudioSession.InterruptionType.began.rawValue {
                self?.audioInterrupted = true
                self?.audio.interrupt(true); self?.status = tr("Audio interrupted"); self?.sessionPhase = "Interrupted"
            } else { self?.audioInterrupted = false; self?.restartAudio() }
         } }
        #else
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.restartAudio() } }
        #endif
    }
    func search() {
        guard browser == nil else { return }
        searching = true; error = nil; discoveryDenied = false
        let browser = NWBrowser(for: .bonjour(type: LAN.service, domain: nil), using: LAN.discoveryParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in MainActor.assumeIsolated {
            guard let self else { return }
            self.nearby = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint { return NearbyMac(name: name, endpoint: result.endpoint) }
                return nil
            }.sorted { $0.name < $1.name }
            if self.wantConnection, self.peer == nil, self.retry == nil, let found = self.nearby.first(where: { $0.name == self.selectedName }) { self.open(found) }
         } }
        browser.stateUpdateHandler = { [weak self, weak browser] state in MainActor.assumeIsolated {
            guard let self, self.browser === browser else { return }
            switch state {
            case .failed(let error):
                self.discoveryFailed(error)
                self.browser = nil; browser?.cancel()
            case .waiting(let error):
                self.discoveryFailed(error)
                self.browser = nil; browser?.cancel()
            default: break
            }
         } }
        self.browser = browser; browser.start(queue: .main); status = tr("Searching nearby Hosts…")
    }
    private func discoveryFailed(_ failure: NWError) {
        searching = false; status = tr("Discovery unavailable")
        if case .dns(let code) = failure, code == -65555 || code == -65570 {
            discoveryDenied = true
            error = tr("Bonjour access was denied. In LiveContainer, the host app must allow _musicsync._tcp; the guest Info.plist cannot grant this. Enable Local Network for LiveContainer, then use the Mac connection address below, or install MusicSync directly with signing.")
        } else { error = failure.localizedDescription }
    }
    func connectDirect() {
        let value = directAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: "musicsync://" + value),
              let hostname = components.host, !hostname.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              let port = components.port, (1...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            error = tr("Paste the Host connection address, for example MacBook.local:49152 or 192.168.1.20:49152."); return
        }
        disconnect(); sessionID = UUID()
        let mac = NearbyMac(name: value, endpoint: .hostPort(host: NWEndpoint.Host(hostname), port: nwPort))
        directMac = mac; selectedName = mac.name; initialFailures = 0; wantConnection = true
        error = nil; open(mac)
    }
    func connect(_ mac: NearbyMac) {
        disconnect(); sessionID = UUID(); initialFailures = 0; wantConnection = true; selectedName = mac.name
        open(mac)
    }
    private func open(_ mac: NearbyMac) {
        guard peer == nil else { return }
        reconnectTarget = mac; paired = false; pairingCode = ""; pairingHostID = nil; pairingNonce = nil; pairingNotice = nil
        retry?.cancel(); retry = nil
        clock = ClockEstimate(); audio.end(); lastEpoch = nil; pendingPings.removeAll(); pings = 0
        audioInterrupted = false
        sessionPhase = "Connecting"; health = SyncHealthMonitor(); syncIssues = []; traffic = TrafficSnapshot(); lastPong = 0; peakScheduleError = 0; monitorMode = false
        requestedLatency = 0.18; receivedLatency = 0.18; dropped = 0
        let knownID = PairingStore.read("endpoint." + mac.name)
        let expectedPin = knownID.flatMap { sessionPins[$0] ?? PairingStore.read("pin." + $0) }
        pairingHostID = knownID
        let trust = TLSClientTrust(expectedPin:expectedPin); tlsTrust = trust; tlsSession = nil; sentPairingProof = false; receivedChallenge = false; connectionFailure = nil
        let peer = Peer(NWConnection(to:mac.endpoint,using:LAN.clientParameters(trust:trust)),queue:.main)
        self.peer = peer; status = String(format: tr("Connecting to %@…"), mac.name)
        peer.onFailure = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            self.connectionFailure = reason; AppLog.shared.record("Listen",reason,level:.error)
        }
        peer.onState = { [weak self, weak peer] state in
            guard let self, let peer, self.peer === peer else { return }
            switch state {
            case .ready:
                guard let session = peer.tlsSession, trust.publicKeyPin != nil else {
                    self.securityFailure(tr("Encrypted connection verification failed. No audio was sent.")); return
                }
                AppLog.shared.record("Listen",tr("TLS 1.3 connection ready"))
                self.tlsSession = session; self.encrypted = true
                self.connected = true; self.status = tr("Authenticating with Host…"); self.sessionPhase = "Authenticating"
                var hello = Message("hello"); hello.pairingVersion = 2; hello.deviceID = self.deviceID
                hello.channelSelection = self.channelOverride.rawValue
                hello.volumeScope = self.volumeScope; hello.volumeControlVersion = 1; hello.volume = self.outputVolume
                #if os(iOS)
                hello.name = UIDevice.current.name
                #else
                hello.name = Host.current().localizedName ?? "MusicSync Mac"
                #endif
                peer.send(hello)
                DispatchQueue.main.asyncAfter(deadline:.now()+15) { [weak self, weak peer] in
                    guard let self, let peer, self.peer === peer, !self.paired, !self.receivedChallenge else { return }
                    self.disconnect(); self.error = tr("The Host did not respond to pairing. Update MusicSync on both devices and reconnect.")
                }
            case .failed(let error), .waiting(let error):
                if trust.pinRejected { self.securityFailure(tr("The Host security key changed. Verify the Host and forget its old pairing before reconnecting.")) }
                else { self.error = error.localizedDescription; self.lost() }
            case .cancelled: self.lost()
            default: break
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.handle(message)
        }
        let pipeline = audio; let connectionID = peer.id
        peer.onAudioMessage = { message in pipeline.receive(message,session:connectionID) }
        peer.start()
    }
    private func handle(_ message: Message) {
        let now = SyncClock.now
        if ["setChannel","setClientVolume","volumePolicy","identify","pairApproved","pairRejected"].contains(message.kind) { AppLog.shared.record("Listen",String(format:tr("Host control received: %@"),message.kind)) }
        if message.kind == "pairChallenge" {
            guard !paired, message.pairingVersion == 2, let hostID = message.hostID, UUID(uuidString:hostID) != nil,
                  let nonce = message.nonce, UUID(uuidString:nonce) != nil else { return }
            receivedChallenge = true; pairingHostID = hostID; pairingNonce = nonce; updateHostInfo(message)
            guard let currentPin = tlsTrust?.publicKeyPin, let session = tlsSession else { securityFailure(tr("Encrypted connection verification failed. No audio was sent.")); return }
            let savedPin = sessionPins[hostID] ?? PairingStore.read("pin." + hostID)
            if let savedPin, savedPin != currentPin { securityFailure(tr("The Host security key changed. Verify the Host and forget its old pairing before reconnecting.")); return }
            let secret = sessionSecrets[hostID] ?? PairingStore.read("client.tls2." + hostID)
            if savedPin == currentPin, let secret, let proof = PairingProof.make(secret:secret,nonce:nonce,hostID:hostID,clientID:deviceID,binding:session.binding) {
                sentPairingProof = true
                var auth = Message("pairProof"); auth.pairingProof = proof; peer?.send(auth)
            } else { peer?.send(Message("pairRequest")) }
            return
        } else if message.kind == "pairPending" {
            guard !paired, let hostID = pairingHostID, message.hostID == hostID,
                  let code = message.pairingCode, let local = tlsSession?.pairingCode else { return }
            guard code == local else { securityFailure(tr("The pairing codes do not match. Disconnect and verify both devices.")); return }
            pairingCode = local; codeConfirmed = false; sentPairingProof = false; status = tr("Waiting for Host approval…"); sessionPhase = "Awaiting approval"; updateHostInfo(message)
            return
        } else if message.kind == "pairApproved" {
            guard !paired, let hostID = pairingHostID, message.hostID == hostID else { return }
            if let secret = message.pairingSecret {
                guard codeConfirmed, let pin = tlsTrust?.publicKeyPin, let data = Data(base64Encoded:secret), data.count == 32 else { securityFailure(tr("Confirm the matching code on both devices before approval.")); return }
                sessionPins[hostID] = pin
                if let name = selectedName { try? PairingStore.write(hostID,account:"endpoint." + name) }
                do { try PairingStore.write(pin,account:"pin." + hostID) } catch { pairingNotice = error.localizedDescription }
                sessionSecrets[hostID] = secret
                do { try PairingStore.write(secret,account:"client.tls2." + hostID) } catch { pairingNotice = error.localizedDescription }
            } else {
                guard sentPairingProof, let pin = tlsTrust?.publicKeyPin,
                      (sessionPins[hostID] ?? PairingStore.read("pin." + hostID)) == pin else {
                    securityFailure(tr("Confirm the matching code on both devices before approval.")); return
                }
            }
            if let peer { audio.begin(session:peer.id) }
            paired = true; establishedSession = true; initialFailures = 0; pairingCode = ""; updateHostInfo(message)
            supportsVolumeControl = message.volumeControlVersion == 1
            applyVolumePolicy(message); reportVolume()
            if let raw = message.outputChannel, let channel = OutputChannel(rawValue:raw) { hostChannel = channel }
            do { try player.start() } catch { self.error = error.localizedDescription; disconnect(); return }
            health = SyncHealthMonitor(startedAt:now); syncWarmupRemaining = SyncHealthPolicy.warmupDuration
            status = tr("Synchronizing clocks…"); sessionPhase = "Synchronizing"; reportChannel(); startTimers()
            return
        } else if message.kind == "pairRejected" {
            disconnect(); error = tr("The Host declined or expired this pairing. Connect again to request approval."); return
        }
        guard paired else { return }
        if message.kind == "volumePeers", let roster = message.volumePeers, roster.count <= 32,
           Set(roster.map(\.id)).count == roster.count, roster.allSatisfy({ VolumeControl.valid($0.volume) != nil && $0.name.count <= 80 }) {
            volumePeers = roster
            for id in Array(pendingPeerChannels.keys) {
                if !roster.contains(where: { $0.id == id && $0.canControlDevice == true }) || roster.first(where: { $0.id == id })?.channelSelection == pendingPeerChannels[id]?.rawValue { pendingPeerChannels[id] = nil; peerChannelRequests[id] = nil }
            }
            for id in Array(pendingPeerVolumes.keys) where !roster.contains(where: { $0.id == id && $0.canControl }) {
                pendingPeerVolumes[id] = nil; peerVolumeTasks.removeValue(forKey:id)?.cancel()
            }
            return
        } else if message.kind == "peerControlDenied" {
            if let id = message.targetPeerID { pendingPeerChannels[id] = nil; peerChannelRequests[id] = nil }
            error = tr("Device control was denied or not confirmed. Check device permissions on the Host."); return
        } else if message.kind == "peerVolumeDenied" {
            if let id = message.targetPeerID { pendingPeerVolumes[id] = nil; peerVolumeTasks.removeValue(forKey:id)?.cancel() }
            error = tr("The volume change was denied or not confirmed. Check permissions on the Host."); return
        } else if message.kind == "volumePolicy" {
            applyVolumePolicy(message); return
        } else if message.kind == "hostVolume", let value = VolumeControl.valid(message.hostVolume) {
            hostVolumeScope = message.volumeScope == "system" ? "system" : "app"; hostVolume = value; return
        } else if message.kind == "volumeResult", message.volumeTarget == "host", message.requestID == hostVolumeRequestID {
            hostVolumeRequestID = nil; pendingHostVolume = nil
            if let value = VolumeControl.valid(message.hostVolume) { hostVolume = value }
            if message.accepted != true { error = tr("The Host denied the volume change. Ask the Host to grant permission.") }
            return
        } else if message.kind == "setClientVolume" {
            if supportsVolumeControl, (message.targetPeerID == nil ? hostCanControlClientVolume : peersCanControlClientVolume), let value = VolumeControl.valid(message.volume) {
                let previousError = error; error = nil
                applyingVolumeCommand = true; outputVolume = value; applyingVolumeCommand = false
                if error == nil { error = previousError; reportVolume(requestID:message.requestID) }
                else { var denied = Message("volumeResult"); denied.accepted = false; denied.volumeTarget = "client"; denied.requestID = message.requestID; peer?.send(denied) }
            } else {
                var denied = Message("volumeResult"); denied.accepted = false; denied.volumeTarget = "client"; denied.requestID = message.requestID; peer?.send(denied)
            }
            return
        } else if (message.kind == "setChannel" || message.kind == "identify"), message.targetPeerID != nil, !acceptsPeerDeviceControl {
            var denied = Message(message.kind == "identify" ? "identifyResult" : "peerControlResult"); denied.accepted = false; denied.requestID = message.requestID; denied.name = tr("Peer device control is disabled"); peer?.send(denied); return
        } else if message.kind == "setChannel", let raw = message.channelSelection, let selection = ChannelSelection(rawValue:raw) {
            if let channel = message.outputChannel.flatMap(OutputChannel.init(rawValue:)) { hostChannel = channel }
            channelOverride = selection; reportChannel(requestID:message.requestID); return
        } else if message.kind == "hostChannel", let raw = message.outputChannel, let channel = OutputChannel(rawValue:raw) {
            hostChannel = channel; reportChannel(); return
        } else if message.kind == "identify" {
            var result = Message("identifyResult")
            do { result.accepted = try identifierSound.play(); if result.accepted == true { identifyingUntil = Date().addingTimeInterval(1) } }
            catch { result.accepted = false; result.name = error.localizedDescription }
            peer?.send(result); return
        }
        if message.kind == "pong", let t1 = message.t1, let t2 = message.t2, let t3 = message.t3,
           let index = pendingPings.firstIndex(of: t1) {
            pendingPings.remove(at: index)
            clock.observe(t1:t1,t2:t2,t3:t3,t4:now); lastPong = now
            configureAudio()
            rtt = clock.rtt; offset = clock.offset; jitter = clock.jitter
            uncertainty = clock.uncertainty
            if clock.ready, now - lastReport > 1 {
                var stats = Message("stats"); stats.rtt = rtt; stats.offset = offset; stats.jitter = jitter
                stats.latency = max(requestedLatency, min(0.5, max(0.18, rtt / 2 + 4 * jitter + player.outputLatency + 0.07)))
                stats.syncWarning = syncIssues.map(\.rawValue).joined(separator: ",")
                stats.playbackState = sessionPhase
                stats.channelSelection = channelOverride.rawValue; stats.outputChannel = effectiveChannel.rawValue
                stats.dropped = dropped; stats.schedulingError = schedulingErrorMS / 1000; stats.bufferCount = bufferCount
                peer?.send(stats); lastReport = now
                if lastAudio == 0 { status = tr("Connected • waiting for Host audio"); sessionPhase = "Waiting" }
            }
        } else if message.kind == "stop" {
            lastAudio = 0
            status = tr("Connected • Host stopped streaming"); sessionPhase = "Waiting"; health = SyncHealthMonitor(); syncIssues = []
            monitorMode = false; peakScheduleError = 0; bufferCount = 0; bufferAheadMS = 0; schedulingErrorMS = 0
        }
    }
    private func startTimers() {
        pingTimer?.invalidate(); drainTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            self.pings += 1
            if self.pings > 16 && self.pings % 10 != 0 { return }
            let time = SyncClock.now
            self.pendingPings.append(time)
            self.pendingPings.removeAll { time - $0 > 3 }
            var ping = Message("ping"); ping.t1 = time; self.peer?.send(ping)
            if self.connected && self.pendingPings.count >= 3 && time - self.pendingPings[0] > 2 { self.lost() }
         } }
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.drain()  } }
        // Run during native control tracking as well as the default runloop mode.
        if let pingTimer { RunLoop.main.add(pingTimer, forMode: .common) }
        if let drainTimer { RunLoop.main.add(drainTimer, forMode: .common) }
    }
    private func drain() {
        guard paired, clock.ready else { return }
        let now = SyncClock.now
        configureAudio()
        let snapshot = audio.sample()
        if snapshot.drops > dropped { requestedLatency = min(0.5,max(requestedLatency,receivedLatency)+0.02) }
        if lastEpoch != snapshot.epoch, snapshot.epoch != nil {
            lastEpoch = snapshot.epoch; health = SyncHealthMonitor(startedAt:now)
            syncIssues = []; syncWarmupRemaining = SyncHealthPolicy.warmupDuration
        }
        if hostChannel != snapshot.channel { hostChannel = snapshot.channel }
        lastAudio = snapshot.lastAudio; monitorMode = snapshot.monitor; receivedLatency = snapshot.latency
        if snapshot.lastAudio > 0 { sessionPhase = "Streaming" }
        if let failure = snapshot.failure { error = failure }
        if now - lastUI > 0.45 {
            dropped = snapshot.drops
            latency = receivedLatency
            traffic = snapshot.traffic
            bufferCount = snapshot.count
            bufferAheadMS = max(0, (snapshot.queuedUntil ?? now) - now) * 1000
            peakScheduleError = snapshot.error
            schedulingErrorMS = peakScheduleError * 1000
            var input = SyncHealthInput(); input.uncertainty = uncertainty; input.schedulingError = peakScheduleError
            input.dropRate = traffic.dropsPerSecond; input.clockAge = lastPong > 0 ? now - lastPong : 0
            input.streaming = sessionPhase == "Streaming"; input.audioAge = lastAudio > 0 ? now - lastAudio : 0
            input.monitor = monitorMode; healthInput = input; health.update(input,now:now); syncIssues = health.issues; syncWarmupRemaining = health.warmupRemaining(now:now)
            peakScheduleError = 0; lastUpdated = Date()
            if lastAudio > 0 { status = now - lastAudio < 1 ? tr("Streaming • scheduled playback") : tr("Connected • no recent audio") }
            lastUI = now
        }
    }
    private func configureAudio() {
        audio.configure(ready:clock.ready,offset:clock.offset,selection:channelOverride,hostChannel:hostChannel,trim:calibrationMS/1000)
    }
    var effectiveChannel: OutputChannel { channelOverride.channel ?? hostChannel }
    private func updateHostInfo(_ message: Message) {
        if let name = message.name { connectedHostName = String(name.prefix(80)) }
        if let address = message.hostAddress { hostAddress = String(address.prefix(160)) }
        if let name = message.serviceName { hostServiceName = String(name.prefix(80)) }
    }
    func reportChannel(requestID: String? = nil) {
        guard paired else { return }
        player.channel = effectiveChannel
        var message = Message("channelReport"); message.channelSelection = channelOverride.rawValue
        message.playbackState = sessionPhase
        message.outputChannel = effectiveChannel.rawValue; message.requestID = requestID; peer?.send(message)
    }
    private func applyVolumePolicy(_ message: Message) {
        acceptsPeerDeviceControl = message.allowPeerDeviceControl ?? false
        hostVolumeScope = message.volumeScope == "system" ? "system" : "app"
        canControlHostVolume = supportsVolumeControl && (message.allowClientHostVolume ?? false)
        hostCanControlClientVolume = supportsVolumeControl && (message.allowHostClientVolume ?? false)
        peersCanControlClientVolume = supportsVolumeControl && (message.allowPeerClientVolume ?? false)
        if let value = VolumeControl.valid(message.hostVolume) { hostVolume = value }
        if !canControlHostVolume { hostVolumeTask?.cancel(); hostVolumeTask = nil; pendingHostVolume = nil; hostVolumeRequestID = nil }
    }
    private func reportVolume(requestID: String? = nil) {
        guard paired, supportsVolumeControl else { return }
        var report = Message("volumeReport"); report.volume = outputVolume; report.requestID = requestID; peer?.send(report)
    }
    func requestPeerChannel(_ id: UUID, selection: ChannelSelection) {
        guard paired, volumePeers.contains(where: { $0.id == id && $0.canControlDevice == true }) else { return }
        pendingPeerChannels[id] = selection
        let token = UUID(); peerChannelRequests[id] = token
        var request = Message("setPeerChannel"); request.targetPeerID = id; request.channelSelection = selection.rawValue; peer?.send(request)
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self, self.peerChannelRequests[id] == token else { return }
            self.pendingPeerChannels[id] = nil; self.peerChannelRequests[id] = nil; self.error = tr("The Client did not confirm the channel change. Check its connection.")
        }
    }
    func identifyPeer(_ id: UUID) {
        guard paired, volumePeers.contains(where: { $0.id == id && $0.canControlDevice == true }), Date().timeIntervalSince(lastPeerIdentify[id] ?? .distantPast) >= 2 else { return }
        lastPeerIdentify[id] = Date(); var request = Message("identifyPeer"); request.targetPeerID = id; peer?.send(request)
    }
    func requestPeerVolume(_ id: UUID, volume: Double) {
        guard paired, supportsVolumeControl, volumePeers.contains(where: { $0.id == id && $0.canControl }), let value = VolumeControl.valid(volume) else { return }
        pendingPeerVolumes[id] = value; peerVolumeTasks[id]?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.peerVolumeTasks[id] = nil
            guard self.paired, self.volumePeers.contains(where: { $0.id == id && $0.canControl }), let value = self.pendingPeerVolumes.removeValue(forKey:id) else { return }
            var request = Message("setPeerVolume"); request.targetPeerID = id; request.volume = value; self.peer?.send(request)
        }
        peerVolumeTasks[id] = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:task)
    }
    func requestHostVolume(_ volume: Double) {
        guard paired, canControlHostVolume, let value = VolumeControl.valid(volume) else { return }
        pendingHostVolume = value; hostVolumeRequestID = nil; hostVolumeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.sendHostVolume() }
        hostVolumeTask = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:task)
    }
    private func sendHostVolume() {
        hostVolumeTask = nil
        guard paired, canControlHostVolume, let volume = pendingHostVolume else { return }
        let request = UUID().uuidString; hostVolumeRequestID = request
        var message = Message("setHostVolume"); message.volume = volume; message.requestID = request; peer?.send(message)
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self, self.hostVolumeRequestID == request else { return }
            self.hostVolumeRequestID = nil; self.pendingHostVolume = nil; self.error = tr("The Host did not confirm the volume change.")
        }
    }
    func confirmPairingCode() {
        guard !paired, !pairingCode.isEmpty, pairingCode == tlsSession?.pairingCode else { return }
        AppLog.shared.record("Listen",tr("Pairing code match confirmed"))
        codeConfirmed = true
        var message = Message("pairConfirm"); message.pairingCode = pairingCode; peer?.send(message)
    }
    private func securityFailure(_ message: String) {
        // Preserve Host identity so the user can explicitly forget the rejected pin.
        wantConnection = false; retry?.cancel(); retry = nil
        let old = peer; peer = nil; old?.cancel(); cleanup()
        error = message; status = tr("Security verification failed"); sessionPhase = "Stopped"
    }
    func identifyHost() { if paired { peer?.send(Message("identifyHost")) } }
    func forgetHost() {
        if let hostID = pairingHostID {
            do { try PairingStore.remove("client.tls2." + hostID); try PairingStore.remove("pin." + hostID) } catch { pairingNotice = error.localizedDescription }
            sessionPins[hostID] = nil
            sessionSecrets[hostID] = nil
        }
        disconnect()
    }
    private func restartAudio() {
        guard connected, paired, !audioInterrupted else { return }
        audio.interrupt(false)
        do { try player.start() } catch { self.error = error.localizedDescription }
    }
    func stopDiscovery() {
        browser?.cancel(); browser = nil; searching = false; nearby.removeAll()
    }
    func disconnect() {
        wantConnection = false; establishedSession = false; retry?.cancel(); retry = nil
        let old = peer; peer = nil; old?.cancel()
        cleanup(); selectedName = nil; directMac = nil; reconnectTarget = nil; hostAddress = ""; hostServiceName = ""; connectedHostName = ""; pairingHostID = nil; status = tr("Disconnected"); sessionPhase = "Stopped"
    }
    private func cleanup() {
        pingTimer?.invalidate(); drainTimer?.invalidate(); pingTimer = nil; drainTimer = nil
        pendingPeerChannels.removeAll(); peerChannelRequests.removeAll(); lastPeerIdentify.removeAll(); acceptsPeerDeviceControl = false
        for task in peerVolumeTasks.values { task.cancel() }; peerVolumeTasks.removeAll(); pendingPeerVolumes.removeAll(); volumePeers = []; peersCanControlClientVolume = false
        hostVolumeTask?.cancel(); hostVolumeTask = nil; hostVolumeRequestID = nil; pendingHostVolume = nil; canControlHostVolume = false; hostCanControlClientVolume = false; supportsVolumeControl = false
        identifierSound.stop(); paired = false; pairingCode = ""; codeConfirmed = false; encrypted = false; tlsSession = nil
        audio.end(); connected = false; lastAudio = 0; lastReport = 0
        health = SyncHealthMonitor(); syncIssues = []; bufferCount = 0; bufferAheadMS = 0; schedulingErrorMS = 0; traffic = TrafficSnapshot()
    }
    private func lost() {
        let beforeApproval = !establishedSession
        let detail = connectionFailure ?? error ?? tr("The remote device closed the connection")
        let old = peer; peer = nil; old?.cancel(); cleanup()
        guard wantConnection else { return }
        if beforeApproval {
            initialFailures += 1
            if initialFailures >= 3 {
                wantConnection = false; retry?.cancel(); retry = nil
                error = String(format:tr("Pairing stopped after %d failed connections. %@. Update both devices and try connecting again."),initialFailures,detail)
                status = tr("Pairing connection failed"); sessionPhase = "Stopped"; return
            }
        }
        AppLog.shared.record("Listen",tr("Retrying connection in 2 seconds"),level:.warning)
        status = tr("Connection lost • reconnecting…"); sessionPhase = "Reconnecting"
        retry?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnection, let mac = self.reconnectTarget else { return }
            self.retry = nil
            self.open(mac)
        }
        retry = task; DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:task)
    }
}
