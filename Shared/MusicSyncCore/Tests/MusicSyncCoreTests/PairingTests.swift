// SPDX-License-Identifier: MIT
import XCTest
@testable import MusicSyncCore
final class PairingTests: XCTestCase {
    func testRememberedPairingRejectsReplayAndOtherIdentities() throws {
        let secret = PairingProof.newSecret(), nonce = UUID().uuidString
        let host = UUID().uuidString, client = UUID().uuidString
        let proof = try XCTUnwrap(PairingProof.make(secret:secret,nonce:nonce,hostID:host,clientID:client))
        XCTAssertTrue(PairingProof.verify(proof,secret:secret,nonce:nonce,hostID:host,clientID:client))
        XCTAssertFalse(PairingProof.verify(proof,secret:secret,nonce:UUID().uuidString,hostID:host,clientID:client))
        XCTAssertFalse(PairingProof.verify(proof,secret:secret,nonce:nonce,hostID:UUID().uuidString,clientID:client))
        XCTAssertFalse(PairingProof.verify(proof,secret:secret,nonce:nonce,hostID:host,clientID:UUID().uuidString))
        XCTAssertFalse(PairingProof.verify(proof,secret:PairingProof.newSecret(),nonce:nonce,hostID:host,clientID:client))
    }
    func testUnapprovedAndReconnectedSocketsCannotAccessStreamOrControls() {
        var gate = PairingGate()
        for kind in ["ping","stats","audio","identify","identifyHost","setChannel","channelReport"] { XCTAssertFalse(gate.permits(kind)) }
        XCTAssertTrue(gate.permits("hello")); XCTAssertTrue(gate.permits("pairProof"))
        gate.approve(); XCTAssertTrue(gate.permits("stats")); XCTAssertTrue(gate.permits("identifyHost"))
        let reconnected = PairingGate(); XCTAssertFalse(reconnected.permits("stats"))
    }
    func testMalformedCredentialsAreRejected() {
        XCTAssertNil(PairingProof.make(secret:"bad",nonce:"n",hostID:"h",clientID:"c"))
        XCTAssertFalse(PairingProof.verify("bad",secret:PairingProof.newSecret(),nonce:"n",hostID:"h",clientID:"c"))
        XCTAssertFalse(PairingProof.verify(String(repeating:"a",count:1000),secret:PairingProof.newSecret(),nonce:"n",hostID:"h",clientID:"c"))
    }
    func testPairingAndChannelFieldsSurviveFraming() throws {
        var packet = Message("pairChallenge"); packet.hostID = UUID().uuidString; packet.nonce = UUID().uuidString
        packet.hostAddress = "Example-Mac.local:49152"; packet.pairingVersion = 1
        var change = Message("setChannel"); change.channelSelection = "right"; change.requestID = UUID().uuidString
        var decoder = Framer(); let result = try decoder.consume(Framer.encode(packet) + Framer.encode(change))
        XCTAssertEqual(result[0].hostAddress,packet.hostAddress); XCTAssertEqual(result[0].nonce,packet.nonce)
        XCTAssertEqual(result[1].channelSelection,"right"); XCTAssertEqual(result[1].requestID,change.requestID)
    }
}
