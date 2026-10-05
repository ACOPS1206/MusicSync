// SPDX-License-Identifier: MIT
// CI only: automatic approval exists in this test executable, never in production Session.
package dev.musicsync.desktop
import dev.musicsync.core.*
import java.util.concurrent.TimeUnit

fun main(args:Array<String>){
    val platform=object:Platform{
        override val name="MusicSync Kotlin Interop"
        override val store=MemoryStore()
        override fun sink():AudioSink=object:AudioSink{override val latency=.04;override fun start(){};override fun position():Pair<Long,Double>?=null;override fun write(samples:FloatArray){Thread.sleep(10)};override fun close(){}}
        override fun fileSource(file:String):AudioSource=object:AudioSource {
            override val monitor=false
            var frames=0
            override fun read():FloatArray? {if(frames++>=200)return null;Thread.sleep(10);return FloatArray(960){if(it%2==0).25f else -.25f}}
            override fun close(){}
        }
        override fun captureSource():AudioSource=error("Unused")
    }
    val session=Session(platform,false);session.setRole("Host");session.startHost(args.firstOrNull()?.toInt()?:49555)
    var streamed=false
    val end=Clock.now()+60
    while(Clock.now()<end){
        session.state.value.devices.filter{!it.approved&&it.confirmed}.forEach{session.approve(it.id)}
        if(!streamed&&session.state.value.devices.any{it.approved&&it.state=="Streaming"}){streamed=true;session.streamFile("fixture")}
        if(session.state.value.error.isNotEmpty())error(session.state.value.error)
        Thread.sleep(20)
    };session.close()
}
