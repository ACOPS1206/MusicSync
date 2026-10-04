// SPDX-License-Identifier: LicenseRef-MusicSync-Attribution-NonCommercial-SourceSharing-1.0
// Copyright (c) 2026 ACOPS1206
// Source: https://github.com/ACOPS1206/MusicSync

import Foundation
import MusicSyncCore

enum SpeakerLayout: String, CaseIterable, Identifiable {
    case stereo, hostLeft, hostRight
    var id: Self { self }
    var title: String {
        switch self {
        case .stereo: return tr("Stereo on each device")
        case .hostLeft: return tr("Host left · Client right")
        case .hostRight: return tr("Host right · Client left")
        }
    }
    var localChannel: OutputChannel { self == .stereo ? .stereo : self == .hostLeft ? .left : .right }
    var remoteChannel: OutputChannel { self == .stereo ? .stereo : self == .hostLeft ? .right : .left }
}
enum ChannelSelection: String, CaseIterable, Identifiable {
    case automatic, stereo, left, right
    var id: Self { self }
    var channel: OutputChannel? { OutputChannel(rawValue: rawValue) }
    var title: String {
        switch self {
        case .automatic: return tr("Follow Host")
        case .stereo: return tr("Stereo")
        case .left: return tr("Left channel")
        case .right: return tr("Right channel")
        }
    }
}
