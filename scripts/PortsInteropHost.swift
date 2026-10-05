// SPDX-License-Identifier: MIT
// CI-only Swift server. Automatic code approval is restricted to this test executable.
import Foundation
import Network
import MusicSyncCore
let queue=DispatchQueue(label:"MusicSync Swift interop Host")
let identity=try TLSIdentity.create()
let listener=try NWListener(using:LAN.hostParameters(identity:identity),on:NWEndpoint.Port(rawValue:49556)!)
let hostID=UUID().uuidString
let done=DispatchSemaphore(value:0)
var peers:[UUID:Peer]=[:]
var approved=false
var statsReceived=false
var failure=""
listener.stateUpdateHandler={state in
    if case .ready=state { fputs("READY Swift TLS Host\n",stdout);fflush(stdout) }
    if case .failed(let error)=state {failure=error.localizedDescription;done.signal()}
}
listener.newConnectionHandler={connection in
    let peer=Peer(connection,queue:queue);peers[peer.id]=peer
    var authorized=false
    let nonce=UUID().uuidString
    peer.onFailure={reason in if authorized&&statsReceived {done.signal()}else{failure=reason;done.signal()}}
    peer.onMessage={m in
        if m.kind=="hello" {
            var challenge=Message("pairChallenge");challenge.pairingVersion=2;challenge.hostID=hostID;challenge.nonce=nonce;challenge.name="Swift interop Host";challenge.hostAddress="127.0.0.1:49556";peer.send(challenge)
        }else if m.kind=="pairRequest"{
            var pending=Message("pairPending");pending.hostID=hostID;pending.pairingCode=peer.tlsSession?.pairingCode;peer.send(pending)
        }else if m.kind=="pairConfirm"{
            guard m.pairingCode==peer.tlsSession?.pairingCode else{failure="Client/Host exporter mismatch";done.signal();return}
            authorized=true;approved=true
            var approval=Message("pairApproved");approval.hostID=hostID;approval.pairingSecret=PairingProof.newSecret();approval.name="Swift interop Host";approval.outputChannel="stereo";approval.volumeControlVersion=1;approval.hostVolume=1;peer.send(approval)
        }else if authorized&&m.kind=="ping",let t1=m.t1{
            var pong=Message("pong");pong.t1=t1;pong.t2=SyncClock.now;pong.t3=SyncClock.now;peer.send(pong)
        }else if authorized&&m.kind=="stats",!statsReceived {
            guard m.rtt?.isFinite==true,m.offset?.isFinite==true,m.jitter?.isFinite==true else{failure="Invalid Kotlin clock stats";done.signal();return}
            statsReceived=true
            let base=SyncClock.now+0.18
            for sequence in 0..<20 {
                queue.asyncAfter(deadline:.now()+Double(sequence)*0.01){
                    let values=(0..<960).map{Float($0 % 2 == 0 ? 0.25 : -0.25)}
                    var audio=Message("audio");audio.sequence=UInt64(sequence);audio.epoch=1;audio.pts=base+Double(sequence)*0.01;audio.sampleRate=48000;audio.channels=2;audio.frames=480;audio.latency=0.18
                    audio.payload=values.withUnsafeBytes{Data($0)};peer.send(audio)
                }
            }
        }
    };peer.start()
}
listener.start(queue:queue)
let result=done.wait(timeout:.now()+90)
listener.cancel();peers.values.forEach{$0.cancel()}
guard result == .success,failure.isEmpty,approved,statsReceived else{fputs("Swift Host interop failed: \(failure)\n",stderr);exit(1)}
print("PASS: Swift Host / Kotlin Client TLS exporter, code approval, clock stats and scheduled PCM")
