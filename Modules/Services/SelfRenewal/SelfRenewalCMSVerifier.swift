import CryptoKit
import Foundation
import Security

/// Bounded DER SignedData verification using public iOS Security APIs. Trust is
/// exclusively relative to explicit anchors, never an assertion of Apple account,
/// provisioning authority, entitlement authorization, timestamp or revocation.
enum SelfRenewalCMSVerifier {
    enum Failure: Error, Sendable, Equatable {
        case sizeLimit, malformedDER, unsupportedCMS, unsupportedAlgorithm
        case missingContent, ambiguousContent, invalidAttributes, digestMismatch
        case certificateLimit, malformedCertificate, signerNotFound, ambiguousSigner
        case invalidSignature, invalidAnchors, trustConfiguration, untrustedChain
    }
    struct Signer: Sendable, Equatable {
        let certificateSHA256: Data
        let explicitAnchorSHA256: [Data]
        let verifiedAt: Date
        var signatureVerified: Bool { true }
        var chainValidatedToExplicitAnchors: Bool { true }
        var appleProvisioningAuthorityEstablished: Bool { false }
        fileprivate init(certificateSHA256: Data, explicitAnchorSHA256: [Data], verifiedAt: Date) {
            self.certificateSHA256 = certificateSHA256
            self.explicitAnchorSHA256 = explicitAnchorSHA256
            self.verifiedAt = verifiedAt
        }
    }
    struct VerifiedContent: Sendable, Equatable {
        let content: Data
        let signers: [Signer]
        var accountIdentityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(content: Data, signers: [Signer]) {
            self.content = content
            self.signers = signers
        }
    }
    enum Limits {
        static let messageBytes = 2_097_152
        static let contentBytes = 1_048_576
        static let certificateBytes = 65_536
        static let certificates = 16
        static let anchors = 8
        static let signers = 8
        static let children = 256
        static let attributes = 64
    }

    /// This function performs synchronous crypto, so callers must use their
    /// existing non-main worker. Embedded and detached content are exclusive.
    static func verify(_ message: Data, detachedContent: Data? = nil,
        anchors: [Data], at date: Date) throws -> VerifiedContent {
        precondition(!Thread.isMainThread, "CMS verification must stay off main")
        try Task.checkCancellation()
        let started = SourcePerfTrace.now
        defer {
            SourcePerfTrace.record("renewal.material.cms",
                "bytes=\(message.count) main=\(Thread.isMainThread)", since: started, thresholdMs: 0)
        }
        guard !message.isEmpty, message.count <= Limits.messageBytes,
              detachedContent.map({ $0.count <= Limits.contentBytes }) ?? true else { throw Failure.sizeLimit }
        guard !anchors.isEmpty, anchors.count <= Limits.anchors,
              anchors.allSatisfy({ !$0.isEmpty && $0.count <= Limits.certificateBytes }),
              Set(anchors).count == anchors.count, date.timeIntervalSince1970.isFinite else { throw Failure.invalidAnchors }
        let anchorCertificates = try anchors.map { try certificate($0) }
        let outer = try children(try single(message, tag: 0x30))
        guard outer.count == 2, outer[0].tag == 0x06, outer[0].body == OID.signedData,
              outer[1].tag == 0xa0 else { throw Failure.unsupportedCMS }
        let signed = try children(try single(outer[1].body, tag: 0x30))
        guard signed.count == 5, signed[0].tag == 0x02,
              signed[0].body == Data([1]) || signed[0].body == Data([3]),
              signed[1].tag == 0x31, signed[2].tag == 0x30,
              signed[3].tag == 0xa0, signed[4].tag == 0x31 else { throw Failure.unsupportedCMS }
        let digestAlgorithms = try children(signed[1]).map { try digestAlgorithm($0) }
        guard !digestAlgorithms.isEmpty, Set(digestAlgorithms).count == digestAlgorithms.count else { throw Failure.unsupportedAlgorithm }
        let contentFields = try children(signed[2])
        guard !contentFields.isEmpty, contentFields[0].tag == 0x06,
              contentFields[0].body == OID.data, contentFields.count <= 2 else { throw Failure.unsupportedCMS }
        let content: Data
        if contentFields.count == 2 {
            guard detachedContent == nil else { throw Failure.ambiguousContent }
            guard contentFields[1].tag == 0xa0 else { throw Failure.unsupportedCMS }
            content = try single(contentFields[1].body, tag: 0x04).body
        } else {
            guard let detachedContent else { throw Failure.missingContent }
            content = detachedContent
        }
        guard content.count <= Limits.contentBytes else { throw Failure.sizeLimit }
        let certificateNodes = try children(signed[3])
        guard !certificateNodes.isEmpty, certificateNodes.count <= Limits.certificates else { throw Failure.certificateLimit }
        guard Set(certificateNodes.map(\.full)).count == certificateNodes.count else { throw Failure.malformedCertificate }
        let certificates = try certificateNodes.map { try certificate($0.full) }
        let signerNodes = try children(signed[4])
        guard !signerNodes.isEmpty, signerNodes.count <= Limits.signers else { throw Failure.unsupportedCMS }
        var results: [Signer] = []
        var seenSigners = Set<Data>()
        for node in signerNodes {
            try Task.checkCancellation()
            let fields = try children(node)
            guard node.tag == 0x30, fields.count >= 5, fields[0].tag == 0x02 else { throw Failure.unsupportedCMS }
            let sid = fields[1]
            guard (sid.tag == 0x30 && fields[0].body == Data([1])) ||
                  (sid.tag == 0x80 && fields[0].body == Data([3]) && signed[0].body == Data([3])) else { throw Failure.unsupportedCMS }
            let digest = try digestAlgorithm(fields[2])
            guard digestAlgorithms.contains(digest) else { throw Failure.unsupportedAlgorithm }
            let matches = try certificateNodes.indices.filter { try matchesSigner(sid, certificate: certificateNodes[$0]) }
            guard !matches.isEmpty else { throw Failure.signerNotFound }
            guard matches.count == 1, let index = matches.first else { throw Failure.ambiguousSigner }
            let leaf = certificates[index]
            let leafHash = Data(SHA256.hash(data: certificateNodes[index].full))
            guard seenSigners.insert(leafHash).inserted else { throw Failure.ambiguousSigner }
            var position = 3
            let signatureInput: Data
            if fields[position].tag == 0xa0 {
                signatureInput = try validateAttributes(fields[position], content: content, digest: digest)
                position += 1
            } else {
                signatureInput = content
            }
            guard fields.count == position + 2 || fields.count == position + 3,
                  fields[position + 1].tag == 0x04,
                  !fields[position + 1].body.isEmpty else { throw Failure.unsupportedCMS }
            if fields.count == position + 3 {
                guard fields[position + 2].tag == 0xa1 else { throw Failure.unsupportedCMS }
                // Timestamp/countersignature attributes convey no trust here.
                _ = try children(fields[position + 2])
            }
            let algorithm = try signatureAlgorithm(fields[position], digest: digest)
            guard let key = SecCertificateCopyKey(leaf),
                  SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { throw Failure.unsupportedAlgorithm }
            var signatureError: Unmanaged<CFError>?
            guard SecKeyVerifySignature(key, algorithm, signatureInput as CFData,
                fields[position + 1].body as CFData, &signatureError) else {
                if let signatureError { _ = signatureError.takeRetainedValue() }
                throw Failure.invalidSignature
            }
            let chain = [leaf] + certificates.enumerated().filter { $0.offset != index }.map(\.element)
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
                  let trust,
                  SecTrustSetAnchorCertificates(trust, anchorCertificates as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
                  SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess else { throw Failure.trustConfiguration }
            var trustError: CFError?
            guard SecTrustEvaluateWithError(trust, &trustError) else { throw Failure.untrustedChain }
            try Task.checkCancellation()
            results.append(Signer(certificateSHA256: leafHash,
                explicitAnchorSHA256: anchors.map { Data(SHA256.hash(data: $0)) }, verifiedAt: date))
        }
        return VerifiedContent(content: content, signers: results)
    }

    private enum Digest: Hashable {
        case sha1, sha256, sha384, sha512
        func hash(_ data: Data) -> Data {
            switch self {
            case .sha1: return Data(Insecure.SHA1.hash(data: data))
            case .sha256: return Data(SHA256.hash(data: data))
            case .sha384: return Data(SHA384.hash(data: data))
            case .sha512: return Data(SHA512.hash(data: data))
            }
        }
        var rsa: SecKeyAlgorithm {
            switch self {
            case .sha1: return .rsaSignatureMessagePKCS1v15SHA1
            case .sha256: return .rsaSignatureMessagePKCS1v15SHA256
            case .sha384: return .rsaSignatureMessagePKCS1v15SHA384
            case .sha512: return .rsaSignatureMessagePKCS1v15SHA512
            }
        }
        var ecdsa: SecKeyAlgorithm {
            switch self {
            case .sha1: return .ecdsaSignatureMessageX962SHA1
            case .sha256: return .ecdsaSignatureMessageX962SHA256
            case .sha384: return .ecdsaSignatureMessageX962SHA384
            case .sha512: return .ecdsaSignatureMessageX962SHA512
            }
        }
    }
    private static func certificate(_ data: Data) throws -> SecCertificate {
        guard !data.isEmpty, data.count <= Limits.certificateBytes,
              let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw Failure.malformedCertificate }
        return certificate
    }
    private static func algorithmFields(_ node: Node) throws -> [Node] {
        let fields = try children(node)
        guard node.tag == 0x30, fields.count == 1 || fields.count == 2,
              fields[0].tag == 0x06 else { throw Failure.unsupportedAlgorithm }
        return fields
    }
    private static func digestAlgorithm(_ node: Node) throws -> Digest {
        let fields = try algorithmFields(node)
        guard fields.count == 1 || (fields[1].tag == 0x05 && fields[1].body.isEmpty) else { throw Failure.unsupportedAlgorithm }
        switch fields[0].body {
        case OID.sha1: return .sha1
        case OID.sha256: return .sha256
        case OID.sha384: return .sha384
        case OID.sha512: return .sha512
        default: throw Failure.unsupportedAlgorithm
        }
    }
    private static func signatureAlgorithm(_ node: Node, digest: Digest) throws -> SecKeyAlgorithm {
        let fields = try algorithmFields(node)
        if fields[0].body == OID.rsaEncryption {
            guard fields.count == 1 || (fields[1].tag == 0x05 && fields[1].body.isEmpty) else { throw Failure.unsupportedAlgorithm }
            return digest.rsa
        }
        let rsaDigests: [Data: Digest] = [OID.rsaSHA1: .sha1, OID.rsaSHA256: .sha256, OID.rsaSHA384: .sha384, OID.rsaSHA512: .sha512]
        if let boundDigest = rsaDigests[fields[0].body] {
            guard boundDigest == digest, fields.count == 1 || (fields[1].tag == 0x05 && fields[1].body.isEmpty) else { throw Failure.unsupportedAlgorithm }
            return digest.rsa
        }
        let ecDigests: [Data: Digest] = [OID.ecSHA1: .sha1, OID.ecSHA256: .sha256, OID.ecSHA384: .sha384, OID.ecSHA512: .sha512]
        guard let boundDigest = ecDigests[fields[0].body], boundDigest == digest, fields.count == 1 else { throw Failure.unsupportedAlgorithm }
        return digest.ecdsa
    }
    private static func validateAttributes(_ node: Node, content: Data, digest: Digest) throws -> Data {
        let attributes = try children(node)
        guard !attributes.isEmpty, attributes.count <= Limits.attributes else { throw Failure.invalidAttributes }
        var previous: Data?
        var seen = Set<Data>()
        var expectedDigest: Data?
        var hasContentType = false
        var derNodes = 0
        for attribute in attributes {
            try validateAttributeDER(attribute, depth: 0, nodes: &derNodes)
            if let previous, attribute.full.lexicographicallyPrecedes(previous) { throw Failure.invalidAttributes }
            previous = attribute.full
            let fields = try children(attribute)
            guard attribute.tag == 0x30, fields.count == 2, fields[0].tag == 0x06,
                  fields[1].tag == 0x31, seen.insert(fields[0].body).inserted else { throw Failure.invalidAttributes }
            let values = try children(fields[1])
            guard !values.isEmpty else { throw Failure.invalidAttributes }
            if fields[0].body == OID.contentType {
                guard values.count == 1, values[0].tag == 0x06, values[0].body == OID.data else { throw Failure.invalidAttributes }
                hasContentType = true
            } else if fields[0].body == OID.messageDigest {
                guard values.count == 1, values[0].tag == 0x04 else { throw Failure.invalidAttributes }
                expectedDigest = values[0].body
            }
        }
        guard hasContentType, let expectedDigest else { throw Failure.invalidAttributes }
        guard expectedDigest == digest.hash(content) else { throw Failure.digestMismatch }
        // RFC5652 section5.4: sign the complete DER SET encoding, replacing the
        // implicit context tag only; its canonical length/contents stay intact.
        var encoded = node.full
        encoded[encoded.startIndex] = 0x31
        return encoded
    }
    private static func validateAttributeDER(_ node: Node, depth: Int, nodes: inout Int) throws {
        try Task.checkCancellation()
        nodes += 1
        guard depth <= 16, nodes <= 4_096 else { throw Failure.sizeLimit }
        if node.tag & 0xc0 == 0 {
            let constructed = node.tag & 0x20 != 0
            let sequenceOrSet = node.tag & 0x1f == 0x10 || node.tag & 0x1f == 0x11
            guard constructed == sequenceOrSet else { throw Failure.malformedDER }
        }
        if node.tag & 0x20 != 0 {
            let nested = try children(node)
            var previous: Data?
            for child in nested {
                if node.tag == 0x31, let previous,
                   child.full.lexicographicallyPrecedes(previous) { throw Failure.malformedDER }
                previous = child.full
                try validateAttributeDER(child, depth: depth + 1, nodes: &nodes)
            }
        } else if node.tag == 0x02 {
            guard !node.body.isEmpty else { throw Failure.malformedDER }
            if node.body.count > 1 {
                let first = node.body[node.body.startIndex]
                let second = node.body[node.body.startIndex + 1]
                guard !(first == 0 && second < 0x80), !(first == 0xff && second >= 0x80) else { throw Failure.malformedDER }
            }
        } else if node.tag == 0x01 {
            guard node.body == Data([0]) || node.body == Data([0xff]) else { throw Failure.malformedDER }
        } else if node.tag == 0x05 {
            guard node.body.isEmpty else { throw Failure.malformedDER }
        } else if node.tag == 0x03 {
            guard let unused = node.body.first, unused <= 7 else { throw Failure.malformedDER }
            if node.body.count == 1 {
                guard unused == 0 else { throw Failure.malformedDER }
            } else if let last = node.body.last, unused > 0 {
                guard last & UInt8((1 << Int(unused)) - 1) == 0 else { throw Failure.malformedDER }
            }
        } else if node.tag == 0x06 {
            guard !node.body.isEmpty, let last = node.body.last, last & 0x80 == 0 else { throw Failure.malformedDER }
            var start = true
            for byte in node.body {
                guard !(start && byte == 0x80) else { throw Failure.malformedDER }
                start = byte & 0x80 == 0
            }
        } else if node.tag == 0x0c {
            guard String(data: node.body, encoding: .utf8) != nil else { throw Failure.malformedDER }
        }
    }
    private static func matchesSigner(_ sid: Node, certificate: Node) throws -> Bool {
        let certificateFields = try children(certificate)
        guard certificate.tag == 0x30, certificateFields.count == 3 else { throw Failure.malformedCertificate }
        let tbs = try children(certificateFields[0])
        let start = tbs.first?.tag == 0xa0 ? 1 : 0
        guard tbs.count >= start + 6, tbs[start].tag == 0x02 else { throw Failure.malformedCertificate }
        if sid.tag == 0x30 {
            let fields = try children(sid)
            guard fields.count == 2, fields[0].tag == 0x30, fields[1].tag == 0x02 else { throw Failure.unsupportedCMS }
            return fields[0].full == tbs[start + 2].full && fields[1].body == tbs[start].body
        }
        guard !sid.body.isEmpty else { throw Failure.unsupportedCMS }
        guard let extensions = tbs.dropFirst(start + 6).first(where: { $0.tag == 0xa3 }) else { return false }
        var found: Data?
        for ext in try children(try single(extensions.body, tag: 0x30)) {
            let fields = try children(ext)
            guard ext.tag == 0x30, fields.count == 2 || fields.count == 3,
                  fields[0].tag == 0x06, fields.last?.tag == 0x04 else { throw Failure.malformedCertificate }
            if fields[0].body == OID.subjectKeyIdentifier {
                guard found == nil, let value = fields.last else { throw Failure.malformedCertificate }
                found = try single(value.body, tag: 0x04).body
            }
        }
        return found == sid.body
    }

    private struct Node {
        let tag: UInt8
        let full: Data
        let body: Data
    }
    private static func single(_ data: Data, tag: UInt8) throws -> Node {
        var offset = 0
        let node = try next(data, offset: &offset)
        guard node.tag == tag, offset == data.count else { throw Failure.malformedDER }
        return node
    }
    private static func children(_ node: Node) throws -> [Node] {
        guard node.tag & 0x20 != 0 else { throw Failure.malformedDER }
        var result: [Node] = []
        var offset = 0
        while offset < node.body.count {
            try Task.checkCancellation()
            guard result.count < Limits.children else { throw Failure.sizeLimit }
            result.append(try next(node.body, offset: &offset))
        }
        return result
    }
    private static func next(_ data: Data, offset: inout Int) throws -> Node {
        let start = offset
        guard offset <= data.count - 2 else { throw Failure.malformedDER }
        let tag = data[data.startIndex + offset]
        offset += 1
        guard tag != 0, tag & 0x1f != 0x1f else { throw Failure.malformedDER }
        let first = Int(data[data.startIndex + offset])
        offset += 1
        let length: Int
        if first < 128 {
            length = first
        } else {
            let width = first & 127
            guard width > 0, width <= 4, offset <= data.count - width,
                  data[data.startIndex + offset] != 0 else { throw Failure.malformedDER }
            var value = 0
            for _ in 0..<width { value = (value << 8) | Int(data[data.startIndex + offset]); offset += 1 }
            guard value >= 128 else { throw Failure.malformedDER }
            length = value
        }
        guard length <= data.count - offset else { throw Failure.malformedDER }
        let end = offset + length
        let body = Data(data[(data.startIndex + offset)..<(data.startIndex + end)])
        offset = end
        return Node(tag: tag, full: Data(data[(data.startIndex + start)..<(data.startIndex + end)]), body: body)
    }
    private enum OID {
        static let signedData = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,7,2])
        static let data = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,7,1])
        static let contentType = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,9,3])
        static let messageDigest = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,9,4])
        static let sha1 = Data([0x2b,0x0e,3,2,0x1a])
        static let sha256 = Data([0x60,0x86,0x48,1,0x65,3,4,2,1])
        static let sha384 = Data([0x60,0x86,0x48,1,0x65,3,4,2,2])
        static let sha512 = Data([0x60,0x86,0x48,1,0x65,3,4,2,3])
        static let rsaEncryption = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,1])
        static let rsaSHA1 = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,5])
        static let rsaSHA256 = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,11])
        static let rsaSHA384 = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,12])
        static let rsaSHA512 = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,13])
        static let ecSHA1 = Data([0x2a,0x86,0x48,0xce,0x3d,4,1])
        static let ecSHA256 = Data([0x2a,0x86,0x48,0xce,0x3d,4,3,2])
        static let ecSHA384 = Data([0x2a,0x86,0x48,0xce,0x3d,4,3,3])
        static let ecSHA512 = Data([0x2a,0x86,0x48,0xce,0x3d,4,3,4])
        static let subjectKeyIdentifier = Data([0x55,0x1d,0x0e])
    }
}
