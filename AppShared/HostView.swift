// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
import MediaPlayer
#endif
struct HostView: View {
    @State private var showingHelp = false
    #if os(iOS)
    @State private var importingFile = false
    @State private var pickingMusic = false
    @State private var importingMusic = false
    #endif
    @ObservedObject var model: HostModel
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.status, systemImage:model.streaming ? "waveform" : "antenna.radiowaves.left.and.right")
                    #if os(iOS)
                    Toggle("Direct connection only (LiveContainer)", isOn: $model.directOnly).disabled(model.active)
                    #endif
                    Button(model.active ? tr("Stop Host") : tr("Start Host")) {
                        if model.active { model.stopHost() } else { model.startHost() }
                    }.buttonStyle(.glassProminent).disabled(model.busy)
                    if model.active { Label("TLS 1.3 encrypted",systemImage:"lock.shield") }
                    if !model.connectionAddress.isEmpty {
                        LabeledContent("Direct connection", value: model.connectionAddress).textSelection(.enabled)
                        Button("Copy Connection Address") {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.connectionAddress, forType: .string)
                            #else
                            UIPasteboard.general.string = model.connectionAddress
                            #endif
                        }.buttonStyle(.glass)
                    }
                }
                SyncWarningView(issues:model.syncIssues,input:model.healthInput,rtt:model.timingDevice?.rtt ?? 0,jitter:model.timingDevice?.jitter ?? 0,remoteIssues:Array(Set(model.devices.flatMap(\.syncIssues))))
                if model.active { RealtimeStatusView(phase:model.sessionPhase,traffic:model.traffic,drops:model.localDrops,schedulingErrorMS:model.schedulingErrorMS,updated:model.lastUpdated,timing:TimingSummaryView(latency:model.latency,rtt:model.timingDevice?.rtt ?? 0,offset:model.timingDevice?.offset ?? 0,jitter:model.timingDevice?.jitter ?? 0,uncertainty:model.healthInput.uncertainty,drops:model.localDrops,peerName:model.timingDevice?.name)) }
                LiveActivitySettingsView()
                if model.devices.contains(where: { !$0.gate.approved }) {
                    Section("Pairing requests") {
                        Text("Compare all eight digits on both devices. The Client must confirm the match before you approve. Unapproved devices receive no audio.").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.devices.filter { !$0.gate.approved }) { device in
                            VStack(alignment:.leading,spacing:8) {
                                Label(device.name,systemImage:"iphone")
                                if let code = device.pairingCode {
                                    Text(verbatim:code).font(.title2.monospacedDigit()).textSelection(.enabled)
                                    if !device.clientConfirmed { Text("Waiting for Client code confirmation…").font(.caption).foregroundStyle(.secondary) }
                                    HStack {
                                        Button("Approve") { model.approveDevice(device.id) }.buttonStyle(.glassProminent).disabled(!device.clientConfirmed)
                                        Button("Reject",role:.destructive) { model.rejectDevice(device.id) }.buttonStyle(.glass)
                                    }
                                } else { Text("Authenticating…").foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section("Connected Devices") {
                    if !model.devices.contains(where: { $0.gate.approved }) { Text("Connect from MusicSync on another iPhone or Mac.").foregroundStyle(.secondary) }
                    ForEach(model.devices.filter { $0.gate.approved }) { device in
                        VStack(alignment:.leading,spacing:8) {
                            Label(device.name,systemImage:"iphone")
                            Label("TLS 1.3 encrypted",systemImage:"lock.shield").font(.caption)
                            Text(device.ready ? tr("Clock synchronized") : tr("Synchronizing…")).foregroundStyle(.secondary)
                            LabeledContent("Current output channel",value:device.effectiveChannel.title)
                            if model.streaming && device.ready { Text(tr(device.playbackState)).foregroundStyle(.secondary) }
                            Picker("Output channel",selection:Binding(
                                get:{ model.devices.first(where: { $0.id == device.id }).map { $0.pendingChannel ?? $0.channelSelection } ?? .automatic },
                                set:{ model.setChannel(device.id,selection:$0) })) {
                                ForEach(ChannelSelection.allCases) { channel in Text(channel.title).tag(channel) }
                            }
                            if device.pendingChannel != nil { Text("Waiting for channel confirmation…").font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button("Play Identification Tone") { model.identifyDevice(device.id) }.buttonStyle(.glass)
                                    .disabled(Date().timeIntervalSince(device.lastIdentify) < 2)
                                Button("Remove Pairing",role:.destructive) { model.forgetDevice(device.id) }.buttonStyle(.glass)
                            }
                            if device.identifyingUntil > Date() { Label("Playing identification tone",systemImage:"speaker.wave.3.fill").foregroundStyle(.secondary) }
                            if !device.syncIssues.isEmpty { Label("Client reports sync risk",systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            if device.ready {
                                Text(String(format:tr("RTT %.1f ms · Clock %+.1f ms"),device.rtt * 1000,device.offset * 1000)).monospacedDigit()
                                Text(String(format:tr("Clock uncertainty ≥ %.1f ms"),(device.rtt / 2 + device.jitter) * 1000)).font(.caption)
                            }
                        }
                    }
                    Button("Identify This Host") { model.identifyHost() }.buttonStyle(.glass).disabled(!model.active)
                    Text("Channel changes affect upcoming audio after the queued buffers finish. Identification plays three short chirps only on the selected device.").font(.caption).foregroundStyle(.secondary)
                }
                if let notice = model.pairingNotice { Section("Pairing storage") { Text(notice).font(.caption).foregroundStyle(.secondary) } }
                Section("Audio") {
                    #if os(macOS)
                    Picker("Capture",selection:$model.mode) {
                        Text("Synchronized • CoreAudio tap").tag(0)
                        Text("Monitor • ScreenCaptureKit").tag(1)
                    }.disabled(model.streaming || model.busy)
                    #else
                    Button("Choose Music File") { importingFile = true }.disabled(model.streaming || importingMusic)
                    Button("Import from Music Library") {
                        MPMediaLibrary.requestAuthorization { result in DispatchQueue.main.async {
                            if result == .authorized { pickingMusic = true }
                            else { model.error = AudioSourceFailure.musicDenied.localizedDescription }
                        } }
                    }.disabled(model.streaming || importingMusic)
                    if importingMusic { ProgressView("Importing music…") }
                    if !model.fileName.isEmpty { LabeledContent("Selected music", value: model.fileName) }
                    Text("Music library import supports downloaded, DRM-free tracks. Apple Music subscription songs and cloud-only tracks cannot be transmitted. Use Files for your own MP3, AAC, WAV or other supported audio.").font(.caption).foregroundStyle(.secondary)
                    #endif
                    Picker("Speaker layout", selection: $model.layout) {
                        ForEach(SpeakerLayout.allCases) { layout in Text(layout.title).tag(layout) }
                    }.disabled(model.streaming || model.mode == 1)
                    Text("Place Host on the selected side and the Client on the other. Both channels are sent; each device plays its assigned channel through its speakers.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Host timing trim", value: String(format: "%+.0f ms", model.calibrationMS))
                    Slider(value: $model.calibrationMS, in: -30...30, step: 1)
                    LabeledContent("Format",value:tr("48 kHz · Stereo · Float32 PCM"))
                    LabeledContent("Shared buffer",value:String(format:"%.0f ms",model.latency * 1000))
                    #if os(macOS)
                    if model.mode == 1 { Text("Monitor mode leaves the original Mac output audible. It cannot delay that output to match iPhone.").font(.caption).foregroundStyle(.secondary) }
                    #endif
                    HStack {
                        Button(model.streaming ? tr("Stop Streaming") : tr("Start Streaming")) {
                            Task { if model.streaming { await model.stopStreaming() } else { await model.startStreaming() } }
                        }.buttonStyle(.glassProminent)
                        if !model.streaming {
                            Button("Test Tone") { Task { await model.startStreaming(testTone:true) } }.buttonStyle(.glass)
                        }
                    }.disabled(!model.active || model.busy)
                }
                #if os(macOS)
                Section("Permissions & output") {
                    Text("Local Network discovers and streams to your iPhone. Synchronized mode needs System Audio Recording; monitor mode needs Screen & System Audio Recording. No microphone is used.")
                    Text("Select Mac built-in speakers in System Settings. While synchronized capture runs, source apps are muted by the tap and MusicSync replays their audio with a shared delay. Stopping restores normal audio.").foregroundStyle(.secondary)
                }.font(.callout)
                #else
                Section("Permissions & output") {
                    Text("Host uses Local Network to advertise and send music, and Media & Apple Music permission only when you import from your library. No microphone or other app audio is captured. Keep both devices on built-in speakers.")
                    Text("LiveContainer may block advertising this Bonjour service. Copy the Host address and connect directly from the other device. The container still needs Local Network permission.").foregroundStyle(.secondary)
                }
                #endif
                if let error = model.error { Section("Attention") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                ProjectLinkView()
            }.formStyle(.grouped).navigationTitle(sessionTitle(model.sessionPhase))
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
            } }
            .sheet(isPresented: $showingHelp) { HelpView() }
            #if os(iOS)
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.audio]) { result in
                do {
                    let original = try result.get()
                    let url = try MusicImport.file(original)
                    replaceFile(url, name: original.lastPathComponent)
                } catch { model.error = error.localizedDescription }
            }
            .sheet(isPresented: $pickingMusic) {
                MusicLibraryPicker { item in
                    pickingMusic = false
                    guard let item else { return }
                    importingMusic = true
                    Task {
                        defer { importingMusic = false }
                        do { let url = try await MusicImport.library(item); replaceFile(url, name: item.title ?? tr("Music file")) }
                        catch { model.error = error.localizedDescription }
                    }
                }
            }
            #endif
        }
    }
    #if os(iOS)
    private func replaceFile(_ url: URL, name: String) {
        if let old = model.fileURL { try? FileManager.default.removeItem(at: old) }
        model.fileURL = url; model.fileName = name; model.error = nil
    }
    #endif
}
