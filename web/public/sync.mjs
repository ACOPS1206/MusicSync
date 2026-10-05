// SPDX-License-Identifier: MIT
export class ClockEstimate {
  samples=[];rtt=0;offset=0;jitter=0;
  get ready(){return this.samples.length>=8}
  get uncertainty(){return this.rtt/2+this.jitter}
  observe(t1,t2,t3,t4){
    if(![t1,t2,t3,t4].every(Number.isFinite))return false;
    const rtt=t4-t1-(t3-t2);if(rtt<0||rtt>=1||t4<t1||t3<t2)return false;
    this.samples.push({rtt,offset:((t2-t1)+(t3-t4))/2});if(this.samples.length>32)this.samples.shift();
    const best=[...this.samples].sort((a,b)=>a.rtt-b.rtt).slice(0,8),mean=xs=>xs.reduce((a,b)=>a+b,0)/xs.length;
    this.rtt=mean(best.map(x=>x.rtt));const candidate=mean(best.map(x=>x.offset));
    this.offset=this.samples.length<=8?candidate:this.offset*.9+candidate*.1;
    const avg=mean(this.samples.map(x=>x.rtt));this.jitter=Math.sqrt(mean(this.samples.map(x=>(x.rtt-avg)**2)));return true;
  }
}
export class JitterBuffer {
  packets=new Map();epoch=-1;last=-1;drops=0;
  insert(m){
    if(!validAudio(m)||m.epoch<this.epoch||m.pts>1e12)return false;
    const changed=m.epoch!==this.epoch;if(changed){this.packets.clear();this.epoch=m.epoch;this.last=-1}
    if(m.sequence<=this.last)return changed;
    this.packets.set(m.sequence,m);if(this.packets.size>100){this.packets.delete(Math.min(...this.packets.keys()));this.drops++}return changed;
  }
  take(now,offset,horizon=.13){const result=[];for(const [id,m] of [...this.packets].sort((a,b)=>a[0]-b[0])){
    const time=m.pts-offset;if(time>now+Math.min(.5,horizon))break;this.packets.delete(id);this.last=id;
    if(time<now+.015||time>now+1)this.drops++;else result.push(m);
  }return result}
}
export function validAudio(m){return m.kind==='audio'&&m.version===1&&m.sampleRate===48000&&m.channels===2&&Number.isInteger(m.frames)&&m.frames>0&&m.frames<=4800&&Number.isFinite(m.pts)&&Number.isSafeInteger(m.sequence)&&m.sequence>=0&&Number.isSafeInteger(m.epoch)&&m.epoch>=0&&typeof m.payload==='string'&&m.payload.length===Math.ceil(m.frames*8/3)*4}
export function decodePCM(m){if(!validAudio(m))throw Error('Invalid PCM packet');const raw=atob(m.payload);if(raw.length!==m.frames*8)throw Error('Invalid PCM size');const view=new DataView(Uint8Array.from(raw,x=>x.charCodeAt(0)).buffer);return Array.from({length:m.frames*2},(_,i)=>{const x=view.getFloat32(i*4,true);return Number.isFinite(x)?Math.max(-1,Math.min(1,x)):0})}
// Map monotonic presentation time to the audio hardware timeline. Prefer output timestamps
// over currentTime, because currentTime points ahead of audible output by route latency.
export function audioTime(context,presentation,now){
  const stamp=context.getOutputTimestamp?.();
  if(stamp&&stamp.contextTime>0&&stamp.performanceTime>0)return stamp.contextTime+(presentation-stamp.performanceTime/1000);
  return context.currentTime+(presentation-now)-(context.outputLatency||context.baseLatency||0);
}
export class ScheduledAudio {
  constructor(context){this.context=context;this.gain=context.createGain();this.gain.connect(context.destination);this.sources=new Set();this.drops=0;this.error=0;this.channel='stereo';this.trim=0}
  schedule(m,presentation,now){
    const context=this.context,time=audioTime(context,presentation+this.trim,now);
    if(time<context.currentTime+.003){this.drops++;this.error=context.currentTime-time;return false}
    const pcm=decodePCM(m),buffer=context.createBuffer(2,m.frames,48000),left=buffer.getChannelData(0),right=buffer.getChannelData(1);
    for(let i=0;i<m.frames;i++){left[i]=this.channel==='right'?pcm[i*2+1]:pcm[i*2];right[i]=this.channel==='left'?pcm[i*2]:pcm[i*2+1]}
    const source=context.createBufferSource();source.buffer=buffer;source.connect(this.gain);this.sources.add(source);
    source.onended=()=>{this.sources.delete(source);source.disconnect()};source.start(time);this.error=0;return true;
  }
  clear(){for(const source of this.sources){try{source.stop()}catch{}source.disconnect()}this.sources.clear()}
  identify(){const c=this.context;for(let i=0;i<3;i++){const o=c.createOscillator(),g=c.createGain(),t=c.currentTime+.02+i*.2;o.frequency.value=880;g.gain.setValueAtTime(.15,t);g.gain.exponentialRampToValueAtTime(.001,t+.12);o.connect(g);g.connect(this.gain);o.start(t);o.stop(t+.13);o.onended=()=>{o.disconnect();g.disconnect()}}}
}
