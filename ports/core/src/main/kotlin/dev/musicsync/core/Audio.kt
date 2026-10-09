// SPDX-License-Identifier: MIT
package dev.musicsync.core

import kotlin.math.*
import java.util.concurrent.atomic.AtomicBoolean

/** Written frame -> actual output time mapping supplied by each OS audio backend. */
interface AudioSink : AutoCloseable {
    val latency: Double
    val underruns: Int get()=0
    fun start()
    fun position(): Pair<Long,Double>?
    fun write(samples: FloatArray)
}
interface AudioSource : AutoCloseable {
    val monitor: Boolean
    fun read(): FloatArray?
}
interface Platform {
    val name: String
    val store: Store
    val systemVolume: Boolean get() = false
    fun volume(): Double = 1.0
    fun setVolume(value: Double): Boolean = false
    fun sink(): AudioSink
    fun fileSource(file: String): AudioSource
    fun captureSource(): AudioSource
}
/** An independent sample lane. Effects never occupy the music lane. */
internal class SampleLane {
    private data class Block(val at: Double, val pcm: FloatArray)
    private val blocks = java.util.PriorityQueue<Block>(compareBy { it.at })
    private var current: Block? = null
    private var index = 0
    private var nextTime: Double? = null
    var drops = 0; private set
    var error = 0.0; private set
    @Synchronized fun add(samples: FloatArray, at: Double, continuous: Boolean = true) {
        require(samples.isNotEmpty() && samples.size % 2 == 0)
        val end = nextTime
        val start = if (continuous && end != null && kotlin.math.abs(at-end) <= .002) end else at
        if (blocks.size >= 100) { blocks.poll(); drops++ }
        blocks.add(Block(start, samples.copyOf()))
        nextTime = start + samples.size / 2 / 48000.0
    }
    @Synchronized fun clear() { blocks.clear(); current = null; index = 0; nextTime = null }
    @Synchronized fun mix(into: FloatArray, at: Double, gain: Float, channel: String) {
        for (frame in 0 until into.size / 2) {
            val time = at + frame / 48000.0
            while (current == null) {
                val first = blocks.peek() ?: break
                if (first.at > time + 1.0/48000) break
                current = blocks.poll(); index = 0
                error = time-first.at
                if (error > .003) { index = (error*48000).roundToInt()*2; drops++ }
                if (index >= first.pcm.size) current = null else break
            }
            val block = current ?: continue
            val left = block.pcm[index]; val right = block.pcm[index+1]
            into[frame*2] += (if (channel == "right") right else left)*gain
            into[frame*2+1] += (if (channel == "left") left else right)*gain
            index += 2
            if (index >= block.pcm.size) current = null
        }
    }
}
/** Continuous hardware-timed output, with a separate additive identification lane. */
class ScheduledPlayer(private val factory: ()->AudioSink) : AutoCloseable {
    private class Run {
        val active = AtomicBoolean(true)
        val music = SampleLane(); val effects = SampleLane()
        @Volatile var sink: AudioSink? = null
        var worker: Thread? = null
    }
    private var run: Run? = null
    @Volatile var gain = 1.0
    @Volatile var channel = "stereo"
    @Volatile var calibration = 0.0
    @Volatile var error = 0.0; private set
    @Volatile var failure = ""; private set
    @Volatile var drops = 0; private set
    @Volatile var outputLatency = .04; private set
    @Synchronized fun schedule(samples: FloatArray, at: Double) {
        if (!at.isFinite() || samples.isEmpty() || samples.size % 2 != 0) return
        if (failure.isNotEmpty()) { drops++; return }
        val state = run ?: start()
        val before = state.music.drops; state.music.add(samples, at + calibration); drops += state.music.drops-before
    }
    @Synchronized fun reset() { run?.music?.clear() }
    private fun start(): Run {
        val state = Run(); run = state
        state.worker = kotlin.concurrent.thread(name="MusicSync audio timeline",isDaemon=true) {
            var output: AudioSink? = null
            try {
                output = factory(); state.sink = output
                if (!state.active.get()) return@thread
                output.start(); outputLatency = output.latency
                var written = 0L
                var origin = Clock.now()+output.latency
                var nextStamp = 0.0; var previousUnderruns = 0
                while (state.active.get()) {
                    if (Clock.now() >= nextStamp) {
                        output.latency.takeIf{it.isFinite()&&it in 0.0..2.0}?.let{outputLatency=it}
                        output.position()?.let { (frame, time) -> origin = OutputTimeline.discipline(origin,frame,time,written) }
                        val underruns = output.underruns
                        if (underruns > previousUnderruns) drops += underruns-previousUnderruns
                        previousUnderruns = underruns; nextStamp = Clock.now()+.1
                    }
                    val chunk = FloatArray(960); val at = origin+written/48000.0
                    val previousDrops = state.music.drops+state.effects.drops
                    val g = gain.takeIf{it.isFinite()}?.coerceIn(0.0,1.0)?.toFloat() ?: 0f
                    state.music.mix(chunk,at,g,channel)
                    state.effects.mix(chunk,at,g,"stereo")
                    for (i in chunk.indices) chunk[i] = chunk[i].coerceIn(-1f,1f)
                    drops += state.music.drops+state.effects.drops-previousDrops
                    error = state.music.error
                    output.write(chunk); written += 480
                }
            } catch (e: Exception) {
                if (state.active.get()) { drops++; failure=e.message?.take(160)?:e.javaClass.simpleName }
            } finally { state.active.set(false); runCatching { output?.close() }; state.sink = null }
        }
        return state
    }
    @Synchronized fun identify() {
        if (failure.isNotEmpty()) return
        val samples = FloatArray(48000*2)
        for (i in 0 until 48000) {
            val t = i/48000.0; val on = (t%.30)<.12 && t<.9
            val value = if (on) (.15*sin(2*PI*880*t)*sin(PI*(t%.30)/.12)).toFloat() else 0f
            samples[i*2] = value; samples[i*2+1] = value
        }
        (run ?: start()).effects.add(samples,Clock.now()+.15,continuous=false)
    }
    @Synchronized override fun close() {
        val old = run; run = null
        old?.active?.set(false); runCatching { old?.sink?.close() }
        old?.worker?.join(500)
        old?.music?.clear(); old?.effects?.clear(); failure=""
        // Each worker owns its cancellation flag: an old worker cannot revive on restart.
    }
}

/** A hardware discontinuity must not leave playback permanently on the old slow timeline. */
object OutputTimeline {
    fun discipline(origin:Double, frame:Long, time:Double, written:Long):Double {
        if(!time.isFinite())return origin
        val measured=time-frame/48000.0
        val delta=measured-origin
        return if(written<48000||abs(delta)>.020)measured
            else origin+delta.coerceIn(-.001,.001)*.1
    }
}
