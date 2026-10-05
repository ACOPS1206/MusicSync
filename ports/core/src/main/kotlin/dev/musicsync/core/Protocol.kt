// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
package dev.musicsync.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64
import kotlin.math.*

@Serializable
data class Message(val kind: String, val version: Int = 1,
    val name: String? = null,
    val pairingVersion: Int? = null,
    val deviceID: String? = null,
    val hostID: String? = null,
    val hostAddress: String? = null,
    val serviceName: String? = null,
    val nonce: String? = null,
    val pairingCode: String? = null,
    val pairingProof: String? = null,
    val pairingSecret: String? = null,
    val channelSelection: String? = null,
    val requestID: String? = null,
    val accepted: Boolean? = null,
    val playbackState: String? = null,
    val t1: Double? = null,
    val t2: Double? = null,
    val t3: Double? = null,
    val rtt: Double? = null,
    val offset: Double? = null,
    val jitter: Double? = null,
    val latency: Double? = null,
    val sequence: Long? = null,
    val epoch: Long? = null,
    val pts: Double? = null,
    val sampleRate: Double? = null,
    val channels: Int? = null,
    val frames: Int? = null,
    val syncWarning: String? = null,
    val dropped: Int? = null,
    val schedulingError: Double? = null,
    val bufferCount: Int? = null,
    val monitor: Boolean? = null,
    val outputChannel: String? = null,
    val volumeScope: String? = null,
    val volumeControlVersion: Int? = null,
    val volume: Double? = null,
    val hostVolume: Double? = null,
    val volumeTarget: String? = null,
    val allowClientHostVolume: Boolean? = null,
    val allowHostClientVolume: Boolean? = null,
    val allowPeerDeviceControl: Boolean? = null,
    val allowPeerClientVolume: Boolean? = null,
    val targetPeerID: String? = null,
    val volumePeers: List<VolumePeer>? = null,
    val payload: String? = null
) {
    fun validAudio(): Boolean = kind == "audio" && version == 1 && pts?.isFinite() == true &&
        sampleRate == 48000.0 && channels == 2 && frames in 1..4800 && sequence != null && epoch != null &&
        runCatching { Base64.getDecoder().decode(payload).size == frames!! * 8 }.getOrDefault(false)
    fun samples(): FloatArray {
        require(validAudio())
        val b = ByteBuffer.wrap(Base64.getDecoder().decode(payload)).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray(frames!! * 2) { b.float.let { if (it.isFinite()) it.coerceIn(-1f,1f) else 0f } }
    }
}
@Serializable
data class VolumePeer(val id: String, val name: String, val volume: Double, val canControl: Boolean,
    val volumeScope: String? = null, val outputChannel: String? = null, val channelSelection: String? = null,
    val playbackState: String? = null, val canControlDevice: Boolean? = null)
@Serializable
data class Permissions(val clientMayControlHost: Boolean = false, val hostMayControlClient: Boolean = true,
    val clientMayControlPeers: Boolean = false, val peersMayControlClient: Boolean = false,
    val clientMayControlPeerDevices: Boolean = false, val peersMayControlClientDevice: Boolean = false)
object Wire {
    const val MAX = 128 * 1024
    val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
    fun encode(m: Message): ByteArray {
        val bytes = json.encodeToString(m).toByteArray(Charsets.UTF_8)
        require(bytes.size in 1..MAX)
        return ByteBuffer.allocate(bytes.size + 4).putInt(bytes.size).put(bytes).array()
    }
    fun read(input: InputStream): Message {
        val data = DataInputStream(input)
        val n = data.readInt()
        require(n in 1..MAX) { "Invalid MusicSync frame length" }
        val body = ByteArray(n); data.readFully(body)
        return json.decodeFromString<Message>(body.toString(Charsets.UTF_8)).also { require(it.version == 1) { "Update MusicSync on both devices" } }
    }
    fun payload(samples: FloatArray): String {
        val buffer = ByteBuffer.allocate(samples.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { buffer.putFloat(it) }
        return Base64.getEncoder().encodeToString(buffer.array())
    }
}
object Clock { fun now(): Double = System.nanoTime() / 1_000_000_000.0 }
class ClockEstimate {
    private val samples = ArrayDeque<Pair<Double,Double>>()
    var rtt = 0.0; private set
    var offset = 0.0; private set
    var jitter = 0.0; private set
    val ready get() = samples.size >= 8
    val uncertainty get() = rtt / 2 + jitter
    fun observe(t1: Double, t2: Double, t3: Double, t4: Double) {
        if (!listOf(t1,t2,t3,t4).all { it.isFinite() }) return
        val d = t4-t1-(t3-t2)
        if (d !in 0.0..<1.0 || t4 < t1 || t3 < t2) return
        samples.addLast(d to ((t2-t1)+(t3-t4))/2)
        if (samples.size > 32) samples.removeFirst()
        val best = samples.sortedBy { it.first }.take(8)
        rtt = best.map { it.first }.average()
        val candidate = best.map { it.second }.average()
        offset = if (samples.size <= 8) candidate else offset * .9 + candidate * .1
        val mean = samples.map { it.first }.average()
        jitter = sqrt(samples.map { (it.first-mean).pow(2) }.average())
    }
}
class JitterBuffer {
    private val packets = java.util.TreeMap<Long,Message>()
    private var epoch = -1L
    private var last = -1L
    var drops = 0; private set
    val size get() = packets.size
    fun insert(m: Message): Boolean {
        if (!m.validAudio() || m.epoch!! < epoch) return false
        val changed = epoch != m.epoch
        if (changed) { packets.clear(); epoch = m.epoch; last = -1 }
        if (m.sequence!! <= last) return changed
        packets.putIfAbsent(m.sequence,m)
        if (packets.size > 100) { packets.pollFirstEntry(); drops++ }
        return changed
    }
    fun take(now: Double, offset: Double, horizon: Double = .13): List<Message> {
        val result = mutableListOf<Message>()
        while (packets.isNotEmpty()) {
            val m = packets.firstEntry().value
            val local = m.pts!! - offset
            if (local > now + horizon.coerceIn(.13,.5)) break
            packets.pollFirstEntry()
            if(last>=0&&m.sequence!!>last+1)drops+=(m.sequence-last-1).coerceAtMost(1000).toInt()
            last = m.sequence!!
            if (local < now + .015) drops++ else result.add(m)
        }
        return result
    }
}
