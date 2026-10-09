// SPDX-License-Identifier: MIT
package dev.musicsync.desktop
import kotlin.test.*

class PulseRoutingTest {
    private class Fake : PulseCommands {
        var default="speaker";var virtual="";var failMove=false
        val calls=mutableListOf<List<String>>()
        val sinks=mutableMapOf("1" to "speaker")
        val streams=mutableMapOf("10" to ("1" to "100"),"11" to ("1" to "200"))
        override fun call(args:List<String>):String {
            calls.add(args)
            return when(args[0]) {
                "get-default-sink"->default
                "load-module"->{virtual=args.first{it.startsWith("sink_name=")}.substringAfter('=');sinks["2"]=virtual;"42"}
                "set-default-sink"->{default=args[1];""}
                "move-sink-input"->{if(failMove)error("fixture routing failure");val old=streams[args[1]]!!;streams[args[1]]=sinks.entries.single{it.value==args[2]}.key to old.second;""}
                "unload-module"->{sinks.remove("2");""}
                "-f"->if(args.last()=="sinks")sinks.entries.joinToString(prefix="[",postfix="]"){"{\"index\":${it.key},\"name\":\"${it.value}\"}"}
                    else streams.entries.joinToString(prefix="[",postfix="]"){"{\"index\":${it.key},\"sink\":${it.value.first},\"properties\":{\"application.process.id\":\"${it.value.second}\"}}"}
                else->error("Unexpected command $args")
            }
        }
    }
    @Test fun capturesExistingMusicButKeepsOwnDelayedPlaybackOnPhysicalSpeaker(){
        val fake=Fake();val route=PulseRouting(fake,200)
        assertEquals("2",fake.streams["10"]!!.first);assertEquals("1",fake.streams["11"]!!.first)
        fake.streams["11"]="2" to "200";route.routeLocalOutput();assertEquals("1",fake.streams["11"]!!.first)
        route.close();assertEquals("speaker",fake.default);assertEquals("1",fake.streams["10"]!!.first);assertFalse(fake.sinks.containsKey("2"))
        val count=fake.calls.size;route.close();assertEquals(count,fake.calls.size)
    }
    @Test fun cleanupPreservesAnIndependentDefaultSinkChange(){
        val fake=Fake();val route=PulseRouting(fake,200);fake.default="user-selected-speaker";route.close()
        assertEquals("user-selected-speaker",fake.default);assertEquals("1",fake.streams["10"]!!.first)
    }
    @Test fun setupFailureStillRestoresDefaultAndUnloadsVirtualSink(){
        val fake=Fake();fake.failMove=true
        assertFails{PulseRouting(fake,200)};assertEquals("speaker",fake.default);assertFalse(fake.sinks.containsKey("2"))
    }
}
