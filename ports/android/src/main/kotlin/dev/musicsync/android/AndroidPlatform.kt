// SPDX-License-Identifier: MIT
package dev.musicsync.android

import android.content.Context
import android.media.*
import android.media.projection.MediaProjection
import android.net.Uri
import android.os.*
import android.security.keystore.*
import dev.musicsync.core.*
import java.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class AndroidStore(context:Context):Store {
    private val prefs=context.getSharedPreferences("private-pairing",Context.MODE_PRIVATE)
    private val key:SecretKey
    init {val ks=KeyStore.getInstance("AndroidKeyStore");ks.load(null);key=(ks.getKey("MusicSyncPairing",null) as? SecretKey)?:run{
        val gen=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder("MusicSyncPairing",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());gen.generateKey()
    }}
    @Synchronized override fun clearPairings(){
        val update=prefs.edit();prefs.all.keys.filter{pairingKey(it)}.forEach{update.remove(it)};check(update.commit())
    }
    @Synchronized override fun get(key:String):String? {val saved=prefs.getString(key,null)?:return null
        return runCatching{val bytes=Base64.getDecoder().decode(saved);require(bytes.size>12);val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,this.key,GCMParameterSpec(128,bytes.copyOfRange(0,12)));cipher.doFinal(bytes.copyOfRange(12,bytes.size)).toString(Charsets.UTF_8)}.getOrNull()
    }
    @Synchronized override fun put(key:String,value:String?){if(value==null){check(prefs.edit().remove(key).commit());return};val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,this.key);val bytes=cipher.iv+cipher.doFinal(value.toByteArray());check(prefs.edit().putString(key,Base64.getEncoder().encodeToString(bytes)).commit())}
}
class AndroidPlatform(private val context:Context):Platform {
    override val name = "${Build.MANUFACTURER} ${Build.MODEL}"
    override val store = AndroidStore(context)
    @Volatile var projection:MediaProjection?=null
    private val manager=context.getSystemService(AudioManager::class.java)
    override val systemVolume=true
    override fun volume():Double=manager.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble()/manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
    override fun setVolume(value:Double):Boolean=runCatching{manager.setStreamVolume(AudioManager.STREAM_MUSIC,(value*manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)).toInt(),0);true}.getOrDefault(false)
    override fun sink():AudioSink=AndroidSink()
    override fun fileSource(file:String):AudioSource=WaveSource(context.contentResolver.openInputStream(Uri.parse(file))!!.buffered())
    override fun captureSource():AudioSource=AndroidCapture(projection?:error("Allow system audio sharing first"))
}
class AndroidSink:AudioSink {
    private var track:AudioTrack?=null
    private var owner:Thread?=null
    @Volatile private var stopped=false
    @Volatile private var bufferFrames=2880
    @Volatile private var observedUnderruns=0
    @Volatile private var estimatedLatency=.06
    private var submittedFrames=0L
    private val timestamp=AudioTimestamp()
    override val latency get()=estimatedLatency
    override val underruns get()=observedUnderruns
    override fun start(){
        owner=Thread.currentThread()
        runCatching{Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)}
        val min=AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_STEREO,AudioFormat.ENCODING_PCM_FLOAT)
        require(min>0){"48 kHz float stereo output is unavailable: $min"}
        val minimumFrames=(min+7)/8
        val output=AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).setAllowedCapturePolicy(AudioAttributes.ALLOW_CAPTURE_BY_NONE).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build())
            .setBufferSizeInBytes(maxOf(min*2,5760*8)).setTransferMode(AudioTrack.MODE_STREAM).setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY).build()
        check(output.state==AudioTrack.STATE_INITIALIZED){"AudioTrack initialization failed"}
        track=output
        output.setBufferSizeInFrames(maxOf(minimumFrames,2880))
        bufferFrames=output.bufferSizeInFrames
        estimatedLatency=bufferFrames/48000.0
        if(!stopped)output.play()
    }
    override fun position():Pair<Long,Double>? {
        val output=track?:return null
        if(stopped)return null
        val count=output.underrunCount
        if(count>observedUnderruns){
            // Grow only the app's effective buffer, bounded by the reserved capacity.
            output.setBufferSizeInFrames(minOf(output.bufferCapacityInFrames,output.bufferSizeInFrames+960))
        }
        observedUnderruns=count
        bufferFrames=output.bufferSizeInFrames
        if(!output.getTimestamp(timestamp)||timestamp.framePosition<=0)return null
        val time=timestamp.nanoTime/1e9
        val observedAt=Clock.now()
        if(time<observedAt-.5||time>observedAt+.05)return null
        // Written-versus-presented frames expose route queues beyond the app buffer.
        val pending=submittedFrames-timestamp.framePosition-(observedAt-time)*48000.0
        estimatedLatency=maxOf(bufferFrames/48000.0,(pending/48000.0).coerceIn(0.0,2.0))
        return timestamp.framePosition to time
    }
    override fun write(samples:FloatArray){
        val output=track?:return
        var offset=0
        while(offset<samples.size&&!stopped){
            val n=output.write(samples,offset,samples.size-offset,AudioTrack.WRITE_BLOCKING)
            if(n<=0){if(stopped)return;error("AudioTrack write failed: $n; underruns=$observedUnderruns; buffer=$bufferFrames frames")}
            submittedFrames+=n/2
            offset+=n
        }
    }
    @Synchronized override fun close(){
        stopped=true
        val output=track?:return
        runCatching{output.pause()}
        // UI cancellation interrupts blocking writes; the audio owner releases the handle.
        if(Thread.currentThread()===owner){track=null;runCatching{output.flush();output.release()}}
    }
}
class AndroidCapture(projection:MediaProjection):AudioSource {
    override val monitor=true
    private val record:AudioRecord
    init {
        val config=AudioPlaybackCaptureConfiguration.Builder(projection).addMatchingUsage(AudioAttributes.USAGE_MEDIA).addMatchingUsage(AudioAttributes.USAGE_GAME).excludeUid(Process.myUid()).build()
        val min=AudioRecord.getMinBufferSize(48000,AudioFormat.CHANNEL_IN_STEREO,AudioFormat.ENCODING_PCM_FLOAT)
        record=AudioRecord.Builder().setAudioPlaybackCaptureConfig(config).setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_IN_STEREO).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build()).setBufferSizeInBytes(maxOf(min,3840*8)).build()
        check(record.state==AudioRecord.STATE_INITIALIZED);record.startRecording()
    }
    override fun read():FloatArray? {val data=FloatArray(960);var offset=0;while(offset<data.size){val n=record.read(data,offset,data.size-offset,AudioRecord.READ_BLOCKING);if(n<=0)return null;offset+=n};return data}
    override fun close(){runCatching{record.stop();record.release()}}
}
