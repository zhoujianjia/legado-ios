import CryptoKit
import Foundation
import Security
@testable import yuedu_app

/// Test-only dynamic PKI. Security creates/retains each private key; only public
/// keys, certificates, CMS and signatures become Data. No fixed private fixture.
enum SelfRenewalSigningOwnedPKIFixture {
    typealias Material = SelfRenewalSigningMaterialVault.KeyMaterial
    typealias Value = SelfRenewalDERPropertyList.Value

    static func certificate(for key: SecKey, signedBy issuer: Material? = nil, at date: Date) throws -> Data {
        let subjectPublic = try publicBytes(key)
        let ec = try isEC(key)
        let signingKey = issuer?.privateKey ?? key
        let signingEC = try isEC(signingKey)
        let algorithm = signatureAlgorithm(ec: signingEC)
        let subject = name(subjectPublic)
        let issuerName = try issuer.map { try certificateFields($0.certificateChainDER[0]).subject } ?? subject
        let spkiAlgorithm = ec ? sequence([oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 2, 1]), oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 3, 1, 7])])
            : sequence([oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]), der(5, Data())])
        let spki = sequence([spkiAlgorithm, der(3, Data([0]) + subjectPublic)])
        let isRoot = issuer == nil
        let constraints = sequence([oid([0x55, 0x1d, 0x13]), der(1, Data([0xff])),
            der(4, sequence(isRoot ? [der(1, Data([0xff]))] : []))])
        let usage = sequence([oid([0x55, 0x1d, 0x0f]), der(1, Data([0xff])),
            der(4, der(3, isRoot ? Data([2, 0x84]) : Data([7, 0x80])))])
        let validity = sequence([time(date.addingTimeInterval(-3_600)), time(date.addingTimeInterval(86_400 * 30))])
        let tbs = sequence([der(0xa0, integer(2)), integer(isRoot ? 1 : 2), algorithm, issuerName, validity, subject, spki,
            der(0xa3, sequence([constraints, usage]))])
        let signature = try sign(tbs, key: signingKey)
        let certificate = sequence([tbs, algorithm, der(3, Data([0]) + signature)])
        guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else { throw CocoaError(.coderInvalidValue) }
        return certificate
    }

    /// The ephemeral test issuer has no persistent lifecycle and is never an
    /// Apple account or provisioning service. Vault signing keys are separate.
    static func issuer(at date: Date) throws -> Material {
        let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(options as CFDictionary, &error) else {
            if let error { _ = error.takeRetainedValue() }; throw CocoaError(.coderInvalidValue)
        }
        return Material(privateKey: key, certificateChainDER: [try certificate(for: key, at: date)])
    }

    static func profile(from original: SelfRenewalProvisioningProfileVerifier.ModernProfile,
        developerCertificate: Data, issuer: Material, at date: Date,
        transform: ((inout [String: Value]) -> Void)? = nil) throws -> Data {
        guard case .dictionary(var properties) = original.properties else { throw CocoaError(.coderInvalidValue) }
        properties["UUID"] = .string(UUID().uuidString)
        properties["CreationDate"] = .date(date.addingTimeInterval(-60))
        properties["ExpirationDate"] = .date(date.addingTimeInterval(3_600))
        properties["DeveloperCertificates"] = .array([.data(Data(SHA256.hash(data: developerCertificate)))])
        transform?(&properties)
        let inner = try cms(encode(.dictionary(properties)), issuer: issuer)
        let outer = try PropertyListSerialization.data(fromPropertyList: ["DER-Encoded-Profile": inner], format: .xml, options: 0)
        return try cms(outer, issuer: issuer)
    }
    static func cms(_ content: Data, issuer: Material) throws -> Data {
        let certificate = try certificateFields(issuer.certificateChainDER[0])
        let digest = sequence([oid([0x60, 0x86, 0x48, 1, 0x65, 3, 4, 2, 1]), der(5, Data())])
        let algorithm = signatureAlgorithm(ec: try isEC(issuer.privateKey))
        let signature = try sign(content, key: issuer.privateKey)
        let signer = sequence([integer(1), sequence([certificate.issuer, certificate.serial]), digest, algorithm, der(4, signature)])
        let signed = sequence([integer(1), der(0x31, digest), sequence([oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 7, 1]), der(0xa0, der(4, content))]),
            der(0xa0, issuer.certificateChainDER.reduce(into: Data()) { $0.append($1) }), der(0x31, signer)])
        return sequence([oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 7, 2]), der(0xa0, signed)])
    }
    private static func sign(_ data: Data, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        let algorithm: SecKeyAlgorithm = try isEC(key) ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
        guard let result = SecKeyCreateSignature(key, algorithm, data as CFData, &error) as Data? else {
            if let error { _ = error.takeRetainedValue() }; throw CocoaError(.coderInvalidValue)
        }
        return result
    }
    private static func publicBytes(_ key: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw CocoaError(.coderInvalidValue) }
        var error: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            if let error { _ = error.takeRetainedValue() }; throw CocoaError(.coderInvalidValue)
        }
        return bytes
    }
    private static func isEC(_ key: SecKey) throws -> Bool {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any], let kind = attributes[kSecAttrKeyType as String] as? String else {
            throw CocoaError(.coderInvalidValue)
        }
        return kind == kSecAttrKeyTypeECSECPrimeRandom as String
    }
    private static func certificateFields(_ data: Data) throws -> (issuer: Data, serial: Data, subject: Data) {
        let outer = try SelfRenewalCMSVerifier.children(of: SelfRenewalCMSVerifier.parseDER(data))
        let tbs = try SelfRenewalCMSVerifier.children(of: outer[0])
        let base = tbs[0].tag == 0xa0 ? 1 : 0
        return (tbs[base + 2].originalDER, tbs[base].originalDER, tbs[base + 4].originalDER)
    }
    private static func name(_ publicKey: Data) -> Data {
        let hash = SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
        return sequence([der(0x31, sequence([oid([0x55, 4, 3]), der(0x0c, Data(("Owned Runtime " + hash).utf8))]))])
    }
    private static func signatureAlgorithm(ec: Bool) -> Data {
        ec ? sequence([oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 2])])
            : sequence([oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 0x0b]), der(5, Data())])
    }
    private static func time(_ value: Date) -> Data {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let year = formatter.calendar.component(.year, from: value)
        formatter.dateFormat = (1950...2049).contains(year) ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return der((1950...2049).contains(year) ? 0x17 : 0x18, Data(formatter.string(from: value).utf8))
    }
    private static func encode(_ value: Value) throws -> Data {
        switch value {
        case .dictionary(let values):
            let pairs = try values.map { sequence([der(0x0c, Data($0.key.utf8)), try encode($0.value)]) }.sorted { $0.lexicographicallyPrecedes($1) }
            return der(0x31, pairs.reduce(into: Data()) { $0.append($1) })
        case .array(let values): return sequence(try values.map(encode))
        case .string(let value): return der(0x0c, Data(value.utf8))
        case .data(let value): return der(4, value)
        case .integer(let value): return integer(value)
        case .boolean(let value): return der(1, Data([value ? 0xff : 0]))
        case .date(let value): return time(value)
        case .null: return der(5, Data())
        }
    }
    private static func integer(_ value: Int64) -> Data {
        let bits = UInt64(bitPattern: value)
        var bytes = (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        while bytes.count > 1 && ((bytes[0] == 0 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xff && bytes[1] & 0x80 != 0)) { bytes.removeFirst() }
        return der(2, Data(bytes))
    }
    private static func oid(_ bytes: [UInt8]) -> Data { der(6, Data(bytes)) }
    private static func sequence(_ values: [Data]) -> Data { der(0x30, values.reduce(into: Data()) { $0.append($1) }) }
    private static func der(_ tag: UInt8, _ body: Data) -> Data {
        var result = Data([tag])
        if body.count < 128 { result.append(UInt8(body.count)) }
        else {
            var count = body.count; var length: [UInt8] = []
            while count > 0 { length.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            result.append(0x80 | UInt8(length.count)); result.append(contentsOf: length)
        }
        result.append(body); return result
    }
}
