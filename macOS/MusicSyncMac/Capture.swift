// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation
import AVFoundation
import CoreAudio
import ScreenCaptureKit
import CoreMedia

enum CaptureFailure: LocalizedError {
    case status(String, OSStatus), unavailable
    var errorDescription: String? {
        switch self {
        case let .status(operation, code): return String(format: tr("%@: %d. Check System Audio Recording permission."), operation, code)
        case .unavailable: return tr("Audio source is unavailable.")
        }
    }
}

/// Private aggregate reads a global process tap; default output is never reassigned.
final class TapCapture: AudioCapture {
    var onPCM: ((Data, Int, Double) -> Void)?
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "MusicSync.capture", qos: .userInteractive)
    private let encoder = PCMEncoder()
    private func check(_ status: OSStatus, _ name: String) throws {
        if status != noErr { throw CaptureFailure.status(name, status) }
    }
    func start() async throws {
        do {
            var ownProcess = AudioObjectID(0)
            var pid = getpid()
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess), "Resolve own audio process")
            guard ownProcess != kAudioObjectUnknown else { throw CaptureFailure.unavailable }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            description.name = "MusicSync synchronized system audio"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")
            var asbd = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            address.mSelector = kAudioTapPropertyFormat
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "Read tap format")
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureFailure.unavailable }
            self.format = format
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MusicSync private capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Create private aggregate")
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { [weak self] _, input, inputTime, _, _ in
                guard let self, let format = self.format else { return }
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = list.first, first.mData != nil else { return }
                let frames = first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame
                guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                copy.frameLength = frames
                let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                guard destination.count == list.count else { return }
                for i in 0..<list.count {
                    if let src = list[i].mData, let dst = destination[i].mData {
                        memcpy(dst, src, min(Int(list[i].mDataByteSize), Int(destination[i].mDataByteSize)))
                    }
                }
                let time = inputTime.pointee.mHostTime
                let captureTime = time > 0 ? AVAudioTime.seconds(forHostTime: time) : AVAudioTime.seconds(forHostTime: mach_absolute_time())
                if let (data, count) = self.encoder.encode(copy) { self.onPCM?(data, count, captureTime) }
            }, "Create tap reader")
            try check(AudioDeviceStart(device, io), "Start tap reader")
        } catch { await stop(); throw error }
    }
    func stop() async {
        if device != 0 {
            if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        io = nil; device = 0; tap = 0
    }
}

/// Monitor fallback: leaves original Mac sound audible, so cannot synchronize that original sound.
final class ScreenCapture: NSObject, AudioCapture, SCStreamOutput, SCStreamDelegate {
    var onPCM: ((Data, Int, Double) -> Void)?
    var onError: ((String) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "MusicSync.screenAudio", qos: .userInteractive)
    private let encoder = PCMEncoder()
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureFailure.unavailable }
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000; config.channelCount = 2
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }
    func stop() async { try? await stream?.stopCapture(); stream = nil }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &retained) == noErr else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        copy.frameLength = AVAudioFrameCount(count)
        let src = UnsafeMutableAudioBufferListPointer(list), dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return }
        for i in 0..<src.count {
            if let source = src[i].mData, let destination = dst[i].mData { memcpy(destination, source, min(Int(src[i].mDataByteSize),Int(dst[i].mDataByteSize))) }
        }
        let pts = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        guard pts.isFinite else { return }
        if let (data, frames) = encoder.encode(copy) { onPCM?(data, frames, pts) }
    }
}
