// SPDX-License-Identifier: MIT
package dev.musicsync.desktop

import kotlinx.serialization.json.*
import java.util.concurrent.TimeUnit

internal fun interface PulseCommands { fun call(args: List<String>): String }
internal class Pactl : PulseCommands {
    override fun call(args: List<String>): String {
        val process=ProcessBuilder(listOf("pactl")+args).redirectErrorStream(true).start()
        val result=java.util.concurrent.CompletableFuture.supplyAsync { process.inputStream.bufferedReader().use{it.readText()} }
        if(!process.waitFor(3,TimeUnit.SECONDS)){process.destroyForcibly();error("PulseAudio command timed out")}
        val text=result.get(1,TimeUnit.SECONDS).trim()
        check(process.exitValue()==0){"PulseAudio routing failed: ${text.take(160)}"};return text
    }
}
/** A silent capture sink; only MusicSync's delayed output is routed to the original speaker. */
internal class PulseRouting(private val commands: PulseCommands = Pactl(), private val pid: Long = ProcessHandle.current().pid()) : AutoCloseable {
    val original = commands.call(listOf("get-default-sink"))
    val virtual = "musicsync_${pid}_${java.util.UUID.randomUUID().toString().take(8)}"
    private var module: String? = null
    private var changedDefault = false
    @Volatile private var closed = false
    private fun list(kind: String) = Json.parseToJsonElement(commands.call(listOf("-f","json","list",kind))).jsonArray.map{it.jsonObject}
    private fun index(name: String) = list("sinks").single{it["name"]?.jsonPrimitive?.content==name}["index"]!!.jsonPrimitive.content
    private fun processID(stream: JsonObject) = stream["properties"]?.jsonObject?.get("application.process.id")?.jsonPrimitive?.content
    init {
        try {
            val physical=index(original)
            module=commands.call(listOf("load-module","module-null-sink","sink_name=$virtual","rate=48000","channels=2","sink_properties=device.description=MusicSync_Synchronized_Capture"))
            commands.call(listOf("set-default-sink",virtual));changedDefault=true
            // Existing audio keeps playing, but now only into the silent capture sink.
            for(stream in list("sink-inputs"))if(stream["sink"]?.jsonPrimitive?.content==physical&&processID(stream)!=pid.toString()){
                commands.call(listOf("move-sink-input",stream["index"]!!.jsonPrimitive.content,virtual))
            }
        } catch(e:Exception) { close();throw e }
    }
    fun routeLocalOutput() {
        check(!closed)
        val outputs=list("sink-inputs").filter{processID(it)==pid.toString()}
        check(outputs.isNotEmpty()) { "MusicSync output must use PulseAudio/PipeWire-Pulse. Select the PulseAudio JavaSound output or use monitor capture." }
        for(output in outputs)commands.call(listOf("move-sink-input",output["index"]!!.jsonPrimitive.content,original))
    }
    @Synchronized override fun close() {
        if(closed)return;closed=true
        // Do not overwrite a default sink changed independently by the user.
        if(changedDefault)runCatching{
            if(commands.call(listOf("get-default-sink"))==virtual)commands.call(listOf("set-default-sink",original))
        }
        runCatching {
            val sink=index(virtual)
            for(stream in list("sink-inputs"))if(stream["sink"]?.jsonPrimitive?.content==sink){
                runCatching{commands.call(listOf("move-sink-input",stream["index"]!!.jsonPrimitive.content,original))}
            }
        }
        module?.let{runCatching{commands.call(listOf("unload-module",it))}}
    }
}
