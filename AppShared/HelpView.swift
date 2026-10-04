import SwiftUI
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
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
                Section("Language") {
                    Text("MusicSync follows the system app language and supports English and Korean. In LiveContainer, the host language configuration may affect the guest. Restart the app after changing language.")
                }
            }.navigationTitle("Help")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 560, height: 650)
        #endif
    }
}
