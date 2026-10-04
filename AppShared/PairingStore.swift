// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation
import Security

enum PairingStore {
    static func identity(_ role: String) -> String {
        let key = "pairingIdentity." + role
        if let id = UserDefaults.standard.string(forKey:key), UUID(uuidString:id) != nil { return id }
        let id = UUID().uuidString; UserDefaults.standard.set(id,forKey:key); return id
    }
    private static func query(_ account: String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"dev.acops.MusicSync.pairing.v1", kSecAttrAccount as String:account]
    }
    static func read(_ account: String) -> String? {
        var query = query(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    static func write(_ secret: String, account: String) throws {
        let lookup = query(account); let data = Data(secret.utf8)
        let result = SecItemUpdate(lookup as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw failure(result) }
        var item = lookup; item[kSecValueData as String] = data
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemAdd(item as CFDictionary,nil)
        guard status == errSecSuccess else { throw failure(status) }
    }
    static func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain:"MusicSync.Pairing",code:Int(status),userInfo:[NSLocalizedDescriptionKey:String(format:tr("Keychain unavailable (%d). Pairing changes may last only until the app restarts."),status)])
    }
}
