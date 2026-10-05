# MusicSync for Windows, Android and Linux — 0.9.0 / build 12

[한국어](README.ko.md) · [Main README](../README.md)

These are real Host/Listen applications with a shared Kotlin protocol implementation and **Material 3 Expressive** Compose UI. Apple apps continue using SwiftUI/Liquid Glass. Use the same LAN; connect through `_musicsync._tcp.local.` Bonjour/DNS-SD, compare the independently calculated eight-digit TLS codes, confirm on the Client, and approve on the Host. All three ports can host and receive; Mac and iPhone use the existing protocol.

## Layout

- `core`: interoperable JSON framing, TLS 1.3, P-256 identities, exporter-bound pairing/HMAC, NTP clock estimation, bounded jitter buffer, continuous scheduled PCM output, Host-owned permissions, WAV decode/resampling and session state. This is a JVM library usable by Android and desktop; the Swift package is unchanged.
- `ui`: one Compose source compiled for Android and desktop, bilingual English/Korean, real device controls above metrics, logs/help, channel assignment and permission settings. Uses experimental `MaterialExpressiveTheme` from pinned Material3 alpha versions, with rounded components, expressive motion, light/dark themes and standard Material controls.
- `android`: AudioTrack hardware timestamps, MediaProjection/AudioPlaybackCapture, encrypted Android Keystore credential storage and foreground audio/projection service.
- `desktop`: JavaSound output frame clock, Windows WASAPI bridge, Linux PulseAudio/PipeWire monitor and private local identity file.
- `native`: pinned miniaudio Windows output loopback bridge, loaded with JNA and embedded in the Windows app.
- `../.github/workflows/ports.yml`: Android APK, Windows MSI/portable ZIP, Linux DEB/RPM/portable ZIP, Core tests and real Swift/Kotlin TLS interoperability.

## Audio modes and synchronization

**PCM WAV file hosting is the synchronized mode on all ports.** Choose a mono/stereo PCM16/24/32 or Float32 WAV (8–192 kHz). It is decoded incrementally, linearly resampled to 48 kHz interleaved Float32 stereo, timestamped on one continuous sample timeline and played locally and remotely at that timeline. No full-file memory loading. Both original channels stay on the wire; each device can select Stereo/Left/Right/Follow Host. Pause, seek, playlists, AAC/MP3 file decoding and high-quality band-limited resampling are not implemented in these ports.

**System sharing is monitor mode.** Windows uses default-output WASAPI loopback. Linux uses the current PulseAudio/PipeWire-Pulse default sink monitor (`pactl`/`parec`). Android uses a user-approved MediaProjection token and AudioRecord playback capture, excluding MusicSync's UID. Android source apps can reject capture; DRM/protected content can yield silence. Monitor mode sends captured sound to receivers but **does not mute/delay the source app's existing local output**, so that original speaker is ahead. It does not add delayed local replay. Use WAV hosting when Host and Clients must be synchronized. Windows/Linux monitor captures may include the Host identification tone; unlike Android's UID exclusion, it is not per-process capture.

Clients use repeated four-timestamp probes. The lowest eight RTT samples from the latest 32 estimate Host-minus-Client clock offset; RTT variance estimates network jitter. After eight samples the receiver queues frames, rejects invalid/duplicate/late/old-epoch frames, and schedules against the converted PTS. Queue limit: 100 packets. Shared delay starts at 180 ms and can increase to 500 ms according to Client RTT/jitter/output needs and 20 ms requests after new late/drop events, never decreases midstream. Every packet carries version/sequence/epoch/PTS/sample-rate/channel-count/frame-count/payload; JSON is length-prefixed and Float32 PCM is little-endian/base64, identical to Swift.

The player continually writes a frame timeline including silence and maps audio output positions to monotonic time. Android uses AudioTrack's hardware presentation timestamp; desktop uses JavaSound's processed frame counter sampled against `System.nanoTime()` (less precise, driver-dependent). One-second timestamp updates gently discipline output timing. This is not a high-quality variable-rate PLL; hardware drift, scheduling stalls and route changes can still cause small gaps/skips. ±30 ms manual trim is available. **180–250 ms is a design delay budget on a healthy LAN, not a physical measurement or an acoustic accuracy guarantee.** Bluetooth, speaker routing and Wi-Fi asymmetry add error. Desktop audio route changes need reconnect/restart.

Warnings start only after 30 seconds of clock/stream warmup; excessive uncertainty (>60 ms), scheduling error (>25 ms) or stale streaming audio (>2 s) must persist for five seconds. The UI shows current RTT, offset, jitter, uncertainty, shared buffer, output latency estimate, scheduling error, queue and drops. Large clock offset by itself is normal and does not trigger a warning.

## Security and device controls

TLS 1.3 only, no plaintext fallback or TLS session resumption. Bouncy Castle's TLS implementation exposes the same 32-byte `EXPORTER-MusicSync-pairing-v2` key as Apple Network.framework. Code = first eight SHA-256 digest bytes as an unsigned big-endian number, modulo 100,000,000. Humans compare the full code on both devices. Host approval releases a random 256-bit pairing secret; remembered connections prove possession with HMAC-SHA256 over the nonce, installation IDs and fresh TLS exporter binding. The Client pins SHA-256 of the uncompressed P-256 public point and refuses changed keys. Only pairing messages are accepted before authentication. Pairing expires after 60 s. First connection failures retry at two-second intervals at most three times; established connections reconnect automatically.

Android stores credentials with Keystore AES-GCM and disables backup. Windows/Linux store them in `~/.musicsync/identity.properties` (POSIX mode 0600 / folder 0700 where supported). This desktop file contains private credentials and must not be shared; Windows protection relies on the user profile ACL. A native Windows/Linux credential-vault adapter is future work. There is no certificate-authority/network trust modification or internet server. Bonjour discovery remains visible on the LAN.

Host device rows show actual reported playback channel/state and volume. Host can change channel, play a selected device's identification tone, revoke pairings and control Client volume. Peer-to-peer controls relay through the authenticated Host and require both sender and recipient permissions; all peer privileges default off. Channel/volume displays update from actual reports, rather than assuming a sent command succeeded. Commands received by an iPhone may be declined under its policy. Host permissions persist with the pairing. Stereo assignment changes affect newly rendered frames; PCM already being rendered may finish first. Identification has a two-second rate limit.

Android local and remote volume uses public `AudioManager.STREAM_MUSIC` **system volume**, with device-defined discrete steps. Windows/Linux sliders currently change **MusicSync playback gain**. Existing Mac volume uses system output and iOS remote volume remains app gain; those OS rules continue to apply. The port UI labels local volume scope. The Host must authorize remote volume control.

Session logs retain up to 300 selected events in memory with selectable text and Clear. Codes, secret material and raw PCM are not logged. Version/build, English/Korean switch, help and GitHub link are present. No Dynamic Island equivalent is implemented; Android uses an ongoing foreground session notification. Keep the app open for first pairing. Android's OS may still stop sessions due to battery policy, projection revocation or force-stop.

## Build and install

JDK 17 and Gradle **8.13**. Open `ports/` in Android Studio/IntelliJ; Android requires SDK 36, build-tools 36.0.0 and Android 10/API 29 or newer. Windows/Linux first packaged target is x86_64. Linux ARM and Windows ARM packages are not generated yet.

```sh
cd ports
gradle :core:test :android:assembleDebug
# On Linux or Windows; skip Android SDK configuration if only building desktop:
gradle -PwithAndroid=false :desktop:run
gradle -PwithAndroid=false :desktop:packageDistributionForCurrentOS
```

For Windows capture, build and embed the bridge before packaging:

```powershell
cmake -S ports/native -B ports/native/build -A x64
cmake --build ports/native/build --config Release
New-Item -ItemType Directory -Force ports/desktop/src/main/resources/native
Copy-Item ports/native/build/Release/musicsync_capture.dll ports/desktop/src/main/resources/native/
```

Linux system sharing requires `pactl` and `parec` from PulseAudio utilities plus a running PulseAudio or PipeWire-Pulse server. On Arch, install `pipewire-pulse`, `pipewire-alsa`, and `libpulse`; on Debian/Ubuntu install `pulseaudio-utils` and suitable ALSA/PulseAudio routing. Portable Linux ZIP includes Java: extract while preserving executable permissions and launch `MusicSync/bin/MusicSync`; a system Java install is unnecessary. Permit local TCP and UDP 5353/mDNS through the firewall. Multicast-restricting Wi-Fi/VPNs may require pasting the displayed Host address.

Actions → **Build MusicSync ports** → successful run → Artifacts:

| Artifact | Contents |
| --- | --- |
| `MusicSync-Android` | `MusicSync-Android.apk`, installable, CI debug signed |
| `MusicSync-Windows` | `MusicSync-Windows.zip`, Windows MSI, bundled JRE and capture DLL |
| `MusicSync-Linux` | `MusicSync-Linux.zip`, DEB/RPM, bundled JRE |
| `MusicSync-Windows-tests`, `MusicSync-Linux-tests` | Core HTML test reports |

Windows binaries are not Authenticode-signed. Android debug APK is for sideload testing; a future independently signed release requires uninstalling the debug build or using the same signing key. The default CI debug signing identity may change between runners, so an update can require uninstalling and pairing again. Back up no private credentials. APK signing/layout and desktop runtime/launcher presence are checked in CI. The Apple workflow continues producing the original IPA/Mac app independently.

CI validates compile/build, packaging, real TLS connections, exporter equality/pins/HMAC, framing, clock estimation, queue behavior, WAV decode, plus both Kotlin Host → Swift Client and Swift Host → Kotlin Client connections with real scheduled PCM. Physical Android/Windows/Linux speaker output, permissions, firewall/Bonjour reliability and acoustic timing must be tested on user hardware. No sample-accurate or ±3 ms measurement is claimed.

## Dependencies and license

MusicSync source remains MIT. Compose/Kotlin libraries, Bouncy Castle (TLS exporter interoperability), JmDNS (desktop/Android DNS-SD), JNA and miniaudio (Windows capture) are used because Apple-only frameworks cannot implement these ports. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and bundled licenses. Experimental Expressive APIs are pinned; SDK/API changes are validated by CI instead of assuming compatibility.

## 0.9.1 / build 13 — Windows output timing correction

Windows playback now uses a native event-driven WASAPI shared-mode renderer instead of JavaSound. It queries `IAudioClock` position/frequency and its QPC sample time, maps QPC to the JVM monotonic clock without assuming their epochs match, and accounts for prefilled startup silence and underrun silence. The requested endpoint buffer is 20 ms (actual capacity is device-dependent). There is no silent fallback to the old mixer clock; output failures identify the WASAPI HRESULT in logs. Linux retains JavaSound.

The shared scheduler samples output clocks every 100 ms, re-anchors after large hardware timeline discontinuities, and schedules further ahead for routes with long reported latency. Other network, authentication and channel protocols are unchanged. The original system sound in monitor mode remains undelayed; this fix concerns MusicSync's own local/client playback. CI validates native compilation, clock unit conversion, startup/underrun timeline handling and protocol interoperability. Physical speaker alignment still needs comparison on the user's Windows device; built-in/wired speakers are the best starting point, since Bluetooth and audio enhancement pipelines may add latency not reported by the driver. Please record the role/source, output device, relative delay, RTT, buffer, scheduling error and logs when reporting a timing problem.
