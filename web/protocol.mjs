// SPDX-License-Identifier: MIT
import {createHash, createHmac, X509Certificate} from 'node:crypto';
export const MAX = 128 * 1024;
export function encode(message) {
  const data = Buffer.from(JSON.stringify({version:1, ...message}));
  if (!data.length || data.length > MAX) throw Error('Invalid frame size');
  const size = Buffer.alloc(4); size.writeUInt32BE(data.length); return Buffer.concat([size,data]);
}
export class Framer {
  buffer = Buffer.alloc(0);
  consume(data) {
    this.buffer = Buffer.concat([this.buffer,data]); const messages=[];
    while(this.buffer.length>=4) {
      const n=this.buffer.readUInt32BE(0);
      if (!n || n>MAX) throw Error('Invalid frame size');
      if(this.buffer.length<n+4) break;
      const m=JSON.parse(this.buffer.subarray(4,n+4));
      if(m.version!==1 || typeof m.kind!=='string') throw Error('Unsupported protocol');
      messages.push(m); this.buffer=this.buffer.subarray(n+4);
    }
    return messages;
  }
}
export function code(binding) {
  return (createHash('sha256').update(binding).digest().readBigUInt64BE(0)%100000000n).toString().padStart(8,'0');
}
export function pin(raw) {
  const key = new X509Certificate(raw).publicKey.export({format:'jwk'});
  if(key.kty!=='EC'||key.crv!=='P-256') throw Error('Host must use P-256');
  return createHash('sha256').update(Buffer.concat([Buffer.from([4]),Buffer.from(key.x,'base64url'),Buffer.from(key.y,'base64url')])).digest('hex');
}
export function proof(secret,nonce,hostID,clientID,binding) {
  const bytes=Buffer.from(secret,'base64');if(bytes.length!==32)throw Error('Invalid pairing secret');
  return createHmac('sha256',bytes).update(`MusicSync-pair-v2\n${hostID}\n${clientID}\n${nonce}\n${binding}`).digest('base64');
}
export const uuid = value => typeof value==='string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value);
