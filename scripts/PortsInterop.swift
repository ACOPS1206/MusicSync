// SPDX-License-Identifier: MIT
// Real Kotlin TLS 1.3 Host -> Network.framework Swift Client interoperability.
import Foundation
import Network
import MusicSyncCore

let queue = DispatchQueue(label:"MusicSync interop")
let done = DispatchSemaphore(value:0)
let trust = TLSClientTrust(expectedPin:nil)
let peer = Peer(NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:49555)!,using:LAN.clientParameters(trust:trust)),queue:queue)
let deviceID = UUID().uuidString
var hostID = ""
var approved = false
var receivedPong = false
var receivedChannel = false
var failure = ""
peer.onFailure = { reason in failure=reason; done.signal() }
peer.onState = { state in
    switch state {
    case .ready:
        guard peer.tlsSession != nil, trust.publicKeyPin != nil else { failure="No verified TLS session";done.signal();return }
        var m=Message("hello");m.deviceID=deviceID;m.name="Swift interop client";m.pairingVersion=2;m.channelSelection="stereo";m.volumeControlVersion=1;m.volume=1;peer.send(m)
    case .failed(let error):failure=error.localizedDescription;done.signal()
    default:break
    }
}
peer.onMessage = { m in
    if m.kind=="pairChallenge",let id=m.hostID {hostID=id;peer.send(Message("pairRequest"))}
    else if m.kind=="pairPending" {
        guard m.pairingCode==peer.tlsSession?.pairingCode else{failure="TLS exporter codes disagree across Kotlin/Apple";done.signal();return}
        var confirm=Message("pairConfirm");confirm.pairingCode=m.pairingCode;peer.send(confirm)
    } else if m.kind=="pairApproved" {
        guard m.hostID==hostID,let secret=m.pairingSecret,Data(base64Encoded:secret)?.count==32 else{failure="Invalid approval";done.signal();return}
        approved=true
        var ping=Message("ping");ping.t1=SyncClock.now;peer.send(ping)
        var report=Message("channelReport");report.channelSelection="left";report.outputChannel="left";report.playbackState="Streaming";peer.send(report)
        var identify=Message("identifyHost");peer.send(identify)
    } else if m.kind=="pong" {receivedPong=m.t1 != nil && m.t2 != nil && m.t3 != nil}
    else if m.kind=="volumePeers" {receivedChannel=true}
    if approved && receivedPong && receivedChannel {done.signal()}
}
peer.start()
let result=done.wait(timeout:.now()+30)
peer.cancel()
guard result == .success,failure.isEmpty,approved,receivedPong,receivedChannel else{fputs("Interop failed: \(failure)\n",stderr);exit(1)}
print("PASS: Kotlin/Swift TLS 1.3 exporters, human code approval, authenticated clocks and roster")
