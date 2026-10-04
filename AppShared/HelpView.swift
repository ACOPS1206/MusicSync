// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import SwiftUI
struct HelpView: View {
    @AppStorage("appLanguage") private var appLanguage = "system"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("iPhone as Host") {
                    Text("Open Host on iPhone, choose a music file or import a downloaded DRM-free song from Music Library, then start Host. On another iPhone or Mac, open Listen, connect, and wait for clock synchronization. Start Streaming on the Host. Each start plays the chosen file from the beginning.")
                    Text("Apple Music subscription audio is DRM protected and cannot be exported into the MusicSync PCM stream. The picker hides protected and cloud-only items. Download your own DRM-free music first, or import an audio file from Files.")
                    Text("For LiveContainer hosting, enable Direct connection only before starting Host if Bonjour advertising is blocked. Copy the iPhone Host address into the other device. Local Network access is still required; container permissions can also affect music library import.")
                }
                Section("Stereo pair") {
                    Text("In stereo pair mode, Test Tone plays a shared alignment pulse, then a lower left-only tone, then a higher right-only tone each second.")
                    Text("Choose Host left · Client right or Host right · Client left in Speaker layout before streaming. Place the devices on their assigned sides. Client Follow Host applies that assignment automatically. With multiple Clients, choose each output channel manually. Mono source files cannot create a true stereo image.")
                }
                Section("Getting started") {
                    Text("Connect Mac and iPhone to the same Wi-Fi. On Mac, start Host. On iPhone, find nearby Macs and choose your Mac. Wait for clock synchronization, then start streaming on Mac.")
                }
                Section("Test and speaker timing") {
                    Text("Use Test Tone on Mac first. Short pulses should sound together. Adjust iPhone timing trim if needed: positive values play iPhone later. Keep both devices on built-in speakers.")
                }
                Section("LiveContainer connection") {
                    Text("If automatic search reports NoAuth, start Host on Mac and copy Connection Address. Paste the actual address into Direct connection on iPhone, then connect. Allow Local Network for LiveContainer. The example text is not your actual Mac address.")
                }
                Section("Capture modes") {
                    Text("Synchronized mode captures and temporarily mutes source apps, then replays their sound with a shared delay. Stop streaming to restore normal audio. Monitor mode uses ScreenCaptureKit and leaves the original Mac sound ahead of iPhone.")
                }
                Section("Permissions") {
                    Text("Allow Local Network on both devices. Mac synchronized mode needs System Audio Recording; monitor mode needs Screen & System Audio Recording. MusicSync does not use the microphone. DRM-protected audio may be unavailable.")
                }
                Section("If audio stutters") {
                    Text("Keep both devices near the router, use a stable Wi-Fi connection, and keep MusicSync open during testing. If drops increase, the shared buffer adapts upward. Try stopping and starting streaming after changing networks. Avoid Bluetooth and AirPlay for timing tests.")
                }
                Section("What the numbers mean") {
                    Text("Shared buffer is the intentional playback delay. RTT is network round-trip time. Clock offset converts Mac timestamps to iPhone time. Jitter describes network variation. Clock uncertainty is an estimate, not a measured speaker error. Dropped frames arrived too late or could not be scheduled.")
                }
                Section("Sync warning") {
                    Text("Warnings use clock uncertainty, scheduling lateness, recent dropped packets, stale clock updates and stalled audio. They are estimates of risk, not a microphone measurement of the speakers. Clock offset alone is not a warning: devices can have very different uptimes.")
                    Text("Clock uncertainty above 60 ms must persist for 5 seconds. Scheduling error above 25 ms, drops above 10 packets/s, clock age above 5 seconds or audio age above 2 seconds must persist for 3 seconds. Each risk is tracked independently. Warnings clear after 3 seconds below a lower recovery threshold. Monitor mode remains an immediate warning.")
                }
                Section("Live Activity & Dynamic Island") {
                    Text("Enable the Live Activity toggle and connect or start Host while MusicSync is open. Lock Screen and Dynamic Island show role, session state, buffer, RTT, clock uncertainty and warnings. Metrics update about every five seconds, with faster state changes; iOS controls the actual display schedule. A stale label appears if updates stop.")
                    Text("Live Activities need the installed WidgetKit extension. LiveContainer may not register guest extensions, so this feature is not guaranteed there. Install with signing and preserve PlugIns/MusicSyncWidgets.appex for normal use. Re-sign both the app and extension with compatible bundle IDs. In-app status works without Live Activities. No push server is used.")
                }
                Section("License & attribution") {
                    Text("MusicSync by ACOPS1206")
                    Text("MIT License. Commercial use, modification and redistribution are allowed. Keep the copyright notice and license with copies or substantial portions. Derivative source disclosure is not required.")
                    Link("Source code", destination: URL(string: "https://github.com/ACOPS1206/MusicSync")!)
                    Link("Full license", destination: URL(string: "https://github.com/ACOPS1206/MusicSync/blob/main/LICENSE")!)
                }
                Section("Language") {
                    Picker("App language", selection: $appLanguage) {
                        Text("Follow System").tag("system")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "한국어").tag("ko")
                    }
                    Text("Choose English, Korean, or the system language. Live Activity follows the system app language. Reconnect after changing language to refresh connection messages.")
                }
            }.navigationTitle("Help")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 560, height: 650)
        #endif
    }
}
