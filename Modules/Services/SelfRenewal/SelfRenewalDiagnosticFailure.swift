import Foundation

/// Public failure facts only. Error descriptions, associated identities, paths,
/// remote messages and credentials never enter this observation.
struct SelfRenewalDiagnosticFailure: Sendable, Equatable, Encodable {
    let errorType: String
    let failureCode: String
    let causeType: String?
    let httpStatus: Int?
    let osStatus: Int32?

    static func capture(_ error: Error) -> Self {
        var cause = error
        var unwrapped = false
        for _ in 0..<4 {
            guard let next = underlying(cause) else { break }
            cause = next
            unwrapped = true
        }
        let leaf = classify(cause)
        return Self(errorType: typeName(error), failureCode: leaf.failureCode,
            causeType: unwrapped ? leaf.errorType : nil,
            httpStatus: leaf.httpStatus, osStatus: leaf.osStatus)
    }

    private static func typeName(_ error: Error) -> String {
        String(String(reflecting: type(of: error)).prefix(256))
    }

    /// Preserve the primary operation failure. Secondary cleanup errors and
    /// completed values remain with their existing owners, outside this schema.
    private static func underlying(_ error: Error) -> Error? {
        if let value = error as? SelfRenewalAppSession.InitialNamespaceBindingFailure { return value.underlying }
        if let value = error as? SelfRenewalAppSession.SigningMaterialUnavailable { return value.underlying }
        if let value = error as? SelfRenewalAppSession.InitializationFailure { return value.underlying }
        if let value = error as? SelfRenewalAppSession.DeveloperMaterialFinalizationFailure { return value.underlying }
        if let value = error as? SelfRenewalAppSession.Unavailable { return value.underlying }
        if let value = error as? SelfRenewalAppSession.RenewalExecutionFailure { return value.underlying }
        if let value = error as? SelfRenewalAppSession.ObservationFailures {
            return value.installedMaterial ?? value.normalUserData
        }
        if let value = error as? SelfRenewalAppSession.RecoveryFailed {
            if let recovery = value.recoveryError { return recovery }
            if let observation = value.observationError { return observation }
            return value.signingMaterials
        }
        if let value = error as? SelfRenewalDeveloperAccountClient.EnrollmentFailure { return value.underlying }
        if let value = error as? SelfRenewalDeveloperAccountClient.PublicationFinalizationFailure { return value.underlying }
        if let value = error as? SelfRenewalDeveloperAccountClient.SessionInvalidationFailure {
            // Match the existing owner classification: credential invalidation
            // could not be saved, independently of the prior session failure.
            return value.storageError
        }
        if let value = error as? SelfRenewalAuthenticatedInstallationClient.OperationFailure { return value.underlying }
        if let value = error as? SelfRenewalAuthenticatedInstallationClient.RegistrationCleanupFailure { return value.underlying }
        if let value = error as? SelfRenewalAuthenticatedInstallationClient.RegistrationFinalizationFailure<SelfRenewalSigningMaterialVault.Lease> {
            return value.stopSessionError
        }
        if let value = error as? SelfRenewalControlledRenewalCoordinator.PreparationFailure { return value.underlying }
        if let value = error as? SelfRenewalControlledRenewalCoordinator.Interrupted { return value.underlying }
        return nil
    }

    private static func classify(_ error: Error) -> Self {
        let name = typeName(error)
        func fact(_ code: String, httpStatus: Int? = nil, osStatus: Int32? = nil) -> Self {
            Self(errorType: name, failureCode: code, causeType: nil,
                httpStatus: httpStatus, osStatus: osStatus)
        }

        if error is CancellationError { return fact("cancelled") }
        if let value = error as? SelfRenewalSigningMaterialVault.Failure {
            switch value {
            case .limit: return fact("vault.limit")
            case .namespaceUnavailable: return fact("vault.namespaceUnavailable")
            case .malformedManifest: return fact("vault.malformedManifest")
            case .manifestWrite: return fact("vault.manifestWrite")
            case .staleGeneration: return fact("vault.staleGeneration")
            case .keyGeneration: return fact("vault.keyGeneration")
            case .keychain(let status): return fact("vault.keychain", osStatus: status)
            case .missingKey: return fact("vault.missingKey")
            case .keyMismatch: return fact("vault.keyMismatch")
            case .revoked: return fact("vault.revoked")
            case .invalidCertificate: return fact("vault.invalidCertificate")
            case .untrustedCertificate: return fact("vault.untrustedCertificate")
            case .identityChanged: return fact("vault.identityChanged")
            case .invalidProfiles: return fact("vault.invalidProfiles")
            case .clockMovedBackwards: return fact("vault.clockMovedBackwards")
            }
        }
        if let value = error as? SelfRenewalSigningMaterialVault.CertificateRequestFailure {
            switch value {
            case .invalidSubject: return fact("vault.csr.invalidSubject")
            case .signature: return fact("vault.csr.signature")
            }
        }
        if let value = error as? SelfRenewalApplicationMaterialVerifier.Failure {
            return fact(value.diagnosticCode)
        }
        if let value = error as? KeychainHelper.ReadFailure {
            switch value {
            case .lookup(let status): return fact("keychain.read.lookup", osStatus: status)
            case .unexpectedResult: return fact("keychain.read.unexpectedResult")
            case .invalidUTF8: return fact("keychain.read.invalidUTF8")
            case .valueLimit: return fact("keychain.read.valueLimit")
            case .accessibilityMigration(let status): return fact("keychain.read.accessibilityMigration", osStatus: status)
            }
        }
        if let value = error as? KeychainHelper.WriteFailure {
            switch value {
            case .insert(let status): return fact("keychain.write.insert", osStatus: status)
            }
        }
        if let value = error as? SelfRenewalAnisetteV3Provider.Failure {
            switch value {
            case .invalidConfiguration: return fact("anisette.invalidConfiguration")
            case .malformedResponse: return fact("anisette.malformedResponse")
            case .limit: return fact("anisette.limit")
            case .storageUnavailable: return fact("anisette.storageUnavailable")
            case .storage: return fact("anisette.storage")
            case .staleRegistration: return fact("anisette.staleRegistration")
            case .registrationBoundToAnotherEndpoint: return fact("anisette.registrationBoundToAnotherEndpoint")
            case .provisioningOutcomeUnknown: return fact("anisette.provisioningOutcomeUnknown")
            case .registrationRejected: return fact("anisette.registrationRejected")
            case .remoteRejected: return fact("anisette.remoteRejected")
            case .resetNotRequired: return fact("anisette.resetNotRequired")
            case .resetCommitUnknown: return fact("anisette.resetCommitUnknown")
            case .busy: return fact("anisette.busy")
            case .timedOut: return fact("anisette.timedOut")
            case .http(let status): return fact("anisette.http", httpStatus: status)
            }
        }
        if let value = error as? SelfRenewalDeveloperAuthentication.Failure {
            switch value {
            case .busy: return fact("authentication.busy")
            case .invalidInput: return fact("authentication.invalidInput")
            case .malformedResponse: return fact("authentication.malformedResponse")
            case .unsupportedProtocol: return fact("authentication.unsupportedProtocol")
            case .missingDeviceMetadata: return fact("authentication.missingDeviceMetadata")
            case .expiredChallenge: return fact("authentication.expiredChallenge")
            case .unsupportedSecondaryAuthentication: return fact("authentication.unsupportedSecondaryAuthentication")
            case .incorrectCredentials: return fact("authentication.incorrectCredentials")
            case .incorrectVerificationCode: return fact("authentication.incorrectVerificationCode")
            case .http(let status): return fact("authentication.http", httpStatus: status)
            case .portal: return fact("authentication.portal")
            case .transport: return fact("authentication.transport")
            }
        }
        if let value = error as? SelfRenewalDeveloperAccountClient.Failure {
            switch value {
            case .busy: return fact("account.busy")
            case .signedOut: return fact("account.signedOut")
            case .invalidInput: return fact("account.invalidInput")
            case .malformedResponse: return fact("account.malformedResponse")
            case .limit: return fact("account.limit")
            case .storage: return fact("account.storage")
            case .sessionExpired: return fact("account.sessionExpired")
            case .accountChanged: return fact("account.accountChanged")
            case .teamChanged: return fact("account.teamChanged")
            case .notPersonalTeam: return fact("account.notPersonalTeam")
            case .appIdentifierMissing: return fact("account.appIdentifierMissing")
            case .ambiguousAppIdentifier: return fact("account.ambiguousAppIdentifier")
            case .keyMismatch: return fact("account.keyMismatch")
            case .staleOperation: return fact("account.staleOperation")
            case .reconciliationRequired: return fact("account.reconciliationRequired")
            case .incompleteCertificateList: return fact("account.incompleteCertificateList")
            case .ambiguousCertificate: return fact("account.ambiguousCertificate")
            case .http(let status): return fact("account.http", httpStatus: status)
            case .portal: return fact("account.portal")
            case .transport: return fact("account.transport")
            }
        }
        if let value = error as? SelfRenewalDeveloperAccountTransportFailure {
            switch value {
            case .cancelled: return fact("accountTransport.cancelled")
            case .network: return fact("accountTransport.network")
            case .wrongEndpoint: return fact("accountTransport.wrongEndpoint")
            case .responseLimit: return fact("accountTransport.responseLimit")
            case .redirect: return fact("accountTransport.redirect")
            case .response: return fact("accountTransport.response")
            }
        }
        if let value = error as? SelfRenewalGSASRP.Failure {
            switch value {
            case .invalidInput: return fact("srp.invalidInput")
            case .random: return fact("srp.random")
            case .invalidServerPublicKey: return fact("srp.invalidServerPublicKey")
            case .proof: return fact("srp.proof")
            case .negotiation: return fact("srp.negotiation")
            case .encryptedData: return fact("srp.encryptedData")
            }
        }
        if let value = error as? SelfRenewalAuthenticatedDeviceTransport.Failure {
            switch value {
            case .invalidEndpoint: return fact("deviceTransport.invalidEndpoint")
            case .invalidCredentials: return fact("deviceTransport.invalidCredentials")
            case .invalidLimit: return fact("deviceTransport.invalidLimit")
            case .cancelled: return fact("deviceTransport.cancelled")
            case .deadlineExceeded: return fact("deviceTransport.deadlineExceeded")
            case .endOfStream: return fact("deviceTransport.endOfStream")
            case .transferLimit: return fact("deviceTransport.transferLimit")
            case .posix: return fact("deviceTransport.posix")
            case .tls(let status): return fact("deviceTransport.tls", osStatus: status)
            case .peerMismatch: return fact("deviceTransport.peerMismatch")
            case .peerTrustFailed: return fact("deviceTransport.peerTrustFailed")
            case .missingFreshAuthentication: return fact("deviceTransport.missingFreshAuthentication")
            case .missingMutualAuthentication: return fact("deviceTransport.missingMutualAuthentication")
            }
        }
        if let value = error as? SelfRenewalAppSession.Failure {
            switch value {
            case .invalidConfiguration: return fact("session.invalidConfiguration")
            case .configurationInUse: return fact("session.configurationInUse")
            case .storage: return fact("session.storage")
            case .changedFile: return fact("session.changedFile")
            case .limit: return fact("session.limit")
            case .notConfigured: return fact("session.notConfigured")
            case .authenticationNotConfigured: return fact("session.authenticationNotConfigured")
            case .identityUnavailable(let status): return fact("session.identityUnavailable", osStatus: status)
            case .busy: return fact("session.busy")
            case .commitDurabilityUnknown: return fact("session.commitDurabilityUnknown")
            case .ownedApplicationIsNotCurrentProcess: return fact("session.ownedApplicationIsNotCurrentProcess")
            }
        }
        if let value = error as? SelfRenewalAppSession.DeveloperServicesFailure {
            switch value {
            case .unavailable: return fact("services.unavailable")
            }
        }
        return fact("unclassified")
    }
}
