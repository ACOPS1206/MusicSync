// SPDX-License-Identifier: MIT
package dev.musicsync.core
import kotlin.test.*
import java.io.*
import java.net.*
import java.util.concurrent.*
import kotlin.concurrent.thread
class CoreTest {
    @Test fun swiftCompatibleFramingAndFloatPayload(){
        val m=Message("audio",sequence=1,epoch=2,pts=10.2,sampleRate=48000.0,channels=2,frames=2,payload=Wire.payload(floatArrayOf(.5f,-.5f,1f,0f)))
        val round=Wire.read(ByteArrayInputStream(Wire.encode(m)));assertTrue(round.validAudio());assertContentEquals(floatArrayOf(.5f,-.5f,1f,0f),round.samples())
        assertFails{Wire.read(ByteArrayInputStream(byteArrayOf(0,3,0,0)))}
        assertFalse(m.copy(frames=3).validAudio());assertFalse(m.copy(pts=Double.NaN).validAudio())
    }
    @Test fun ntpHostMinusClientAndJitter(){val c=ClockEstimate();repeat(8){c.observe(10.0,12.005,12.006,10.011)};assertTrue(c.ready);assertEquals(2.0,c.offset,1e-8);assertEquals(.010,c.rtt,1e-8);assertEquals(.005,c.uncertainty,1e-8);c.observe(0.0,0.0,0.0,-1.0);assertEquals(2.0,c.offset,1e-8)}
    @Test fun jitterEpochDuplicateLateAndBound(){val q=JitterBuffer();fun m(seq:Long,pts:Double,epoch:Long=1)=Message("audio",sequence=seq,epoch=epoch,pts=pts,sampleRate=48000.0,channels=2,frames=1,payload=Wire.payload(floatArrayOf(0f,0f)))
        q.insert(m(1,10.1));q.insert(m(1,10.1));assertEquals(1,q.size);assertEquals(0,q.take(9.0,0.0).size);assertEquals(1,q.take(10.0,0.0).size)
        q.insert(m(2,9.0));assertEquals(0,q.take(10.0,0.0).size);assertEquals(1,q.drops);repeat(120){q.insert(m(it+3L,20.0))};assertEquals(100,q.size)
        assertTrue(q.insert(m(1,30.0,2)));q.insert(m(500,30.0,1));assertEquals(1,q.size)
    }
    @Test fun tlsExporterPinsAndProof(){
        val store=MemoryStore();val identity=Identity(store);assertEquals(Pairing.pin(identity.cert),Pairing.pin(Identity(store).cert))
        val listener=ServerSocket(0);val serverResult=CompletableFuture<SecurePeer>()
        thread(isDaemon=true){try{serverResult.complete(SecurePeer.server(listener.accept(),identity))}catch(e:Exception){serverResult.completeExceptionally(e)}}
        val client=SecurePeer.client(Socket("127.0.0.1",listener.localPort),Pairing.pin(identity.cert));val server=serverResult.get(15,TimeUnit.SECONDS)
        assertEquals(client.binding,server.binding);assertEquals(client.code,server.code);assertEquals(8,client.code.length)
        val secret=Pairing.secret();val proof=Pairing.proof(secret,"nonce","host","client",client.binding)
        assertTrue(Pairing.verify(proof,secret,"nonce","host","client",server.binding));assertFalse(Pairing.verify(proof,secret,"nonce","host","client","wrong-binding"))
        val got=CompletableFuture<Message>();server.onMessage={got.complete(it)};server.start();client.start();client.send(Message("ping",t1=1.0));assertEquals("ping",got.get(5,TimeUnit.SECONDS).kind)
        client.close();server.close();listener.close()
    }
    @Test fun invalidVolumeAndLegacyPermissions(){assertNull(Session.validVolume(Double.NaN));assertNull(Session.validVolume(1.01));assertEquals(1.0,Session.validVolume(1.0));val p=Wire.json.decodeFromString<Permissions>("{}");assertTrue(p.hostMayControlClient);assertFalse(p.clientMayControlPeerDevices)}
    @Test fun waveMonoResampleAndRiffValidation(){val pcm=java.nio.ByteBuffer.allocate(44+160).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        pcm.put("RIFF".toByteArray()).putInt(36+160).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(160);repeat(80){pcm.putShort(8192)}
        val source=WaveSource(ByteArrayInputStream(pcm.array()));val samples=source.read()!!;assertEquals(960,samples.size);assertTrue(samples.all{it==.25f});assertNull(source.read());source.close()
    }
}
