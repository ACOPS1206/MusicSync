// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation
import AVFoundation
import MusicSyncCore

enum AudioSourceFailure: LocalizedError {
    case noFile, unsupported, musicDenied
    var errorDescription: String? {
        switch self {
        case .noFile: return tr("Choose a music file before starting streaming.")
        case .unsupported: return tr("This track cannot be imported. Choose a downloaded, DRM-free music file. Apple Music subscription tracks cannot be streamed as PCM.")
        case .musicDenied: return tr("Music library access was denied. Allow Media & Apple Music access in Settings, or choose a file instead.")
        }
    }
}

/// Decode incrementally, never load an entire song into memory. Feed the common timestamp pipeline.
final class FileAudioSource: AudioCapture {
    var onPCM: ((Data, Int, Double) -> Void)?
    var onEnd: ((String?) -> Void)?
    private let url: URL
    private let queue = DispatchQueue(label: "MusicSync.file", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var encoder = PCMEncoder()
    private var pending = Data()
    private var startTime = 0.0
    private var emitted = 0
    private var finished = false
    private var flushed = false
    init(url: URL) { self.url = url }
    func start() async throws {
        try queue.sync {
            file = try AVAudioFile(forReading: url)
            guard let file, file.length > 0 else { throw AudioSourceFailure.unsupported }
            encoder = PCMEncoder(); pending.removeAll(); emitted = 0; finished = false; flushed = false
            startTime = SyncClock.now
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() async {
        queue.sync { timer?.cancel(); timer = nil; file = nil; pending.removeAll() }
    }
    private func pump() {
        guard let file, !finished else { return }
        do {
            // Catch up after a delayed callback, with a bound to avoid flooding a stalled LAN.
            let due = min(emitted + 4800, Int((SyncClock.now - startTime) * 48_000))
            while emitted + 480 <= due {
                while pending.count < 480 * 8 && file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw AudioSourceFailure.unsupported }
                    try file.read(into: buffer)
                    if let (data, _) = encoder.encode(buffer) { pending.append(data) }
                }
                if file.framePosition >= file.length, !flushed {
                    flushed = true
                    if let (tail, _) = encoder.finish() { pending.append(tail) }
                }
                if pending.isEmpty { end(nil); return }
                let frames = min(480, pending.count / 8)
                let data = Data(pending.prefix(frames * 8)); pending = Data(pending.dropFirst(frames * 8))
                onPCM?(data, frames, startTime + Double(emitted) / 48_000)
                emitted += frames
                if frames < 480 { end(nil); return }
            }
        } catch { end(error.localizedDescription) }
    }
    private func end(_ error: String?) { finished = true; timer?.cancel(); timer = nil; onEnd?(error) }
}
