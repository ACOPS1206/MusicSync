// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
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
    var rtt = 0.0
    var offset = 0.0
    var jitter = 0.0
    var request = 0.18
}

@MainActor final class HostModel: ObservableObject {
    @Published var active = false
    @Published var directOnly = false
    @Published var connectionAddress = ""
    @Published var streaming = false
    @Published var busy = false
    @Published var status = tr("Ready")
    @Published var error: String?
    @Published var devices: [ConnectedDevice] = []
    @Published var latency = 0.18
    @Published var mode = 0 { didSet { if mode == 1 { layout = .stereo } } }
    @Published var fileURL: URL?
    @Published var fileName = ""
    @Published var layout = SpeakerLayout.stereo { didSet { player.channel = layout.localChannel } }
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
        error = nil
        do {
            let listener = try NWListener(using: LAN.parameters())
            #if os(macOS)
            let name = Host.current().localizedName ?? "MusicSync Mac"
            #else
            let name = UIDevice.current.name + " · MusicSync"
            #endif
            if !directOnly { listener.service = NWListener.Service(name: name, type: LAN.service) }
            listener.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated { self?.accept(connection)  } }
            listener.stateUpdateHandler = { [weak self, weak listener] state in MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.active = true; self.status = tr("Host available on LAN")
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
        listener?.cancel(); listener = nil; connectionAddress = ""
        for peer in peers.values { peer.cancel() }
        peers.removeAll(); devices.removeAll(); active = false; status = tr("Stopped")
    }
    private func accept(_ connection: NWConnection) {
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
    }
    private func handle(_ message: Message, from peer: Peer) {
        if message.kind == "ping", let t1 = message.t1 {
            var response = Message("pong"); response.t1 = t1
            response.t2 = SyncClock.now; response.t3 = SyncClock.now
            peer.send(response)
        } else if message.kind == "hello", let index = devices.firstIndex(where: { $0.id == peer.id }) {
            devices[index].name = String((message.name ?? "iPhone").prefix(80))
        } else if message.kind == "stats", let index = devices.firstIndex(where: { $0.id == peer.id }),
                  let rtt = message.rtt, let offset = message.offset, let jitter = message.jitter,
                  let requested = message.latency, [rtt,offset,jitter,requested].allSatisfy({ $0.isFinite }),
                  rtt >= 0, rtt < 1, jitter >= 0, requested >= 0.18, requested <= 0.5 {
            devices[index].ready = true; devices[index].rtt = rtt; devices[index].offset = offset
            devices[index].jitter = jitter; devices[index].request = requested
            delay.update(rtt: rtt, jitter: jitter, requested: requested)
            latency = delay.target
            var timeline = Message("timeline"); timeline.latency = latency
            peer.send(timeline)
        }
    }
    func startStreaming(testTone: Bool = false) async {
        guard active, !streaming, !busy else { return }
        busy = true; defer { busy = false }
        error = nil; delay = DelayController(); latency = delay.target
        sequence = 0; epoch += 1; nextPTS = nil
        do {
            #if os(macOS)
            if mode == 0 || testTone || fileURL != nil { try player.start() }
            #else
            try player.start()
            #endif
            if testTone {
                phase = 0
                streaming = true; status = tr("Synchronized test tone")
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
                status = fileURL != nil ? tr("Streaming music file") : mode == 0 ? tr("Synchronized system audio") : tr("ScreenCaptureKit monitor • original Mac output is ahead")
            }
        } catch {
            self.error = error.localizedDescription
            streaming = false
            await capture?.stop(); capture = nil; player.stop()
        }
    }
    func stopStreaming() async {
        streaming = false; toneTimer?.invalidate(); toneTimer = nil
        await capture?.stop(); capture = nil; player.stop(); nextPTS = nil
        var message = Message("stop"); message.epoch = epoch
        for peer in peers.values { peer.send(message) }
        status = active ? tr("Host available on LAN") : tr("Stopped")
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
        let now = SyncClock.now
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
            message.outputChannel = layout.remoteChannel.rawValue
            message.payload = data.subdata(in: (cursor * 8)..<((cursor + count) * 8))
            nextPTS! += Double(count) / 48_000; cursor += count
            player.calibration = calibrationMS / 1000
            if player.running { _ = player.schedule(message, offset: 0) }
            for device in devices where device.ready { peers[device.id]?.send(message) }
        }
        if now - lastPublished > 1 { latency = delay.target; lastPublished = now }
    }
}
