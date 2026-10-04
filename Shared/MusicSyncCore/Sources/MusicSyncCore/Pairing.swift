// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation
import CryptoKit

/// A remembered pairing proves possession on a fresh connection, without resending the secret.
/// TLS exporter binding prevents proof relay across different TLS connections.
public enum PairingProof {
    public static func newSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }
    private static func context(nonce: String, hostID: String, clientID: String, binding: String) -> Data {
        Data("MusicSync-pair-v2\n\(hostID)\n\(clientID)\n\(nonce)\n\(binding)".utf8)
    }
    public static func make(secret: String, nonce: String, hostID: String, clientID: String, binding: String = "") -> String? {
        guard let bytes = Data(base64Encoded: secret), bytes.count == 32 else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: context(nonce:nonce,hostID:hostID,clientID:clientID,binding:binding), using: SymmetricKey(data:bytes))).base64EncodedString()
    }
    public static func verify(_ proof: String, secret: String, nonce: String, hostID: String, clientID: String, binding: String = "") -> Bool {
        guard proof.count <= 64, let code = Data(base64Encoded:proof), code.count == 32,
              let bytes = Data(base64Encoded:secret), bytes.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code,authenticating:context(nonce:nonce,hostID:hostID,clientID:clientID,binding:binding),using:SymmetricKey(data:bytes))
    }
}
/// Every newly accepted socket starts unapproved, even if its claimed device ID is familiar.
public struct PairingGate {
    public private(set) var approved = false
    public init() {}
    public mutating func approve() { approved = true }
    public func permits(_ kind: String) -> Bool {
        approved || ["hello", "pairRequest", "pairProof", "pairConfirm"].contains(kind)
    }
}
