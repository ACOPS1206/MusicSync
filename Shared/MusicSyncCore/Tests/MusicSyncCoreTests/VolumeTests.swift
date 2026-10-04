// SPDX-License-Identifier: MIT
import XCTest
@testable import MusicSyncCore
final class VolumeTests: XCTestCase {
    func testRejectsUnsafeGains() {
        for value in [Double.nan,.infinity,-.infinity,-0.001,1.001] { XCTAssertNil(VolumeControl.valid(value)) }
        XCTAssertNil(VolumeControl.valid(nil)); XCTAssertEqual(VolumeControl.valid(0),0); XCTAssertEqual(VolumeControl.valid(1),1)
    }
    func testLeastPrivilegeDefaultsAndPersistedPolicy() throws {
        var policy = VolumePermissions()
        XCTAssertTrue(policy.hostMayControlClient)
        XCTAssertFalse(policy.clientMayControlHost); XCTAssertFalse(policy.clientMayControlPeers); XCTAssertFalse(policy.peersMayControlClient)
        policy.clientMayControlPeers = true
        XCTAssertEqual(try JSONDecoder().decode(VolumePermissions.self,from:JSONEncoder().encode(policy)),policy)
        var gate = PairingGate()
        for kind in ["setHostVolume","setPeerVolume","volumeReport"] { XCTAssertFalse(gate.permits(kind)) }
        gate.approve(); XCTAssertTrue(gate.permits("setPeerVolume"))
    }
    func testRosterFramingAndOlderMessageCompatibility() throws {
        var message = Message("volumePeers")
        message.volumePeers = [VolumePeer(id:UUID(),name:"iPhone",volume:0.4,canControl:false)]
        var framer = Framer()
        XCTAssertEqual(try framer.consume(Framer.encode(message)).first?.volumePeers,message.volumePeers)
        let older = try JSONDecoder().decode(Message.self,from:Data(#"{"version":1,"kind":"pairApproved"}"#.utf8))
        XCTAssertNil(older.volumePeers); XCTAssertNil(older.volumeControlVersion)
    }
}
