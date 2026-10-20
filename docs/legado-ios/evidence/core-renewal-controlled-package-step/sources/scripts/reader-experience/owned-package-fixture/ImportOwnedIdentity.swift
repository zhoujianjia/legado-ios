import CoreFoundation
import Foundation
import Security

// macOS generator tool only, never linked into the iOS app. Private PKCS12 and
// random passwords arrive only through stdin and never become a file or output.
struct Input: Decodable { let path: String; let keychainPassword: String; let p12Password: String; let p12: Data }
func run() throws {
    let inputHandle = FileHandle.standardInput
    guard let bytes = try inputHandle.read(upToCount: 1_048_577), bytes.count <= 1_048_576,
          (try inputHandle.read(upToCount: 1) ?? Data()).isEmpty else { throw NSError(domain: "OwnedFixture", code: 1) }
    let input = try JSONDecoder().decode(Input.self, from: bytes)
    var keychain: SecKeychain?
    let status = input.keychainPassword.withCString { password in
        SecKeychainCreate(input.path, UInt32(input.keychainPassword.utf8.count), password, false, nil, &keychain)
    }
    guard status == errSecSuccess, let keychain else { throw NSError(domain: "OwnedFixture", code: Int(status)) }
    var application: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &application) == errSecSuccess, let application else {
        throw NSError(domain: "OwnedFixture", code: 2)
    }
    var access: SecAccess?
    guard SecAccessCreate("Owned short-lived fixture" as CFString, [application] as CFArray, &access) == errSecSuccess,
          let access else { throw NSError(domain: "OwnedFixture", code: 3) }
    let options: [String: Any] = [kSecImportExportPassphrase as String: input.p12Password,
        kSecImportExportKeychain as String: keychain, kSecImportExportAccess as String: access]
    var imported: CFArray?
    let result = SecPKCS12Import(input.p12 as CFData, options as CFDictionary, &imported)
    guard result == errSecSuccess, let imported, CFArrayGetCount(imported) > 0 else {
        throw NSError(domain: "OwnedFixture", code: Int(result))
    }
}
do { try run() } catch {
    // Error code only: never echo stdin, passwords, key data or Error.userInfo.
    fputs("Owned identity import failed\n", stderr); exit(1)
}
