// SPDX-License-Identifier: MIT
import {ClockEstimate,JitterBuffer,ScheduledAudio} from './sync.mjs';
const $=id=>document.getElementById(id),now=()=>performance.now()/1000;
const words={en:{access:'Gateway access',inviteHelp:'Open the invite link shown in the gateway terminal on this device. LAN only.',unlock:'Use invitation',nearby:'Nearby hosts',refresh:'Refresh',connect:'Connect',disconnect:'Disconnect',pairHelp:'Compare this code with the host, then approve this device on the host.',confirm:'Codes match',speaker:'Speaker placement & volume',channel:'Channel',automatic:'Automatic',stereo:'Stereo',left:'Left',right:'Right',identify:'Identify this device',identifyHost:'Identify host',volume:'This device app volume',hostVolume:'Host volume (if permitted)',trim:'Output trim (ms)',devices:'Connected devices',live:'Live status',latency:'Buffer latency',sync:'Clock uncertainty',help:'Help & logs',helpText:'Connect enables audio playback. Background tabs and locked phones may suspend playback. RTT is round trip time; the buffer holds audio for scheduled playback. Sync figures are estimates, not measured acoustic speaker differences.',footer:'TLS encrypted on LAN without cloud. Web volume controls app gain, not system volume.',ready:'Ready',connecting:'Connecting',pairing:'Awaiting host approval',syncing:'Synchronizing',streaming:'Streaming',waiting:'Waiting for audio',reconnecting:'Reconnecting',confirmed:'Waiting for host approval',suspended:'Audio suspended. Tap Connect to resume.',gatewayError:'Gateway connection failed. Check the gateway terminal.',inviteError:'Invitation required or expired. Open the current terminal link.',noHosts:'No hosts found',monitor:'Monitor capture: original host sound is not delayed. Use synchronized file/tap hosting for speaker alignment.',warming:'Sync warning warm-up',warning:'Sustained clock uncertainty or audio interruption. Wi-Fi congestion, browser scheduling or output route delay may be responsible.',denied:'The host declined this control.',paused:'Tab hidden: playback and clock timing may be suspended.',approved:'Host approved',ended:'Disconnected'},ko:{ready:'준비',connecting:'연결 중',pairing:'호스트 승인 대기',syncing:'시계 동기화 중',streaming:'스트리밍 중',waiting:'오디오 대기 중',reconnecting:'재연결 중',confirmed:'호스트 승인을 기다립니다',suspended:'오디오가 중단되었습니다. 연결을 눌러 재개하세요.',gatewayError:'게이트웨이 연결 실패. 터미널 상태를 확인하세요.',inviteError:'초대가 필요하거나 만료되었습니다. 현재 터미널 링크를 여세요.',noHosts:'발견된 호스트 없음',monitor:'모니터 캡처: 호스트의 원본 소리가 먼저 재생됩니다. 스피커 정렬에는 동기화 파일/프로세스 탭 호스팅을 사용하세요.',warming:'동기화 경고 준비 시간',warning:'시계 불확실성 또는 오디오 끊김이 지속됩니다. Wi-Fi 혼잡, 브라우저 예약 처리 또는 출력 장치 지연이 원인일 수 있습니다.',denied:'호스트가 제어를 거절했습니다.',paused:'탭이 숨겨져 재생과 시계 동기화가 중단될 수 있습니다.',approved:'호스트 승인됨',ended:'연결 해제됨'}};
for(const el of document.querySelectorAll('[data-t]'))words.ko[el.dataset.t]=el.textContent;
let language=localStorage.getItem('musicsync.language')|| (navigator.language.startsWith('ko')?'ko':'en');
const tr=k=>words[language][k]||words.en[k]||k;
let ws,context,player,paired=false,wants=false,established=false,target='',phase='ready',clock=new ClockEstimate(),buffer=new JitterBuffer(),pings=new Set(),latency=.18,requested=.18,lastDrops=0,lastAudio=0,start=0,badSince=0,hostChannel='stereo',policy={},peers=[],rosterSignature='',attempt=0,retryTimer,connecting=false,lastPong=0,probeCount=0;
let deviceID=localStorage.getItem('musicsync.deviceID');if(!deviceID){deviceID=crypto.randomUUID().toUpperCase();localStorage.setItem('musicsync.deviceID',deviceID)}
const logs=[];
function log(text){logs.push(`${new Date().toLocaleTimeString()} ${text}`);if(logs.length>100)logs.shift();$('logs').textContent=logs.join('\n')}
function error(text){$('error').textContent=text;$('error').hidden=!text;if(text)log(text)}
function send(m){if(ws?.readyState===WebSocket.OPEN)ws.send(JSON.stringify({version:1,...m}))}
function channel(){return $('channel').value==='automatic'?hostChannel:$('channel').value}
function report(){if(player)player.channel=channel();if(paired)send({kind:'channelReport',channelSelection:$('channel').value,outputChannel:channel(),playbackState:phase,volume:Number($('volume').value)})}
function policyApply(m){policy={host:m.allowClientHostVolume===true,local:m.allowHostClientVolume===true,peerVolume:m.allowPeerClientVolume===true,peerDevice:m.allowPeerDeviceControl===true};$('hostVolume').disabled=!policy.host;if(Number.isFinite(m.hostVolume))$('hostVolume').value=m.hostVolume}
function renderPeers(){const signature=JSON.stringify([language,peers]);if(signature===rosterSignature)return;rosterSignature=signature;$('devices').replaceChildren();
  for(const peer of peers){const row=document.createElement('div');row.className='peer';const title=document.createElement('strong');title.textContent=`${peer.name} · ${tr(peer.outputChannel||'stereo')}`;row.append(title);
    const status=document.createElement('p');status.textContent=peer.playbackState||'';row.append(status);
    const controls=document.createElement('div');controls.className='row';
    const select=document.createElement('select');select.setAttribute('aria-label',`${peer.name} ${tr('channel')}`);for(const value of ['automatic','stereo','left','right']){const o=new Option(tr(value),value);select.add(o)}select.value=peer.channelSelection||'automatic';select.disabled=!peer.canControlDevice;select.onchange=()=>send({kind:'setPeerChannel',targetPeerID:peer.id,channelSelection:select.value});controls.append(select);
    const button=document.createElement('button');button.textContent=tr('identify');button.disabled=!peer.canControlDevice;button.onclick=()=>send({kind:'identifyPeer',targetPeerID:peer.id});controls.append(button);
    const volume=document.createElement('input');volume.type='range';volume.min='0';volume.max='1';volume.step='.01';volume.value=peer.volume;volume.disabled=!peer.canControl;volume.setAttribute('aria-label',`${peer.name} ${tr('volume')}`);volume.onchange=()=>send({kind:'setPeerVolume',targetPeerID:peer.id,volume:Number(volume.value)});row.append(controls,volume);$('devices').append(row);
  }
}
function render(){document.documentElement.lang=language;$('language').value=language;for(const el of document.querySelectorAll('[data-t]'))el.textContent=tr(el.dataset.t);$('title').textContent=phase==='streaming'?`MusicSync ${tr('streaming')}`:'MusicSync';$('phase').textContent=tr(phase);$('latency').textContent=`${(latency*1000).toFixed(0)} ms`;$('uncertainty').textContent=clock.ready?`±${(clock.uncertainty*1000).toFixed(1)} ms`:'—';renderPeers()}
async function unlock(){const token=location.hash.slice(1)||$('invite').value;const res=await fetch('/session',{method:'POST',body:token});history.replaceState(null,'','/');$('invite').value='';if(!res.ok)throw Error(tr('inviteError'));$('access').hidden=true;await refresh()}
async function refresh(){const res=await fetch('/hosts');if(!res.ok){$('access').hidden=false;return}const hosts=await res.json(),chosen=$('hosts').value;$('hosts').replaceChildren(...hosts.map(h=>new Option(h.name,h.id)));if(hosts.some(x=>x.id===chosen))$('hosts').value=chosen;if(!hosts.length)$('hosts').add(new Option(tr('noHosts'),''));$('access').hidden=true}
async function enableAudio(){if(!context){context=new AudioContext({sampleRate:48000,latencyHint:'interactive'});player=new ScheduledAudio(context);context.onstatechange=()=>{if(context.state!=='running'&&paired)error(tr('suspended'))}}await context.resume();player.gain.gain.value=Number($('volume').value);report()}
function reset(){paired=false;player?.clear();clock=new ClockEstimate();buffer=new JitterBuffer();pings.clear();lastAudio=0;lastPong=now();probeCount=0;latency=.18;requested=.18;lastDrops=0;badSince=0;policy={};$('hostVolume').disabled=true;peers=[];renderPeers();$('pairing').hidden=true}
function retry(){if(!wants||(!established&&attempt>=3))return;clearTimeout(retryTimer);phase='reconnecting';render();retryTimer=setTimeout(()=>{attempt++;open()},Math.min(15000,1500*2**Math.min(attempt,3)))}
function open(){if(connecting)return;connecting=true;reset();phase='connecting';render();ws=new WebSocket(`wss://${location.host}/stream`);const current=ws;
  ws.onopen=()=>{connecting=false;send({kind:'connect',target,deviceID,name:`MusicSync Web · ${navigator.platform||'Browser'}`})};
  ws.onmessage=event=>{try{handle(JSON.parse(event.data))}catch(e){error(e.message);wants=false;current.close()}};
  ws.onerror=()=>error(tr('gatewayError'));
  ws.onclose=()=>{if(ws!==current)return;connecting=false;reset();phase='ended';render();retry()};
}
function handle(m){
  if(m.kind==='transportNotice'){log(m.reason);return}
  if(m.kind==='gatewayError'){wants=false;error(m.reason);ws.close();return}
  if(m.kind==='disconnected'){ws.close();return}
  if(m.kind==='pairPending'){phase='pairing';$('code').textContent=m.pairingCode;$('pairing').hidden=false;$('confirm').disabled=false;$('address').textContent=`${m.name||''} · ${m.hostAddress||''}`;render();log(tr('pairing'));return}
  if(m.kind==='pairApproved'){paired=true;established=true;attempt=0;phase='syncing';start=now();lastPong=now();$('pairing').hidden=true;$('address').textContent=`${m.name||''} · ${m.hostAddress||''}`;hostChannel=m.outputChannel||'stereo';policyApply(m);report();send({kind:'volumeReport',volume:Number($('volume').value)});log(tr('approved'));render();return}
  if(!paired)return;
  switch(m.kind){
    case 'pong':if(pings.delete(m.t1)&&clock.observe(m.t1,m.t2,m.t3,now()))lastPong=now();break;
    case 'audio':if(clock.ready){if(buffer.insert(m)){player.clear();start=now();badSince=0}lastAudio=now();phase='streaming';if(m.latency>=.18&&m.latency<=.5)latency=m.latency;$('monitor').textContent=m.monitor?tr('monitor'):''}break;
    case 'stop':player.clear();buffer=new JitterBuffer();lastAudio=0;phase='waiting';break;
    case 'timeline':if(m.latency>=.18&&m.latency<=.5)latency=m.latency;break;
    case 'volumePolicy':policyApply(m);break;
    case 'hostVolume':case 'volumeResult':if(Number.isFinite(m.hostVolume))$('hostVolume').value=m.hostVolume;if(m.accepted===false)error(tr('denied'));break;
    case 'volumePeers':if(Array.isArray(m.volumePeers)&&m.volumePeers.length<=32)peers=m.volumePeers;break;
    case 'setClientVolume':{const allowed=m.targetPeerID?policy.peerVolume:policy.local,ok=allowed&&Number.isFinite(m.volume)&&m.volume>=0&&m.volume<=1;if(ok){$('volume').value=m.volume;player.gain.gain.value=m.volume;send({kind:'volumeReport',volume:m.volume,requestID:m.requestID})}else send({kind:'volumeResult',volumeTarget:'client',accepted:false,requestID:m.requestID});break}
    case 'setChannel':if(!m.targetPeerID||policy.peerDevice){if(['automatic','stereo','left','right'].includes(m.channelSelection)){$('channel').value=m.channelSelection;report()}}else send({kind:'peerControlResult',accepted:false,requestID:m.requestID});break;
    case 'hostChannel':case 'channel':if(['stereo','left','right'].includes(m.outputChannel)){hostChannel=m.outputChannel;report()}break;
    case 'identify':{const allowed=!m.targetPeerID||policy.peerDevice;if(allowed)player.identify();send({kind:'identifyResult',accepted:allowed,requestID:m.requestID});break}
    case 'peerVolumeDenied':case 'peerControlDenied':error(tr('denied'));break;
  }
}
setInterval(()=>{if(!paired||!clock.ready||context?.state!=='running')return;for(const packet of buffer.take(now(),clock.offset,Math.max(.13,(context.outputLatency||context.baseLatency||0)+.08)))player.schedule(packet,packet.pts-clock.offset,now())},20);
setInterval(()=>{if(!paired)return;const t=now();if(t-lastPong>5){ws.close();return}probeCount++;if(probeCount<=16||probeCount%10===0){for(const p of pings)if(t-p>3)pings.delete(p);pings.add(t);send({kind:'ping',t1:t})}},100);
setInterval(()=>{if(!paired){render();return}const t=now(),drops=buffer.drops+player.drops;
  if(drops>lastDrops)requested=Math.min(.5,Math.max(latency,requested)+.02);lastDrops=drops;
  requested=Math.min(.5,Math.max(requested,.18,clock.rtt/2+4*clock.jitter+(context.outputLatency||context.baseLatency||0)+.07));
  if(clock.ready&&context.state==='running')send({kind:'stats',rtt:clock.rtt,offset:clock.offset,jitter:clock.jitter,latency:Math.max(latency,requested),playbackState:phase,outputChannel:channel(),channelSelection:$('channel').value,dropped:drops,schedulingError:player.error,bufferCount:buffer.packets.size});
  const warmup=Math.max(0,30-(t-start)),bad=clock.uncertainty>.06||player.error>.025||(lastAudio>0&&t-lastAudio>2);
  if(warmup||!bad)badSince=0;else if(!badSince)badSince=t;
  $('warning').textContent=badSince&&t-badSince>=5?tr('warning'):'';
  $('details').textContent=`RTT ${(clock.rtt*1000).toFixed(1)} ms · ${language==='ko'?'시계 오프셋':'Clock offset'} ${(clock.offset*1000).toFixed(1)} ms · Jitter ${(clock.jitter*1000).toFixed(1)} ms · ${tr('latency')} ${(latency*1000).toFixed(0)} ms · ${tr('sync')} ${(clock.uncertainty*1000).toFixed(1)} ms · ${language==='ko'?'예약 지연':'Schedule lateness'} ${(player.error*1000).toFixed(1)} ms · ${language==='ko'?'출력 지연 추정':'Output latency estimate'} ${((context.outputLatency||context.baseLatency||0)*1000).toFixed(1)} ms · ${language==='ko'?'버퍼 패킷':'Buffered packets'} ${buffer.packets.size} · ${language==='ko'?'폐기':'Dropped'} ${drops} · ${tr('warming')} ${warmup.toFixed(0)} s · ${tr('channel')} ${tr(channel())}`;render();
},250);
$('language').onchange=()=>{language=$('language').value;localStorage.setItem('musicsync.language',language);render()};
$('unlock').onclick=()=>unlock().catch(e=>error(e.message));$('refresh').onclick=()=>refresh().catch(e=>error(e.message));
$('connect').onclick=async()=>{try{await enableAudio();error('');if(paired)return;target=$('hosts').value;if(!target)throw Error(tr('noHosts'));clearTimeout(retryTimer);wants=true;established=false;attempt=0;if(ws){wants=false;ws.close();ws=undefined;connecting=false;wants=true}open()}catch(e){error(e.message)}};
$('disconnect').onclick=()=>{wants=false;clearTimeout(retryTimer);send({kind:'disconnect'});ws?.close();reset();phase='ended';render()};
$('confirm').onclick=()=>{send({kind:'pairConfirm'});$('confirm').disabled=true;log(tr('confirmed'))};
$('channel').onchange=report;$('volume').oninput=()=>{if(player)player.gain.gain.value=Number($('volume').value)};$('volume').onchange=()=>{if(paired)send({kind:'volumeReport',volume:Number($('volume').value)})};
$('hostVolume').onchange=()=>send({kind:'setHostVolume',volume:Number($('hostVolume').value)});
$('trim').oninput=()=>{if(player)player.trim=Number($('trim').value)/1000;$('trimValue').textContent=$('trim').value};
$('identify').onclick=async()=>{await enableAudio();player.identify()};$('identifyHost').onclick=()=>{if(paired)send({kind:'identifyHost'})};
document.addEventListener('visibilitychange',()=>{if(document.hidden&&paired)log(tr('paused'));if(!document.hidden){player?.clear();buffer=new JitterBuffer();clock=new ClockEstimate();probeCount=0;start=now()}});
window.addEventListener('hashchange',()=>{if(location.hash)unlock().catch(e=>error(e.message))});
render();if(location.hash)unlock().catch(e=>error(e.message));else refresh().catch(e=>error(e.message));setInterval(()=>refresh().catch(()=>{}),5000);
