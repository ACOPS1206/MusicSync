// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync
import SwiftUI
import MusicSyncCore

struct PlaybackVolumeView: View {
    let title: LocalizedStringKey
    @Binding var volume: Double
    var body: some View {
        VStack(alignment:.leading) {
            LabeledContent(title,value:String(format:"%.0f%%",volume * 100))
            Slider(value:$volume,in:0...1) { Text(title) }
        }
    }
}
struct DeviceVolumeView: View {
    @ObservedObject var model: HostModel
    let device: ConnectedDevice
    var body: some View {
        PlaybackVolumeView(title:device.volumeScope == "system" ? "System volume" : "MusicSync playback volume",volume:Binding(
            get:{ model.devices.first(where: { $0.id == device.id }).map { $0.pendingVolume ?? $0.volume } ?? device.volume },
            set:{ model.setClientVolume(device.id,volume:$0) }))
            .disabled(!device.supportsVolumeControl || !device.permissions.hostMayControlClient)
        if device.supportsVolumeControl {
            DisclosureGroup("Device permissions") {
                Toggle("Client may change Host volume",isOn:Binding(get:{device.permissions.clientMayControlHost},set:{model.setVolumePermissions(device.id,clientMayControlHost:$0)}))
                Toggle("Host may change Client volume",isOn:Binding(get:{device.permissions.hostMayControlClient},set:{model.setVolumePermissions(device.id,hostMayControlClient:$0)}))
                Toggle("Client may change other Clients",isOn:Binding(get:{device.permissions.clientMayControlPeers},set:{model.setVolumePermissions(device.id,clientMayControlPeers:$0)}))
                Toggle("Other Clients may change this Client",isOn:Binding(get:{device.permissions.peersMayControlClient},set:{model.setVolumePermissions(device.id,peersMayControlClient:$0)}))
                Toggle("Client may change other devices' channels and identify them",isOn:Binding(get:{device.permissions.clientMayControlPeerDevices},set:{model.setVolumePermissions(device.id,clientMayControlPeerDevices:$0)}))
                Toggle("Other Clients may change this device's channel and identify it",isOn:Binding(get:{device.permissions.peersMayControlClientDevice},set:{model.setVolumePermissions(device.id,peersMayControlClientDevice:$0)}))
                Text("Client-to-Client control needs permission on both the controlling and receiving devices.").font(.caption).foregroundStyle(.secondary)
            }
        } else { Text("Update both devices to use remote volume control.").font(.caption).foregroundStyle(.secondary) }
    }
}
struct ClientVolumeView: View {
    @ObservedObject var model: ClientModel
    var body: some View {
        Section("Volume") {
            #if os(iOS)
            Text("iPhone system volume").font(.subheadline)
            NativeSystemVolumeView().frame(height:36)
            #endif
            PlaybackVolumeView(title:model.volumeScope == "system" ? "System volume" : "MusicSync playback volume",volume:$model.outputVolume).disabled(!model.volumeAvailable)
            if !model.volumeAvailable { Text("System volume is unavailable for this output device.").font(.caption).foregroundStyle(.secondary) }
            if model.paired {
                PlaybackVolumeView(title:model.hostVolumeScope == "system" ? "Host system volume" : "Host MusicSync volume",volume:Binding(get:{model.pendingHostVolume ?? model.hostVolume},set:{model.requestHostVolume($0)}))
                    .disabled(!model.canControlHostVolume)
                if !model.canControlHostVolume { Text("Ask the Host to allow volume control.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Mac system volume affects all sound on the selected output device. iPhone remote controls adjust MusicSync playback; change iPhone system volume directly using the native slider or buttons.").font(.caption).foregroundStyle(.secondary)
        }
        if model.paired, !model.volumePeers.isEmpty {
            Section("Connected Devices") {
                ForEach(model.volumePeers) { device in
                    VStack(alignment:.leading) {
                        Label(device.name,systemImage:"hifispeaker")
                        LabeledContent("Current output channel",value:device.outputChannel.flatMap(OutputChannel.init(rawValue:))?.title ?? "—")
                        if let state = device.playbackState { Text(tr(state)).font(.caption).foregroundStyle(.secondary) }
                        Picker("Output channel",selection:Binding(get:{model.pendingPeerChannels[device.id] ?? ChannelSelection(rawValue:device.channelSelection ?? "automatic") ?? .automatic},set:{model.requestPeerChannel(device.id,selection:$0)})) {
                            ForEach(ChannelSelection.allCases) { channel in Text(channel.title).tag(channel) }
                        }.disabled(device.canControlDevice != true)
                        Button("Play Identification Tone") { model.identifyPeer(device.id) }.buttonStyle(.glass).disabled(device.canControlDevice != true)
                        if device.canControlDevice != true { Text("Ask the Host to allow channel and identification control.").font(.caption).foregroundStyle(.secondary) }
                        PlaybackVolumeView(title:device.volumeScope == "system" ? "System volume" : "MusicSync playback volume",volume:Binding(get:{model.pendingPeerVolumes[device.id] ?? device.volume},set:{model.requestPeerVolume(device.id,volume:$0)})).disabled(!device.canControl)
                        if !device.canControl { Text("Ask the Host to allow volume control.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}
