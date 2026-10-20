import CryptoKit
import Foundation

/// The fixed macOS producer emits this public JSON before xcodebuild. The
/// resource, actual producer source/commands and output hashes are retained in
/// the same SDK evidence. Missing generation fails the selected test.
enum SelfRenewalSDKOwnedPackageFixture {
    struct Input: Sendable { let archive: Data; let anchor: Data; let date: Date }
    private struct Payload: Decodable {
        let schema: Int; let archive: Data; let anchor: Data
        let verificationEpochSeconds: Int64; let archiveSHA256: String
    }
    static func load() throws -> Input {
        precondition(!Thread.isMainThread)
        guard let url = Bundle(for: SelfRenewalSDKOwnedPackageBundle.self).url(forResource: "owned-sdk-package", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let count = attributes[.size] as? NSNumber, count.int64Value >= 0, count.int64Value <= 8_388_608 else { throw CocoaError(.fileReadTooLarge) }
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        guard raw.count <= 8_388_608 else { throw CocoaError(.fileReadTooLarge) }
        let payload = try JSONDecoder().decode(Payload.self, from: raw)
        guard payload.schema == 1, !payload.archive.isEmpty, payload.archive.count <= 4_194_304,
              !payload.anchor.isEmpty, payload.anchor.count <= 65_536,
              Data(SHA256.hash(data: payload.archive)).map({ String(format: "%02x", $0) }).joined() == payload.archiveSHA256 else {
            throw CocoaError(.coderInvalidValue)
        }
        let resourceSHA256 = Data(SHA256.hash(data: raw)).map({ String(format: "%02x", $0) }).joined()
        print("YUEDU_SDK_OWNED_FIXTURE resourceSHA256=\(resourceSHA256) resourceBytes=\(raw.count) archiveSHA256=\(payload.archiveSHA256) archiveBytes=\(payload.archive.count)")
        return Input(archive: payload.archive, anchor: payload.anchor, date: Date(timeIntervalSince1970: TimeInterval(payload.verificationEpochSeconds)))
    }
}
private final class SelfRenewalSDKOwnedPackageBundle: NSObject {}
