// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import SwiftUI
import MusicSyncCore
#if os(macOS)
import CoreAudio
#else
import MediaPlayer
#endif

/// Injectable hardware access keeps CI from changing the runner's volume.
struct VolumeEndpoint {
    private let readSystem: (() -> (value:Double,writable:Bool)?)?
    private let writeSystem: ((Double) -> Bool)?
    var scope: String { readSystem == nil ? "app" : "system" }
    init(playbackOnly: Bool = false) {
        #if os(macOS)
        readSystem = playbackOnly ? nil : MacSystemVolume.read
        writeSystem = playbackOnly ? nil : MacSystemVolume.set
        #else
        readSystem = nil; writeSystem = nil
        #endif
    }
    init(read: @escaping () -> (value:Double,writable:Bool)?, write: @escaping (Double) -> Bool) { readSystem = read; writeSystem = write }
    func read() -> (value:Double,writable:Bool)? { readSystem?() }
    func set(_ value: Double) -> Bool { guard VolumeControl.valid(value) != nil else { return false }; return writeSystem?(value) ?? false }
}
#if os(macOS)
private enum MacSystemVolume {
    private static func device() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        .init(mSelector:kAudioDevicePropertyVolumeScalar,mScope:kAudioDevicePropertyScopeOutput,mElement:element)
    }
    private static func controls(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        var main = address(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device,&main) { return [kAudioObjectPropertyElementMain] }
        var pair: [UInt32] = [1,2]; var size = UInt32(2 * MemoryLayout<UInt32>.size)
        var preferred = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyPreferredChannelsForStereo,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        _ = pair.withUnsafeMutableBytes { AudioObjectGetPropertyData(device,&preferred,0,nil,&size,$0.baseAddress!) }
        return Array(Set(pair)).sorted().filter { element in var property = address(element); return element != 0 && AudioObjectHasProperty(device,&property) }
    }
    private static func values(_ device: AudioObjectID, controls: [AudioObjectPropertyElement]) -> (values:[Float32],writable:Bool)? {
        guard !controls.isEmpty else { return nil }
        var result: [Float32] = []; var allWritable = true
        for element in controls {
            var property = address(element); var scalar = Float32(0); var size = UInt32(MemoryLayout<Float32>.size); var writable = DarwinBoolean(false)
            guard AudioObjectGetPropertyData(device,&property,0,nil,&size,&scalar) == noErr, VolumeControl.valid(Double(scalar)) != nil else { return nil }
            allWritable = allWritable && AudioObjectIsPropertySettable(device,&property,&writable) == noErr && writable.boolValue
            result.append(scalar)
        }
        return (result,allWritable)
    }
    static func read() -> (value:Double,writable:Bool)? {
        guard let device = device(), let state = values(device,controls:controls(device)), let peak = state.values.max() else { return nil }
        return (Double(peak),state.writable)
    }
    static func set(_ value: Double) -> Bool {
        guard let value = VolumeControl.valid(value), let device = device() else { return false }
        let controls = controls(device)
        guard let state = values(device,controls:controls), state.writable else { return false }
        let peak = state.values.max() ?? 0
        for (index,element) in controls.enumerated() {
            var property = address(element)
            var scalar = peak > 0 ? Float32(value) * state.values[index] / peak : Float32(value)
            if AudioObjectSetPropertyData(device,&property,0,nil,UInt32(MemoryLayout<Float32>.size),&scalar) != noErr {
                // Best-effort rollback if a device disappears or rejects a channel write.
                for (i,channel) in controls.enumerated() { var oldProperty = address(channel); var old = state.values[i]; _ = AudioObjectSetPropertyData(device,&oldProperty,0,nil,UInt32(MemoryLayout<Float32>.size),&old) }
                return false
            }
        }
        return true
    }

}
#else
/// User-operated public system volume control; no hidden slider automation.
struct NativeSystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame:.zero) }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
#endif
