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
                Section("Connected Devices") {
                    if model.devices.isEmpty { Text("Connect from MusicSync on another iPhone or Mac.").foregroundStyle(.secondary) }
                    ForEach(model.devices) { device in
                        VStack(alignment:.leading,spacing:6) {
                            Label(device.name,systemImage:"iphone")
                            Text(device.ready ? tr("Clock synchronized") : tr("Synchronizing…")).foregroundStyle(.secondary)
                            if device.ready {
                                Text(String(format:tr("RTT %.1f ms · Clock %+.1f ms"),device.rtt * 1000,device.offset * 1000)).monospacedDigit()
                                Text(String(format:tr("Clock uncertainty ≥ %.1f ms"),(device.rtt / 2 + device.jitter) * 1000)).font(.caption)
                            }
                        }
                    }
                }
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
            }.formStyle(.grouped).navigationTitle("MusicSync")
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
