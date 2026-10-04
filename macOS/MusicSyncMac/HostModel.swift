import SwiftUI
import Network
import MusicSyncCore
import AVFoundation
import SystemConfiguration

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
    @Published var connectionAddress = ""
    @Published var streaming = false
    @Published var busy = false
    @Published var status = "Ready"
    @Published var error: String?
    @Published var devices: [ConnectedDevice] = []
    @Published var latency = 0.18
    @Published var mode = 0
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
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            // Restore tapped process output before the application exits.
            if let capture = self.capture {
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached { await capture.stop(); semaphore.signal() }
                _ = semaphore.wait(timeout: .now() + 1)
            }
         } }
    }
    func startHost() {
        guard !active else { return }
        error = nil
        do {
            let listener = try NWListener(using: LAN.parameters())
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "MusicSync Mac", type: LAN.service)
            listener.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated { self?.accept(connection)  } }
            listener.stateUpdateHandler = { [weak self, weak listener] state in MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.active = true; self.status = "Host available on LAN"
                    if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, let port = listener?.port {
                        self.connectionAddress = "\(name).local:\(port.rawValue)"
                    }
                case .failed(let error): self.error = error.localizedDescription; self.stopHost()
                default: break
                }
             } }
            self.listener = listener; listener.start(queue: .main)
            status = "Starting Bonjour…"
        } catch { self.error = error.localizedDescription }
    }
    func stopHost() {
        Task { await stopStreaming() }
        listener?.cancel(); listener = nil; connectionAddress = ""
        for peer in peers.values { peer.cancel() }
        peers.removeAll(); devices.removeAll(); active = false; status = "Stopped"
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
            if mode == 0 || testTone { try player.start() }
            if testTone {
                streaming = true; status = "Synchronized test tone"
                toneTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tone()  } }
            } else {
                let source: AudioCapture
                if mode == 0 { source = TapCapture() } else {
                    let screen = ScreenCapture()
                    screen.onError = { [weak self] text in DispatchQueue.main.async {
                        self?.error = text; Task { await self?.stopStreaming() }
                    } }
                    source = screen
                }
                capture = source
                source.onPCM = { [weak self] data, frames, time in
                    DispatchQueue.main.async { self?.broadcast(data, frames: frames, captureTime: time) }
                }
                try await source.start()
                streaming = true
                status = mode == 0 ? "Synchronized system audio" : "ScreenCaptureKit monitor • original Mac output is ahead"
            }
        } catch {
            self.error = error.localizedDescription
            await capture?.stop(); capture = nil; player.stop()
        }
    }
    func stopStreaming() async {
        streaming = false; toneTimer?.invalidate(); toneTimer = nil
        await capture?.stop(); capture = nil; player.stop(); nextPTS = nil
        var message = Message("stop"); message.epoch = epoch
        for peer in peers.values { peer.send(message) }
        status = active ? "Host available on LAN" : "Stopped"
    }
    private func tone() {
        var samples = [Float](repeating: 0, count: 960)
        for frame in 0..<480 {
            // A short pulse each second makes acoustic alignment easy to hear.
            let seconds = phase / 48_000
            let value = seconds.truncatingRemainder(dividingBy: 1) < 0.1 ? Float(sin(phase * 2 * .pi * 880 / 48_000)) * 0.12 : 0
            samples[frame * 2] = value; samples[frame * 2 + 1] = value; phase += 1
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
            message.payload = data.subdata(in: (cursor * 8)..<((cursor + count) * 8))
            nextPTS! += Double(count) / 48_000; cursor += count
            if player.running { _ = player.schedule(message, offset: 0) }
            for device in devices where device.ready { peers[device.id]?.send(message) }
        }
        if now - lastPublished > 1 { latency = delay.target; lastPublished = now }
    }
}
