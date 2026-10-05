// SPDX-License-Identifier: MIT
import {execFileSync} from 'node:child_process';
import {mkdirSync,writeFileSync,existsSync,chmodSync} from 'node:fs';
import {networkInterfaces,hostname} from 'node:os';
import {resolve} from 'node:path';
const dir=resolve(process.env.MUSICSYNC_WEB_DATA||'.local');mkdirSync(dir,{recursive:true,mode:0o700});
if(existsSync(`${dir}/server.key`))throw Error('Keys already exist. Setup does not replace trusted keys.');
const ips=Object.values(networkInterfaces()).flat().filter(x=>x?.family==='IPv4'&&!x.internal).map(x=>x.address);
const hosts=['localhost',hostname(),`${hostname().replace(/\.local$/,'')}.local`];
const sans=[...new Set(hosts)].map(x=>`DNS:${x}`).concat(['IP:127.0.0.1',...ips.map(x=>`IP:${x}`)]).join(',');
const run=(...args)=>execFileSync('openssl',args,{stdio:'inherit',cwd:dir});
run('req','-x509','-newkey','rsa:3072','-nodes','-sha256','-days','3650','-keyout','ca.key','-out','MusicSync-Web-CA.crt','-subj','/CN=MusicSync Private LAN Web CA','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign');
run('req','-new','-newkey','rsa:2048','-nodes','-keyout','server.key','-out','server.csr','-subj','/CN=MusicSync LAN Web');
writeFileSync(`${dir}/server.ext`,`subjectAltName=${sans}\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n`);
run('x509','-req','-in','server.csr','-CA','MusicSync-Web-CA.crt','-CAkey','ca.key','-CAcreateserial','-out','server.crt','-days','365','-sha256','-extfile','server.ext');
for(const file of ['ca.key','server.key'])chmodSync(`${dir}/${file}`,0o600);
console.log(`Trust ONLY ${dir}/MusicSync-Web-CA.crt on your own devices. NEVER share *.key. See README.ko.md / README.md.\nLAN addresses: ${ips.join(', ')}`);
