// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation
func tr(_ key: String) -> String {
    let language = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    if ["en", "ko"].contains(language), let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    return NSLocalizedString(key, comment: "")
}
func sessionTitle(_ phase: String) -> String { String(format: tr("MusicSync %@"), tr(phase)) }
