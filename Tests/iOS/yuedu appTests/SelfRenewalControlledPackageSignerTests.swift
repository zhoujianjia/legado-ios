import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Owned whole-package signing through one live vault and one archive path", .serialized)
struct SelfRenewalControlledPackageSignerTests {
    private typealias Signer = SelfRenewalControlledPackageSigner
    private typealias Vault = SelfRenewalSigningMaterialVault
    private typealias Unpacker = SelfRenewalIPAUnpacker
    private typealias Bytes = SelfRenewalControlledPackageFixture
    private typealias PKI = SelfRenewalSigningOwnedPKIFixture

    @Test("actual three-bundle profile resource nested executable and raw ZIP chain")
    func signsOwnedThreeBundlePackageAndReverifiesActualArchiveBytes() async throws {
        try await Self.fixture { f in
            let result = try await f.sign()
            #expect(result.originalArchiveSHA256 == Data(SHA256.hash(data: f.originalBytes)))
            #expect(result.originalArchiveBytes == f.originalBytes.count)
            #expect(result.changes.count == 3)
            #expect(result.changes.last?.relativePath == ".")
            #expect(result.changes.allSatisfy { $0.originalExecutableSHA256 != $0.signedExecutableSHA256 })
            #expect(result.changes.allSatisfy { $0.originalProfileSHA256 != $0.signedProfileSHA256 })
            let raw = try await result.archive.data(maximumBytes: 1_048_576)
            #expect(Data(SHA256.hash(data: raw)) == result.archive.sha256)
            #expect(raw.count == result.archive.byteCount)
            let permissions = try Self.archivePermissions(raw)
            let executablePaths = Set(result.signed.resources.executableMaterials.inventory.codeFiles.map { "Payload/Owned.app/" + $0.file.relativePath })
            #expect(permissions.count == 15)
            for (path, mode) in permissions { #expect(mode == (executablePaths.contains(path) ? 0o755 : 0o644)) }
            let output = f.directory.appendingPathComponent("independent-signed.ipa")
            try raw.write(to: output, options: .withoutOverwriting)
            let readback = try await Unpacker.verify(ipa: output, codeAnchors: f.issuer.certificateChainDER,
                profileAnchors: f.issuer.certificateChainDER, at: f.date)
            #expect(readback.archiveSHA256 == result.archive.sha256)
            #expect(readback.entryCount == 15 && readback.application.bundles.count == 3)
            #expect(readback.application.resources.resourceEnvelopesVerified)
            #expect(readback.application.resources.components.allSatisfy { $0.resources.unresolvedRequirementCapabilities.isEmpty })
            #expect(readback.application.bundles.allSatisfy { if case .matched = $0.profileResourceBinding { return true }; return false })
            for before in result.original.bundles {
                let after = try #require(result.signed.bundles.first { $0.componentRelativePath == before.componentRelativePath })
                #expect(after.bundleIdentifier == before.bundleIdentifier)
                #expect(after.slices.map(\.appGroups) == before.slices.map(\.appGroups))
                #expect(after.slices.map(\.keychainAccessGroups) == before.slices.map(\.keychainAccessGroups))
                #expect(after.slices.map(\.codeSignerCertificateSHA256) != before.slices.map(\.codeSignerCertificateSHA256))
            }
            let unchanged = try Data(contentsOf: f.input)
            #expect(unchanged == f.originalBytes)
            #expect(!result.appleSigningAuthorityEstablished && !result.accountIdentityEstablished)
            #expect(!result.deviceEligibilityEstablished && !result.replacementAuthorized)
        }
    }

    @Test("lease raw profile bytes survive actual Keychain publication and reopen")
    func bindsExactRawCMSProfileBytesToReopenedLease() async throws {
        try await Self.fixture { f in
            let reopened = try await f.vault.lease(in: f.namespace)
            #expect(reopened.profileInputs.count == 3 && reopened.profiles.count == 3)
            for input in reopened.profileInputs {
                let path = input.componentRelativePath == "." ? "embedded.mobileprovision" : input.componentRelativePath + "/embedded.mobileprovision"
                let verified = try #require(reopened.profiles.first { $0.file.relativePath == path })
                #expect(verified.rawFileDigests[2] == Data(SHA256.hash(data: input.bytes)))
                #expect(verified.file.byteCount == Int64(input.bytes.count))
                let originalInput = try #require(f.lease.profileInputs.first { $0.componentRelativePath == input.componentRelativePath })
                #expect(input.bytes == originalInput.bytes)
            }
        }
    }

    @Test("revoked and stale generation leases never produce replacement bytes")
    func rejectsRevokedAndStaleLeasesWithoutChangingInput() async throws {
        try await Self.fixture { f in
            try await f.vault.revoke(f.lease.keyID, in: f.namespace, expectedGeneration: f.lease.generation)
            do { _ = try await f.sign(); Issue.record("Revoked package lease accepted") }
            catch Vault.Failure.staleGeneration {}
            let original = try Data(contentsOf: f.input)
            #expect(original == f.originalBytes)
        }
    }

    @Test("observed cancellation cannot publish a signed archive")
    func rejectsCancelledPackageWithoutChangingInput() async throws {
        try await Self.fixture { f in
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.sign()
            }
            do { _ = try await task.value; Issue.record("Cancelled package accepted") }
            catch is CancellationError {}
            try await f.vault.validate(f.lease)
            let original = try Data(contentsOf: f.input)
            #expect(original == f.originalBytes)
        }
    }

    @Test("actual false requirement rejects and unresolved Apple policy remains unresolved")
    func rejectsFalseAndUnresolvedOriginalNestedRequirements() async throws {
        try await Self.fixture { f in
            for encoded in [Bytes.falseRequirementBase64, Bytes.unresolvedRequirementBase64] {
                let raw = try Bytes.data(encoded)
                let input = f.directory.appendingPathComponent(UUID().uuidString + ".ipa")
                try raw.write(to: input, options: .withoutOverwriting)
                do { _ = try await f.sign(input); Issue.record("Unsatisfied requirement accepted") }
                catch Signer.Failure.unresolvedRequirement(_) {}
                catch SelfRenewalResourceSealVerifier.Failure.nestedRequirementFailed(_) {}
                let original = try Data(contentsOf: input)
                #expect(original == raw)
            }
        }
    }

    @Test("same profile allowance cannot substitute different actual signed app-group claims")
    func rejectsDifferentActualGroupsWithinSameVerifiedProfileAllowance() async throws {
        try await Self.fixture { f in
            let raw = try Bytes.data(Bytes.differentActualGroupsBase64)
            let input = f.directory.appendingPathComponent("different-actual-groups.ipa")
            try raw.write(to: input, options: .withoutOverwriting)
            let alternate = try await Unpacker.verify(ipa: input, codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], at: f.date)
            #expect(alternate.application.profileAndCodeIdentityConsistencyVerified)
            for old in f.lease.profiles {
                let new = try #require(alternate.application.profiles.profiles.first { $0.file.relativePath == old.file.relativePath })
                guard case .dictionary(let left) = old.properties, case .dictionary(let right) = new.properties else { throw CocoaError(.coderInvalidValue) }
                #expect(left["Entitlements"] == right["Entitlements"])
            }
            do { _ = try await f.sign(input); Issue.record("Another actual group set accepted for namespace") }
            catch Vault.Failure.identityChanged {}
            let kept = try Data(contentsOf: input)
            #expect(kept == raw)
            try await f.vault.validate(f.lease)
        }
    }

    @Test("scoped file CAS keeps original bytes and expired capabilities reject reads")
    func preservesOwnedFilesOnWrongPreimageAndInvalidatesEscapedScope() async throws {
        try await Self.fixture { f in
            let escaped = try await Unpacker.withOwnedApplication(ipa: f.input, codeAnchors: [f.oldAnchor],
                profileAnchors: [f.oldAnchor], at: f.date) { scope in
                let before = try await scope.read("chapter.txt", maximumBytes: 16)
                do { try await scope.replace("chapter.txt", with: Data("changed".utf8), expectedSHA256: Data(repeating: 0, count: 32), maximumBytes: 16)
                    Issue.record("Wrong preimage accepted") }
                catch Unpacker.Failure.inputChanged {}
                let kept = try await scope.read("chapter.txt", maximumBytes: 16)
                #expect(kept == before)
                do { try await scope.replace("absent.txt", with: Data(), expectedSHA256: Data(), maximumBytes: 16)
                    Issue.record("New arbitrary path accepted") }
                catch Unpacker.Failure.readBudget {}
                return scope
            }
            do { _ = try await escaped.read("chapter.txt", maximumBytes: 16); Issue.record("Expired scope accepted") }
            catch Unpacker.Failure.stagingChanged {}
            // This child is inside the REAL archive worker while callback
            // completion tries to close the scope. Closing cancels then drains
            // it; no timing sleeps, main waits or fake file IO stand in for it.
            for throwsFromCallback in [false, true] {
                let gate = LifecycleGate()
                let parent = Task.detached {
                    do {
                        try await Unpacker.withOwnedApplication(ipa: f.input, codeAnchors: [f.oldAnchor],
                            profileAnchors: [f.oldAnchor], at: f.date, observer: { event in await gate.observe(event) }) { scope in
                            let child = Task { try await scope.archive(codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], at: f.date) }
                            await gate.setChild(child)
                            await gate.waitEntered()
                            do { _ = try await scope.read("chapter.txt", maximumBytes: 16); Issue.record("Concurrent archive read accepted") }
                            catch Unpacker.Failure.operationInProgress {}
                            if throwsFromCallback { throw OwnedTestFailure.callback }
                        }
                        #expect(!throwsFromCallback)
                    } catch OwnedTestFailure.callback { #expect(throwsFromCallback) }
                }
                await gate.waitClosing()
                await gate.release()
                try await parent.value
                let storedChild = await gate.child
                let child = try #require(storedChild)
                do { _ = try await child.value; Issue.record("Escaping writer survived close") }
                catch is CancellationError {}
                let events = await gate.events
                #expect(events == [.archiveEntered, .scopeClosing, .exclusiveFinished, .scopeDrained, .stagingWillCleanup, .stagingCleaned])
            }

        }
    }

    @Test("resource update retains exact requirement and rule values while replacing actual seals")
    func updatesVerifiedResourceSealsWithoutWideningRulesOrRequirements() async throws {
        try await Self.fixture { f in
            try await Unpacker.withOwnedApplication(ipa: f.input, codeAnchors: [f.oldAnchor],
                profileAnchors: [f.oldAnchor], at: f.date) { scope in
                let proof = try #require(scope.original.resources.components.first { $0.relativePath == "." })
                let old = try await scope.read("_CodeSignature/CodeResources", maximumBytes: SelfRenewalResourceSealVerifier.Limits.envelopeBytes)
                let original = try #require(PropertyListSerialization.propertyList(from: old, options: [], format: nil) as? [String: Any])
                let profile = try #require(f.lease.profileInputs.first { $0.componentRelativePath == "." })
                let hints = Dictionary(uniqueKeysWithValues: proof.resources.verifiedNestedResources.map { ($0.relativePath, Data(repeating: 0x31, count: 20)) })
                let result = try SelfRenewalPackageResourceUpdater.update(old, component: proof,
                    freshProfiles: ["embedded.mobileprovision": profile.bytes], nestedCDHashes: hints)
                let updated = try #require(PropertyListSerialization.propertyList(from: result.bytes, options: [], format: nil) as? [String: Any])
                let oldRules = try #require(original["rules2"] as? NSDictionary)
                let newRules = try #require(updated["rules2"] as? NSDictionary)
                #expect(oldRules.isEqual(newRules))
                let oldSeals = try #require(original["files2"] as? [String: Any])
                let newSeals = try #require(updated["files2"] as? [String: Any])
                for nested in proof.resources.verifiedNestedResources {
                    let left = try #require(oldSeals[nested.relativePath] as? [String: Any])
                    let right = try #require(newSeals[nested.relativePath] as? [String: Any])
                    #expect(left["requirement"] as? String == right["requirement"] as? String)
                    #expect(right["cdhash"] as? Data == hints[nested.relativePath])
                }
                let seal = try #require(newSeals["embedded.mobileprovision"] as? [String: Any])
                #expect(seal["hash2"] as? Data == Data(SHA256.hash(data: profile.bytes)))
                #expect(result.changedNestedHints == 2 && result.changedProfileSeals == 1)
            }
        }
    }

    @Test("actual same-job xcrun main extensions and framework retain their referenced offsets")
    func signsSDKProducedMainExtensionsAndFrameworkInSameJob() async throws {
        try await Task.detached {
            let sdk = try SelfRenewalSDKOwnedPackageFixture.load()
            let f = try await Fixture.make(sdk: sdk)
            do {
                let result = try await f.sign()
                #expect(result.changes.count == 4)
                #expect(result.signed.bundles.count == 3)
                #expect(result.signed.resources.executableMaterials.inventory.components.count == 4)
                #expect(result.changes.contains { $0.relativePath == "Frameworks/OwnedFramework.framework" && $0.signedProfileSHA256 == nil })
                #expect(result.signed.resources.resourceEnvelopesVerified)
                // Real producer output contains LC_DYSYMTAB and MH_DYLIB;
                // the same production signer is invoked for every component.
                for component in result.original.resources.executableMaterials.inventory.components {
                    let original = try #require(component.executable)
                    let signed = try #require(result.signed.resources.executableMaterials.code.first { $0.file.relativePath == original.file.relativePath })
                    #expect(signed.signedCodeVerification?.allLoadedDirectoriesAuthenticated == true)
                }
                let original = try Data(contentsOf: f.input)
                #expect(original == sdk.archive)
                try await f.cleanup()
            } catch { do { try await f.cleanup() } catch { Issue.record(error) }; throw error }
        }.value
    }

    @Test("authenticated DYSYMTAB executable and dylib retain table commands and payload offsets")
    func resignsDynamicSymbolTablesAndDylibAtStableOffsets() async throws {
        try await Task.detached {
            let date = Date(timeIntervalSince1970: 1_792_540_800)
            let identity = try PKI.issuer(at: date)
            let anchor = try Bytes.data(Bytes.anchorBase64)
            let external: [UInt32: Data] = [1: try Bytes.data(Bytes.layoutInfoBase64), 3: try Bytes.data(Bytes.layoutResourcesBase64)]
            for encoded in [Bytes.dysymtabExecutableBase64, Bytes.dysymtabLibraryBase64] {
                let input = try Bytes.data(encoded)
                let signed = try await SelfRenewalControlledMachOSigner.resign(input, identity: identity,
                    originalAnchors: [anchor], replacementAnchors: identity.certificateChainDER, at: date,
                    externalSpecialSlots: external)
                #expect(signed.signatures.allLoadedDirectoriesAuthenticated)
                #expect(signed.signatureOffset == 32768)
                for tag: UInt32 in [2, 0xb] {
                    let old = try Self.command(input, tag: tag)
                    let new = try Self.command(signed.signedMachO, tag: tag)
                    #expect(input.subdata(in: old) == signed.signedMachO.subdata(in: new))
                }
                #expect(input.subdata(in: 16384..<32768) == signed.signedMachO.subdata(in: 16384..<32768))
                #expect(input.subdata(in: 4096..<4352) == signed.signedMachO.subdata(in: 4096..<4352))
                #expect(input.subdata(in: 12..<16) == signed.signedMachO.subdata(in: 12..<16))
            }
        }.value
    }

    @Test("all dynamic-symbol table ranges and symbol indexes are bounded before transformation")
    func rejectsDynamicSymbolTableBoundsAndMissingSymbolTable() async throws {
        try await Task.detached {
            let date = Date(timeIntervalSince1970: 1_792_540_800)
            let identity = try PKI.issuer(at: date)
            let anchor = try Bytes.data(Bytes.anchorBase64)
            let input = try Bytes.data(Bytes.dysymtabLibraryBase64)
            let command = try Self.command(input, tag: 0xb)
            let external: [UInt32: Data] = [1: try Bytes.data(Bytes.layoutInfoBase64), 3: try Bytes.data(Bytes.layoutResourcesBase64)]
            var variants: [Data] = []
            for field in [32, 40, 48, 56, 64, 72] {
                var changed = input
                Self.u32(UInt32.max, into: &changed, at: command.lowerBound + field)
                Self.u32(1, into: &changed, at: command.lowerBound + field + 4)
                variants.append(changed)
            }
            for field in [8, 16, 24] {
                var changed = input; Self.u32(2, into: &changed, at: command.lowerBound + field); variants.append(changed)
            }
            var missing = input
            let symbol = try Self.command(input, tag: 2)
            Self.u32(0x1b, into: &missing, at: symbol.lowerBound)
            variants.append(missing)
            for changed in variants {
                do { _ = try await SelfRenewalControlledMachOSigner.resign(changed, identity: identity,
                    originalAnchors: [anchor], replacementAnchors: identity.certificateChainDER, at: date,
                    externalSpecialSlots: external); Issue.record("Malformed symbol layout accepted") }
                catch SelfRenewalControlledMachOSigner.Failure.malformedLayout {}
            }
        }.value
    }
    private static func archivePermissions(_ bytes: Data) throws -> [String: UInt16] {
        func word(_ offset: Int, _ length: Int) throws -> UInt32 {
            guard offset >= 0, length <= 4, offset <= bytes.count - length else { throw CocoaError(.coderInvalidValue) }
            return (0..<length).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count >= 22, try word(bytes.count - 22, 4) == 0x06054b50 else { throw CocoaError(.coderInvalidValue) }
        let count = Int(try word(bytes.count - 12, 2))
        var cursor = Int(try word(bytes.count - 6, 4)); var result: [String: UInt16] = [:]
        for _ in 0..<count {
            guard try word(cursor, 4) == 0x02014b50 else { throw CocoaError(.coderInvalidValue) }
            let name = Int(try word(cursor + 28, 2)); let extra = Int(try word(cursor + 30, 2)); let comment = Int(try word(cursor + 32, 2))
            guard name > 0, cursor + 46 <= bytes.count - name,
                  let path = String(data: bytes.subdata(in: (cursor + 46)..<(cursor + 46 + name)), encoding: .utf8) else { throw CocoaError(.coderInvalidValue) }
            result[path] = UInt16((try word(cursor + 38, 4)) >> 16) & 0o777
            cursor += 46 + name + extra + comment
        }
        return result
    }
    private static func command(_ bytes: Data, tag: UInt32) throws -> Range<Int> {
        func word(_ at: Int) throws -> UInt32 {
            guard at >= 0, at <= bytes.count - 4 else { throw CocoaError(.coderInvalidValue) }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
        }
        let count = try word(16); var cursor = 32
        for _ in 0..<count {
            let type = try word(cursor); let size = Int(try word(cursor + 4))
            guard size >= 8, cursor <= bytes.count - size else { throw CocoaError(.coderInvalidValue) }
            if type == tag { return cursor..<(cursor + size) }; cursor += size
        }
        throw CocoaError(.coderInvalidValue)
    }
    private static func u32(_ word: UInt32, into bytes: inout Data, at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: word >> (8 * index)) }
    }

    nonisolated private static func fixture(_ action: @escaping @Sendable (Fixture) async throws -> Void) async throws {
        try await Task.detached {
            let fixture = try await Fixture.make()
            do { try await action(fixture); try await fixture.cleanup() }
            catch { do { try await fixture.cleanup() } catch { Issue.record(error) }; throw error }
        }.value
    }
    private enum OwnedTestFailure: Error { case callback }
    private actor LifecycleGate {
        var events: [Unpacker.OperationEvent] = []
        var child: Task<Unpacker.ControlledArchive, Error>?
        private var entered = false; private var closing = false; private var released = false
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var closeWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func setChild(_ child: Task<Unpacker.ControlledArchive, Error>) { self.child = child }
        func observe(_ event: Unpacker.OperationEvent) async {
            events.append(event)
            if event == .archiveEntered {
                entered = true; let waiters = enterWaiters; enterWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                if !released { await withCheckedContinuation { releaseWaiter = $0 } }
            }
            if event == .scopeClosing {
                closing = true; let waiters = closeWaiters; closeWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        func waitEntered() async { if !entered { await withCheckedContinuation { enterWaiters.append($0) } } }
        func waitClosing() async { if !closing { await withCheckedContinuation { closeWaiters.append($0) } } }
        func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
    }
    private final class Fixture: @unchecked Sendable {
        let directory: URL; let input: URL; let originalBytes: Data; let oldAnchor: Data
        let issuer: Vault.KeyMaterial; let vault: Vault; let namespace: Vault.Namespace; let lease: Vault.Lease
        let date: Date
        init(directory: URL, input: URL, originalBytes: Data, oldAnchor: Data, issuer: Vault.KeyMaterial,
            vault: Vault, namespace: Vault.Namespace, lease: Vault.Lease, date: Date) {
            self.directory = directory; self.input = input; self.originalBytes = originalBytes; self.oldAnchor = oldAnchor
            self.issuer = issuer; self.vault = vault; self.namespace = namespace; self.lease = lease; self.date = date
        }
        func sign(_ input: URL? = nil) async throws -> Signer.Result {
            try await Signer.resign(ipa: input ?? self.input, vault: vault, lease: lease,
                originalCodeAnchors: [oldAnchor], originalProfileAnchors: [oldAnchor])
        }
        func cleanup() async throws {
            let generation = try await vault.generation(in: namespace)
            try await vault.destroy(namespace, expectedGeneration: generation)
            try FileManager.default.removeItem(at: directory)
        }
        static func make(sdk: SelfRenewalSDKOwnedPackageFixture.Input? = nil) async throws -> Fixture {
            precondition(!Thread.isMainThread)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-package-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var ownedVault: Vault?; var ownedNamespace: Vault.Namespace?
            do {
                let input = directory.appendingPathComponent("original.ipa")
                let raw: Data; let anchor: Data
                if let sdk { raw = sdk.archive; anchor = sdk.anchor }
                else { raw = try Bytes.data(Bytes.validBase64); anchor = try Bytes.data(Bytes.anchorBase64) }
                try raw.write(to: input, options: .withoutOverwriting)
                let date = sdk?.date ?? Date(timeIntervalSince1970: 1_792_540_800)
                let baseline = try await Unpacker.verify(ipa: input, codeAnchors: [anchor], profileAnchors: [anchor], at: date)
                let issuer = try PKI.issuer(at: date)
                let vault = Vault(codeAnchors: issuer.certificateChainDER, profileAnchors: issuer.certificateChainDER, clock: { date })
                ownedVault = vault
                let namespace = try await vault.create(identity: baseline.application); ownedNamespace = namespace
                let generation = try await vault.generation(in: namespace)
                let key = try await vault.generateKey(in: namespace, expectedGeneration: generation)
                let leaf = try PKI.certificate(for: key.privateKey, signedBy: issuer, at: date)
                let profiles = try baseline.application.bundles.map { bundle -> Vault.ProfileInput in
                    let old = try #require(baseline.application.profiles.profiles.first { $0.file.relativePath == bundle.profileRelativePath })
                    return .init(componentRelativePath: bundle.componentRelativePath,
                        bytes: try PKI.profile(from: old, developerCertificate: leaf, issuer: issuer, at: date))
                }
                let lease = try await vault.publish(in: namespace, keyID: key.id, expectedGeneration: key.generation,
                    certificateChainDER: [leaf] + issuer.certificateChainDER, profiles: profiles)
                return Fixture(directory: directory, input: input, originalBytes: raw, oldAnchor: anchor,
                    issuer: issuer, vault: vault, namespace: namespace, lease: lease, date: date)
            } catch {
                if let vault = ownedVault, let namespace = ownedNamespace {
                    do { let generation = try await vault.generation(in: namespace); try await vault.destroy(namespace, expectedGeneration: generation) }
                    catch { Issue.record(error) }
                }
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
                throw error
            }
        }
    }
}
