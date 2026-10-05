// SPDX-License-Identifier: MIT
import test from 'node:test';
import assert from 'node:assert/strict';
import {encode,Framer,code,proof} from '../protocol.mjs';
import {ClockEstimate,JitterBuffer,decodePCM,audioTime,ScheduledAudio} from '../public/sync.mjs';
const packet=(sequence=0,pts=10.2,epoch=1)=>{const bytes=Buffer.alloc(480*8);for(let i=0;i<960;i++)bytes.writeFloatLE(i%2?-.25:.25,i*4);return {version:1,kind:'audio',sequence,epoch,pts,frames:480,channels:2,sampleRate:48000,payload:bytes.toString('base64')}};
test('Framing survives fragments and multiple packets; rejects hostile lengths',()=>{
  const f=new Framer(),data=Buffer.concat([encode({kind:'ping',t1:1}),encode({kind:'pong'})]);
  assert.deepEqual(f.consume(data.subarray(0,2)),[]);assert.equal(f.consume(data.subarray(2,9)).length,0);assert.deepEqual(f.consume(data.subarray(9)).map(x=>x.kind),['ping','pong']);
  assert.throws(()=>new Framer().consume(Buffer.from([255,255,255,255])));
  assert.throws(()=>new Framer().consume(Buffer.from([0,0,0,0])));
});
test('TLS binding changes pairing code and HMAC; nonce prevents replay',()=>{
  assert.equal(code(Buffer.alloc(32)), '61709175'); // deterministic exporter fixture
  const secret=Buffer.alloc(32,7).toString('base64');
  assert.notEqual(proof(secret,'nonce-1','host','client','binding'),proof(secret,'nonce-2','host','client','binding'));
  assert.notEqual(proof(secret,'nonce-1','host','client','binding'),proof(secret,'nonce-1','host','client','other'));
});
test('NTP recovers independent clock epochs and filters congestion outliers',()=>{
  const c=new ClockEstimate();for(let i=0;i<8;i++)c.observe(i,1000+i+.01,1000+i+.011,i+.021);
  assert.equal(c.ready,true);assert.ok(Math.abs(c.offset-1000)<1e-10);assert.ok(Math.abs(c.rtt-.02)<1e-10);
  c.observe(10,1010.3,1010.301,10.801);assert.ok(Math.abs(c.offset-1000)<1e-10);
  assert.equal(c.observe(1,2,3,1.1),false);assert.equal(c.observe(NaN,2,3,4),false);
});
test('Jitter buffer reorders, drops late/duplicate/old epochs and bounds memory',()=>{
  const b=new JitterBuffer();b.insert(packet(1,10.21));b.insert(packet(0));assert.deepEqual(b.take(10.1,0).map(m=>m.sequence),[0,1]);
  b.insert(packet(0));assert.equal(b.packets.size,0);b.insert(packet(2,10));b.take(10.1,0);assert.equal(b.drops,1);
  b.insert(packet(0,10.3,2));b.insert(packet(3,10.2,1));assert.equal(b.epoch,2);assert.equal(b.packets.size,1);
  for(let i=1;i<110;i++)b.insert(packet(i,11,2));assert.equal(b.packets.size,100);
});
test('PCM validates payload and preserves stereo',()=>{
  const p=packet(),samples=decodePCM(p);assert.equal(samples.length,960);assert.equal(samples[0],.25);assert.equal(samples[1],-.25);
  assert.throws(()=>decodePCM({...p,frames:481}));assert.throws(()=>decodePCM({...p,payload:'!'.repeat(p.payload.length)}));
});
test('Hardware timestamps map presentation time; fallback compensates route latency',()=>{
  assert.ok(Math.abs(audioTime({currentTime:50,getOutputTimestamp:()=>({contextTime:49.9,performanceTime:10000})},10.2,10)-50.1)<1e-10);
  assert.ok(Math.abs(audioTime({currentTime:50,outputLatency:.1},10.2,10)-50.1)<1e-10);
});
test('Scheduling uses future timestamp, selected stereo channel and rejects late packets',()=>{
  let started;const output=[];
  const c={currentTime:1,outputLatency:.05,createGain:()=>({connect(){},gain:{value:1}}),destination:{},createBuffer:()=>({getChannelData:i=>output[i]=new Float32Array(480)}),createBufferSource:()=>({connect(){},disconnect(){},start(t){started=t},stop(){}})};
  const p=new ScheduledAudio(c);p.channel='right';assert.equal(p.schedule(packet(),10.2,10),true);assert.ok(Math.abs(started-1.15)<1e-9);assert.equal(output[0][0],-.25);assert.equal(output[1][0],-.25);
  assert.equal(p.schedule(packet(),10.01,10),false);assert.equal(p.drops,1);
});
