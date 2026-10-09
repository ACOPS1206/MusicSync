// SPDX-License-Identifier: MIT
package dev.musicsync.desktop
import dev.musicsync.core.*
import java.io.*
import java.nio.*
import java.nio.file.*
import javax.sound.sampled.*
import com.sun.jna.*

class DesktopStore : Store {
    private val folder = File(System.getProperty("user.home"),".musicsync")
    private val file = File(folder,"identity.properties")
    private val data = java.util.Properties()
    init {folder.mkdirs();protect(folder);if(file.exists())file.inputStream().use{data.load(it)}}
    private fun protect(f:File){runCatching{Files.setPosixFilePermissions(f.toPath(),java.nio.file.attribute.PosixFilePermissions.fromString(if(f.isDirectory)"rwx------"else"rw-------"))}}
    @Synchronized override fun clearPairings(){
        val keys=data.stringPropertyNames().filter{pairingKey(it)}
        keys.forEach{data.remove(it)}
        if(keys.isNotEmpty())put("id.client",data.getProperty("id.client"))
    }
    @Synchronized override fun get(key:String)=data.getProperty(key)
    @Synchronized override fun put(key:String,value:String?){if(value==null)data.remove(key)else data.setProperty(key,value)
        val tmp=File(folder,"identity.tmp");tmp.createNewFile();protect(tmp);tmp.outputStream().use{data.store(it,"MusicSync private local identity; do not share")};Files.move(tmp.toPath(),file.toPath(),StandardCopyOption.REPLACE_EXISTING);protect(file)
    }
}
class DesktopPlatform : dev.musicsync.core.Platform {
    @Volatile private var routing: PulseRouting? = null
    override val name = (System.getenv("COMPUTERNAME") ?: runCatching{java.net.InetAddress.getLocalHost().hostName}.getOrDefault("MusicSync Desktop"))
    override val store = DesktopStore()
    override fun sink():AudioSink=if(System.getProperty("os.name").startsWith("Windows"))WindowsSink()else DesktopSink { routing?.routeLocalOutput() }
    override fun fileSource(file:String):AudioSource=WaveSource(File(file).inputStream().buffered())
    override fun captureSource():AudioSource {
        if(System.getProperty("os.name").startsWith("Windows"))return WindowsCapture()
        if(System.getenv("MUSICSYNC_MONITOR_CAPTURE")=="1")return PulseCapture()
        val route=PulseRouting();routing=route
        try { return PulseCapture(route.virtual,monitor=false,onClose={route.close();if(routing===route)routing=null}) }
        catch(e:Exception){route.close();routing=null;throw e}
    }
}
class DesktopSink(private val route: ()->Unit = {}) : AudioSink {
    private var line: SourceDataLine?=null
    private var started=0.0
    override val latency get()=.04
    override fun start(){val format=AudioFormat(48000f,16,2,true,false);val output=AudioSystem.getSourceDataLine(format);output.open(format,7680);line=output;try{route();output.start();started=Clock.now()}catch(e:Exception){close();throw e}}
    override fun position():Pair<Long,Double>?=line?.let{if(it.longFramePosition>0)it.longFramePosition to Clock.now()else null}
    override fun write(samples:FloatArray){val bytes=ByteBuffer.allocate(samples.size*2).order(ByteOrder.LITTLE_ENDIAN);samples.forEach{bytes.putShort((it.coerceIn(-1f,1f)*32767).toInt().toShort())};val raw=bytes.array();var offset=0
        while(offset<raw.size){val n=line?.write(raw,offset,raw.size-offset)?:return;if(n<=0)return;offset+=n}
    }
    override fun close(){val output=line;line=null;runCatching{output?.stop();output?.flush();output?.close()}}
}
class PulseCapture(sinkName:String?=null,override val monitor:Boolean=true,private val onClose:()->Unit={}) : AudioSource {
    private val closed=java.util.concurrent.atomic.AtomicBoolean(false)
    private val process:Process
    init {
        val sink=sinkName?:Pactl().call(listOf("get-default-sink"));require(sink.isNotEmpty()){ "Install PipeWire-Pulse or PulseAudio and pulseaudio-utils (pactl/parec)" }
        process=ProcessBuilder("parec","--device=$sink.monitor","--format=float32le","--rate=48000","--channels=2","--latency-msec=20").redirectError(ProcessBuilder.Redirect.DISCARD).start()
    }
    override fun read():FloatArray?{val raw=ByteArray(3840);val stream=DataInputStream(process.inputStream);try{stream.readFully(raw)}catch(_:EOFException){return null};val data=ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);return FloatArray(960){data.float}}
    override fun close(){if(!closed.compareAndSet(false,true))return;try{process.destroy();process.inputStream.close()}finally{onClose()}}
}
interface CaptureLibrary : Library {
    fun ms_capture_open():Pointer?
    fun ms_capture_open_device(captureName:WString,outputName:WString?):Pointer?
    fun ms_capture_read(context:Pointer,pcm:FloatArray,frames:Int):Int
    fun ms_capture_stop(context:Pointer)
    fun ms_capture_dispose(context:Pointer)
}
class WindowsCapture : AudioSource {
    private val captureName=System.getenv("MUSICSYNC_CAPTURE_DEVICE")?.takeIf{it.isNotBlank()}
    private val outputName=System.getenv("MUSICSYNC_OUTPUT_DEVICE")?.takeIf{it.isNotBlank()}
    override val monitor get()=captureName==null
    private val library:CaptureLibrary
    private val pointer:Pointer
    @Volatile private var closed=false
    private val readLock=Any()
    init {
        val override=System.getenv("MUSICSYNC_CAPTURE_LIBRARY")
        val path=override?:run{
            val input=javaClass.getResourceAsStream("/native/musicsync_capture.dll")?:error("Windows capture DLL missing from this package")
            val tmp=File.createTempFile("musicsync-capture-",".dll");tmp.deleteOnExit();input.use{i->tmp.outputStream().use{i.copyTo(it)}};tmp.absolutePath
        }
        library=Native.load(path,CaptureLibrary::class.java);pointer=(if(captureName==null)library.ms_capture_open()else library.ms_capture_open_device(WString(captureName),outputName?.let{WString(it)}))?:error("WASAPI capture unavailable. Use an exact virtual output name and a different physical playback device; disable direct monitoring.")
    }
    override fun read():FloatArray?=synchronized(readLock){if(closed)return@synchronized null;val out=FloatArray(960);if(library.ms_capture_read(pointer,out,480)>0)out else null}
    @Synchronized override fun close(){if(closed)return;closed=true;library.ms_capture_stop(pointer);synchronized(readLock){library.ms_capture_dispose(pointer)}}
}
