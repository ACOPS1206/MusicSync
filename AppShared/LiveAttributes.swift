// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
#if os(iOS)
import ActivityKit
import Foundation

struct MusicSyncActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var latencyMS: Int
        var rttMS: Int
        var uncertaintyMS: Int
        var deviceCount: Int
        var dropped: Int
        var warning: Bool
        var offsetMS: Double? = nil
        var jitterMS: Double? = nil
    }
    var role: String
    var sessionID: String
    var peerName: String
}
#endif
