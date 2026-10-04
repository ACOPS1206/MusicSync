import SwiftUI
@main struct MusicSyncMacApp: App {
    @StateObject private var model = HostModel()
    var body: some Scene {
        WindowGroup("MusicSync") { HostView(model: model).frame(minWidth: 480, minHeight: 580) }
        .defaultSize(width: 540, height: 700)
    }
}
struct HostView: View {
    @State private var showingHelp = false
    @ObservedObject var model: HostModel
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.status, systemImage:model.streaming ? "waveform" : "antenna.radiowaves.left.and.right")
                    Button(model.active ? tr("Stop Host") : tr("Start Host")) {
                        if model.active { model.stopHost() } else { model.startHost() }
                    }.buttonStyle(.glassProminent).disabled(model.busy)
                    if !model.connectionAddress.isEmpty {
                        LabeledContent("Direct connection", value: model.connectionAddress).textSelection(.enabled)
                        Button("Copy Connection Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.connectionAddress, forType: .string)
                        }.buttonStyle(.glass)
                    }
                }
                Section("Connected Devices") {
                    if model.devices.isEmpty { Text("Connect from MusicSync on your iPhone.").foregroundStyle(.secondary) }
                    ForEach(model.devices) { device in
                        VStack(alignment:.leading,spacing:6) {
                            Label(device.name,systemImage:"iphone")
                            Text(device.ready ? tr("Clock synchronized") : "Synchronizing…").foregroundStyle(.secondary)
                            if device.ready {
                                Text(String(format:tr("RTT %.1f ms · Clock %+.1f ms"),device.rtt * 1000,device.offset * 1000)).monospacedDigit()
                                Text(String(format:tr("Clock uncertainty ≥ %.1f ms"),(device.rtt / 2 + device.jitter) * 1000)).font(.caption)
                            }
                        }
                    }
                }
                Section("Audio") {
                    Picker("Capture",selection:$model.mode) {
                        Text("Synchronized • CoreAudio tap").tag(0)
                        Text("Monitor • ScreenCaptureKit").tag(1)
                    }.disabled(model.streaming || model.busy)
                    LabeledContent("Format",value:tr("48 kHz · Stereo · Float32 PCM"))
                    LabeledContent("Shared buffer",value:String(format:"%.0f ms",model.latency * 1000))
                    if model.mode == 1 { Text("Monitor mode leaves the original Mac output audible. It cannot delay that output to match iPhone.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button(model.streaming ? tr("Stop Streaming") : tr("Start Streaming")) {
                            Task { if model.streaming { await model.stopStreaming() } else { await model.startStreaming() } }
                        }.buttonStyle(.glassProminent)
                        if !model.streaming {
                            Button("Test Tone") { Task { await model.startStreaming(testTone:true) } }.buttonStyle(.glass)
                        }
                    }.disabled(!model.active || model.busy)
                }
                Section("Permissions & output") {
                    Text("Local Network discovers and streams to your iPhone. Synchronized mode needs System Audio Recording; monitor mode needs Screen & System Audio Recording. No microphone is used.")
                    Text("Select Mac built-in speakers in System Settings. While synchronized capture runs, source apps are muted by the tap and MusicSync replays their audio with a shared delay. Stopping restores normal audio.").foregroundStyle(.secondary)
                }.font(.callout)
                if let error = model.error { Section("Attention") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }.formStyle(.grouped).navigationTitle("MusicSync")
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
            } }
            .sheet(isPresented: $showingHelp) { HelpView() }
        }
    }
}
