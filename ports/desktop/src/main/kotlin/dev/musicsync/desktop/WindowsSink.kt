// SPDX-License-Identifier: MIT
package dev.musicsync.desktop

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import dev.musicsync.core.AudioSink
import dev.musicsync.core.Clock
import java.io.File

interface RenderLibrary : Library {
    fun ms_render_open(): Pointer?
    fun ms_render_last_error(): Int
    fun ms_render_latency(context: Pointer): Double
    fun ms_render_position(context: Pointer, result: DoubleArray): Int
    fun ms_render_write(context: Pointer, samples: FloatArray, frames: Int): Int
    fun ms_render_stop(context: Pointer)
    fun ms_render_dispose(context: Pointer)
}
/** Every COM operation runs on the audio worker; UI cancellation sets only an atomic flag. */
class WindowsSink : AudioSink {
    private val library: RenderLibrary
    private val lock=Any()
    private var pointer:Pointer?=null
    private var owner:Thread?=null
    private var stopped=false
    private var measuredLatency=.04
    override val latency get()=measuredLatency
    init {
        val path=System.getenv("MUSICSYNC_CAPTURE_LIBRARY")?:run{
            val resource=javaClass.getResourceAsStream("/native/musicsync_capture.dll")
                ?:error("Windows WASAPI output DLL missing. Install the complete MusicSync package.")
            val file=File.createTempFile("musicsync-output-",".dll");file.deleteOnExit()
            resource.use{input->file.outputStream().use{input.copyTo(it)}};file.absolutePath
        }
        library=Native.load(path,RenderLibrary::class.java)
    }
    private fun failure()="WASAPI output failed (0x${library.ms_render_last_error().toUInt().toString(16)}). Check the selected Windows speaker."
    override fun start(){
        owner=Thread.currentThread()
        val value=library.ms_render_open()?:error(failure())
        synchronized(lock){pointer=value;if(stopped)library.ms_render_stop(value)}
        measuredLatency=library.ms_render_latency(value).also{require(it.isFinite()&&it in 0.0..2.0)}
    }
    override fun position():Pair<Long,Double>? {
        val value=pointer?:return null
        val result=DoubleArray(2);val before=Clock.now()
        val ok=library.ms_render_position(value,result);val after=Clock.now()
        if(ok==0||!result.all{it.isFinite()}||kotlin.math.abs(result[1])>.1||after-before>.01)return null
        // QPC and System.nanoTime have different epochs. Map through a short paired observation.
        return result[0].toLong() to ((before+after)/2+result[1])
    }
    override fun write(samples:FloatArray){
        require(samples.size%2==0&&samples.size in 2..9600)
        val value=pointer?:error("Windows output is closed")
        if(library.ms_render_write(value,samples,samples.size/2)!=samples.size/2){
            if(!synchronized(lock){stopped})error(failure())
        }
    }
    override fun close(){synchronized(lock){
        stopped=true
        pointer?.let{value->
            library.ms_render_stop(value)
            if(Thread.currentThread()===owner){library.ms_render_dispose(value);pointer=null}
        }
    }}
}
