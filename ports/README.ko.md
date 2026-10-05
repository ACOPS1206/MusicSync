# MusicSync Windows·Android·Linux — 0.9.0 / 빌드 12

[English](README.md) · [기존 앱 설명](../README.ko.md)

세 플랫폼에 실제 **호스트/수신 앱**을 추가했습니다. Kotlin 공통 통신·오디오 예약 코드와 **Material 3 Expressive** Compose UI를 사용합니다. 기존 Mac·iOS는 SwiftUI/Liquid Glass를 유지하며, 동일 프로토콜로 연결합니다.

## 사용

1. 모든 기기를 같은 LAN에 연결하세요. 호스트 탭에서 호스트를 시작합니다.
2. 수신 탭에서 자동 검색된 호스트를 선택합니다. Bonjour 서비스는 기존과 같은 `_musicsync._tcp`입니다.
3. 양쪽에서 **8자리 전체 코드**를 비교하고 클라이언트에서 코드 일치 확인, 호스트에서 승인합니다. 승인 전에는 오디오·시계·기기 제어를 허용하지 않습니다.
4. 시계 동기화 후 호스트에서 **WAV 파일 선택 후 스트리밍**을 누릅니다. WAV 호스팅은 호스트와 클라이언트를 같은 재생 타임라인에 맞춥니다.
5. 스피커 배치에서 좌/우/스테레오/호스트 설정 따르기를 선택합니다. 호스트 기기 목록에서는 실제 보고 채널과 재생 상태를 확인하고 변경·식별음·권한·페어링 삭제를 제어합니다.
6. 클라이언트 간 채널·식별음·볼륨 제어에는 호스트에서 조작 기기와 대상 기기의 권한을 모두 켜야 합니다. 기본값은 차단입니다.

## 오디오와 동기화 범위

**파일 호스팅이 세 플랫폼의 동기화 모드입니다.** 1~2채널, 8~192kHz PCM16/24/32 또는 Float32 WAV를 조금씩 읽고 선형 리샘플링해 48kHz 스테레오 Float32로 전송합니다. 전체 파일을 메모리에 올리지 않습니다. 로컬 출력과 원격 출력에 같은 PTS를 사용합니다. MP3/AAC 디코딩, 탐색·재생목록·일시정지와 고품질 대역 제한 리샘플러는 아직 없습니다.

**시스템 오디오 공유는 모니터 모드입니다.** Windows는 기본 출력의 WASAPI 루프백, Linux는 PulseAudio/PipeWire-Pulse 기본 sink의 monitor(`pactl`/`parec`), Android는 사용자 승인 MediaProjection과 AudioPlaybackCapture를 사용합니다. Android는 자신의 UID를 제외하며 원본 앱이 캡처를 허용해야 합니다. DRM은 무음일 수 있습니다. 세 포트의 시스템 공유는 원본 앱의 로컬 출력을 지연/음소거하지 않으므로 **호스트 스피커가 먼저 들립니다**. 중복 로컬 재생도 추가하지 않습니다. 호스트까지 맞추려면 WAV 호스팅을 사용하세요. Windows/Linux 모니터는 프로세스 제외가 아니어서 호스트 식별음도 캡처될 수 있습니다.

32개 시계 표본 중 RTT가 낮은 8개로 호스트-클라이언트 오프셋을 추정합니다. 8개 유효 표본 이후 오디오를 최대 100패킷의 지터 버퍼에 넣고, timestamp를 변환해 예약 재생합니다. 중복·과거 epoch·늦은 패킷은 버립니다. 공통 지연은 180ms에서 시작해 클라이언트의 네트워크·출력 요구에 따라 최대 500ms까지 늘어나며 재생 중에는 줄이지 않습니다. Float32 little-endian/base64 payload와 4바이트 big-endian 길이+JSON 형식은 Swift와 동일합니다.

Android는 AudioTrack 하드웨어 timestamp, 데스크톱은 JavaSound의 처리 프레임 카운터와 monotonic 시계를 사용합니다. 침묵을 포함한 연속 프레임 타임라인을 유지하며 1초 간격으로 출력 시각을 보정합니다. 데스크톱 카운터 정확도는 드라이버에 영향을 받습니다. 지속적인 가변 리샘플링 PLL이 없어 하드웨어 드리프트나 정체로 작은 공백/드롭이 생길 수 있습니다. ±30ms 수동 보정이 있습니다. **180~250ms는 정상 LAN에서의 설계 지연 예산이며, 실측값이나 ±3ms 음향 정확도 보장이 아닙니다.** Bluetooth·Wi-Fi 비대칭·출력 경로가 영향을 줍니다. 데스크톱 출력 장치 변경 후에는 재연결/재시작하세요.

경고는 동기화/새 스트림 시작 후 30초 준비하고 불확실성 60ms 초과, 예약 오차 25ms 초과 또는 재생 오디오 2초 정체가 5초간 지속될 때 표시합니다. 큰 시계 오프셋 자체는 오류가 아닙니다. 실시간 현황 아래 작은 글씨로 RTT·오프셋·지터·시계 불확실성·공통 버퍼·출력 지연·예약 오차·대기 패킷·드롭을 표시합니다. 조작과 연결 기기는 현황 위에 있습니다.

## 인증·볼륨·권한

TLS 1.3 전용, 평문 전환/세션 재개는 없습니다. Apple과 동일한 TLS exporter 연결 키에서 양쪽이 코드를 독립 계산하고, 승인 후 256비트 비밀을 저장합니다. 저장된 페어링은 새 nonce·기기 ID·TLS 연결 키가 포함된 HMAC-SHA256으로 인증합니다. 호스트 P-256 공개키 SHA-256을 고정하고 키가 바뀌면 자동 재연결을 중단합니다. 페어링은 60초 후 만료하며 최초 연결은 최대 3회/2초 간격, 승인된 세션은 자동 재연결합니다.

Android 인증 정보는 Keystore AES-GCM으로 암호화하고 백업을 끕니다. Windows/Linux는 `~/.musicsync/identity.properties` 개인 파일을 사용합니다. POSIX 환경은 폴더 0700·파일 0600, Windows는 사용자 프로필 ACL에 의존합니다. **파일에 개인키와 페어링 비밀이 있으므로 공유하지 마세요.** 데스크톱 OS 자격 증명 저장소 연동은 남아 있습니다. 인증기관·클라우드 서버나 시스템 신뢰 변경은 없습니다. Bonjour 검색은 LAN에서 보입니다.

호스트가 기기별로 자신의 볼륨 조절, 클라이언트 볼륨 조절, 다른 클라이언트 볼륨 조절 및 대상의 수락, 다른 클라이언트 채널·식별음 조절 및 대상의 수락을 설정합니다. 원격 표시값은 대상의 실제 보고에서 갱신합니다. 식별음은 2초 간격 제한입니다. **Android는 실제 미디어 시스템 볼륨**, Windows/Linux는 현재 **MusicSync 재생 볼륨**을 조절합니다. 기존 Mac은 시스템 볼륨, iOS 원격은 재생 볼륨이라는 제약도 유지됩니다. Android 시스템 볼륨은 기기별 정수 단계로 적용됩니다.

영어/한국어 전환, 도움말·GitHub 링크, 버전/빌드와 최대 300개 메모리 세션 로그를 제공합니다. 로그는 텍스트 선택·복사와 지우기가 가능하며 코드·키·비밀·PCM은 기록하지 않습니다. Android는 백그라운드 세션을 위한 지속 알림/foreground service를 사용합니다. 별도의 Dynamic Island 대응 화면은 없습니다. 최초 페어링은 앱을 열어 두세요. 배터리 정책·강제 종료·캡처 승인 취소로 세션이 중단될 수 있습니다.

## 빌드와 배포

JDK 17, Gradle **8.13**. `ports/`를 Android Studio/IntelliJ에서 열 수 있습니다. Android SDK 36/build-tools 36.0.0, 최소 Android 10/API 29입니다. 최초 데스크톱 패키지는 Windows/Linux x86_64이며 ARM 패키지는 아직 생성하지 않습니다.

```sh
cd ports
gradle :core:test :android:assembleDebug
gradle -PwithAndroid=false :desktop:run
gradle -PwithAndroid=false :desktop:packageDistributionForCurrentOS
```

Windows 캡처 DLL 빌드·포함 명령은 [영문 빌드 설명](README.md#build-and-install)에 있습니다. Linux 시스템 공유에는 PulseAudio/PipeWire-Pulse 서버 및 `pactl`/`parec`가 필요합니다. Arch에서는 `pipewire-pulse`, `pipewire-alsa`, `libpulse`, Debian/Ubuntu에서는 `pulseaudio-utils`와 적절한 ALSA/PulseAudio 경로를 설치하세요. Linux ZIP에는 Java가 포함되어 별도 JDK가 필요 없습니다. 실행 권한을 보존해 압축을 풀고 `MusicSync/bin/MusicSync`를 실행합니다. 방화벽에서 로컬 TCP와 UDP 5353/mDNS를 허용하세요. VPN·멀티캐스트 제한 환경은 호스트 화면의 주소를 직접 입력할 수 있습니다.

**Actions → Build MusicSync ports → 성공한 실행 → Artifacts**:

| Artifact | 포함 파일 |
| --- | --- |
| `MusicSync-Android` | 설치 가능한 CI debug 서명 `MusicSync-Android.apk` |
| `MusicSync-Windows` | `MusicSync-Windows.zip`, MSI, Java 런타임·캡처 DLL |
| `MusicSync-Linux` | `MusicSync-Linux.zip`, DEB/RPM, Java 런타임 |
| `MusicSync-Windows-tests`, `MusicSync-Linux-tests` | Core HTML 테스트 보고서 |

Windows 실행 파일은 Authenticode 서명하지 않습니다. Android debug APK는 테스트용이며 CI runner의 debug 서명 키가 달라지면 업데이트 설치 대신 기존 앱 삭제 후 설치·재페어링이 필요할 수 있습니다. 정식 배포에는 유지되는 별도 서명 키를 사용해야 합니다. 기존 Apple workflow는 IPA/Mac 앱을 따로 계속 생성합니다.

CI에서 컴파일·패키징·APK 서명/구조·데스크톱 실행 파일/Java 포함·실제 TLS exporter/공개키/HMAC·PCM·시계·버퍼·WAV 테스트와 **Kotlin 호스트↔Swift Network.framework 클라이언트** 연결을 확인합니다. 실제 Android/Windows/Linux 스피커, 캡처 권한·방화벽·Bonjour 및 음향 싱크는 실기기 검증이 남습니다.

MusicSync는 MIT입니다. 포트의 Compose/Kotlin·Bouncy Castle·JmDNS·JNA·miniaudio와 포함 Java 런타임에는 각자 라이선스가 적용됩니다. [제3자 고지](THIRD_PARTY_NOTICES.md)를 확인하세요. Apple 프레임워크가 제공하던 UI·TLS exporter·DNS-SD·Windows 캡처를 새 플랫폼에서 구현하기 위한 의존성이며 Expressive alpha API는 버전을 고정합니다.
