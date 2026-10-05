// SPDX-License-Identifier: MIT
// Actual HTTPS -> WSS -> native TLS -> PCM -> browser AudioBufferSource integration.
import {spawn,execFileSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,readFileSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import tls from 'node:tls';
import {randomUUID,randomBytes} from 'node:crypto';
import assert from 'node:assert/strict';
import {chromium} from 'playwright';
import {WebSocket} from 'ws';
import {encode,Framer,code,proof} from '../protocol.mjs';
const cwd=resolve(new URL('..',import.meta.url).pathname),dir=mkdtempSync(join(tmpdir(),'musicsync-web-'));
let host,gateway,browser,page,invite,approved=0,stats=0,confirmation=0,connections=0;
const nativeSockets=new Set();
const hostID=randomUUID().toUpperCase(),secret=randomBytes(32).toString('base64');
const clock=()=>Number(process.hrtime.bigint())/1e9;
try{
  execFileSync(process.execPath,['setup.mjs'],{cwd,env:{...process.env,MUSICSYNC_WEB_DATA:dir},stdio:'pipe'});
  execFileSync('openssl',['req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-keyout',join(dir,'native.key'),'-out',join(dir,'native.crt'),'-days','1','-subj','/CN=Native test Host'],{stdio:'pipe'});
  // Old persisted records must be removed, even if malformed.
  writeFileSync(join(dir,'pairings.json'),'legacy records are not loaded');
  let fixtureReady=false;
  if(!process.env.MUSICSYNC_WEB_EXTERNAL_HOST){
    host=tls.createServer({key:readFileSync(join(dir,'native.key')),cert:readFileSync(join(dir,'native.crt')),minVersion:'TLSv1.3',maxVersion:'TLSv1.3'},socket=>{
      connections++;nativeSockets.add(socket);const binding=socket.exportKeyingMaterial(32,'EXPORTER-MusicSync-pairing-v2'),nonce=randomUUID().toUpperCase(),f=new Framer();let authenticated=false,clientID,timer;
      socket.on('error',()=>{});socket.on('close',()=>{nativeSockets.delete(socket);clearInterval(timer)});
      const send=m=>socket.write(encode(m));
      const authorize=remembered=>{authenticated=true;approved++;send({kind:'pairApproved',hostID,name:'Native test Host',outputChannel:'stereo',hostVolume:.7,volumeScope:'app',allowClientHostVolume:true,allowHostClientVolume:true,...(!remembered?{pairingSecret:secret}:{})})};
      socket.on('data',bytes=>{for(const m of f.consume(bytes)){
        if(m.kind==='hello'){clientID=m.deviceID;send({kind:'pairChallenge',hostID,nonce,name:'Native test Host',pairingVersion:2})}
        else if(m.kind==='pairRequest')send({kind:'pairPending',hostID,pairingCode:code(binding)});
        else if(m.kind==='pairConfirm'){assert.equal(m.pairingCode,code(binding));confirmation++;authorize(false)}
        else if(m.kind==='pairProof'){assert.equal(m.pairingProof,proof(secret,nonce,hostID,clientID,binding.toString('base64')));authorize(true)}
        else if(authenticated&&m.kind==='ping'){send({kind:'pong',t1:m.t1,t2:clock(),t3:clock()})}
        else if(authenticated&&m.kind==='stats'){
          stats++;if(timer)continue;let sequence=0;timer=setInterval(()=>{
            const bytes=Buffer.alloc(480*8);for(let i=0;i<960;i++)bytes.writeFloatLE(i%2?-.25:.25,i*4);
            send({kind:'audio',sequence:sequence++,epoch:1,pts:clock()+.3,sampleRate:48000,channels:2,frames:480,payload:bytes.toString('base64'),latency:.3});
          },10);
        }
      }});
    });await new Promise(r=>host.listen(0,'127.0.0.1',r));fixtureReady=true;
  }
  const endpoint=process.env.MUSICSYNC_WEB_EXTERNAL_HOST||`127.0.0.1:${host.address().port}`;
  gateway=spawn(process.execPath,['server.mjs'],{cwd,env:{...process.env,PORT:'18443',MUSICSYNC_WEB_BIND:'127.0.0.1',MUSICSYNC_WEB_DATA:dir,MUSICSYNC_WEB_TEST_TARGET:endpoint},stdio:['ignore','pipe','pipe']});
  let text='',errors='';gateway.stderr.on('data',x=>errors+=x);
  await new Promise((res,rej)=>{const timer=setTimeout(()=>rej(Error(`Gateway not ready ${errors}`)),15000);gateway.on('exit',x=>rej(Error(`Gateway exited ${x}: ${errors}`)));gateway.stdout.on('data',data=>{text+=data;const found=text.match(/Local: (https:\/\/localhost:\d+\/#\S+)/);if(found){invite=found[1];clearTimeout(timer);res()}})});
  assert.equal(existsSync(join(dir,'pairings.json')),false);
  browser=await chromium.launch({headless:true,args:['--autoplay-policy=no-user-gesture-required']});
  const ctx=await browser.newContext({ignoreHTTPSErrors:true,locale:'en-US'});page=await ctx.newPage();let pageErrors=[];page.on('pageerror',e=>pageErrors.push(e.message));
  await page.addInitScript(()=>{
    window.scheduled=[];const original=AudioContext.prototype.createBufferSource;
    AudioContext.prototype.createBufferSource=function(){const source=original.call(this),start=source.start.bind(source),c=this;source.start=(time,...args)=>{window.scheduled.push({time,now:c.currentTime,left:source.buffer?.getChannelData(0)[0],right:source.buffer?.getChannelData(1)[0]});return start(time,...args)};return source};
  });
  await page.goto('https://localhost:18443/');assert.equal(await page.locator('#access').isVisible(),true);
  const denied=await ctx.request.get('https://localhost:18443/hosts');assert.equal(denied.status(),404);
  await page.goto(invite);await page.waitForSelector('#access',{state:'hidden'});
  assert.equal(new URL(page.url()).hash,'');
  const rejectWS=(headers)=>new Promise((res,rej)=>{const socket=new WebSocket('wss://localhost:18443/stream',{rejectUnauthorized:false,headers});socket.on('open',()=>{socket.close();rej(Error('Unauthorized WebSocket accepted'))});socket.on('error',()=>res())});
  await rejectWS({Origin:'https://localhost:18443'});
  const cookies=await ctx.cookies();await rejectWS({Origin:'https://other.invalid',Cookie:cookies.map(x=>`${x.name}=${x.value}`).join('; ')});
  await page.click('#connect');await page.waitForSelector('#pairing',{state:'visible'});
  await page.waitForTimeout(200);if(fixtureReady){assert.equal(approved,0);assert.equal(stats,0)}
  await page.click('#confirm');await page.waitForFunction(()=>document.querySelector('#title').textContent.includes('Streaming'),{},{timeout:15000});
  await page.waitForFunction(()=>window.scheduled.length>=5);
  let recorded=await page.evaluate(()=>window.scheduled);assert.ok(recorded.some(x=>x.time>x.now));assert.ok(recorded.some(x=>x.left===.25&&x.right===-.25));
  assert.match(await page.locator('#details').textContent(),/Clock offset/);assert.equal(await page.locator('#warning').textContent(),'');
  await page.selectOption('#channel','right');await page.waitForFunction(()=>window.scheduled.some(x=>x.left===-.25&&x.right===-.25));
  await page.selectOption('#language','ko');assert.match(await page.locator('#title').textContent(),/스트리밍 중/);
  if(fixtureReady){
    for(const socket of nativeSockets)socket.destroy();
    await page.waitForFunction(()=>document.querySelector('#phase').textContent.includes('재연결'));
    await page.waitForFunction(()=>document.querySelector('#title').textContent.includes('스트리밍 중'));
    await page.click('#disconnect');await page.waitForTimeout(200);await page.click('#connect');await page.waitForFunction(()=>document.querySelector('#title').textContent.includes('스트리밍 중'));assert.equal(await page.locator('#pairing').isVisible(),false);assert.equal(confirmation,1);assert.ok(approved>=3);assert.ok(connections>=3);
    const tab=await ctx.newPage();await tab.goto('https://localhost:18443/');await tab.waitForSelector('#access',{state:'hidden'});await tab.click('#connect');await tab.waitForSelector('#pairing',{state:'visible'});assert.equal(await tab.locator('#error').textContent(),'');await tab.close();
    await page.screenshot({path:join(cwd,'test','web-preview.png'),fullPage:true});
    await page.click('#disconnect');await page.waitForTimeout(200);
    // Same-session pin mismatch must not silently trust a replacement host certificate.
    await new Promise(r=>host.close(r));
    execFileSync('openssl',['req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-keyout',join(dir,'changed.key'),'-out',join(dir,'changed.crt'),'-days','1','-subj','/CN=Changed test Host'],{stdio:'pipe'});
    host=tls.createServer({key:readFileSync(join(dir,'changed.key')),cert:readFileSync(join(dir,'changed.crt')),minVersion:'TLSv1.3'},socket=>{socket.on('error',()=>{});const f=new Framer(),binding=socket.exportKeyingMaterial(32,'EXPORTER-MusicSync-pairing-v2');socket.on('data',bytes=>{for(const m of f.consume(bytes)){if(m.kind==='hello')socket.write(encode({kind:'pairChallenge',hostID,nonce:randomUUID().toUpperCase(),pairingVersion:2}));else if(m.kind==='pairRequest')socket.write(encode({kind:'pairPending',hostID,pairingCode:code(binding)}));else if(m.kind==='pairConfirm'){assert.equal(m.pairingCode,code(binding));socket.write(encode({kind:'pairApproved',hostID,pairingSecret:secret,name:'Replacement Host'}))}}})});await new Promise(r=>host.listen(Number(endpoint.split(':')[1]),'127.0.0.1',r));
    await page.click('#connect');await page.waitForFunction(()=>document.querySelector('#error').textContent.includes('보안 키가 바뀌었습니다'));
    // A browser restart/reload discards its old identity and requires fresh approval.
    await page.reload();await page.waitForSelector('#access',{state:'hidden'});
    await page.click('#connect');await page.waitForSelector('#pairing',{state:'visible'});
    assert.equal(await page.locator('#error').textContent(),'');await page.click('#confirm');
    await page.waitForSelector('#pairing',{state:'hidden'});
    assert.equal(existsSync(join(dir,'pairings.json')),false);
  }
  assert.deepEqual(pageErrors,[]);console.log('PASS HTTPS/WSS access gate, native TLS exporter pairing, pre-approval gate, clock sync, timestamped PCM, stereo, bilingual UI, same-session reconnect, host pin protection and fresh approval after reload');
  if(!fixtureReady)await page.screenshot({path:join(cwd,'test','web-preview.png'),fullPage:true});
}catch(e){if(page){console.error('Browser state:',await page.evaluate(()=>({phase:document.querySelector('#phase')?.textContent,error:document.querySelector('#error')?.textContent,logs:document.querySelector('#logs')?.textContent})));await page.screenshot({path:join(cwd,'test','web-preview.png'),fullPage:true}).catch(()=>{})}throw e;}finally{await browser?.close();gateway?.kill('SIGTERM');host?.close();rmSync(dir,{recursive:true,force:true})}
