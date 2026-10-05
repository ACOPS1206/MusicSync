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
    private val timestamp=AudioTimestamp()
    override val latency=.04
    override fun start(){
        val min=AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_STEREO,AudioFormat.ENCODING_PCM_FLOAT)
        require(min>0)
        track=AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).setAllowedCapturePolicy(AudioAttributes.ALLOW_CAPTURE_BY_NONE).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build())
            .setBufferSizeInBytes(maxOf(min,480*8*4)).setTransferMode(AudioTrack.MODE_STREAM).setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY).build().also{check(it.state==AudioTrack.STATE_INITIALIZED);it.play()}
    }
    override fun position():Pair<Long,Double>?=track?.let{if(it.getTimestamp(timestamp)&&timestamp.framePosition>0)timestamp.framePosition to timestamp.nanoTime/1e9 else null}
    override fun write(samples:FloatArray){val output=track?:return;var offset=0;while(offset<samples.size){val n=output.write(samples,offset,samples.size-offset,AudioTrack.WRITE_BLOCKING);check(n>0){"AudioTrack write failed: $n"};offset+=n}}
    override fun close(){val output=track;track=null;runCatching{output?.pause();output?.flush();output?.release()}}
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
