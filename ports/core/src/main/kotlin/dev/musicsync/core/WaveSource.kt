// SPDX-License-Identifier: MIT
package dev.musicsync.core
import java.io.*
import java.nio.*
import kotlin.math.*
import java.util.concurrent.locks.LockSupport

/** Streaming RIFF/WAVE PCM decoder and linear resampler; no full-file memory load. */
class WaveSource(private val input: InputStream) : AudioSource {
    override val monitor = false
    private var remaining = 0L
    private var rate = 48000; private var channels = 2; private var bits = 16; private var format = 1
    private var phase = 0.0
    private var a: FloatArray? = null; private var b: FloatArray? = null
    private var produced = 0L; private var start = 0.0
    private val data = DataInputStream(input)
    init {
        fun read(n:Int)=ByteArray(n).also{data.readFully(it)}
        require(read(4).toString(Charsets.US_ASCII)=="RIFF"); read(4)
        require(read(4).toString(Charsets.US_ASCII)=="WAVE") { "Choose a PCM WAV file" }
        var foundFormat=false
        while(true){
            val tag=read(4).toString(Charsets.US_ASCII);val n=ByteBuffer.wrap(read(4)).order(ByteOrder.LITTLE_ENDIAN).int.toLong()and 0xffffffffL
            if(tag=="fmt "){
                require(n in 16..4096);val raw=read(n.toInt());val f=ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
                format=f.short.toInt()and 65535;channels=f.short.toInt();rate=f.int;f.int;f.short;bits=f.short.toInt()
                if(format==65534&&raw.size>=40)format=ByteBuffer.wrap(raw,24,2).order(ByteOrder.LITTLE_ENDIAN).short.toInt()
                require(format in listOf(1,3)&&channels in 1..2&&rate in 8000..192000&&bits in listOf(16,24,32)&&(format!=3||bits==32)){"WAV must be mono/stereo PCM16/24/32 or Float32"}
                foundFormat=true;if(n%2==1L)read(1)
            }else if(tag=="data"){require(foundFormat);remaining=n;break}
            else { var left=n+(n%2);while(left>0){val skipped=input.skip(left);if(skipped==0L){require(input.read()!=-1);left--}else left-=skipped} }
        }
    }
    private fun next():FloatArray? {
        val frameBytes=channels*(bits/8);if(remaining<frameBytes)return null
        val raw=ByteArray(frameBytes);data.readFully(raw);remaining-=frameBytes
        val result=FloatArray(2)
        for(channel in 0 until channels){val offset=channel*(bits/8);val value=when{
            format==3->ByteBuffer.wrap(raw,offset,4).order(ByteOrder.LITTLE_ENDIAN).float
            bits==16->ByteBuffer.wrap(raw,offset,2).order(ByteOrder.LITTLE_ENDIAN).short/32768f
            bits==24->{var v=(raw[offset].toInt()and 255)or((raw[offset+1].toInt()and 255)shl 8)or(raw[offset+2].toInt()shl 16);v/8388608f}
            else->ByteBuffer.wrap(raw,offset,4).order(ByteOrder.LITTLE_ENDIAN).int/2147483648f
        };result[channel]=if(value.isFinite())value.coerceIn(-1f,1f)else 0f}
        if(channels==1)result[1]=result[0];return result
    }
    override fun read():FloatArray? {
        if(a==null){a=next()?:return null;b=next();start=Clock.now()}
        val out=FloatArray(960);var count=0
        while(count<480&&a!=null){val x=a!!;val y=b?:x;for(c in 0..1)out[count*2+c]=(x[c]+(y[c]-x[c])*phase).toFloat();count++;phase+=rate/48000.0
            while(phase>=1-1e-9&&a!=null){phase--;a=b;b=if(a!=null)next()else null}
        }
        val due=start+produced/48000.0;produced+=count
        while(Clock.now()<due)LockSupport.parkNanos(((due-Clock.now())*1e9).toLong().coerceAtMost(5_000_000))
        return if(count>0)out.copyOf(count*2)else null
    }
    override fun close(){input.close()}
}
