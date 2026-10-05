// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation

/// Host-owned permissions are scoped to an authenticated paired device.
public struct VolumePermissions: Codable, Equatable, Sendable {
    public var clientMayControlHost = false
    public var hostMayControlClient = true
    public var clientMayControlPeers = false
    public var peersMayControlClient = false
    public var clientMayControlPeerDevices = false
    public var peersMayControlClientDevice = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case clientMayControlHost, hostMayControlClient, clientMayControlPeers, peersMayControlClient, clientMayControlPeerDevices, peersMayControlClientDevice }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        clientMayControlHost = try c.decodeIfPresent(Bool.self,forKey:.clientMayControlHost) ?? false
        hostMayControlClient = try c.decodeIfPresent(Bool.self,forKey:.hostMayControlClient) ?? true
        clientMayControlPeers = try c.decodeIfPresent(Bool.self,forKey:.clientMayControlPeers) ?? false
        peersMayControlClient = try c.decodeIfPresent(Bool.self,forKey:.peersMayControlClient) ?? false
        clientMayControlPeerDevices = try c.decodeIfPresent(Bool.self,forKey:.clientMayControlPeerDevices) ?? false
        peersMayControlClientDevice = try c.decodeIfPresent(Bool.self,forKey:.peersMayControlClientDevice) ?? false
    }
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
    public var volumeScope: String?
    public var outputChannel: String?
    public var channelSelection: String?
    public var playbackState: String?
    public var canControlDevice: Bool?
    public var canControl: Bool
    public init(id: UUID, name: String, volume: Double, canControl: Bool, volumeScope: String? = nil, outputChannel: String? = nil, channelSelection: String? = nil, playbackState: String? = nil, canControlDevice: Bool? = nil) {
        self.id = id; self.name = name; self.volume = volume; self.canControl = canControl; self.volumeScope = volumeScope
        self.outputChannel = outputChannel; self.channelSelection = channelSelection; self.playbackState = playbackState; self.canControlDevice = canControlDevice
    }
}
