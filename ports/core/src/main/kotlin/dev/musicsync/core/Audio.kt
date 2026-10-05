// SPDX-License-Identifier: MIT
package dev.musicsync.core

import kotlin.math.*
import java.util.concurrent.atomic.AtomicBoolean

/** Written frame -> actual output time mapping supplied by each OS audio backend. */
interface AudioSink : AutoCloseable {
    val latency: Double
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
/**
 * Continuous audio clock with scheduled silence, never packet-arrival playback.
 * Timestamp updates discipline the frame timeline; noisy observations cannot reorder audio.
 */
class ScheduledPlayer(private val factory: ()->AudioSink) : AutoCloseable {
    private data class Block(val at: Double, val pcm: FloatArray)
    private val blocks = java.util.PriorityQueue<Block>(compareBy { it.at })
    private val active = AtomicBoolean(false)
    @Volatile var gain = 1.0
    @Volatile var channel = "stereo"
    @Volatile var calibration = 0.0
    @Volatile var error = 0.0; private set
    @Volatile var drops = 0; private set
    @Volatile var outputLatency = .04; private set
    private var worker: Thread? = null
    private var sink: AudioSink? = null
    @Synchronized fun schedule(samples: FloatArray, at: Double) {
        if (!at.isFinite()) return
        if (!active.get()) start()
        if (blocks.size >= 100) { blocks.poll(); drops++ }
        blocks.add(Block(at + calibration,samples.copyOf()))
    }
    @Synchronized fun reset() { blocks.clear() }
    private fun start() {
        active.set(true)
        worker = kotlin.concurrent.thread(name="MusicSync audio timeline",isDaemon=true) {
            var output: AudioSink? = null
            try {
                output = factory(); sink = output; output.start(); outputLatency = output.latency
                var written = 0L
                var origin = Clock.now()+output.latency
                var current: Block? = null; var index = 0
                var nextStamp = 0.0
                while (active.get()) {
                    if (Clock.now() >= nextStamp) {
                        output.position()?.let { (frame, time) ->
                            val measured = time - frame/48000.0
                            // Snap initial observations; then slow correction to avoid jitter modulation.
                            origin = if (written < 48000) measured else origin + (measured-origin).coerceIn(-.001,.001)*.1
                        }
                        nextStamp = Clock.now() + 1.0
                    }
                    val chunk = FloatArray(480*2)
                    for (frame in 0 until 480) {
                        val at = origin + (written+frame)/48000.0
                        if (current == null) {
                            current = synchronized(this) {
                                blocks.peek()?.takeIf { it.at <= at+1.0/48000 }?.also { blocks.poll() }
                            }
                            index = 0
                            current?.let {
                                error = at-it.at
                                if (error > .003) { index = (error*48000).roundToInt()*2; drops++ }
                            }
                        }
                        val block = current
                        if (block != null) {
                            if (index+1 < block.pcm.size) {
                                val left = block.pcm[index]; val right = block.pcm[index+1]
                                val g = gain.toFloat()
                                chunk[frame*2] = (if (channel == "right") right else left)*g
                                chunk[frame*2+1] = (if (channel == "left") left else right)*g
                                index += 2
                            }
                            if (index >= block.pcm.size) current = null
                        }
                    }
                    output.write(chunk); written += 480
                }
            } catch (_: Exception) { drops++ } finally { active.set(false); runCatching { output?.close() }; sink = null }
        }
    }
    fun identify() {
        val samples = FloatArray(48000*2)
        for (i in 0 until 48000) {
            val t = i/48000.0; val on = (t%.30)<.12 && t<.9
            val value = if (on) (.15*sin(2*PI*880*t)*sin(PI*(t%.30)/.12)).toFloat() else 0f
            samples[i*2] = value; samples[i*2+1] = value
        }
        schedule(samples,Clock.now()+.15)
    }
    override fun close() {
        active.set(false); runCatching { sink?.close() }; worker?.join(500); synchronized(this) { blocks.clear() }; worker = null
    }
}
