// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync
import SwiftUI

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
        PlaybackVolumeView(title:"Client volume",volume:Binding(
            get:{ model.devices.first(where: { $0.id == device.id }).map { $0.pendingVolume ?? $0.volume } ?? device.volume },
            set:{ model.setClientVolume(device.id,volume:$0) }))
            .disabled(!device.supportsVolumeControl || !device.permissions.hostMayControlClient)
        if device.supportsVolumeControl {
            DisclosureGroup("Volume permissions") {
                Toggle("Client may change Host volume",isOn:Binding(get:{device.permissions.clientMayControlHost},set:{model.setVolumePermissions(device.id,clientMayControlHost:$0)}))
                Toggle("Host may change Client volume",isOn:Binding(get:{device.permissions.hostMayControlClient},set:{model.setVolumePermissions(device.id,hostMayControlClient:$0)}))
                Toggle("Client may change other Clients",isOn:Binding(get:{device.permissions.clientMayControlPeers},set:{model.setVolumePermissions(device.id,clientMayControlPeers:$0)}))
                Toggle("Other Clients may change this Client",isOn:Binding(get:{device.permissions.peersMayControlClient},set:{model.setVolumePermissions(device.id,peersMayControlClient:$0)}))
                Text("Client-to-Client control needs permission on both the controlling and receiving devices.").font(.caption).foregroundStyle(.secondary)
            }
        } else { Text("Update both devices to use remote volume control.").font(.caption).foregroundStyle(.secondary) }
    }
}
struct ClientVolumeView: View {
    @ObservedObject var model: ClientModel
    var body: some View {
        Section("Volume") {
            PlaybackVolumeView(title:"This device volume",volume:$model.outputVolume)
            if model.paired {
                PlaybackVolumeView(title:"Host volume",volume:Binding(get:{model.pendingHostVolume ?? model.hostVolume},set:{model.requestHostVolume($0)}))
                    .disabled(!model.canControlHostVolume)
                if !model.canControlHostVolume { Text("Ask the Host to allow volume control.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("These sliders adjust MusicSync playback only. System volume remains controlled by the device buttons or system settings.").font(.caption).foregroundStyle(.secondary)
        }
        if model.paired, !model.volumePeers.isEmpty {
            Section("Connected Devices") {
                ForEach(model.volumePeers) { device in
                    VStack(alignment:.leading) {
                        Label(device.name,systemImage:"hifispeaker")
                        PlaybackVolumeView(title:"Client volume",volume:Binding(get:{model.pendingPeerVolumes[device.id] ?? device.volume},set:{model.requestPeerVolume(device.id,volume:$0)})).disabled(!device.canControl)
                        if !device.canControl { Text("Ask the Host to allow volume control.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}
