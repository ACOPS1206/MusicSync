// SPDX-License-Identifier: MIT
import XCTest
import Security
import Network
@testable import MusicSyncCore

final class TLSTests: XCTestCase {
    func testInMemoryIdentityPersistsKeyAndChangesCertificate() throws {
        let first = try TLSIdentity.create()
        let second = try TLSIdentity.create(privateRepresentation:first.privateRepresentation)
        XCTAssertEqual(first.publicKeyPin,second.publicKeyPin)
        XCTAssertNotEqual(first.publicKeyPin,try TLSIdentity.create().publicKeyPin)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(first.identity,&certificate),errSecSuccess)
        let cert = try XCTUnwrap(certificate)
        XCTAssertEqual(TLSIdentity.pin(certificate:cert),first.publicKeyPin)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(cert,SecPolicyCreateBasicX509(),&trust),errSecSuccess)
        let value = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(value,[cert] as CFArray),errSecSuccess)
        XCTAssertTrue(SecTrustEvaluateWithError(value,nil),"Generated certificate must have valid X.509 signature and extensions")
    }
    func testMalformedStoredKeyFailsClosed() { XCTAssertThrowsError(try TLSIdentity.create(privateRepresentation:Data([1,2,3]))) }
    func testWrongHostPinAndPlaintextCannotConnect() throws {
        let q = DispatchQueue(label:"TLS.rejection.test")
        let identity = try TLSIdentity.create()
        let parameters = try LAN.hostParameters(identity:identity)
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener = try NWListener(using:parameters)
        let rejected = expectation(description:"Changed key rejected")
        let plainReady = expectation(description:"Plain TCP probe connected")
        let plainRejected = expectation(description:"Plaintext must not reach the application")
        plainRejected.isInverted = true
        let lock = NSLock()
        var accepted: [Peer] = []
        var probes: [NWConnection] = []
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection,queue:q)
            lock.lock(); accepted.append(peer); lock.unlock()
            peer.onState = { state in if case .failed = state { peer.cancel() } }
            peer.onMessage = { _ in plainRejected.fulfill() }
            peer.start()
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            let trust = TLSClientTrust(expectedPin:String(repeating:"0",count:64))
            let changed = NWConnection(host:.ipv4(.loopback),port:port,using:LAN.clientParameters(trust:trust))
            changed.stateUpdateHandler = { state in
                if case .ready = state { XCTFail("Changed host key was accepted") }
                switch state { case .failed, .waiting: XCTAssertTrue(trust.pinRejected); rejected.fulfill(); changed.cancel(); default: break }
            }
            let plain = NWConnection(host:.ipv4(.loopback),port:port,using:.tcp)
            plain.stateUpdateHandler = { state in
                if case .ready = state {
                    plainReady.fulfill()
                    var legacy = Message("hello"); legacy.pairingVersion = 1
                    plain.send(content:try? Framer.encode(legacy),completion:.contentProcessed { _ in })
                    plain.receive(minimumIncompleteLength:1,maximumLength:1024) { data,_,_,_ in
                        if let data, String(data:data,encoding:.utf8)?.contains("pairApproved") == true { plainRejected.fulfill() }
                    }
                }
            }
            lock.lock(); probes += [changed,plain]; lock.unlock()
            changed.start(queue:q); plain.start(queue:q)
        }
        listener.start(queue:q)
        wait(for:[rejected,plainReady,plainRejected],timeout:2)
        listener.cancel()
        lock.lock(); let all = probes; let hosts = accepted; lock.unlock()
        all.forEach { $0.cancel() }; hosts.forEach { $0.cancel() }
    }
}
