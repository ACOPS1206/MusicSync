// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
package dev.musicsync.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.*
import java.util.*
import java.util.concurrent.*
import kotlin.math.*

data class DeviceView(val id: String, val name: String, val approved: Boolean, val code: String?, val confirmed: Boolean,
    val channel: String, val selection: String, val state: String, val rtt: Double, val volume: Double, val policy: Permissions)
data class Snapshot(val role: String = "Listen", val phase: String = "Ready", val nearby: List<Nearby> = emptyList(),
    val hostActive: Boolean = false, val streaming: Boolean = false, val connected: Boolean = false, val paired: Boolean = false,
    val code: String = "", val confirmed: Boolean = false, val hostName: String = "", val address: String = "",
    val devices: List<DeviceView> = emptyList(), val peers: List<VolumePeer> = emptyList(), val channel: String = "stereo",
    val selection: String = "automatic", val volume: Double = 1.0, val volumeScope: String = "app", val hostVolume: Double = 1.0,
    val hostVolumeScope: String = "app", val canControlHost: Boolean = false, val rtt: Double = 0.0, val offset: Double = 0.0, val jitter: Double = 0.0,
    val uncertainty: Double = 0.0, val latency: Double = .18, val outputLatency: Double = 0.0, val buffer: Int = 0,
    val drops: Int = 0, val scheduleError: Double = 0.0, val warmup: Double = 30.0, val warning: String = "",
    val monitor: Boolean = false, val bytesPerSecond: Long = 0, val error: String = "", val logs: List<String> = emptyList())
private class Device(val peer: SecurePeer) {
    var deviceID = ""; var name = "Client"; var approved = false; var confirmed = false; var pending = false
    val nonce = UUID.randomUUID().toString().uppercase()
    var policy = Permissions(); var channel = "stereo"; var selection = "automatic"; var state = "Waiting"
    var rtt = 0.0; var volume = 1.0; var scope = "app"; var ready = false; var lastStats = Clock.now(); var lastIdentify = 0.0
}
/** All protocol state belongs to this executor. Audio and TLS threads never mutate UI state. */
class Session(val platform: Platform, private val discoveryEnabled: Boolean = true) : AutoCloseable {
    private val executor = Executors.newSingleThreadScheduledExecutor { r -> Thread(r,"MusicSync session").apply { isDaemon = true } }
    private val io = Executors.newCachedThreadPool { r -> Thread(r,"MusicSync IO").apply { isDaemon = true } }
    private val mutable = MutableStateFlow(Snapshot(volumeScope=if(platform.systemVolume) "system" else "app"))
    val state = mutable.asStateFlow()
    private var snapshot = mutable.value
    private val logs = ArrayDeque<String>()
    private val store = platform.store
    private val hostID = store.id("host"); private val clientID = store.id("client")
    private var identity: Identity? = null
    private var server: ServerSocket? = null
    private val devices = linkedMapOf<String,Device>()
    private var client: SecurePeer? = null
    private var target: Nearby? = null
    private var wantsConnection = false; private var attempt = 0; private var established = false; private var generation = 0
    private var hostKey = ""; private var nonce = ""; private var proved = false
    private var clock = ClockEstimate(); private var buffer = JitterBuffer()
    private var pairedAt = 0.0; private var lastAudio = 0.0; private var warningSince = 0.0
    private var lastPong = 0.0; private var pingCount = 0; private var lastReport = 0.0; private val pings = mutableSetOf<Double>()
    private var clientCanBeControlled = false; private var peersCanControlVolume = false; private var peersCanControlDevice = false
    private var hostChannel = "stereo"; private var channelSelection = "automatic"
    private var source: AudioSource? = null; @Volatile private var sourceGeneration = 0; private var epoch = 0L; private var sequence = 0L
    private var nextPTS = 0.0; private var lastStreamDelay = .18
    private var latency = .18; private var lastPublish = 0.0; private var totalBytes = 0L; private var lastBytes = 0L
    private var reportBytes = 0L; private var lastTraffic = Clock.now(); private var lastIdentify = 0.0
    private val player = ScheduledPlayer { platform.sink() }
    private val discovery = Discovery({ found -> post { snapshot=snapshot.copy(nearby=found.filter { it.port != server?.localPort }); publish() } },{ reason -> post { log("Bonjour: $reason"); snapshot=snapshot.copy(error=reason); publish() } })
    init {
        log("MusicSync 0.9.0 (12) · ${platform.name}")
        if (discoveryEnabled) discovery.start()
        executor.scheduleAtFixedRate({ runCatching { tick() }.onFailure { fail(it) } },0,10,TimeUnit.MILLISECONDS)
    }
    private fun post(block: ()->Unit) { if (!executor.isShutdown) executor.execute { runCatching(block).onFailure { fail(it) } } }
    private fun fail(e: Throwable) { val text = e.message?.take(160) ?: e.javaClass.simpleName; log(text); snapshot=snapshot.copy(error=text); publish() }
    private fun log(text: String) {
        // Only selected event summaries, never raw packets, codes, pins, secrets or proofs.
        synchronized(logs) { logs.addLast("${java.time.LocalTime.now().withNano(0)} ${text.replace('\n',' ').take(200)}"); while(logs.size>300)logs.removeFirst() }
    }
    private fun publish() {
        snapshot = snapshot.copy(devices=devices.values.map { DeviceView(it.peer.id,it.name,it.approved,if(it.pending)it.peer.code else null,it.confirmed,it.channel,it.selection,it.state,it.rtt,it.volume,it.policy) },
            channel=effectiveChannel(),selection=channelSelection,outputLatency=player.outputLatency,buffer=buffer.size,
            drops=buffer.drops+player.drops,scheduleError=player.error,latency=latency,logs=synchronized(logs){logs.toList()})
        mutable.value = snapshot
    }
    private fun info(kind: String) = Message(kind,pairingVersion=2,hostID=hostID,name=platform.name,serviceName=platform.name,
        hostAddress=(discovery.address ?: Discovery.lanAddress()?.hostAddress ?: "127.0.0.1")+":"+(server?.localPort ?: 0))
    fun setRole(role: String) = post {
        disconnectInternal(); stopHostInternal(); snapshot=Snapshot(role=role,nearby=snapshot.nearby,volumeScope=if(platform.systemVolume)"system" else "app")
        channelSelection="automatic"; publish()
    }
    fun startHost(port: Int = 0) = post {
        if (server != null) return@post
        disconnectInternal(); identity = Identity(store); val listener = ServerSocket(port); server=listener
        snapshot=snapshot.copy(hostActive=true,phase="Hosting",hostName=platform.name,address=info("address").hostAddress ?: "",error="")
        log("Host listening on ${listener.localPort}")
        if (discoveryEnabled) io.execute { for(i in 0..40) { if(server !== listener)break; if(discovery.address != null){ discovery.advertise(platform.name,listener.localPort);post{if(server===listener){snapshot=snapshot.copy(address=info("address").hostAddress?:"");publish()}};break }; Thread.sleep(250) } }
        io.execute {
            while (!listener.isClosed) {
                val socket = runCatching { listener.accept() }.getOrNull() ?: break
                io.execute {
                    try { val peer=SecurePeer.server(socket,identity!!); post {
                        if(server !== listener || devices.size>=16){peer.close();return@post}
                        val d=Device(peer); devices[peer.id]=d
                        peer.onMessage={m->post{handleHost(d,m)}};peer.onClose={_->post{devices.remove(peer.id);log("Client disconnected");publish()}}
                        peer.start(); log("TLS 1.3 Client connected"); publish()
                        executor.schedule({ if(!d.approved){d.peer.send(Message("pairRejected"));d.peer.close()} },60,TimeUnit.SECONDS)
                    } } catch (_: Exception) { runCatching { socket.close() }; post { log("TLS handshake failed") } }
                }
            }
        }; publish()
    }
    fun stopHost() = post { stopHostInternal(); publish() }
    private fun stopHostInternal() {
        stopStreamingInternal(); runCatching { server?.close() }; server=null
        devices.values.toList().forEach { it.peer.close() }; devices.clear(); discovery.unadvertise()
        snapshot=snapshot.copy(hostActive=false,phase="Ready",devices=emptyList())
    }
    fun connect(host: Nearby) = post {
        disconnectInternal(); stopHostInternal(); target=host;wantsConnection=true;attempt=0;established=false;openClient();publish()
    }
    fun connectDirect(address: String) = post {
        val uri=URI("musicsync://"+address.trim());require(uri.host!=null&&uri.port in 1..65535&&uri.userInfo==null&&uri.path.isNullOrEmpty()&&uri.query==null&&uri.fragment==null){"Use host.local:port"}
        connect(Nearby(uri.host,uri.host,uri.port))
    }
    private fun openClient() {
        val host=target ?: return
        val token=++generation;attempt++; snapshot=snapshot.copy(phase="Connecting",error="");publish()
        val known=store.get("endpoint.${host.name}"); val pin=known?.let{store.get("pin.$it")}
        io.execute {
            var socket: Socket?=null
            try {
                socket=Socket();socket.connect(InetSocketAddress(host.address,host.port),10000)
                val peer=SecurePeer.client(socket,pin)
                post {
                    if(token!=generation||!wantsConnection){peer.close();return@post}
                    client=peer;clock=ClockEstimate();buffer=JitterBuffer();pings.clear();pingCount=0;lastPong=Clock.now();lastAudio=0.0;lastReport=0.0;proved=false
                    snapshot=snapshot.copy(connected=true,paired=false,phase="Authenticating",hostName=host.name,code="",confirmed=false,warning="",peers=emptyList())
                    peer.onMessage={m->post{if(client===peer)handleClient(m)}};peer.onClose={reason->post{if(client===peer)lost(reason)}};peer.start()
                    peer.send(Message("hello",pairingVersion=2,deviceID=clientID,name=platform.name,channelSelection=channelSelection,volumeControlVersion=1,volume=volume(),volumeScope=snapshot.volumeScope))
                    log("TLS 1.3 Host connected");publish()
                }
            } catch(e:Exception) {
                runCatching{socket?.close()};post{if(token==generation) { if(e.message?.contains("key changed")==true){ wantsConnection=false;fail(e) }else lost(e.javaClass.simpleName) }}
            }
        }
    }
    fun disconnect() = post { disconnectInternal(); publish() }
    private fun disconnectInternal() {
        wantsConnection=false;generation++;val old=client;client=null;old?.close();player.close();buffer=JitterBuffer()
        snapshot=snapshot.copy(connected=false,paired=false,phase="Ready",code="",confirmed=false,peers=emptyList(),warning="")
    }
    private fun lost(reason: String) {
        val old=client;client=null;old?.close();player.close();buffer=JitterBuffer()
        snapshot=snapshot.copy(connected=false,paired=false,code="",confirmed=false,phase="Disconnected",error=reason)
        log("Connection ended: $reason")
        if(wantsConnection&&(established||attempt<3)) {
            snapshot=snapshot.copy(phase="Reconnecting");val token=generation
            executor.schedule({if(token==generation&&wantsConnection&&client==null)openClient()},2,TimeUnit.SECONDS)
        } else wantsConnection=false
        publish()
    }
    fun confirmCode() = post {
        if(snapshot.code.isNotEmpty()&&!snapshot.paired){snapshot=snapshot.copy(confirmed=true);client?.send(Message("pairConfirm",pairingCode=snapshot.code));publish()}
    }
    fun forgetHost() = post {
        if(hostKey.isNotEmpty()){store.put("client.$hostKey",null);store.put("pin.$hostKey",null)}
        target?.let{store.put("endpoint.${it.name}",null)};disconnectInternal();log("Host pairing forgotten");publish()
    }
    fun approve(id: String) = post {
        val d=devices[id] ?: return@post
        if(!d.approved&&d.confirmed&&d.pending){val secret=Pairing.secret();store.put("host.${d.deviceID}",secret);d.policy=Permissions();authorize(d,secret)};publish()
    }
    fun reject(id: String, forget: Boolean = false) = post {
        devices[id]?.let{if(forget){store.put("host.${it.deviceID}",null);store.put("policy.${it.deviceID}",null)};it.peer.send(Message("pairRejected"));it.peer.close()};publish()
    }
    private fun pending(d: Device) { d.pending=true;d.peer.send(info("pairPending").copy(pairingCode=d.peer.code));publish() }
    private fun authorize(d: Device,secret: String?) {
        devices.values.filter{it!==d&&it.deviceID==d.deviceID}.toList().forEach{it.peer.close();devices.remove(it.peer.id)}
        d.approved=true;d.pending=false
        d.peer.send(policyMessage(d,"pairApproved").copy(pairingSecret=secret,outputChannel=hostChannel));roster();log("Client authorized");publish()
    }
    private fun policyMessage(d: Device,kind: String) = info(kind).copy(volumeControlVersion=1,hostVolume=volume(),volumeScope=snapshot.volumeScope,
        allowClientHostVolume=d.policy.clientMayControlHost,allowHostClientVolume=d.policy.hostMayControlClient,
        allowPeerClientVolume=d.policy.peersMayControlClient,allowPeerDeviceControl=d.policy.peersMayControlClientDevice)
    fun setPermissions(id: String, policy: Permissions) = post {
        val d=devices[id]?:return@post;if(!d.approved)return@post;d.policy=policy;store.put("policy.${d.deviceID}",Wire.json.encodeToString(policy));d.peer.send(policyMessage(d,"volumePolicy"));roster();publish()
    }
    private fun roster() {
        val paired=devices.values.filter{it.approved}
        paired.forEach{recipient->recipient.peer.send(Message("volumePeers",volumePeers=paired.filter{it!==recipient}.map{target->
            VolumePeer(target.peer.id,target.name,target.volume,recipient.policy.clientMayControlPeers&&target.policy.peersMayControlClient,
                target.scope,target.channel,target.selection,target.state,recipient.policy.clientMayControlPeerDevices&&target.policy.peersMayControlClientDevice)
        }))}
    }
    private fun validID(s: String?) = s!=null&&runCatching{UUID.fromString(s)}.isSuccess
    private fun handleHost(d: Device,m: Message) {
        if(devices[d.peer.id]!==d)return
        if(!d.approved&&m.kind !in listOf("hello","pairRequest","pairProof","pairConfirm"))return
        when(m.kind) {
            "hello"->{ if(d.deviceID.isNotEmpty())return
                if(m.pairingVersion!=2||!validID(m.deviceID)){d.peer.send(Message("pairRejected"));d.peer.close();return}
                d.deviceID=m.deviceID!!;d.name=(m.name?:"Client").take(80);d.volume=validVolume(m.volume)?:1.0;d.scope=if(m.volumeScope=="system")"system"else"app"
                d.selection=validSelection(m.channelSelection)?:"automatic"
                d.policy=store.get("policy.${d.deviceID}")?.let{runCatching{Wire.json.decodeFromString<Permissions>(it)}.getOrNull()}?:Permissions()
                d.peer.send(info("pairChallenge").copy(nonce=d.nonce));publish()
            }
            "pairRequest"->if(d.deviceID.isNotEmpty()&&!d.approved)pending(d)
            "pairProof"->{ val secret=store.get("host.${d.deviceID}")
                if(!d.approved&&d.deviceID.isNotEmpty()){if(secret!=null&&Pairing.verify(m.pairingProof,secret,d.nonce,hostID,d.deviceID,d.peer.binding))authorize(d,null)else pending(d)}
            }
            "pairConfirm"->{if(d.pending&&!d.approved&&m.pairingCode==d.peer.code){d.confirmed=true;publish()}}
            "ping"->{val t=Clock.now();if(m.t1?.isFinite()==true)d.peer.send(Message("pong",t1=m.t1,t2=t,t3=Clock.now()))}
            "stats"->{if(m.rtt?.isFinite()!=true||m.jitter?.isFinite()!=true||m.latency?.isFinite()!=true)return
                if(m.rtt !in 0.0..<1.0||m.jitter<0||m.latency !in .18.. .5)return
                d.ready=true;d.lastStats=Clock.now();d.rtt=m.rtt;d.state=m.playbackState?:"Waiting"
                snapshot=snapshot.copy(rtt=m.rtt,offset=m.offset?.takeIf{it.isFinite()}?:0.0,jitter=m.jitter,uncertainty=m.rtt/2+m.jitter)
                val needed=max(.18,max(m.latency,m.rtt/2+4*m.jitter+.08)).coerceAtMost(.5);latency=max(latency,needed)
                d.peer.send(Message("timeline",latency=latency));updateDevice(d,m);roster()
            }
            "channelReport","volumeReport"->{updateDevice(d,m);roster();publish()}
            "identifyHost"->{if(Clock.now()-lastIdentify>=2){lastIdentify=Clock.now();player.identify()}}
            "setHostVolume"->{val v=validVolume(m.volume);val allowed=d.policy.clientMayControlHost&&v!=null
                val ok=allowed&&applyVolume(v!!);d.peer.send(Message("volumeResult",requestID=m.requestID,volumeTarget="host",accepted=ok,hostVolume=volume(),volumeScope=snapshot.volumeScope));broadcastHostVolume()}
            "setPeerVolume","setPeerChannel","identifyPeer"->{
                val target=devices[m.targetPeerID];val volume=m.kind=="setPeerVolume"
                val allowed=target!=null&&target!==d&&target.approved&&if(volume)d.policy.clientMayControlPeers&&target.policy.peersMayControlClient else d.policy.clientMayControlPeerDevices&&target.policy.peersMayControlClientDevice
                if(!allowed){d.peer.send(Message(if(volume)"peerVolumeDenied"else"peerControlDenied",targetPeerID=m.targetPeerID));return}
                if(volume){ val v=validVolume(m.volume)?:return;target!!.peer.send(Message("setClientVolume",volume=v,targetPeerID=d.peer.id,requestID=m.requestID?:UUID.randomUUID().toString())) }
                else if(m.kind=="setPeerChannel") {val ch=validSelection(m.channelSelection)?:return;target!!.peer.send(Message("setChannel",channelSelection=ch,targetPeerID=d.peer.id,requestID=m.requestID))}
                else if(Clock.now()-target!!.lastIdentify>=2){target.lastIdentify=Clock.now();target.peer.send(Message("identify",targetPeerID=d.peer.id,requestID=m.requestID))}
            }
        }
    }
    private fun updateDevice(d:Device,m:Message){validSelection(m.channelSelection)?.let{d.selection=it};if(m.outputChannel in listOf("left","right","stereo"))d.channel=m.outputChannel!!;m.playbackState?.let{d.state=it.take(40)};validVolume(m.volume)?.let{d.volume=it}}
    private fun handleClient(m: Message) {
        val peer=client?:return
        when(m.kind) {
            "pairChallenge"->{if(snapshot.paired||m.pairingVersion!=2||!validID(m.hostID)||!validID(m.nonce))return
                hostKey=m.hostID!!;nonce=m.nonce!!;snapshot=snapshot.copy(hostName=m.name?:snapshot.hostName,address=m.hostAddress?:snapshot.address)
                val pin=store.get("pin.$hostKey");if(pin!=null&&pin!=peer.pin){wantsConnection=false;lost("Host security key changed");return}
                val secret=store.get("client.$hostKey")
                if(pin==peer.pin&&secret!=null){proved=true;peer.send(Message("pairProof",pairingProof=Pairing.proof(secret,nonce,hostKey,clientID,peer.binding)))}else peer.send(Message("pairRequest"))
            }
            "pairPending"->{if(m.hostID!=hostKey||m.pairingCode!=peer.code){wantsConnection=false;lost("Pairing code mismatch");return};proved=false;snapshot=snapshot.copy(code=peer.code,confirmed=false,phase="Awaiting approval")}
            "pairApproved"->{if(snapshot.paired||m.hostID!=hostKey)return
                if(m.pairingSecret!=null){if(!snapshot.confirmed||runCatching{Base64.getDecoder().decode(m.pairingSecret).size}.getOrDefault(0)!=32){wantsConnection=false;lost("Confirm codes before approval");return};store.put("client.$hostKey",m.pairingSecret);store.put("pin.$hostKey",peer.pin);target?.let{store.put("endpoint.${it.name}",hostKey)}}
                else if(!proved){wantsConnection=false;lost("Pairing proof required");return}
                established=true;attempt=0;pairedAt=Clock.now();lastPong=Clock.now();hostChannel=m.outputChannel?:"stereo"
                snapshot=snapshot.copy(paired=true,code="",confirmed=false,phase="Synchronizing",hostName=m.name?:snapshot.hostName,address=m.hostAddress?:snapshot.address)
                applyPolicy(m);reportChannel();log("Host authorized")
            }
            "pairRejected"->{wantsConnection=false;lost("Pairing declined or expired");return}
        }
        if(!snapshot.paired){publish();return}
        when(m.kind){
            "pong"->{if(m.t1!=null&&m.t2!=null&&m.t3!=null&&pings.remove(m.t1)){clock.observe(m.t1,m.t2,m.t3,Clock.now());lastPong=Clock.now()}}
            "audio"->{if(clock.ready&&m.validAudio()){
                if(buffer.insert(m)){player.close();pairedAt=Clock.now();warningSince=0.0}
                totalBytes+=(m.frames?:0)*8;lastAudio=Clock.now();snapshot=snapshot.copy(phase="Streaming",monitor=m.monitor?:false)
                m.latency?.takeIf{it.isFinite()&&it in .18.. .5}?.let{latency=it}
            }}
            "stop"->{player.close();buffer=JitterBuffer();lastAudio=0.0;snapshot=snapshot.copy(phase="Waiting",warning="",monitor=false)}
            "timeline"->{m.latency?.takeIf{it.isFinite()&&it in .18.. .5}?.let{latency=it}}
            "volumePolicy"->applyPolicy(m)
            "hostVolume","volumeResult"->{validVolume(m.hostVolume)?.let{snapshot=snapshot.copy(hostVolume=it)};if(m.accepted==false)snapshot=snapshot.copy(error="Volume change declined")}
            "volumePeers"->{val peers=m.volumePeers;if(peers!=null&&peers.size<=32&&peers.map{it.id}.toSet().size==peers.size&&peers.all{validID(it.id)&&validVolume(it.volume)!=null&&it.name.length<=80})snapshot=snapshot.copy(peers=peers)}
            "setClientVolume"->{val v=validVolume(m.volume);val allowed=if(m.targetPeerID==null)clientCanBeControlled else peersCanControlVolume
                if(v!=null&&allowed&&applyVolume(v))peer.send(Message("volumeReport",volume=volume(),requestID=m.requestID))else peer.send(Message("volumeResult",volumeTarget="client",accepted=false,requestID=m.requestID))}
            "setChannel"->{val selection=validSelection(m.channelSelection)
                if(selection!=null&&(m.targetPeerID==null||peersCanControlDevice)){channelSelection=selection;reportChannel(m.requestID)}else if(m.targetPeerID!=null)peer.send(Message("peerControlResult",accepted=false,requestID=m.requestID))}
            "channel","hostChannel"->{if(m.outputChannel in listOf("stereo","left","right")){hostChannel=m.outputChannel!!;reportChannel()}}
            "identify"->{val allowed=(m.targetPeerID==null||peersCanControlDevice)&&Clock.now()-lastIdentify>=2
                if(allowed){lastIdentify=Clock.now();player.identify()};peer.send(Message("identifyResult",accepted=allowed,requestID=m.requestID))}
            "peerVolumeDenied","peerControlDenied"->snapshot=snapshot.copy(error="Host permissions declined this device control")
        };publishIfDue()
    }
    private fun applyPolicy(m: Message){clientCanBeControlled=m.allowHostClientVolume?:false;peersCanControlVolume=m.allowPeerClientVolume?:false;peersCanControlDevice=m.allowPeerDeviceControl?:false;snapshot=snapshot.copy(canControlHost=m.allowClientHostVolume?:false,hostVolume=validVolume(m.hostVolume)?:snapshot.hostVolume,hostVolumeScope=if(m.volumeScope=="system")"system"else"app")}
    private fun effectiveChannel()=if(channelSelection=="automatic")hostChannel else channelSelection
    private fun reportChannel(requestID:String?=null){player.channel=effectiveChannel();if(snapshot.paired)client?.send(Message("channelReport",channelSelection=channelSelection,outputChannel=effectiveChannel(),playbackState=snapshot.phase,requestID=requestID))}
    fun setChannel(value:String)=post{channelSelection=validSelection(value)?:return@post;player.channel=effectiveChannel();reportChannel();publish()}
    fun setDeviceChannel(id:String,value:String)=post{val d=devices[id]?:return@post;if(d.approved)d.peer.send(Message("setChannel",channelSelection=validSelection(value)?:return@post,requestID=UUID.randomUUID().toString()))}
    fun identifyDevice(id:String)=post{devices[id]?.takeIf{it.approved&&Clock.now()-it.lastIdentify>=2}?.let{it.lastIdentify=Clock.now();it.peer.send(Message("identify"))}}
    fun identify()=post{player.identify()}
    fun identifyHost()=post{if(snapshot.paired)client?.send(Message("identifyHost"))}
    fun peerChannel(id:String,value:String)=post{if(snapshot.peers.any{it.id==id&&it.canControlDevice==true})client?.send(Message("setPeerChannel",targetPeerID=id,channelSelection=validSelection(value)?:return@post,requestID=UUID.randomUUID().toString()))}
    fun identifyPeer(id:String)=post{if(snapshot.peers.any{it.id==id&&it.canControlDevice==true})client?.send(Message("identifyPeer",targetPeerID=id))}
    private fun volume()=if(platform.systemVolume)platform.volume()else snapshot.volume
    private fun applyVolume(value:Double):Boolean {
        if(platform.systemVolume&&!platform.setVolume(value)){snapshot=snapshot.copy(error="System volume unavailable");return false}
        snapshot=snapshot.copy(volume=if(platform.systemVolume)platform.volume()else value);player.gain=if(platform.systemVolume)1.0 else value;return true
    }
    fun setVolume(value:Double)=post{if(validVolume(value)!=null&&applyVolume(value)){if(snapshot.paired)client?.send(Message("volumeReport",volume=volume()));broadcastHostVolume()};publish()}
    fun setHostVolume(value:Double)=post{if(snapshot.paired&&snapshot.canControlHost&&validVolume(value)!=null)client?.send(Message("setHostVolume",volume=value,requestID=UUID.randomUUID().toString()))}
    fun setDeviceVolume(id:String,value:Double)=post{devices[id]?.takeIf{it.approved&&it.policy.hostMayControlClient&&validVolume(value)!=null}?.peer?.send(Message("setClientVolume",volume=value,requestID=UUID.randomUUID().toString()))}
    fun setPeerVolume(id:String,value:Double)=post{if(snapshot.peers.any{it.id==id&&it.canControl}&&validVolume(value)!=null)client?.send(Message("setPeerVolume",volume=value,targetPeerID=id,requestID=UUID.randomUUID().toString()))}
    private fun broadcastHostVolume(){devices.values.filter{it.approved}.forEach{it.peer.send(Message("hostVolume",hostVolume=volume()))}}
    fun setCalibration(ms:Double)=post{if(ms.isFinite())player.calibration=ms.coerceIn(-30.0,30.0)/1000}
    fun streamFile(file:String)=startSource{platform.fileSource(file)}
    fun streamCapture()=startSource{platform.captureSource()}
    private fun startSource(make:()->AudioSource)=post {
        if(server==null)return@post;stopStreamingInternal();val token=++sourceGeneration
        io.execute {
            try {
                val input=make();post{if(sourceGeneration!=token){input.close();return@post};source=input;epoch++;sequence=0;latency=.18;nextPTS=0.0;lastStreamDelay=.18;snapshot=snapshot.copy(streaming=true,monitor=input.monitor,phase="Streaming",error="");publish()}
                while(sourceGeneration==token){val samples=input.read()?:break;val captured=Clock.now();post{
                    if(sourceGeneration!=token)return@post
                    if(nextPTS==0.0)nextPTS=captured+latency
                    if(latency>lastStreamDelay){nextPTS+=latency-lastStreamDelay;lastStreamDelay=latency}
                    if(nextPTS<captured+.025){nextPTS=captured+latency;epoch++;sequence=0}
                    val presentation=nextPTS;nextPTS+=samples.size/2/48000.0
                    val m=Message("audio",sequence=sequence++,epoch=epoch,pts=presentation,sampleRate=48000.0,channels=2,frames=samples.size/2,payload=Wire.payload(samples),latency=latency,monitor=input.monitor)
                    devices.values.filter{it.approved&&it.ready&&captured-it.lastStats<5}.forEach{it.peer.send(m)}
                    if(!input.monitor)player.schedule(samples,m.pts!!)
                    totalBytes+=samples.size*4
                }}
                post{if(sourceGeneration==token)stopStreamingInternal();publish()};input.close()
            }catch(e:Exception){post{if(sourceGeneration==token){stopStreamingInternal();fail(e)}}}
        }
    }
    fun stopStreaming()=post{stopStreamingInternal();publish()}
    private fun stopStreamingInternal(){sourceGeneration++;runCatching{source?.close()};source=null;player.close();devices.values.filter{it.approved}.forEach{it.peer.send(Message("stop"))};snapshot=snapshot.copy(streaming=false,monitor=false,phase=if(server!=null)"Hosting"else"Ready")}
    private fun tick(){
        val now=Clock.now()
        if(snapshot.paired){
            if(now-lastReport>=.1){pingCount++;if(pingCount<=16||pingCount%10==0){pings.removeIf{now-it>3};pings.add(now);client?.send(Message("ping",t1=now))};lastReport=now}
            if(now-lastPong>5){lost("Host clock timed out");return}
            if(clock.ready){buffer.take(now,clock.offset).forEach{player.schedule(it.samples(),it.pts!!-clock.offset)}
                if(now-lastPublish>=.25){
                    val requested=max(.18,clock.rtt/2+4*clock.jitter+player.outputLatency+.07).coerceAtMost(.5)
                    client?.send(Message("stats",rtt=clock.rtt,offset=clock.offset,jitter=clock.jitter,latency=max(latency,requested),playbackState=snapshot.phase,
                        outputChannel=effectiveChannel(),channelSelection=channelSelection,dropped=buffer.drops+player.drops,schedulingError=player.error,bufferCount=buffer.size))
                }
            }
            val warmup=max(0.0,30-(now-pairedAt));val bad=clock.uncertainty>.060||abs(player.error)>.025||(lastAudio>0&&now-lastAudio>2)
            if(warmup>0||!bad)warningSince=0.0 else if(warningSince==0.0)warningSince=now
            val warning=if(warningSince>0&&now-warningSince>=5) "RTT %.1f ms · clock uncertainty %.1f ms · schedule %.1f ms. Wi-Fi congestion or audio route delay.".format(clock.rtt*1000,clock.uncertainty*1000,player.error*1000) else ""
            snapshot=snapshot.copy(rtt=clock.rtt,offset=clock.offset,jitter=clock.jitter,uncertainty=clock.uncertainty,warmup=warmup,warning=warning)
        }
        if(now-lastTraffic>=1){reportBytes=totalBytes-lastBytes;lastBytes=totalBytes;lastTraffic=now;snapshot=snapshot.copy(bytesPerSecond=reportBytes,volume=volume());if(server!=null)broadcastHostVolume()}
        publishIfDue()
    }
    private fun publishIfDue(){val now=Clock.now();if(now-lastPublish>=.25){lastPublish=now;publish()}}
    fun clearLogs()=post{synchronized(logs){logs.clear()};publish()}
    override fun close(){post{disconnectInternal();stopHostInternal();discovery.close();executor.shutdown();io.shutdownNow()}}
    companion object {
        fun validVolume(v:Double?)=v?.takeIf{it.isFinite()&&it in 0.0..1.0}
        fun validSelection(v:String?)=v?.takeIf{it in listOf("automatic","stereo","left","right")}
    }
}
