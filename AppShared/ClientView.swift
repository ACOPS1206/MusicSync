// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import SwiftUI
struct ClientView: View {
    @State private var showingHelp = false
    @ObservedObject var model: ClientModel
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.status,systemImage:model.connected ? "waveform" : "wifi")
                    if !model.searching {
                        Text("Allow Local Network access to find a Host and receive audio directly over Wi-Fi. MusicSync does not use an internet server or your microphone.").foregroundStyle(.secondary)
                        Button("Find Nearby Hosts") { model.search() }.buttonStyle(.glassProminent)
                    }
                }
                Section("Nearby Hosts") {
                    if model.nearby.isEmpty && model.searching { HStack { ProgressView(); Text("Searching…") } }
                    ForEach(model.nearby) { mac in
                        Button { model.connect(mac) } label: {
                            HStack {
                                Label(mac.name,systemImage:"laptopcomputer")
                                Spacer()
                                if model.selectedName == mac.name { Image(systemName:model.connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath") }
                            }
                        }
                    }
                }
                Section("Direct connection / LiveContainer") {
                    TextField("MacBook.local:port", text: $model.directAddress)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        #endif
                        .onSubmit { model.connectDirect() }
                    Button("Connect to Address") { model.connectDirect() }
                        .buttonStyle(.glass).disabled(model.directAddress.isEmpty)
                    Text("On the Host, start hosting and copy Connection Address. Paste it here if Bonjour discovery is unavailable. Local Network access is still required.").font(.caption).foregroundStyle(.secondary)
                    #if os(iOS)
                    if model.discoveryDenied {
                        Button("Open App Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    #endif
                }
                if model.selectedName != nil {
                    Section("Latency & Synchronization") {
                        metric("Shared buffer",model.latency)
                        metric("RTT",model.rtt)
                        metric("Clock offset (Host − Client)",model.offset)
                        metric("Network jitter",model.jitter)
                        metric("Clock uncertainty estimate",model.uncertainty)
                        LabeledContent("Dropped frames",value:String(model.dropped))
                        Text("Clock uncertainty is an estimate, not a measured speaker-to-speaker error. Keep both devices on built-in speakers.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Speaker layout") {
                        Picker("Output channel", selection: $model.channelOverride) {
                            ForEach(ChannelSelection.allCases) { channel in Text(channel.title).tag(channel) }
                        }
                        Text("Follow Host applies the Host stereo pair assignment. Select Left or Right manually when more than two devices are connected.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Speaker calibration") {
                        LabeledContent("Client timing trim",value:String(format:"%+.0f ms",model.calibrationMS))
                        Slider(value:$model.calibrationMS,in:-30...30,step:1)
                        Text("Use the Host test pulses to adjust residual speaker delay. Positive values play this Client later.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section { Button("Disconnect",role:.destructive) { model.disconnect() }.buttonStyle(.glass) }
                }
                if let error = model.error { Section("Attention") { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("MusicSync")
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
            } }
            .sheet(isPresented: $showingHelp) { HelpView() }
        }
    }
    private func metric(_ title: String, _ seconds: Double) -> some View {
        LabeledContent(tr(title),value:String(format:"%.1f ms",seconds * 1000)).monospacedDigit()
    }
}
