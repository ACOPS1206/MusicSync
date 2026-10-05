// SPDX-License-Identifier: MIT
import https from 'node:https';
import tls from 'node:tls';
import {randomBytes,timingSafeEqual,X509Certificate} from 'node:crypto';
import {readFileSync,writeFileSync,mkdirSync,existsSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {networkInterfaces} from 'node:os';
import {WebSocketServer,WebSocket} from 'ws';
import {Bonjour} from 'bonjour-service';
import {Framer,encode,code,pin,proof,uuid} from './protocol.mjs';
const here=dirname(fileURLToPath(import.meta.url));
const dir=resolve(process.env.MUSICSYNC_WEB_DATA||'.local');mkdirSync(dir,{recursive:true,mode:0o700});
const pairsPath=resolve(dir,'pairings.json');
let pairs=existsSync(pairsPath)?JSON.parse(readFileSync(pairsPath,'utf8')):{};
const save=()=>writeFileSync(pairsPath,JSON.stringify(pairs),{mode:0o600});
const invite=randomBytes(32).toString('base64url'), sessions=new Set(), targets=new Map();
const lanIP=Object.values(networkInterfaces()).flat().find(x=>x?.family==='IPv4'&&!x.internal)?.address||'127.0.0.1';
const port=Number(process.env.PORT||8443), bind=process.env.MUSICSYNC_WEB_BIND||'0.0.0.0';
const staticFiles={'/':['index.html','text/html'], '/app.mjs':['app.mjs','text/javascript'],'/sync.mjs':['sync.mjs','text/javascript'],'/style.css':['style.css','text/css']};
function equal(a,b){return typeof a==='string'&&Buffer.byteLength(a)===Buffer.byteLength(b)&&timingSafeEqual(Buffer.from(a),Buffer.from(b));}
const cookie=req=>req.headers.cookie?.split(';').map(x=>x.trim()).find(x=>x.startsWith('musicsync='))?.slice(10);
const authenticated=req=>sessions.has(cookie(req));
const server=https.createServer({key:readFileSync(resolve(dir,'server.key')),cert:readFileSync(resolve(dir,'server.crt')),minVersion:'TLSv1.3'},(req,res)=>{
  res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
  res.setHeader('Content-Security-Policy',"default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'");
  if(req.method==='POST'&&req.url==='/session'){
    if(req.headers.origin!==`https://${req.headers.host}`){res.writeHead(403).end();return}
    let body='';req.on('data',x=>{body+=x;if(body.length>200)req.destroy()});
    req.on('end',()=>{if(!equal(body,invite)||sessions.size>=64){res.writeHead(403).end();return};const token=randomBytes(32).toString('base64url');sessions.add(token);res.setHeader('Set-Cookie',`musicsync=${token}; HttpOnly; Secure; SameSite=Strict; Path=/`);res.writeHead(204).end()});return;
  }
  if(req.method==='GET'&&req.url==='/hosts'&&authenticated(req)){res.setHeader('Content-Type','application/json');res.end(JSON.stringify([...targets.values()].map(({id,name,address})=>({id,name,address}))));return}
  const entry=staticFiles[req.url];if(req.method!=='GET'||!entry){res.writeHead(404).end();return}
  res.setHeader('Content-Type',entry[1]);res.end(readFileSync(resolve(here,'public',entry[0])));
});
const MAX_CLIENT=16384;
const wss=new WebSocketServer({noServer:true,maxPayload:MAX_CLIENT,perMessageDeflate:false});
server.on('upgrade',(req,socket,head)=>{
  if(req.url!=='/stream'||!authenticated(req)||req.headers.origin!==`https://${req.headers.host}`||wss.clients.size>=8){socket.destroy();return}
  wss.handleUpgrade(req,socket,head,ws=>wss.emit('connection',ws,req));
});
let bonjour;
if(process.env.MUSICSYNC_WEB_TEST_TARGET){
  const [host,p]=process.env.MUSICSYNC_WEB_TEST_TARGET.split(':');targets.set('test',{id:'test',name:'Test Host',address:`${host}:${p}`,host,port:Number(p)});
}else{
  bonjour=new Bonjour();const browser=bonjour.find({type:'musicsync',protocol:'tcp'});
  browser.on('up',s=>{const host=s.addresses?.find(x=>/^\d+\.\d+\.\d+\.\d+$/.test(x))||s.host;
    targets.set(s.fqdn,{id:s.fqdn,name:s.name,address:`${s.host}:${s.port}`,host,port:s.port})});
  browser.on('down',s=>targets.delete(s.fqdn));
}
const allowed=new Set(['ping','stats','channelReport','volumeReport','identifyHost','setHostVolume','setPeerVolume','setPeerChannel','identifyPeer','identifyResult','volumeResult','peerControlResult']);
wss.on('connection',ws=>{
  let socket,paired=false,confirmed=false,proved=false,hostID,nonce,binding,localCode,actualPin,clientID,endpoint,deadline;
  let budget=0;const limiter=setInterval(()=>budget=0,1000);
  const send=m=>{if(ws.readyState===WebSocket.OPEN){if(ws.bufferedAmount>512*1024){ws.close(1013,'Slow browser');return}ws.send(JSON.stringify(m))}};
  const end=reason=>{send({kind:'gatewayError',reason});socket?.destroy();socket=undefined;paired=false;clearTimeout(deadline)};
  const native=m=>{if(socket&&!socket.destroyed){if(socket.writableLength>512*1024){end('Slow host');return}socket.write(encode(m))}};
  ws.on('message',(data,isBinary)=>{try{
    if(isBinary||++budget>100)throw Error('Invalid or excessive control messages');
    const m=JSON.parse(data);if(m.kind==='connect'){
      if(socket)throw Error('Disconnect before changing host');endpoint=targets.get(m.target);
      if(!endpoint||!uuid(m.deviceID))throw Error('Select a discovered LAN host');
      clientID=m.deviceID.toUpperCase();paired=false;confirmed=false;proved=false;hostID=undefined;
      const key=`${clientID}|${endpoint.id}`;const record=pairs[key];
      socket=tls.connect({host:endpoint.host,port:endpoint.port,rejectUnauthorized:false,minVersion:'TLSv1.3',maxVersion:'TLSv1.3'});
      socket.setNoDelay(true);const connection=socket,framer=new Framer();
      deadline=setTimeout(()=>end('Pairing timed out; reconnect to request approval'),60000);
      socket.on('secureConnect',()=>{try{
        actualPin=pin(socket.getPeerCertificate().raw);if(record&&record.pin!==actualPin)throw Error('Host key changed. Verify host; remove pairing in gateway before retrying.');
        binding=socket.exportKeyingMaterial(32,'EXPORTER-MusicSync-pairing-v2');localCode=code(binding);
        native({kind:'hello',pairingVersion:2,deviceID:clientID,name:String(m.name||'MusicSync Web').slice(0,80),volumeScope:'app',volumeControlVersion:1,volume:1,channelSelection:'automatic'});
      }catch(e){end(e.message)}});
      socket.on('data',data=>{if(socket!==connection)return;try{for(const message of framer.consume(data)){
        if(message.kind==='pairChallenge'){
          if(hostID||message.pairingVersion!==2||!uuid(message.hostID)||!uuid(message.nonce))throw Error('Invalid pairing challenge');
          hostID=message.hostID;nonce=message.nonce;
          if(record){if(record.hostID!==hostID)throw Error('Host identity changed');proved=true;native({kind:'pairProof',pairingProof:proof(record.secret,nonce,hostID,clientID,binding.toString('base64'))})}
          else native({kind:'pairRequest'});
        }else if(message.kind==='pairPending'){
          if(message.hostID!==hostID||message.pairingCode!==localCode)throw Error('Pairing code mismatch');proved=false;
          send({kind:'pairPending',pairingCode:localCode,name:message.name,hostAddress:message.hostAddress||endpoint.address});
        }else if(message.kind==='pairApproved'){
          if(paired||message.hostID!==hostID)throw Error('Invalid approval');
          if(message.pairingSecret){if(!confirmed||Buffer.from(message.pairingSecret,'base64').length!==32)throw Error('Confirm matching code before approval');pairs[key]={hostID,pin:actualPin,secret:message.pairingSecret};save()}
          else if(!proved)throw Error('Pairing proof required');
          paired=true;clearTimeout(deadline);const {pairingSecret,...safe}=message;send({...safe,hostAddress:message.hostAddress||endpoint.address});
        }else if(message.kind==='pairRejected'){end('Host declined or expired pairing')}
        else if(paired)send(message);
      }}catch(e){end(e.message)}});
      socket.on('error',()=>{if(socket===connection)send({kind:'transportNotice',reason:'LAN host connection failed'})});socket.on('close',()=>{if(socket!==connection)return;socket=undefined;paired=false;clearTimeout(deadline);send({kind:'disconnected'})});
    }else if(m.kind==='disconnect'){socket?.destroy();socket=undefined;paired=false}
    else if(m.kind==='pairConfirm'){if(!socket||!localCode||paired)throw Error('No pending pairing');confirmed=true;native({kind:'pairConfirm',pairingCode:localCode})}
    else if(paired&&allowed.has(m.kind)){native({...m,version:1})}
  }catch(e){end(e.message)}});
  ws.on('close',()=>{clearInterval(limiter);clearTimeout(deadline);socket?.destroy()});ws.on('error',()=>socket?.destroy());
});
server.listen(port,bind,()=>{
  console.log(`MusicSync Web: https://${lanIP}:${port}/#${invite}`);
  console.log(`Local: https://localhost:${port}/#${invite}`);
  console.log(`Certificate SHA256: ${new X509Certificate(readFileSync(resolve(dir,'server.crt'))).fingerprint256}`);
  console.log('Invite grants access to this LAN gateway. Share only with your own trusted devices. Native host approval is still required.');
});
const close=()=>{wss.clients.forEach(x=>x.terminate());wss.close();bonjour?.destroy();server.close(()=>process.exit(0))};
process.on('SIGINT',close);process.on('SIGTERM',close);
