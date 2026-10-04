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
    @Published var nearby: [NearbyMac] = []
    @Published var status = "Ready to search"
    @Published var connected = false
    @Published var searching = false
    @Published var selectedName: String?
    @Published var error: String?
    @Published var rtt = 0.0
    @Published var offset = 0.0
    @Published var jitter = 0.0
    @Published var latency = 0.18
    @Published var uncertainty = 0.0
    @Published var dropped = 0
    @Published var calibrationMS = 0.0
    @Published var directAddress = ""
    @Published var discoveryDenied = false
    private var directMac: NearbyMac?
    private var browser: NWBrowser?
    private var peer: Peer?
    private let player = PCMPlayer()
    private var clock = ClockEstimate()
    private var buffer = JitterQueue()
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
    init() {
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.restartAudio()  } }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in MainActor.assumeIsolated {
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            if type == AVAudioSession.InterruptionType.began.rawValue {
                self?.player.stop(); self?.buffer = JitterQueue(); self?.status = "Audio interrupted"
            } else { self?.restartAudio() }
         } }
    }
    func search() {
        guard browser == nil else { return }
        searching = true; error = nil; discoveryDenied = false
        let browser = NWBrowser(for: .bonjour(type: LAN.service, domain: nil), using: LAN.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in MainActor.assumeIsolated {
            guard let self else { return }
            self.nearby = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint { return NearbyMac(name: name, endpoint: result.endpoint) }
                return nil
            }.sorted { $0.name < $1.name }
            if self.wantConnection, self.peer == nil, let found = self.nearby.first(where: { $0.name == self.selectedName }) { self.open(found) }
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
        self.browser = browser; browser.start(queue: .main); status = "Searching nearby Macs…"
    }
    private func discoveryFailed(_ failure: NWError) {
        searching = false; status = "Discovery unavailable"
        if case .dns(let code) = failure, code == -65555 || code == -65570 {
            discoveryDenied = true
            error = "Bonjour access was denied. In LiveContainer, the host app must allow _musicsync._tcp; the guest Info.plist cannot grant this. Enable Local Network for LiveContainer, then use the Mac connection address below, or install MusicSync directly with signing."
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
            error = "Paste the Mac connection address, for example MacBook.local:49152."; return
        }
        disconnect()
        let mac = NearbyMac(name: value, endpoint: .hostPort(host: NWEndpoint.Host(hostname), port: nwPort))
        directMac = mac; selectedName = mac.name; wantConnection = true
        error = nil; open(mac)
    }
    func connect(_ mac: NearbyMac) {
        disconnect(); wantConnection = true; selectedName = mac.name
        open(mac)
    }
    private func open(_ mac: NearbyMac) {
        guard peer == nil else { return }
        retry?.cancel(); retry = nil
        clock = ClockEstimate(); buffer = JitterQueue(); lastEpoch = nil; pendingPings.removeAll(); pings = 0
        requestedLatency = 0.18
        let peer = Peer(NWConnection(to: mac.endpoint, using: LAN.parameters()), queue: .main)
        self.peer = peer; status = "Connecting to \(mac.name)…"
        peer.onState = { [weak self, weak peer] state in
            guard let self, let peer, self.peer === peer else { return }
            switch state {
            case .ready:
                do { try self.player.start() } catch { self.error = error.localizedDescription; self.disconnect(); return }
                self.connected = true; self.status = "Synchronizing clocks…"
                var hello = Message("hello"); hello.name = UIDevice.current.name; peer.send(hello)
                self.startTimers()
            case .failed(let error): self.error = error.localizedDescription; self.lost()
            case .cancelled: self.lost()
            case .waiting(let error): self.error = error.localizedDescription; self.lost()
            default: break
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.handle(message)
        }
        peer.start()
    }
    private func handle(_ message: Message) {
        let now = SyncClock.now
        if message.kind == "pong", let t1 = message.t1, let t2 = message.t2, let t3 = message.t3,
           let index = pendingPings.firstIndex(of: t1) {
            pendingPings.remove(at: index)
            clock.observe(t1:t1,t2:t2,t3:t3,t4:now)
            rtt = clock.rtt; offset = clock.offset; jitter = clock.jitter
            uncertainty = clock.uncertainty
            if clock.ready, now - lastReport > 1 {
                var stats = Message("stats"); stats.rtt = rtt; stats.offset = offset; stats.jitter = jitter
                stats.latency = max(requestedLatency, min(0.5, max(0.18, rtt / 2 + 4 * jitter + player.outputLatency + 0.07)))
                peer?.send(stats); lastReport = now
                if lastAudio == 0 { status = "Connected • waiting for Host audio" }
            }
        } else if message.kind == "audio", clock.ready, message.validAudio {
            if lastEpoch != message.epoch {
                player.stop(); try? player.start(); buffer = JitterQueue(); lastEpoch = message.epoch
            }
            buffer.insert(message); lastAudio = now
            if let delay = message.latency, delay.isFinite, (0.18...0.5).contains(delay) { latency = delay }
        } else if message.kind == "stop" {
            player.stop(); try? player.start(); buffer = JitterQueue(); lastAudio = 0
            status = "Connected • Host stopped streaming"
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
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.drain()  } }
        // Run during native control tracking as well as the default runloop mode.
        if let pingTimer { RunLoop.main.add(pingTimer, forMode: .common) }
        if let drainTimer { RunLoop.main.add(drainTimer, forMode: .common) }
    }
    private func drain() {
        guard clock.ready else { return }
        let now = SyncClock.now
        player.calibration = calibrationMS / 1000
        let before = buffer.drops
        let lead = max(0.025, player.outputLatency + abs(player.calibration) + 0.01)
        for packet in buffer.take(now:now, offset:clock.offset, horizon:max(0.065,lead + 0.03), minimumLead:lead) {
            if !player.schedule(packet, offset:clock.offset) { dropped += 1 }
        }
        if buffer.drops > before { requestedLatency = min(0.5, latency + 0.02) }
        if now - lastUI > 0.5 {
            dropped = max(dropped, buffer.drops)
            if lastAudio > 0 { status = now - lastAudio < 1 ? "Streaming • scheduled playback" : "Connected • no recent audio" }
            lastUI = now
        }
    }
    private func restartAudio() {
        guard connected else { return }
        player.stop(); buffer = JitterQueue()
        do { try player.start() } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        wantConnection = false; retry?.cancel(); retry = nil
        let old = peer; peer = nil; old?.cancel()
        cleanup(); selectedName = nil; directMac = nil; status = "Disconnected"
    }
    private func cleanup() {
        pingTimer?.invalidate(); drainTimer?.invalidate(); pingTimer = nil; drainTimer = nil
        player.stop(); buffer = JitterQueue(); connected = false; lastAudio = 0; lastReport = 0
    }
    private func lost() {
        let old = peer; peer = nil; old?.cancel(); cleanup()
        guard wantConnection else { return }
        status = "Connection lost • reconnecting…"
        retry?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnection, let mac = self.directMac ?? self.nearby.first(where: { $0.name == self.selectedName }) else { return }
            self.open(mac)
        }
        retry = task; DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:task)
    }
}
