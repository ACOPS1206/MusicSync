// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation

/// Host-owned permissions are scoped to an authenticated paired device.
public struct VolumePermissions: Codable, Equatable, Sendable {
    public var clientMayControlHost = false
    public var hostMayControlClient = true
    public var clientMayControlPeers = false
    public var peersMayControlClient = false
    public init() {}
}
public enum VolumeControl {
    public static func valid(_ volume: Double?) -> Double? {
        guard let volume, volume.isFinite, (0...1).contains(volume) else { return nil }
        return volume
    }
}

/// Session identifiers are deliberately not persistent pairing identities.
public struct VolumePeer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var volume: Double
    public var canControl: Bool
    public init(id: UUID, name: String, volume: Double, canControl: Bool) {
        self.id = id; self.name = name; self.volume = volume; self.canControl = canControl
    }
}
