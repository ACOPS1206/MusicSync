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
    var channelSelection = ChannelSelection.automatic
    var effectiveChannel = OutputChannel.stereo
    var pendingChannel: ChannelSelection?
    var channelRequestID: String?
    var identifyingUntil = Date.distantPast
    var lastIdentify = Date.distantPast
}

@MainActor final class HostModel: ObservableObject {
    @Published var sessionID = UUID()
    @Published var sessionPhase = "Waiting"
    @Published var syncIssues: [SyncIssue] = []
    @Published var healthInput = SyncHealthInput()
    @Published var traffic = TrafficSnapshot()
    @Published var schedulingErrorMS = 0.0
    @Published var localDrops = 0
    @Published var lastUpdated = Date()
    private var health = SyncHealthMonitor()
    private var meter = TrafficMeter()
    private var statusTimer: Timer?
    private var peakScheduleError = 0.0
    private var lastPCM = 0.0
    private var isMonitor = false
    @Published var active = false
    @Published var directOnly = false
    @Published private(set) var listeningPort: UInt16?
    @Published var connectionAddress = ""
    @Published var serviceName = ""
    @Published var pairingNotice: String?
    private let hostID = PairingStore.identity("host")
    private var sessionSecrets: [String:String] = [:]
    private var revokedIDs: Set<String> = []
    private let identifierSound = IdentificationSound()
    @Published var streaming = false
    @Published var busy = false
    @Published var status = tr("Ready")
    @Published var error: String?
    @Published var devices: [ConnectedDevice] = []
    @Published var latency = 0.18
    @Published var mode = 0 { didSet { if mode == 1 { layout = .stereo } } }
    @Published var fileURL: URL?
    @Published var fileName = ""
    @Published var layout = SpeakerLayout.stereo { didSet { player.channel = layout.localChannel; sendLayout() } }
    @Published var calibrationMS = 0.0
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var capture: AudioCapture?
    private let player = PCMPlayer()
    private var delay = DelayController()
    private var sequence: UInt64 = 0
    private var epoch: UInt64 = 0
    private var nextPTS: Double?
    private var lastPublished = 0.0
    private var toneTimer: Timer?
    private var phase = 0.0
    private var observer: NSObjectProtocol?
    init() {
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
    func startHost() {
        guard !active else { return }
        error = nil; sessionID = UUID(); sessionPhase = "Connecting"
        do {
            let listener = try NWListener(using: LAN.parameters())
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
        peers.removeAll(); devices.removeAll(); active = false; status = tr("Stopped"); sessionPhase = "Stopped"
        statusTimer?.invalidate(); statusTimer = nil; syncIssues = []
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 16 else { connection.cancel(); return }
        let peer = Peer(connection, queue: .main)
        peers[peer.id] = peer; devices.append(ConnectedDevice(id: peer.id))
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.handle(message, from: peer)
        }
        peer.onState = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .cancelled, .failed:
                self.peers.removeValue(forKey: peer.id); self.devices.removeAll { $0.id == peer.id }
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
        var message = Message(kind); message.pairingVersion = 1; message.hostID = hostID
        message.name = serviceName; message.serviceName = directOnly ? nil : serviceName; message.hostAddress = connectionAddress
        return message
    }
    private func handle(_ message: Message, from peer: Peer) {
        guard let index = devices.firstIndex(where: { $0.id == peer.id }), !devices[index].rejected, devices[index].gate.permits(message.kind) else { return }
        if message.kind == "hello" {
            guard !devices[index].gate.approved, devices[index].deviceID == nil else { return }
            guard message.pairingVersion == 1, let id = message.deviceID, UUID(uuidString:id) != nil else { rejectDevice(peer.id); return }
            devices[index].deviceID = id; devices[index].name = String((message.name ?? "MusicSync Client").prefix(80))
            devices[index].channelSelection = ChannelSelection(rawValue:message.channelSelection ?? "automatic") ?? .automatic
            var challenge = hostInfo("pairChallenge"); challenge.nonce = devices[index].nonce; peer.send(challenge)
        } else if message.kind == "pairRequest" {
            requestApproval(peer.id)
        } else if message.kind == "pairProof" {
            guard !devices[index].gate.approved, let id = devices[index].deviceID else { return }
            let secret = sessionSecrets[id] ?? PairingStore.read("host." + id)
            if !revokedIDs.contains(id), let secret, let proof = message.pairingProof,
               PairingProof.verify(proof,secret:secret,nonce:devices[index].nonce,hostID:hostID,clientID:id) {
                authorize(peer.id,secret:nil)
            } else { requestApproval(peer.id) }
        } else if message.kind == "ping", let t1 = message.t1 {
            var response = Message("pong"); response.t1 = t1
            response.t2 = SyncClock.now; response.t3 = SyncClock.now; peer.send(response)
        } else if message.kind == "channelReport" {
            updatePlaybackState(message, index:index)
            if let raw = message.channelSelection, let selection = ChannelSelection(rawValue:raw) { devices[index].channelSelection = selection }
            if let raw = message.outputChannel, let channel = OutputChannel(rawValue:raw) { devices[index].effectiveChannel = channel }
            if message.requestID == devices[index].channelRequestID { devices[index].pendingChannel = nil; devices[index].channelRequestID = nil }
        } else if message.kind == "identifyResult" {
            if message.accepted == true { devices[index].identifyingUntil = Date().addingTimeInterval(1) }
            else if let text = message.name { error = String(format:tr("Identification tone unavailable: %@"),String(text.prefix(200))) }
        } else if message.kind == "identifyHost" {
            identifyHost()
        } else if message.kind == "stats",
                  let rtt = message.rtt, let offset = message.offset, let jitter = message.jitter,
                  let requested = message.latency, [rtt,offset,jitter,requested].allSatisfy({ $0.isFinite }),
                  rtt >= 0, rtt < 1, jitter >= 0, requested >= 0.18, requested <= 0.5 {
            updatePlaybackState(message,index:index)
            devices[index].ready = true; devices[index].rtt = rtt; devices[index].offset = offset
            devices[index].jitter = jitter; devices[index].request = requested; devices[index].lastStats = SyncClock.now
            if let raw = message.syncWarning { devices[index].syncIssues = raw.split(separator:",").compactMap { SyncIssue(rawValue:String($0)) } }
            if let count = message.dropped, (0...1_000_000).contains(count) { devices[index].dropped = count }
            if let raw = message.channelSelection, let selection = ChannelSelection(rawValue:raw) { devices[index].channelSelection = selection }
            if let raw = message.outputChannel, let channel = OutputChannel(rawValue:raw) { devices[index].effectiveChannel = channel }
            delay.update(rtt:rtt,jitter:jitter,requested:requested); latency = delay.target
            var timeline = Message("timeline"); timeline.latency = latency; peer.send(timeline)
        }
    }
    private func updatePlaybackState(_ message: Message, index: Int) {
        if let state = message.playbackState, ["Waiting","Streaming","Interrupted","Synchronizing"].contains(state) { devices[index].playbackState = state }
    }
    private func requestApproval(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].deviceID != nil, !devices[index].gate.approved else { return }
        if devices[index].pairingCode == nil { devices[index].pairingCode = String(format:"%06d",Int.random(in:0...999_999)) }
        var pending = hostInfo("pairPending"); pending.pairingCode = devices[index].pairingCode
        peers[id]?.send(pending)
    }
    func approveDevice(_ id: UUID) {
        guard let device = devices.first(where: { $0.id == id }), let clientID = device.deviceID, device.pairingCode != nil, !device.gate.approved, !device.rejected else { return }
        let secret = PairingProof.newSecret(); sessionSecrets[clientID] = secret; revokedIDs.remove(clientID)
        do { try PairingStore.write(secret,account:"host." + clientID) }
        catch { pairingNotice = error.localizedDescription }
        // A replaced pairing invalidates any other live socket claiming this device identity.
        for other in devices where other.id != id && other.deviceID == clientID { rejectDevice(other.id) }
        authorize(id,secret:secret)
    }
    private func authorize(_ id: UUID, secret: String?) {
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].rejected else { return }
        devices[index].gate.approve(); devices[index].pairingCode = nil
        var approved = hostInfo("pairApproved"); approved.pairingSecret = secret
        approved.outputChannel = layout.remoteChannel.rawValue; peers[id]?.send(approved)
    }
    func rejectDevice(_ id: UUID) {
        guard let peer = peers[id], let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].rejected = true; devices[index].ready = false; devices[index].gate = PairingGate()
        peer.send(Message("pairRejected"))
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak peer] in peer?.cancel() }
    }
    func forgetDevice(_ id: UUID) {
        guard let device = devices.first(where: { $0.id == id }), let clientID = device.deviceID else { return }
        do { try PairingStore.remove("host." + clientID) }
        catch { pairingNotice = error.localizedDescription }
        revokedIDs.insert(clientID); sessionSecrets[clientID] = nil
        for other in devices where other.deviceID == clientID { rejectDevice(other.id) }
    }
    func setChannel(_ id: UUID, selection: ChannelSelection) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].gate.approved else { return }
        let request = UUID().uuidString; devices[index].pendingChannel = selection; devices[index].channelRequestID = request
        var message = Message("setChannel"); message.channelSelection = selection.rawValue
        message.outputChannel = layout.remoteChannel.rawValue; message.requestID = request; peers[id]?.send(message)
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self, let index = self.devices.firstIndex(where: { $0.id == id }), self.devices[index].channelRequestID == request else { return }
            self.devices[index].pendingChannel = nil; self.devices[index].channelRequestID = nil
            self.error = tr("The Client did not confirm the channel change. Check its connection.")
        }
    }
    private func sendLayout() {
        var message = Message("hostChannel"); message.outputChannel = layout.remoteChannel.rawValue
        for device in devices where device.gate.approved { peers[device.id]?.send(message) }
    }
    func identifyDevice(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].gate.approved,
              Date().timeIntervalSince(devices[index].lastIdentify) >= 2 else { return }
        devices[index].lastIdentify = Date(); peers[id]?.send(Message("identify"))
    }
    func identifyHost() {
        do { _ = try identifierSound.play() } catch { self.error = error.localizedDescription }
    }
    func startStreaming(testTone: Bool = false) async {
        guard active, !streaming, !busy else { return }
        busy = true; defer { busy = false }
        error = nil; delay = DelayController(); latency = delay.target
        sequence = 0; epoch += 1; nextPTS = nil
        isMonitor = mode == 1 && !testTone && fileURL == nil
        lastPCM = SyncClock.now; localDrops = 0; peakScheduleError = 0; health = SyncHealthMonitor(); meter = TrafficMeter()
        sessionPhase = "Synchronizing"
        do {
            #if os(macOS)
            if mode == 0 || testTone || fileURL != nil { try player.start() }
            #else
            try player.start()
            #endif
            if testTone {
                phase = 0
                streaming = true; status = tr("Synchronized test tone"); sessionPhase = "Streaming"
                toneTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tone()  } }
                if let toneTimer { RunLoop.main.add(toneTimer, forMode: .common) }
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
                source.onPCM = { [weak self] data, frames, time in
                    DispatchQueue.main.async {
                        guard let self, self.epoch == sourceEpoch else { return }
                        self.broadcast(data, frames: frames, captureTime: time)
                    }
                }
                streaming = true
                try await source.start()
                guard active, capture === source else { await source.stop(); streaming = false; return }
                sessionPhase = "Streaming"
                status = fileURL != nil ? tr("Streaming music file") : mode == 0 ? tr("Synchronized system audio") : tr("ScreenCaptureKit monitor • original Mac output is ahead")
            }
        } catch {
            self.error = error.localizedDescription
            streaming = false; sessionPhase = active ? "Waiting" : "Stopped"
            await capture?.stop(); capture = nil; player.stop()
        }
    }
    func stopStreaming() async {
        streaming = false; toneTimer?.invalidate(); toneTimer = nil
        await capture?.stop(); capture = nil; player.stop(); nextPTS = nil
        var message = Message("stop"); message.epoch = epoch
        for device in devices where device.gate.approved { peers[device.id]?.send(message) }
        status = active ? tr("Host available on LAN") : tr("Stopped")
        sessionPhase = active ? "Waiting" : "Stopped"; health = SyncHealthMonitor(); syncIssues = []; isMonitor = false
    }
    private func tone() {
        var samples = [Float](repeating: 0, count: 960)
        for frame in 0..<480 {
            // A short pulse each second makes acoustic alignment easy to hear.
            let seconds = phase / 48_000
            let value = seconds.truncatingRemainder(dividingBy: 1) < 0.1 ? Float(sin(phase * 2 * .pi * 880 / 48_000)) * 0.12 : 0
            var left = value, right = value
            let pulse = seconds.truncatingRemainder(dividingBy: 1)
            if layout != .stereo {
                if (0.25..<0.35).contains(pulse) { left = Float(sin(phase * 2 * .pi * 440 / 48_000)) * 0.12 }
                if (0.5..<0.6).contains(pulse) { right = Float(sin(phase * 2 * .pi * 660 / 48_000)) * 0.12 }
            }
            samples[frame * 2] = left; samples[frame * 2 + 1] = right; phase += 1
        }
        let data = samples.withUnsafeBytes { Data($0) }
        broadcast(data, frames: 480, captureTime: SyncClock.now)
    }
    private func broadcast(_ data: Data, frames: Int, captureTime: Double) {
        guard streaming else { return }
        let now = SyncClock.now; lastPCM = now
        // Keep the audio sample timeline continuous; callback arrival is not the presentation clock.
        let earliest = captureTime + delay.target
        if nextPTS == nil { nextPTS = max(earliest, now + delay.target) }
        if nextPTS! < now + 0.06 { nextPTS = now + delay.target }
        if earliest > nextPTS! + 0.03 { nextPTS = earliest }
        var cursor = 0
        while cursor < frames {
            let count = min(480, frames - cursor)
            var message = Message("audio")
            message.sequence = sequence; sequence += 1; message.epoch = epoch
            message.pts = nextPTS; message.sampleRate = 48_000; message.channels = 2; message.frames = count
            message.latency = delay.target
            message.outputChannel = layout.remoteChannel.rawValue; message.monitor = isMonitor
            message.payload = data.subdata(in: (cursor * 8)..<((cursor + count) * 8))
            nextPTS! += Double(count) / 48_000; cursor += count
            player.calibration = calibrationMS / 1000
            meter.record(bytes: message.payload?.count ?? 0)
            if player.running {
                if !player.schedule(message, offset: 0) { localDrops += 1 }
                peakScheduleError = max(peakScheduleError, player.schedulingError)
            }
            for device in devices where device.ready && device.gate.approved { peers[device.id]?.send(message) }
        }
        if now - lastPublished > 1 { latency = delay.target; lastPublished = now }
    }
    var timingDevice: ConnectedDevice? { devices.filter(\.ready).max { $0.rtt / 2 + $0.jitter < $1.rtt / 2 + $1.jitter } }
    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshStatus() } }
        if let statusTimer { RunLoop.main.add(statusTimer, forMode: .common) }
    }
    private func refreshStatus() {
        let now = SyncClock.now
        traffic = meter.sample(now: now, drops: localDrops)
        schedulingErrorMS = peakScheduleError * 1000
        var input = SyncHealthInput()
        input.uncertainty = devices.filter(\.ready).map { $0.rtt / 2 + $0.jitter }.max() ?? 0
        input.clockAge = devices.filter(\.ready).map { now - $0.lastStats }.max() ?? 0
        input.streaming = streaming && sessionPhase == "Streaming"; input.audioAge = lastPCM > 0 ? now - lastPCM : 0
        input.dropRate = traffic.dropsPerSecond; input.schedulingError = peakScheduleError; input.monitor = isMonitor
        healthInput = input
        health.update(input,now:now)
        syncIssues = SyncIssue.allCases.filter { issue in health.issues.contains(issue) || devices.contains { $0.syncIssues.contains(issue) } }
        peakScheduleError = 0; lastUpdated = Date()
    }

}
