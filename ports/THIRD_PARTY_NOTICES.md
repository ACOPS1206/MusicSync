# Third-party software in MusicSync ports

MusicSync source: MIT, Copyright (c) 2026 ACOPS1206. Preserve [../LICENSE](../LICENSE).

| Component | Purpose | License / upstream |
| --- | --- | --- |
| Kotlin, coroutines, kotlinx.serialization | JVM code, state, JSON | Apache-2.0 — https://github.com/JetBrains/kotlin / https://github.com/Kotlin/kotlinx.coroutines / https://github.com/Kotlin/kotlinx.serialization |
| Compose Multiplatform / AndroidX Compose | Material 3 Expressive UI | Apache-2.0 — https://github.com/JetBrains/compose-multiplatform / https://android.googlesource.com/platform/frameworks/support |
| Bouncy Castle 1.81 | TLS 1.3 exporter and X.509 | MIT — https://github.com/bcgit/bc-java/blob/r1rv81/LICENSE.html |
| JmDNS 3.6.1 | DNS-SD / Bonjour | Apache-2.0 — https://github.com/jmdns/jmdns |
| JNA 5.17.0 | Windows capture bridge | Apache-2.0 option — https://github.com/java-native-access/jna |
| miniaudio 0.11.23 | WASAPI loopback | Public-domain option — https://github.com/mackron/miniaudio |
| Eclipse Temurin / OpenJDK 17 runtime | Portable desktop runtime | GPL-2.0 with Classpath Exception; bundled runtime legal files — https://adoptium.net / https://openjdk.org |
| Skiko / Skia (Compose transitive) | Desktop rendering | Apache-2.0 / BSD-3-Clause; upstream and embedded notices — https://github.com/JetBrains/skiko / https://skia.googlesource.com/skia |

Selected dependency JARs preserve their embedded META-INF licenses/notices. The app embeds the MusicSync license, Apache 2.0 license and Bouncy Castle MIT license as Java resources. The bundled Java runtime includes its legal directory; its independent license does not change MusicSync source from MIT. This repository does not relicense third-party dependencies. No third-party source is represented as original MusicSync code.
