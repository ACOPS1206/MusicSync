// SPDX-License-Identifier: MIT
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
                if model.selectedName != nil {
                    Section("Connected Host") {
                        LabeledContent("Host name",value:model.connectedHostName.isEmpty ? (model.selectedName ?? "") : model.connectedHostName)
                        if !model.hostAddress.isEmpty {
                            LabeledContent("Host connection address",value:model.hostAddress).textSelection(.enabled)
                            Button("Copy Host Address") {
                                #if os(macOS)
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.hostAddress,forType:.string)
                                #else
                                UIPasteboard.general.string = model.hostAddress
                                #endif
                            }.buttonStyle(.glass)
                        }
                        if !model.hostServiceName.isEmpty {
                            LabeledContent("Bonjour service",value:model.hostServiceName + " · _musicsync._tcp.local").textSelection(.enabled)
                        }
                        if model.encrypted { Label("TLS 1.3 encrypted",systemImage:"lock.shield") }
                        if !model.paired {
                            if !model.pairingCode.isEmpty {
                                LabeledContent("Pairing code") { Text(verbatim:model.pairingCode).font(.title2.monospacedDigit()).textSelection(.enabled) }
                                Text("Compare all eight digits on both devices. Confirm here, then approve this device on the Host. Never approve different codes.").font(.caption).foregroundStyle(.secondary)
                            Button(model.codeConfirmed ? tr("Code confirmed • waiting for Host") : tr("Codes Match")) { model.confirmPairingCode() }.buttonStyle(.glassProminent).disabled(model.codeConfirmed)
                            } else { Text("Authenticating with Host…").foregroundStyle(.secondary) }
                            Button("Forget This Host",role:.destructive) { model.forgetHost() }.buttonStyle(.glass)
                        } else {
                            Label("Paired",systemImage:"checkmark.shield")
                            Button("Identify Host") { model.identifyHost() }.buttonStyle(.glass)
                            Button("Forget This Host",role:.destructive) { model.forgetHost() }.buttonStyle(.glass)
                        }
                        if let notice = model.pairingNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                SyncWarningView(issues:model.syncIssues,input:model.healthInput,rtt:model.rtt,jitter:model.jitter)
                if model.selectedName != nil {
                    RealtimeStatusView(phase:model.sessionPhase,traffic:model.traffic,drops:model.dropped,schedulingErrorMS:model.schedulingErrorMS,updated:model.lastUpdated,timing:TimingSummaryView(latency:model.latency,rtt:model.rtt,offset:model.offset,jitter:model.jitter,uncertainty:model.uncertainty,drops:model.dropped))
                    Section("Audio queue") {
                        LabeledContent("Buffered packets", value: String(model.bufferCount))
                        LabeledContent("Scheduled ahead", value: String(format:"%.0f ms",model.bufferAheadMS))
                    }
                }
                LiveActivitySettingsView()
                Section("Nearby Hosts") {
                    if model.nearby.isEmpty && model.searching { HStack { ProgressView(); Text("Searching…") } }
                    ForEach(model.nearby) { mac in
                        Button { model.connect(mac) } label: {
                            HStack {
                                Label(mac.name,systemImage:"laptopcomputer")
                                Spacer()
                                if model.selectedName == mac.name { Image(systemName:model.paired ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath") }
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
                    Section("Speaker layout") {
                        LabeledContent("Current output channel",value:model.effectiveChannel.title)
                        if model.identifyingUntil > Date() { Label("Playing identification tone",systemImage:"speaker.wave.3.fill").foregroundStyle(.secondary) }
                        Picker("Output channel", selection: $model.channelOverride) {
                            ForEach(ChannelSelection.allCases) { channel in Text(channel.title).tag(channel) }
                        }
                        Text("Follow Host applies the Host stereo pair assignment. You can choose a channel here, and the Host can change this selection remotely. Changes affect upcoming audio after queued buffers finish.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Speaker calibration") {
                        LabeledContent("Client timing trim",value:String(format:"%+.0f ms",model.calibrationMS))
                        Slider(value:$model.calibrationMS,in:-30...30,step:1)
                        Text("Use the Host test pulses to adjust residual speaker delay. Positive values play this Client later.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section { Button("Disconnect",role:.destructive) { model.disconnect() }.buttonStyle(.glass) }
                }
                if let error = model.error { Section("Attention") { Text(error).foregroundStyle(.red) } }
                ProjectLinkView()
            }.navigationTitle(sessionTitle(model.sessionPhase))
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
            } }
            .sheet(isPresented: $showingHelp) { HelpView() }
        }
    }
}
