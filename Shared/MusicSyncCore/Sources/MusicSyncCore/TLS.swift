// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation
import Security
import CryptoKit
import Network

public enum TLSError: Error { case identity, certificate, exporter }

/// Local P-256 identity. SecIdentityCreate works with in-memory keys; no global trust changes.
public struct TLSIdentity {
    public let identity: SecIdentity
    public let privateRepresentation: Data
    public let publicKeyPin: String
    public static func create(privateRepresentation saved: Data? = nil) throws -> TLSIdentity {
        let attributes: [String:Any] = [kSecAttrKeyType as String:kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String:256, kSecAttrKeyClass as String:kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        let key: SecKey
        if let saved {
            guard let imported = SecKeyCreateWithData(saved as CFData,attributes as CFDictionary,&error) else { throw TLSError.identity }
            key = imported
        } else {
            guard let created = SecKeyCreateRandomKey(attributes as CFDictionary,&error) else { throw TLSError.identity }
            key = created
        }
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicData = SecKeyCopyExternalRepresentation(publicKey,&error) as Data?, publicData.count == 65,
              let privateData = SecKeyCopyExternalRepresentation(key,&error) as Data? else { throw TLSError.identity }
        let signatureAlgorithm = DER.sequence(DER.oid([0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02]))
        let name = DER.sequence(DER.value(0x31,DER.sequence(DER.oid([0x55,0x04,0x03]) + DER.value(0x0c,Data("MusicSync Local Host".utf8)))))
        let spki = DER.sequence(DER.sequence(DER.oid([0x2a,0x86,0x48,0xce,0x3d,0x02,0x01]) + DER.oid([0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07])) + DER.bits(publicData))
        var serial = Data(repeating:0,count:16)
        guard serial.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!) }) == errSecSuccess else { throw TLSError.identity }
        serial[0] = (serial[0] & 0x7f) | 1
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "yyMMddHHmmss'Z'"
        let now = Date()
        let validity = DER.sequence(DER.value(0x17,Data(formatter.string(from:now.addingTimeInterval(-86400)).utf8)) + DER.value(0x17,Data(formatter.string(from:now.addingTimeInterval(365*86400)).utf8)))
        let critical = Data([0x01,0x01,0xff])
        let basic = DER.sequence(DER.oid([0x55,0x1d,0x13]) + critical + DER.value(0x04,DER.sequence(Data())))
        let usage = DER.sequence(DER.oid([0x55,0x1d,0x0f]) + critical + DER.value(0x04,Data([0x03,0x02,0x07,0x80])))
        let eku = DER.sequence(DER.oid([0x55,0x1d,0x25]) + DER.value(0x04,DER.sequence(DER.oid([0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x01]))))
        let body = DER.sequence(DER.value(0xa0,Data([0x02,0x01,0x02])) + DER.value(0x02,serial) + signatureAlgorithm + name + validity + name + spki + DER.value(0xa3,DER.sequence(basic+usage+eku)))
        guard let signature = SecKeyCreateSignature(key,.ecdsaSignatureMessageX962SHA256,body as CFData,&error) as Data?,
              let certificate = SecCertificateCreateWithData(nil,DER.sequence(body+signatureAlgorithm+DER.bits(signature)) as CFData),
              let identity = SecIdentityCreate(nil,certificate,key) else { throw TLSError.certificate }
        return TLSIdentity(identity:identity,privateRepresentation:privateData,publicKeyPin:pin(publicData))
    }
    public static func pin(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    public static func pin(certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate), let bytes = SecKeyCopyExternalRepresentation(key,nil) as Data?, bytes.count == 65 else { return nil }
        return pin(bytes)
    }
}
private enum DER {
    static func value(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = [UInt8](), n = bytes.count
        if n < 128 { length = [UInt8(n)] } else {
            while n > 0 { length.insert(UInt8(n & 255),at:0); n >>= 8 }; length.insert(0x80 | UInt8(length.count),at:0)
        }
        return Data([tag]+length)+bytes
    }
    static func sequence(_ bytes: Data) -> Data { value(0x30,bytes) }
    static func oid(_ bytes: [UInt8]) -> Data { value(0x06,Data(bytes)) }
    static func bits(_ bytes: Data) -> Data { value(0x03,Data([0])+bytes) }
}

/// Unknown self-signed certificates permit only bootstrap; application approval and key pinning follow.
/// A known pin can reject a changed server key inside the TLS handshake itself.
public final class TLSClientTrust: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedPin: String?
    private var capturedPin: String?
    private var rejected = false
    public init(expectedPin: String? = nil) { self.expectedPin = expectedPin }
    public var publicKeyPin: String? { lock.lock(); defer { lock.unlock() }; return capturedPin }
    public var pinRejected: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
    func verify(_ trust: sec_trust_t) -> Bool {
        let value = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(value) as? [SecCertificate], let certificate = chain.first,
              let pin = TLSIdentity.pin(certificate:certificate) else { return false }
        lock.lock(); defer { lock.unlock() }
        capturedPin = pin
        if let expectedPin, expectedPin != pin { rejected = true; return false }
        return true
    }
}

public struct TLSSessionInfo {
    public let pairingCode: String
    public let binding: String
    /// Never includes exported secret bytes or credentials.
    public static func diagnostic(_ connection: NWConnection) -> String {
        guard let metadata = connection.metadata(definition:NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return "stage=metadata-unavailable" }
        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata)
        let cipher = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata)
        return "stage=TLS-exporter-unavailable; version=\(version); cipher=\(cipher)"
    }
    public static func read(_ connection: NWConnection) -> TLSSessionInfo? {
        guard let metadata = connection.metadata(definition:NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13 else { return nil }
        let label = "EXPORTER-MusicSync-pairing-v2"
        guard let secret = label.withCString({ sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata,label.utf8.count,$0,32) }) else { return nil }
        let bytes = Data(secret as DispatchData)
        guard bytes.count == 32 else { return nil }
        let digest = SHA256.hash(data:bytes)
        let number = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 100_000_000
        return TLSSessionInfo(pairingCode:String(format:"%08llu",number),binding:bytes.base64EncodedString())
    }
}
