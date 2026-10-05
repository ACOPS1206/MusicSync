// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
package dev.musicsync.ui

import androidx.compose.runtime.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.animation.animateContentSize
import androidx.compose.material3.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import dev.musicsync.core.*
import java.util.Locale

private val korean = mapOf(
    "Listen" to "수신", "Host" to "호스트", "Ready" to "준비됨", "Hosting" to "호스팅 중", "Streaming" to "스트리밍 중",
    "Connecting" to "연결 중", "Authenticating" to "인증 중", "Awaiting approval" to "승인 대기", "Synchronizing" to "동기화 중",
    "Waiting" to "오디오 대기", "Reconnecting" to "재연결 중", "Disconnected" to "연결 끊김", "Nearby Hosts" to "주변 호스트",
    "Start Host" to "호스트 시작", "Stop Host" to "호스트 중지", "Connect" to "연결", "Disconnect" to "연결 해제", "Pairing" to "페어링",
    "Codes match" to "양쪽 코드가 일치합니다", "Confirm the same code on both devices, then approve on the Host." to "양쪽 기기의 코드가 같은지 확인한 뒤 호스트에서 승인하세요.",
    "Approve" to "승인", "Reject" to "거절", "Waiting for Client confirmation" to "클라이언트 확인 대기", "Waiting for Host approval" to "호스트 승인 대기",
    "Connected devices" to "연결된 기기", "Speaker placement" to "스피커 배치", "automatic" to "호스트 설정 따르기", "stereo" to "스테레오", "left" to "왼쪽", "right" to "오른쪽",
    "Identify speaker" to "이 스피커 식별음", "Identify Host" to "호스트 식별음", "Identify device" to "기기 식별음", "Device permissions" to "기기 제어 권한",
    "Client controls Host volume" to "클라이언트가 호스트 볼륨 조절", "Host controls Client volume" to "호스트가 클라이언트 볼륨 조절",
    "Client controls peer volume" to "다른 클라이언트 볼륨 조절", "Peers control this volume" to "다른 클라이언트가 이 기기 볼륨 조절",
    "Client controls peer channel / identification" to "다른 클라이언트 채널 변경 / 식별음", "Peers control this channel / identification" to "다른 클라이언트가 이 기기 채널 변경 / 식별음",
    "Audio source" to "오디오 소스", "Choose WAV and stream" to "WAV 파일 선택 후 스트리밍", "Share system audio" to "시스템 오디오 공유",
    "Stop streaming" to "스트리밍 중지", "Local volume" to "이 기기 볼륨", "Host volume" to "호스트 볼륨", "System volume" to "시스템 볼륨", "MusicSync playback gain" to "MusicSync 재생 볼륨",
    "Live status" to "실시간 현황", "Latency & synchronization" to "지연 및 동기화", "Buffer" to "버퍼", "Clock offset" to "시계 오프셋", "Network jitter" to "네트워크 지터",
    "Clock uncertainty" to "시계 불확실성", "Output latency" to "출력 지연", "Scheduling error" to "예약 재생 오차", "Queued packets" to "대기 패킷", "Dropped packets" to "드롭 수",
    "Calibration" to "수동 출력 보정", "Logs" to "로그", "Help" to "도움말", "Clear" to "지우기", "Close" to "닫기", "Copyable session log" to "복사 가능한 세션 로그",
    "Direct connection" to "주소로 연결", "Host Bonjour address" to "호스트 Bonjour 주소", "Forget pairing" to "페어링 삭제", "Remove pairing" to "기기 페어링 삭제",
    "Permissions are managed by the Host." to "제어 권한은 호스트에서 설정합니다.", "Monitor mode: original Host output is ahead. Use WAV hosting for synchronized local output." to "모니터 모드: 호스트 원래 출력이 먼저 들립니다. 로컬 출력도 맞추려면 WAV 파일을 호스팅하세요.",
    "Synchronization warnings start after 30 seconds and require 5 seconds of sustained error." to "동기화 경고는 30초 준비 후, 오류가 5초간 지속될 때 표시됩니다.",
    "Share a LAN with other speakers. Approve only a matching pairing code. No cloud server is used." to "스피커를 같은 LAN에 연결하세요. 페어링 코드가 일치하는 기기만 승인하세요. 클라우드 서버는 사용하지 않습니다.",
    "RTT is a network round trip. Buffer adds shared delay so speakers can play at a planned time. These estimates do not measure acoustic speaker error." to "RTT는 네트워크 왕복 시간입니다. 버퍼는 스피커가 예약된 시각에 재생할 시간을 확보합니다. 표시된 추정값은 실제 스피커 간 음향 오차 측정값이 아닙니다.",
    "System capture needs permission on Android and capture-capable apps. Desktop WAV hosting supports PCM WAV, 1–2 channels, 8–192 kHz. DRM audio may be unavailable." to "Android 시스템 캡처에는 사용자 승인과 원본 앱의 캡처 허용이 필요합니다. WAV 호스팅은 1~2채널, 8~192 kHz PCM WAV를 지원합니다. DRM 오디오는 캡처되지 않을 수 있습니다.",
    "Windows/Linux credentials are stored in a private local file; Android uses Keystore encryption. Do not share the desktop identity file." to "Windows/Linux 인증 정보는 개인 로컬 파일에 보관하고 Android는 Keystore 암호화를 사용합니다. 데스크톱 인증 파일은 공유하지 마세요.",
    "Wi-Fi congestion or audio route delay can increase uncertainty. Bluetooth/AirPlay add extra latency. Use built-in speakers and calibrate after checking the actual sound." to "Wi-Fi 혼잡이나 오디오 경로 지연으로 불확실성이 커질 수 있습니다. Bluetooth/AirPlay는 지연을 추가합니다. 내장 스피커를 사용하고 실제 소리를 확인한 뒤 수동 보정하세요.",
    "Keep the app open for initial pairing. Android uses an ongoing audio notification for background sessions." to "첫 페어링 시 앱을 열어 두세요. Android는 백그라운드 오디오 세션에 지속 알림을 사용합니다."
)
@OptIn(ExperimentalMaterial3ExpressiveApi::class,ExperimentalMaterial3Api::class)
@Composable fun MusicSyncApp(session:Session,onFile:()->Unit,onCapture:()->Unit,onBegin:()->Unit={},onEnd:()->Unit={}) {
    val state by session.state.collectAsState()
    var ko by remember{mutableStateOf(Locale.getDefault().language=="ko")}
    fun t(text:String)=if(ko)korean[text]?:text else text
    var help by remember{mutableStateOf(false)};var logs by remember{mutableStateOf(false)}
    var direct by remember{mutableStateOf("")};var calibration by remember{mutableStateOf(0f)}
    val dark=isSystemInDarkTheme()
    val colors=if(dark)darkColorScheme(primary=Color(0xffbdc9ff),secondary=Color(0xffc4c6dc),surface=Color(0xff111318),surfaceContainer=Color(0xff1d2027))else lightColorScheme(primary=Color(0xff425ba3),secondary=Color(0xff585e75),surface=Color(0xfffaf8ff),surfaceContainer=Color(0xffeeedf4))
    MaterialExpressiveTheme(colorScheme=colors) {
        Surface(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().padding(WindowInsets.safeDrawing.asPaddingValues()),contentAlignment=Alignment.TopCenter) {
                LazyColumn(Modifier.widthIn(max=840.dp).fillMaxSize().padding(horizontal=20.dp),verticalArrangement=Arrangement.spacedBy(16.dp),contentPadding=PaddingValues(top=16.dp,bottom=32.dp)) {
                    item {
                        Column(verticalArrangement=Arrangement.spacedBy(8.dp)){
                            Text("MusicSync ${t(state.phase)}",style=MaterialTheme.typography.headlineLarge)
                            Row(horizontalArrangement=Arrangement.spacedBy(6.dp)){
                                TextButton(onClick={help=true}){Text(t("Help"))};TextButton(onClick={logs=true}){Text(t("Logs"))}
                                TextButton(onClick={ko=!ko}){Text(if(ko)"English"else"한국어")}
                            }
                            Text("0.9.0 · Build 12",style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                            TabRow(selectedTabIndex=if(state.role=="Host")1 else 0){listOf("Listen","Host").forEachIndexed{i,role->Tab(selected=state.role==role,onClick={session.setRole(role);onEnd()},text={Text(t(role))})}}
                        }
                    }
                    if(state.error.isNotEmpty())item{InfoCard("",state.error,warning=true)}
                    if(state.role=="Host") {
                        item{Section(t("Host")){
                            Button(onClick={if(state.hostActive){session.stopHost();onEnd()}else{onBegin();session.startHost()}},modifier=Modifier.fillMaxWidth()){Text(t(if(state.hostActive)"Stop Host"else"Start Host"))}
                            if(state.hostActive){Text(t("Host Bonjour address"),style=MaterialTheme.typography.labelMedium);SelectionContainer{Text(state.address)}}
                        }}
                        if(state.hostActive)item{Section(t("Audio source")){
                            Button(onClick=onFile,modifier=Modifier.fillMaxWidth()){Text(t("Choose WAV and stream"))}
                            OutlinedButton(onClick=onCapture,modifier=Modifier.fillMaxWidth()){Text(t("Share system audio"))}
                            if(state.streaming)TextButton(onClick={session.stopStreaming()}){Text(t("Stop streaming"))}
                            Text("48 kHz · Stereo · Float32 PCM",style=MaterialTheme.typography.bodySmall)
                        }}
                    } else {
                        if(!state.connected)item{Section(t("Nearby Hosts")){
                            if(state.nearby.isEmpty()){CircularProgressIndicator(Modifier.size(24.dp));Text(t("Nearby Hosts")+"…")}
                            state.nearby.forEach{host->OutlinedButton(onClick={onBegin();session.connect(host)},modifier=Modifier.fillMaxWidth()){Column{Text(host.name);Text("${host.address}:${host.port}",style=MaterialTheme.typography.labelSmall)}}}
                            OutlinedTextField(value=direct,onValueChange={direct=it},label={Text(t("Direct connection"))},placeholder={Text("host.local:49152")},singleLine=true,modifier=Modifier.fillMaxWidth())
                            TextButton(onClick={onBegin();session.connectDirect(direct)},enabled=direct.isNotBlank()){Text(t("Connect"))}
                        }}
                        if(state.connected)item{Section(t("Host")){
                            Text(state.hostName,style=MaterialTheme.typography.titleLarge)
                            Text(t("Host Bonjour address"),style=MaterialTheme.typography.labelMedium);SelectionContainer{Text(state.address)}
                            Row{OutlinedButton(onClick={session.disconnect();onEnd()}){Text(t("Disconnect"))};TextButton(onClick={session.forgetHost();onEnd()}){Text(t("Forget pairing"))}}
                        }}
                        if(state.code.isNotEmpty())item{Section(t("Pairing")){
                            Text(state.code,style=MaterialTheme.typography.displayMedium)
                            Text(t("Confirm the same code on both devices, then approve on the Host."))
                            Button(onClick={session.confirmCode()},enabled=!state.confirmed){Text(t(if(state.confirmed)"Waiting for Host approval"else"Codes match"))}
                        }}
                    }
                    if(state.role=="Host"&&state.devices.isNotEmpty())item{Section(t("Connected devices")){
                        state.devices.forEach{d->Column(Modifier.fillMaxWidth().animateContentSize(),verticalArrangement=Arrangement.spacedBy(8.dp)){
                            Text(d.name,style=MaterialTheme.typography.titleLarge)
                            if(!d.approved){d.code?.let{Text(it,style=MaterialTheme.typography.headlineLarge)};Text(t(if(d.confirmed)"Approve"else"Waiting for Client confirmation"));Row{Button(onClick={session.approve(d.id)},enabled=d.confirmed){Text(t("Approve"))};TextButton(onClick={session.reject(d.id)}){Text(t("Reject"))}}}
                            else {
                                Text("${t(d.channel)} · ${t(d.state)} · RTT %.1f ms".format(d.rtt*1000),style=MaterialTheme.typography.bodySmall)
                                Channels(d.selection,enabled=true,t=::t){session.setDeviceChannel(d.id,it)}
                                OutlinedButton(onClick={session.identifyDevice(d.id)}){Text(t("Identify device"))}
                                VolumeSlider(d.volume,enabled=d.policy.hostMayControlClient,t=::t){session.setDeviceVolume(d.id,it)}
                                var permissions by remember(d.id){mutableStateOf(false)}
                                TextButton(onClick={permissions=!permissions}){Text(t("Device permissions"))}
                                if(permissions){
                                    Permission(t("Client controls Host volume"),d.policy.clientMayControlHost){session.setPermissions(d.id,d.policy.copy(clientMayControlHost=it))}
                                    Permission(t("Host controls Client volume"),d.policy.hostMayControlClient){session.setPermissions(d.id,d.policy.copy(hostMayControlClient=it))}
                                    Permission(t("Client controls peer volume"),d.policy.clientMayControlPeers){session.setPermissions(d.id,d.policy.copy(clientMayControlPeers=it))}
                                    Permission(t("Peers control this volume"),d.policy.peersMayControlClient){session.setPermissions(d.id,d.policy.copy(peersMayControlClient=it))}
                                    Permission(t("Client controls peer channel / identification"),d.policy.clientMayControlPeerDevices){session.setPermissions(d.id,d.policy.copy(clientMayControlPeerDevices=it))}
                                    Permission(t("Peers control this channel / identification"),d.policy.peersMayControlClientDevice){session.setPermissions(d.id,d.policy.copy(peersMayControlClientDevice=it))}
                                }
                                TextButton(onClick={session.reject(d.id,true)}){Text(t("Remove pairing"))}
                            };HorizontalDivider()
                        }}
                    }}
                    if(state.role=="Listen"&&state.paired&&state.peers.isNotEmpty())item{Section(t("Connected devices")){
                        state.peers.forEach{peer->Column(verticalArrangement=Arrangement.spacedBy(8.dp)){
                            Text(peer.name,style=MaterialTheme.typography.titleMedium);Text("${t(peer.outputChannel?:"stereo")} · ${t(peer.playbackState?:"Waiting")}",style=MaterialTheme.typography.bodySmall)
                            Channels(peer.channelSelection?:"automatic",peer.canControlDevice==true,::t){session.peerChannel(peer.id,it)}
                            OutlinedButton(onClick={session.identifyPeer(peer.id)},enabled=peer.canControlDevice==true){Text(t("Identify device"))}
                            VolumeSlider(peer.volume,peer.canControl,::t){session.setPeerVolume(peer.id,it)};HorizontalDivider()
                        }};Text(t("Permissions are managed by the Host."),style=MaterialTheme.typography.bodySmall)
                    }}
                    item{Section(t("Speaker placement")){
                        Channels(state.selection,true,::t){session.setChannel(it)}
                        Text(t("Local volume")+" · "+t(if(state.volumeScope=="system")"System volume"else"MusicSync playback gain"),style=MaterialTheme.typography.labelMedium)
                        VolumeSlider(state.volume,true,::t){session.setVolume(it)}
                        OutlinedButton(onClick={session.identify()}){Text(t("Identify speaker"))}
                        if(state.role=="Listen"&&state.paired){
                            Text(t("Host volume")+" · "+t(if(state.hostVolumeScope=="system")"System volume"else"MusicSync playback gain"),style=MaterialTheme.typography.labelMedium);VolumeSlider(state.hostVolume,state.canControlHost,::t){session.setHostVolume(it)}
                            TextButton(onClick={session.identifyHost()}){Text(t("Identify Host"))}
                        }
                        Text(t("Calibration")+" %.0f ms".format(calibration));Slider(value=calibration,onValueChange={calibration=it},onValueChangeFinished={session.setCalibration(calibration.toDouble())},valueRange=-30f..30f)
                    }}
                    if(state.monitor)item{InfoCard("",t("Monitor mode: original Host output is ahead. Use WAV hosting for synchronized local output."),true)}
                    if(state.warning.isNotEmpty())item{InfoCard(t("Latency & synchronization"),if(ko)"시계 불확실성 %.1f ms · RTT %.1f ms · 예약 오차 %.1f ms\nWi-Fi 혼잡이나 오디오 출력 경로 지연을 확인하세요.".format(state.uncertainty*1000,state.rtt*1000,state.scheduleError*1000)else state.warning,true)}
                    item{Section(t("Live status")){
                        Text(t(state.phase),style=MaterialTheme.typography.titleLarge)
                        Text(t("Buffer")+" %.0f ms".format(state.latency*1000),style=MaterialTheme.typography.headlineMedium)
                        Text("TLS 1.3 · 48 kHz · Stereo · %.0f KiB/s".format(state.bytesPerSecond/1024.0))
                        Text(t("Latency & synchronization"),style=MaterialTheme.typography.labelSmall)
                        val metrics=listOf("RTT" to "%.1f ms".format(state.rtt*1000),"Clock offset" to "%+.2f ms".format(state.offset*1000),"Network jitter" to "%.2f ms".format(state.jitter*1000),"Clock uncertainty" to "±%.2f ms".format(state.uncertainty*1000),"Buffer" to "%.0f ms".format(state.latency*1000),"Output latency" to "%.1f ms".format(state.outputLatency*1000),"Scheduling error" to "%+.2f ms".format(state.scheduleError*1000),"Queued packets" to state.buffer.toString(),"Dropped packets" to state.drops.toString())
                        metrics.forEach{(label,value)->Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){Text(t(label),style=MaterialTheme.typography.bodySmall);Text(value,style=MaterialTheme.typography.bodySmall)}}
                        if(state.paired&&state.warmup>0)Text(if(ko)"경고 감지 준비: %.0f초".format(state.warmup)else"Warning warmup: %.0f s".format(state.warmup),style=MaterialTheme.typography.labelSmall)
                    }}
                }
            }
        }
        if(help){val uri=LocalUriHandler.current;AlertDialog(onDismissRequest={help=false},title={Text(t("Help"))},text={Column(Modifier.heightIn(max=500.dp).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(16.dp)){
            listOf("Share a LAN with other speakers. Approve only a matching pairing code. No cloud server is used.","RTT is a network round trip. Buffer adds shared delay so speakers can play at a planned time. These estimates do not measure acoustic speaker error.","Synchronization warnings start after 30 seconds and require 5 seconds of sustained error.","System capture needs permission on Android and capture-capable apps. Desktop WAV hosting supports PCM WAV, 1–2 channels, 8–192 kHz. DRM audio may be unavailable.","Wi-Fi congestion or audio route delay can increase uncertainty. Bluetooth/AirPlay add extra latency. Use built-in speakers and calibrate after checking the actual sound.","Keep the app open for initial pairing. Android uses an ongoing audio notification for background sessions.","Windows/Linux credentials are stored in a private local file; Android uses Keystore encryption. Do not share the desktop identity file.").forEach{Text(t(it))}
            TextButton(onClick={uri.openUri("https://github.com/ACOPS1206/MusicSync")}){Text("GitHub · ACOPS1206/MusicSync")}
        }},confirmButton={TextButton(onClick={help=false}){Text(t("Close"))}})}
        if(logs)AlertDialog(onDismissRequest={logs=false},title={Text(t("Copyable session log"))},text={SelectionContainer{Text(state.logs.joinToString("\n"),modifier=Modifier.heightIn(max=500.dp).verticalScroll(rememberScrollState()),style=MaterialTheme.typography.bodySmall)}},confirmButton={TextButton(onClick={logs=false}){Text(t("Close"))}},dismissButton={TextButton(onClick={session.clearLogs()}){Text(t("Clear"))}})
    }
}
@Composable private fun Section(title:String,content:@Composable ColumnScope.()->Unit){Card(shape=RoundedCornerShape(28.dp),modifier=Modifier.fillMaxWidth().animateContentSize()){Column(Modifier.padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){Text(title,style=MaterialTheme.typography.titleMedium);content()}}}
@Composable private fun InfoCard(title:String,text:String,warning:Boolean=false){Card(colors=CardDefaults.cardColors(containerColor=if(warning)MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainer),shape=RoundedCornerShape(24.dp)){Column(Modifier.fillMaxWidth().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){if(title.isNotEmpty())Text(title,style=MaterialTheme.typography.titleMedium);Text(text)}}}
@Composable private fun Channels(value:String,enabled:Boolean,t:(String)->String,onChange:(String)->Unit){Column(verticalArrangement=Arrangement.spacedBy(6.dp)){Row(horizontalArrangement=Arrangement.spacedBy(6.dp)){listOf("stereo","left","right").forEach{channel->FilterChip(selected=value==channel,onClick={onChange(channel)},enabled=enabled,label={Text(t(channel))})}};FilterChip(selected=value=="automatic",onClick={onChange("automatic")},enabled=enabled,label={Text(t("automatic"))})}}
@Composable private fun VolumeSlider(value:Double,enabled:Boolean,t:(String)->String,onChange:(Double)->Unit){var draft by remember{mutableStateOf(value.toFloat())};var dragging by remember{mutableStateOf(false)};LaunchedEffect(value){if(!dragging)draft=value.toFloat()};Column{Slider(value=draft.coerceIn(0f,1f),onValueChange={dragging=true;draft=it},onValueChangeFinished={dragging=false;onChange(draft.toDouble())},enabled=enabled);Text("${(value*100).toInt()}%",style=MaterialTheme.typography.labelSmall)}}
@Composable private fun Permission(label:String,checked:Boolean,onChange:(Boolean)->Unit){Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){Text(label,modifier=Modifier.weight(1f),style=MaterialTheme.typography.bodyMedium);Switch(checked=checked,onCheckedChange=onChange)}}
