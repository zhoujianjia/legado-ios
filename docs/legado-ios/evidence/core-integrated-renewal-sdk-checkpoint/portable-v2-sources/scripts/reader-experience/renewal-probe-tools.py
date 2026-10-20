#!/usr/bin/env python3
"""Audit the fixed, source-only Simulator diagnostic/material fixture groups.

Selected owned fixture evidence does not establish iPhone service reachability,
installation or unattended self-renewal. Package XCTest evidence is independent.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import struct


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("renewal_probe_smoke", HERE / "smoke-tools.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
TAG_PREFIX = "reader-renewal-"
UNIT_SUITE = "SelfRenewalTransportProbeTests"
DISCOVERY_SUITE = "SelfRenewalDiscoveryProbeTests"
UI_SUITE = "SelfRenewalProbeUITests"
REPLACEMENT_SUITE = "SelfRenewalReplacementPolicyTests"
MATERIALS_SUITE = "SelfRenewalMaterialInventoryTests"
SIGNATURE_SUITE = "SelfRenewalMachOSignatureReaderTests"
HASH_SUITE = "SelfRenewalCodeDirectoryHashVerifierTests"
CMS_SUITE = "SelfRenewalCMSVerifierTests"
PROFILE_SUITE = "SelfRenewalProvisioningProfileVerifierTests"
SIGNED_CODE_SUITE = "SelfRenewalSignedCodeVerifierTests"
RESOURCE_SUITE = "SelfRenewalResourceSealVerifierTests"
NESTED_SUITE = "SelfRenewalNestedCodeRequirementsVerifierTests"
MODERN_PROFILE_SUITE = "SelfRenewalModernProfileVerifierTests"
APPLICATION_MATERIAL_SUITE = "SelfRenewalApplicationMaterialVerifierTests"
PERSISTENT_STATE_SUITE = "LegadoPersistentStateHostTests"
IPA_SUITE = "SelfRenewalIPAUnpackerTests"
VAULT_SUITE = "SelfRenewalSigningMaterialVaultTests"
CONTROLLED_SIGNER_SUITE = "SelfRenewalControlledMachOSignerTests"
PACKAGE_SIGNER_SUITE = "SelfRenewalControlledPackageSignerTests"
AUTH_INSTALL_SUITE = "SelfRenewalAuthenticatedInstallationClientTests"
BOOK_OWNER_SUITE = "LegadoBookStateOwnerTests"
CHAPTER_OWNER_SUITE = "LegadoChapterOwnerPersistenceTests"
BOOK_STORAGE_SUITE = "BookChapterStorageTests"
SDK_REQUIRED_CASE = PACKAGE_SIGNER_SUITE + "/signsSDKProducedMainExtensionsAndFrameworkInSameJob"
SDK_RESOURCE = "Tests/iOS/yuedu appTests/owned-sdk-package.json"
SDK_TOOL_ROOT = "scripts/reader-experience/owned-package-fixture/"
SDK_TOOL_NAMES = ("generate-sdk-owned-package.py", "ImportOwnedIdentity.swift", "main.c", "extension.c", "framework.c")
SDK_MARKER = "YUEDU_SDK_OWNED_FIXTURE"
LANGUAGES = ("zh-Hant", "zh-Hans", "en", "ja", "ko")
BONJOUR_SERVICES = ("_calibresmartdeviceapp._tcp", "_remotepairing._tcp")
USAGE_KEY = "NSLocalNetworkUsageDescription"
EXPECTED_CASES = {
    "unit": {UNIT_SUITE + "/" + name for name in (
        "confirmsQueryTypeWithoutExportingPrivateFields",
        "acceptsBinaryPropertyListResponse",
        "tcpConnectionAloneIsNotServiceSuccess",
        "normalizesErrorsAndRejectsWrongService",
        "rejectsInvalidFrameLengths",
        "rejectsMalformedAndTruncatedResponses",
        "cancellationAndPreCancellationFinishOnce",
        "recordsNetworkFailureWithoutCredentialClaims",
    )},
    "discovery": {DISCOVERY_SUITE + "/" + name for name in (
        "acceptsOnlyOwnedAddresses",
        "rejectsNonUnicastAndMalformedAddresses",
        "scopedIPv6NeedsExactInterface",
        "rejectsBroadcastAndExcludedInterfaces",
        "snapshotsDetectRelevantTopologyChanges",
        "connectsOnlyAfterClosedWindowAndKeepsReportRedacted",
        "removalsAndExpiredRecordsCannotConnect",
        "incompleteOrOverflowedDiscoveryNeverConnects",
        "revalidatesOwnershipAndTTLBeforeEachConnection",
        "cancellationAndGlobalDeadlineCloseAllWork",
        "enforcesBudgetsAndPreservesDistinctFailures",
        "retainsSchemaOneReportCompatibility",
        "tcpAdapterConnectsAndClosesWithoutSendingPayload",
        "selectsFourOwnedEndpointsFromReportedAddressShape",
        "selectionIsStableAcrossOrderAndUsesShorterDuplicateTTL",
        "selectionPreservesHardLimitsCancellationAndSnapshotChecks",
    )},
    "replacement": {REPLACEMENT_SUITE + "/" + name for name in (
        "rejectsAccountTeamAndBundleMappingChanges",
        "rejectsMissingDuplicateOrIncompleteBundleInventory",
        "rejectsChangedOrUnknownEntitlementGroups",
        "rejectsUnverifiedExpiredOrInvalidCandidateMaterial",
        "sameVersionAndBuildYieldOnlyMetadataPreflight",
    )},
    "materials": {MATERIALS_SUITE + "/" + name for name in (
        "parsesBoundedMetadataAndRejectsDamagedOrUnsafeValues",
        "readsThreeBundleFactsWithoutTrustAssertion",
        "retainsAdditionalPotentialSignedComponents",
        "reportsIncompleteAndConflictingRoleStructure",
        "rejectsLinkedMaterials",
        "enforcesDirectoryAndByteLimits",
    )},
    "signature": {SIGNATURE_SUITE + "/" + name for name in (
        "readsThinSignaturesWithoutReadingExecutableBodiesOrClaimingTrust",
        "readsFat32And64InBothByteOrders",
        "rejectsMalformedFatTablesAndOverlappingSlices",
        "rejectsMalformedAndUnknownRequiredLoadCommands",
        "rejectsDamagedEmbeddedSignatureStructures",
        "rejectsInvalidCodeDirectoryOffsetsAndUnsupportedLayouts",
        "readsKnownDirectoryVersionsAndEmptyCMSWithoutAssumingTrust",
        "handlesUnsignedTruncatedAndCancelledInputs",
        "readsOwnedUnpackedAppThroughInventoryAndRejectsLinkedCode",
    )},
    "ui": {UI_SUITE + "/testReadOnlyConnectionProbeCanExportWithoutClaimingRenewal"},
}
EXPECTED_CASES["cryptography"] = EXPECTED_CASES["signature"] | {
    HASH_SUITE + "/" + name for name in (
        "matchesIndependentDigestVectors",
        "verifiesFourAlgorithmsAndAllKnownSpecialMaterials",
        "rejectsChangedPagesDigestsAndSpecialMaterials",
        "verifiesFatAlternateAndUnpagedContentWithBoundedChunks",
        "rejectsMissingExtraAndUnsupportedSpecialSlots",
        "rejectsBudgetsTruncatedReadsAndCancellation",
        "readsOwnedApplicationAndUsesBoundedMaterialIO",
    )
} | {
    CMS_SUITE + "/" + name for name in (
        "verifiesIndependentRSAAndDetachedVectors",
        "verifiesECDSAAndEverySigner",
        "rejectsChangedContentAndSignatures",
        "rejectsUntrustedAndExpiredChains",
        "rejectsMissingAndAmbiguousContent",
        "rejectsMalformedDERAndOversizedInputs",
        "rejectsCancelledVerification",
    )
} | {
    PROFILE_SUITE + "/" + name for name in (
        "readsSignedSummaryAndRejectsValidityFailures",
        "verifiesOwnedProfileThroughInventory",
    )
}
EXPECTED_CASES["sealedmaterials"] = EXPECTED_CASES["cryptography"] | EXPECTED_CASES["materials"] | {
    SIGNED_CODE_SUITE + "/" + name for name in (
        "authenticatesDetachedPrimaryAndPreservesLegacyUnboundAlternate",
        "bindsOriginalHashAgilityEncodingsAndRejectsWrongValues",
        "supportsOriginalTruncatedCDHashAndRejectsAgilityOIDCollisions",
        "preservesOriginalAlternateOrderAndAdHocSemantics",
        "rejectsChangedReadBudgetsAndCancellationAcrossSlices",
        "readsOwnedAppAndKeepsGenericAnchorsSeparateFromAppleAuthority",
        "enforcesSharedOwnedFileReadBoundaryIncludingEmptyFiles",
    )
} | {
    RESOURCE_SUITE + "/" + name for name in (
        "hashesIndependentVectorsWithBoundedChunks",
        "selectsEnvelopeVersionAndLegacyHashFallback",
        "appliesPOSIXWeightedRules",
        "preservesOptionalSealSemantics",
        "rejectsChangedAddedMissingAndWrongTypes",
        "traversesNestedAndOmittedDirectoriesWithoutTrustClaims",
        "rejectsMalformedEnvelopeAndLimits",
        "verifiesOwnedApplicationAndRejectsResourceChanges",
        "rejectsEnvelopeOrCodeDirectoryChangedAfterHashPass",
        "rejectsShortReadsAndCancellation",
    )
}
EXPECTED_CASES["boundmaterials"] = EXPECTED_CASES["sealedmaterials"] | {
    NESTED_SUITE + "/" + name for name in (
        "evaluatesBooleanCertificateAndAttributeGrammar",
        "preservesUnresolvedPolicyWithoutRejectingComplexSupportedExpressions",
        "verifiesActualNestedBundlesAndPublishesBoundDERAttributes",
        "rejectsFalseRequirementAndWrongSelectedOrUniversalIdentity",
        "preservesHintAndLegacyAuthenticationMeaning",
        "retainsActualSystemPolicyAsUnresolved",
        "rejectsNestedResourceAndCMSTampering",
        "rejectsChangedBoundAttributesAndCancellation",
    )
} | {
    MODERN_PROFILE_SUITE + "/" + name for name in (
        "decodesIndependentTypedPropertyValues",
        "decodesVersionedCoreEntitlementsAndRejectsUnknownVersion",
        "rejectsAmbiguousAndMalformedProperties",
        "decodesCanonicalDatesAndRejectsInvalidCalendarValues",
        "enforcesPropertyBudgetsAndCancellation",
        "authenticatesBothCMSLayersAndUsesModernSourceOfTruth",
        "rejectsInvalidInnerCMSAndAuthoritativeValidity",
        "readsModernProfileFromSameInventoryAndRejectsReplacedLinks",
    )
} | {
    APPLICATION_MATERIAL_SUITE + "/" + name for name in (
        "verifiesActualThreeBundleChainWithoutClaimingAppleAuthority",
        "rejectsSignedButInconsistentProfileAndEntitlementIdentities",
        "bindsRereadProfileBytesToEarlierResourceSeals",
        "acceptsNewProfileUUIDWithPreservedBundleGroupsAndIdentity",
        "rejectsWholeChainResourceTamperingExpiryAndCancellation",
    )
} | {
    PERSISTENT_STATE_SUITE + "/" + name for name in (
        "sourceBridgeRemovalPreservesCredentials",
        "isolatesSourcesAndPreservesVerbatimValues",
        "rejectsStaleSourceLoginAndBindingRevisions",
        "commitsSameOwnerAtomicallyAndSkipsUnchangedWrites",
        "preservesOldStateWhenOwnerWritesFail",
        "reusesLegacyCacheAndPreservesTTL",
        "rejectsUnsupportedTransactionsBeforeAnyWrite",
        "enforcesCancellationDeadlineAndBoundedLeases",
        "preservesExplicitOptionsAndRawLoginPayloads",
    )
}
EXPECTED_CASES["controlledsigning"] = {
    IPA_SUITE + "/" + name for name in (
        "verifiesOwnedStoredIPAThroughSealedMaterials",
        "verifiesDeflateAndBothDataDescriptorForms",
        "rejectsTraversalAndAmbiguousPaths",
        "rejectsLinksTypesDuplicatesAndEncodingOverrides",
        "rejectsHeaderLayoutAndDescriptorDisagreements",
        "enforcesCompressedExpandedAndEntryBudgets",
        "rejectsCRCDeflateTailTruncationAndActualExpansion",
        "rejectsSourceLinksAndPropagatesCancellation",
        "cleansOwnedStagingOnArchiveAndMaterialFailure",
    )
} | {
    VAULT_SUITE + "/" + name for name in (
        "publishesReloadsSignsAndRevokesOwnedKeychainMaterial",
        "rejectsSignedIdentityAndKeyChangesWithoutReplacingOldMaterial",
        "rejectsStaleCASAndCancellationBeforePublication",
        "preservesPublicationWhenManifestSaveFails",
        "recoversPendingKeyJournalWithoutDeletingPublishedKey",
        "rejectsExpiredProfilesAndLocallyRevokedLeases",
        "boundsLifetimeAndPreservesUnrelatedKeychainItems",
    )
} | {
    CONTROLLED_SIGNER_SUITE + "/" + name for name in (
        "signsRealRSAAndECDSAAndAuthenticatesActualLeaf",
        "rebuildsAllDigestKindsAndAgileCodeDirectories",
        "preservesIdentityAndEverySpecialBlobByte",
        "allocatesBeforeHashingAndErasesOldSignatureTail",
        "refusesWrongKeysAnchorsAndTamperedOriginal",
        "rejectsUnsupportedLayoutAndUnboundInputs",
        "cancelsAndEnforcesReadAndCapacityBudgets",
    )
}
# One exact native union: old overlapping groups are not separate acceptances.
INTEGRATED_ADDITIONAL_CASES = {
    'LegadoChapterOwnerPersistenceTests': (
        'concurrentChapterMutationUsesOnePersistenceOwner',
        'chapterVariableCasIsDurableAndKeepsFailedWritesInvisible',
        'strictFlushFailurePreservesPreviousFileAndCanRetry',
        'strictFlushTargetsOnlyTheBoundBook',
    ),
    'LegadoBookStateOwnerTests': (
        'hostCommitUsesOriginalChapterFileAndRestart',
        'staleTocAndTaskCancellationRejectOldHostProofs',
        'rejectsUnmappedIdentityAndUnsupportedTransactions',
        'corruptAndUnreadableChapterOwnersRemainErrors',
        'hostWriteFailureAndGenerationRevocationPreserveOldState',
    ),
    'BookChapterStorageTests': (
        'shelfFileCarriesNoTableOfContents',
        'positionSaveLeavesTablesOfContentsUntouched',
        'cachedChapterMarkRewritesOnlyItsBook',
        'inlineShelfOpensCompleteAndMovesListsOut',
        'inlineListFromOlderBuildWinsOverStaleFile',
        'deletingBookDeletesItsTableOfContents',
        'recordsCarrySummaryAndOpenedBookCarriesList',
        'readingRecordKeepsItsListOutsideItsFile',
        'syncLeavesTableOfContentsLocal',
        'restoredShelfRegainsSummaryFromStoredLists',
        'unreadableShelfLeavesTablesOfContentsAlone',
        'audiobookPlayerSeesTheTableOfContents',
    ),
    'SelfRenewalControlledPackageSignerTests': (
        'signsOwnedThreeBundlePackageAndReverifiesActualArchiveBytes',
        'bindsExactRawCMSProfileBytesToReopenedLease',
        'rejectsRevokedAndStaleLeasesWithoutChangingInput',
        'rejectsCancelledPackageWithoutChangingInput',
        'rejectsFalseAndUnresolvedOriginalNestedRequirements',
        'rejectsDifferentActualGroupsWithinSameVerifiedProfileAllowance',
        'preservesOwnedFilesOnWrongPreimageAndInvalidatesEscapedScope',
        'updatesVerifiedResourceSealsWithoutWideningRulesOrRequirements',
        'signsSDKProducedMainExtensionsAndFrameworkInSameJob',
        'resignsDynamicSymbolTablesAndDylibAtStableOffsets',
        'rejectsDynamicSymbolTableBoundsAndMissingSymbolTable',
    ),
    'SelfRenewalAuthenticatedInstallationClientTests': (
        'uploadsRealTLSChunksAndRequiresCompleteLookupCleanupAndStop',
        'rejectsActualWrongDeviceHostAndExpiredTLSCertificates',
        'rejectsInvalidSessionServicePortsAndPlaintextDowngrades',
        'rejectsActualAFCSequenceTruncationErrorsAndChangedArchiveDigest',
        'requiresTerminalCompleteAndExactPostUpgradeLookupIdentity',
        'cancellationWakesActualStalledTLSHandshakeWithoutLateWrites',
        'enforcesActualFrameProgressDeadlineAndArchiveBudgets',
    ),
}
EXPECTED_CASES["integratedrenewal"] = EXPECTED_CASES["boundmaterials"] | EXPECTED_CASES["controlledsigning"] | {
    suite + "/" + method for suite, methods in INTEGRATED_ADDITIONAL_CASES.items() for method in methods
}
assert len(EXPECTED_CASES["integratedrenewal"]) == 140

SELECTION_GROUPS = {
    # Preserve the historical all-mode contract; new implementation tests have
    # an explicit independent selection rather than silently widening it.
    "all": ("unit", "discovery", "replacement", "ui"),
    "replacement": ("replacement",),
    "implementation": ("replacement", "materials"),
    "signature": ("signature",),
    "cryptography": ("cryptography",),
    "sealedmaterials": ("sealedmaterials",),
    "boundmaterials": ("boundmaterials",),
    "controlledsigning": ("controlledsigning",),
    "integratedrenewal": ("integratedrenewal",),
}
SOURCE_INPUTS = (
    "Modules/Services/Diagnostics/SelfRenewalTransportProbe.swift",
    "Modules/Services/Diagnostics/SelfRenewalDiscoveryPolicy.swift",
    "Modules/Services/Diagnostics/SelfRenewalDiscoveryProbe.swift",
    "Modules/Services/Diagnostics/SelfRenewalDiscoveryNativeDriver.swift",
    "Modules/Features/Settings/SelfRenewalProbeView.swift",
    "Modules/Features/Settings/ProfileView.swift",
    "Targets/Yuedu/SharedApp/AppDependencies.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalTransportProbeTests.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalDiscoveryProbeTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalReplacementPolicy.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalReplacementPolicyTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalMaterialInventory.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalMaterialInventoryTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalMachOSignatureReader.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalMachOSignatureReaderTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalCodeDirectoryHashVerifier.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift",
    "Modules/Services/SelfRenewal/SelfRenewalProvisioningProfileVerifier.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalCMSVerifierTests.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalProvisioningProfileVerifierTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalSignedCodeVerifier.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalSignedCodeFixture.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalSignedCodeVerifierTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalResourceSealVerifier.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalResourceFixture.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalResourceSealVerifierTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalNestedCodeRequirementsVerifier.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalNestedResourceFixture.swift",
    "Modules/Services/SelfRenewal/SelfRenewalDERPropertyList.swift",
    "Modules/Services/SelfRenewal/SelfRenewalApplicationMaterialVerifier.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalModernProfileFixture.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalModernProfileVerifierTests.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialFixture.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialVerifierTests.swift",
    "Modules/Core/RuleEngine/ModernParser/ModernParserBridge.swift",
    "Modules/Core/RuleEngine/ModernParser/BookSourceRuntimeStateStore.swift",
    "Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift",
    "Modules/Core/RuleEngine/ModernParser/JS/LegadoCacheBridge.swift",
    "Modules/Services/Online/LegadoPersistentStateHost.swift",
    "Modules/Services/Online/LegadoMainJSSourceService.swift",
    "Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift",
    "Tests/iOS/yuedu appTests/LegadoPersistentStateHostTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalIPAArchiveValidator.swift",
    "Modules/Services/SelfRenewal/SelfRenewalIPAUnpacker.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalIPAArchiveFixture.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalIPAUnpackerTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalSigningOwnedPKIFixture.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalSigningMaterialVaultTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalControlledMachOSigner.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalControlledMachOSignerTests.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalControlledSigningFixture.swift",
    "Modules/Core/RuleEngine/ModernParser/Login/KeychainHelper.swift",
    "Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift",
    'Modules/Services/SelfRenewal/SelfRenewalControlledPackageSigner.swift',
    'Modules/Services/SelfRenewal/SelfRenewalPackageResourceUpdater.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalControlledPackageSignerTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalControlledPackageFixture.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalSDKOwnedPackageFixture.swift',
    'Modules/Services/SelfRenewal/SelfRenewalAuthenticatedDeviceStream.swift',
    'Modules/Services/SelfRenewal/SelfRenewalAuthenticatedInstallationClient.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationFixture.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests.swift',
    'Modules/Services/LibraryStore/BookChapterStore.swift',
    'Modules/Services/LibraryStore/BookStore.swift',
    'Modules/Services/LibraryStore/OriginalRuntimeCommitCancellation.swift',
    'Modules/Services/Online/LegadoBookStateOwner.swift',
    'Modules/Services/Online/OnlineReadingPipeline.swift',
    'Tests/iOS/yuedu appTests/LegadoChapterOwnerPersistenceTests.swift',
    'Tests/iOS/yuedu appTests/LegadoBookStateOwnerTests.swift',
    'Tests/iOS/yuedu appTests/BookChapterStorageTests.swift',
    'Modules/Services/LibraryStore/Models.swift',
    'Modules/Core/BookSource/BookSource.swift',
    'Modules/Core/BookSource/SourcePerfTrace.swift',
    'Modules/Core/TTS/AudiobookPlayer.swift',
    'Modules/Services/Online/ChapterCacheRepository.swift',
    'Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
    'scripts/reader-experience/test-renewal-probe-tools.py',
    'scripts/reader-experience/owned-package-fixture/generate-sdk-owned-package.py',
    'scripts/reader-experience/owned-package-fixture/ImportOwnedIdentity.swift',
    'scripts/reader-experience/owned-package-fixture/main.c',
    'scripts/reader-experience/owned-package-fixture/extension.c',
    'scripts/reader-experience/owned-package-fixture/framework.c',
    'scripts/reader-experience/owned-package-fixture/generate-independent-package-fixtures.py',
    "Tests/iOS-UI/SelfRenewalProbeUITests.swift",
    "Info.plist",
    "Yuedu-Reader.xcodeproj/project.pbxproj",
    "scripts/reader-experience/renewal-probe-tools.py",
    "scripts/reader-experience/inspect-renewal-report.py",
    "scripts/reader-experience/renewal-report-schema1.py",
    "scripts/reader-experience/test-inspect-renewal-report.py",
    "scripts/reader-experience/renewal-probe-tests.sh",
    "scripts/reader-experience/smoke-tools.py",
    "scripts/reader-experience/stage-config.py",
    "scripts/xctest.sh",
    "scripts/sim.sh",
    ".github/workflows/reader-renewal-probe.yml",
) + tuple("Resources/" + language + ".lproj/" + table
          for language in LANGUAGES for table in ("Localizable.strings", "InfoPlist.strings"))


def validate_tag():
    selection_mode()
    return smoke.validate_tag(TAG_PREFIX)


def selection_mode():
    mode = os.environ.get("YUEDU_RENEWAL_SELECTION", "all")
    if mode not in SELECTION_GROUPS:
        raise ValueError("YUEDU_RENEWAL_SELECTION must be all, replacement, implementation, signature, cryptography, sealedmaterials, boundmaterials, controlledsigning or integratedrenewal")
    return mode


def selected_cases():
    mode = selection_mode()
    return {group: EXPECTED_CASES[group] for group in SELECTION_GROUPS[mode]}


def require_source_only():
    if os.environ.get("LEGADO_RUNTIME_SOURCE_ONLY") != "1":
        raise ValueError("Renewal diagnostics must use LEGADO_RUNTIME_SOURCE_ONLY=1")


def source_inputs(overlays=None):
    records = []
    for path in SOURCE_INPUTS:
        original = smoke.git("show", "HEAD:" + path, binary=True)
        actual = (smoke.REPO / path).read_bytes()
        if actual != original:
            # These two inputs alone have an independently reviewed local-mode overlay.
            # Their source fingerprint must remain the original checked-out Git bytes.
            overlay = next((overlays.get(key, {}) for key in ("infoOverlay", "projectOverlay")
                            if overlays.get(key, {}).get("path") == path), None) if overlays else None
            if (path not in smoke.OVERLAYS or overlay is None
                    or overlay.get("originalSHA256") != hashlib.sha256(original).hexdigest()
                    or overlay.get("overlaySHA256") != hashlib.sha256(actual).hexdigest()):
                raise ValueError("Probe source input differs from checked-out HEAD: " + path)
        records.append({"path": path, "sha256": hashlib.sha256(original).hexdigest(), "bytes": len(original)})
    return records


def _sdk_output_names():
    names = {"openssl-version.log", "xcode-version.log", "clang-version.log",
             "root.cert.der", "root.cert.pem", "leaf.cert.der", "leaf.cert.pem",
             "owned-certificate-chain.log", "import-tool-compile.log", "framework-clang.log",
             "owned-sdk-package.ipa", "owned-sdk-package.json"}
    for identifier in ("test.owned.reader", "test.owned.reader.share", "test.owned.reader.widget", "test.owned.reader.framework"):
        names.add(identifier + ".codesign.log")
        if not identifier.endswith(".framework"): names.add(identifier + ".clang.log")
    for role in ("main", "share", "widget", "framework"):
        names.update(role + suffix for suffix in (".macho", ".primary.cd", ".detached.cms", ".verified.cd", ".otool.log", ".original-cms.log"))
    return names


def _bounded_fact(path, maximum=67_108_864):
    path = smoke.config.checked_path(path)
    if not path.is_file() or path.is_symlink() or path.stat().st_nlink != 1:
        raise ValueError("SDK fixture input must be one regular owned file")
    if path.stat().st_size > maximum:
        raise ValueError("SDK fixture file exceeds fixed budget")
    raw = path.read_bytes()
    if len(raw) > maximum:
        raise ValueError("SDK fixture file exceeds fixed budget")
    return raw, {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def _read_sdk_json(path):
    raw, fact = _bounded_fact(path, 8_388_608)
    value = json.loads(raw)
    if not isinstance(value, dict): raise ValueError("SDK fixture JSON must be an object")
    return value, fact


def _sdk_macho(raw, role):
    if len(raw) < 32 or len(raw) > 67_108_864:
        raise ValueError("Invalid SDK Mach-O byte count")
    magic, cpu, subtype, kind, count, commands_size, _, _ = struct.unpack_from("<8I", raw)
    if (magic, cpu, subtype, kind) != (0xFEEDFACF, 0x100000C, 0, 6 if role == "framework" else 2):
        raise ValueError("SDK fixture architecture/file type mismatch")
    if not 0 < count <= 2048 or commands_size > min(len(raw) - 32, 1_048_576):
        raise ValueError("SDK fixture command budget")
    cursor = 32; commands = []; signature = None
    for _ in range(count):
        if cursor + 8 > 32 + commands_size: raise ValueError("Truncated SDK command")
        command, size = struct.unpack_from("<II", raw, cursor)
        if size < 8 or size > 32 + commands_size - cursor: raise ValueError("Malformed SDK command")
        commands.append(command)
        if command == 0xB and size != 80: raise ValueError("Malformed SDK DYSYMTAB")
        if command == 0x1D:
            if size != 16 or signature is not None: raise ValueError("Duplicate/malformed SDK signature")
            signature = struct.unpack_from("<II", raw, cursor + 8)
        cursor += size
    if cursor != 32 + commands_size or 0xB not in commands or signature is None:
        raise ValueError("Actual SDK fixture must contain DYSYMTAB and a signature")
    offset, size = signature
    if offset < cursor or size < 12 or offset + size != len(raw):
        raise ValueError("Actual SDK fixture signature must be terminal")
    magic, total, count = struct.unpack_from(">III", raw, offset)
    if magic != 0xFADE0CC0 or not 0 < count <= 64 or 12 + 8 * count > total or total > size:
        raise ValueError("Malformed SDK SuperBlob")
    blobs = {}
    for index in range(count):
        slot, at = struct.unpack_from(">II", raw, offset + 12 + 8 * index)
        if slot in blobs or at < 12 + 8 * count or at + 8 > total: raise ValueError("Invalid SDK blob index")
        blob_size = struct.unpack_from(">I", raw, offset + at + 4)[0]
        if blob_size < 8 or blob_size > total - at: raise ValueError("Invalid SDK blob range")
        blobs[slot] = raw[offset + at:offset + at + blob_size]
    primary, wrapper = blobs.get(0), blobs.get(0x10000)
    if (primary is None or len(primary) < 44 or struct.unpack_from(">I", primary)[0] != 0xFADE0C02
            or struct.unpack_from(">I", primary, 12)[0] & 2 or wrapper is None or len(wrapper) <= 8
            or struct.unpack_from(">I", wrapper)[0] != 0xFADE0B01):
        raise ValueError("Actual SDK original must carry non-adHoc CodeDirectory and CMS")
    return commands, kind, primary, wrapper[8:]


def _verify_sdk_public(directory, inputs):
    directory = smoke.config.checked_path(directory)
    manifest, manifest_fact = _read_sdk_json(directory / "sdk-produced-fixture-manifest.json")
    names = _sdk_output_names()
    if {path.name for path in directory.iterdir()} != names | {"sdk-produced-fixture-manifest.json"}:
        raise ValueError("SDK artifact directory contains undeclared/non-public files")
    if (type(manifest.get("schema")) is not int or manifest["schema"] != 1
            or type(manifest.get("privateKeyFilesOutsideKeychain")) is not int or manifest["privateKeyFilesOutsideKeychain"] != 0
            or type(manifest.get("privateMaterialArtifacts")) is not int or manifest["privateMaterialArtifacts"] != 0 or manifest.get("temporaryOwnedKeychainDeleted") is not True
            or manifest.get("realAppleAccountUsed") is not False):
        raise ValueError("SDK producer private/owned scope is not established")
    expected_sources = []
    for name in SDK_TOOL_NAMES:
        entry = next((item for item in inputs if item["path"] == SDK_TOOL_ROOT + name), None)
        if entry is None: raise ValueError("SDK producer source missing from source binding")
        expected_sources.append({"path": name, "bytes": entry["bytes"], "sha256": entry["sha256"]})
    if manifest.get("sourceInputs") != expected_sources:
        raise ValueError("SDK producer source closure differs from this source tag")
    outputs = manifest.get("publicOutputs")
    if not isinstance(outputs, list) or len(outputs) != len(names):
        raise ValueError("SDK public output inventory differs")
    declared = {}
    for entry in outputs:
        if not isinstance(entry, dict) or entry.get("path") not in names or entry["path"] in declared:
            raise ValueError("SDK public output path must be unique and allowlisted")
        raw, fact = _bounded_fact(directory / entry["path"])
        if entry != {"path": entry["path"], **fact}: raise ValueError("SDK generated output hash/length differs")
        if b"-----BEGIN PRIVATE KEY-----" in raw or b"-----BEGIN RSA PRIVATE KEY-----" in raw or b"-----BEGIN ENCRYPTED PRIVATE KEY-----" in raw:
            raise ValueError("Private material cannot enter SDK fixture artifacts")
        declared[entry["path"]] = fact
    if sum(fact["bytes"] for fact in declared.values()) > 134_217_728:
        raise ValueError("SDK public output total budget")
    commands = manifest.get("commands")
    if not isinstance(commands, list) or not commands: raise ValueError("Missing actual SDK command evidence")
    for command in commands:
        if not isinstance(command, dict) or type(command.get("exitCode")) is not int or command["exitCode"] != 0:
            raise ValueError("SDK command did not actually finish successfully")
        argv = command.get("argv")
        if not isinstance(argv, list) or not argv or any(not isinstance(part, str) for part in argv):
            raise ValueError("Malformed SDK command evidence")
        if "set-key-partition-list" in argv and ("-k" not in argv or argv.index("-k") + 1 >= len(argv) or argv[argv.index("-k") + 1] != "<random-owned-password>"):
            raise ValueError("SDK command evidence exposed an owned password")
    has = lambda predicate: sum(predicate(command["argv"]) for command in commands)
    if (has(lambda argv: "clang" in argv) < 4 or has(lambda argv: argv[0] == "codesign" and "--sign" in argv) != 4
            or has(lambda argv: "cms" in argv and "-verify" in argv) != 4
            or has(lambda argv: argv[0] == "security" and "delete-keychain" in argv) != 1):
        raise ValueError("Actual clang/codesign/CMS/Keychain cleanup command evidence is incomplete")
    rows = manifest.get("actualSDKProducedMachOs")
    if not isinstance(rows, list) or len(rows) != 4 or {row.get("role") for row in rows if isinstance(row, dict)} != {"main", "share", "widget", "framework"}:
        raise ValueError("Actual SDK main/extension/framework set differs")
    for row in rows:
        role = row["role"]; raw, fact = _bounded_fact(directory / (role + ".macho"))
        actual_commands, kind, primary, cms = _sdk_macho(raw, role)
        if (row.get("bytes") != fact["bytes"] or row.get("sha256") != fact["sha256"]
                or row.get("loadCommands") != actual_commands or row.get("fileType") != kind
                or row.get("originalDetachedCMSActuallyVerified") is not True
                or (directory / (role + ".primary.cd")).read_bytes() != primary
                or (directory / (role + ".verified.cd")).read_bytes() != primary
                or (directory / (role + ".detached.cms")).read_bytes() != cms):
            raise ValueError("Actual SDK raw Mach-O/CD/CMS and verifier output differ")
    payload, resource_fact = _read_sdk_json(directory / "owned-sdk-package.json")
    try:
        archive = base64.b64decode(payload["archive"], validate=True)
        anchor = base64.b64decode(payload["anchor"], validate=True)
    except (KeyError, ValueError, TypeError) as error:
        raise ValueError("Malformed generated SDK resource") from error
    archive_fact = {"bytes": len(archive), "sha256": hashlib.sha256(archive).hexdigest()}
    if (payload.get("schema") != 1 or not 0 < len(archive) <= 4_194_304 or not 0 < len(anchor) <= 65_536
            or type(payload.get("verificationEpochSeconds")) is not int
            or payload.get("archiveSHA256") != archive_fact["sha256"]
            or payload.get("actualSDKProducedMachOs") != rows
            or declared["owned-sdk-package.ipa"] != archive_fact
            or manifest.get("archiveSHA256") != archive_fact["sha256"] or manifest.get("archiveBytes") != len(archive)
            or anchor != (directory / "root.cert.der").read_bytes()
            or archive != (directory / "owned-sdk-package.ipa").read_bytes()):
        raise ValueError("Generated SDK resource is not bound to actual public IPA bytes")
    return {"manifest": manifest_fact, "publicOutputs": declared, "producerSourceInputs": expected_sources,
            "resource": {"path": SDK_RESOURCE, **resource_fact}, "archive": archive_fact,
            "actualSDKProducedMachOs": rows}


def stage_sdk_fixture(work, produced):
    if selection_mode() != "integratedrenewal": raise ValueError("SDK fixture generation belongs only to integratedrenewal")
    require_source_only()
    inputs = smoke.read_json(work / "source-inputs.json")
    if inputs.get("selectionMode") != "integratedrenewal" or inputs.get("sourceCommit") != validate_tag():
        raise ValueError("SDK fixture preparation source/mode mismatch")
    developer = os.environ.get("DEVELOPER_DIR")
    if not isinstance(developer, str) or not developer: raise ValueError("SDK producer must use selected DEVELOPER_DIR")
    verified = _verify_sdk_public(produced, inputs["sourceInputs"])
    target = smoke.config.checked_path(smoke.REPO / SDK_RESOURCE)
    if target.exists(): raise ValueError("Refusing to replace existing SDK test resource")
    artifact = smoke.config.checked_path(work / "sdk-produced-public")
    if artifact.exists(): raise ValueError("Refusing to overwrite previous public SDK evidence")
    artifact.mkdir(parents=True)
    for name in sorted(_sdk_output_names() | {"sdk-produced-fixture-manifest.json"}):
        with (artifact / name).open("xb") as stream: stream.write((produced / name).read_bytes())
    _verify_sdk_public(artifact, inputs["sourceInputs"])
    with target.open("xb") as stream: stream.write((artifact / "owned-sdk-package.json").read_bytes())
    target.chmod(0o444)
    record = {"schemaVersion": 1, "sourceCommit": inputs["sourceCommit"], "selectionMode": "integratedrenewal",
              "developerDirectory": developer, **verified}
    smoke.config.write_new_json(work / "sdk-fixture-binding.json", record)
    return record


def _sdk_runtime_markers(path):
    if path.stat().st_size > 268_435_456: raise ValueError("SDK native log budget")
    expression = re.compile(re.escape(SDK_MARKER) + r" resourceSHA256=([0-9a-f]{64}) resourceBytes=([0-9]+) archiveSHA256=([0-9a-f]{64}) archiveBytes=([0-9]+)")
    values = []
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if SDK_MARKER not in line: continue
            match = expression.search(line)
            if match is None: raise ValueError("Malformed actual SDK fixture loader marker")
            values.append({"resourceSHA256": match[1], "resourceBytes": int(match[2]),
                           "archiveSHA256": match[3], "archiveBytes": int(match[4])})
            if len(values) > 16: raise ValueError("SDK fixture marker count budget")
    if not values: raise ValueError("Missing actual SDK fixture loader marker")
    return values


def verify_sdk_fixture(work, phase, save=True):
    if selection_mode() != "integratedrenewal" or phase not in ("before-build", "after-tests"):
        raise ValueError("Invalid SDK runtime resource phase")
    inputs = smoke.read_json(work / "source-inputs.json")
    binding = smoke.read_json(work / "sdk-fixture-binding.json")
    verified = _verify_sdk_public(work / "sdk-produced-public", inputs["sourceInputs"])
    if (binding.get("sourceCommit") != validate_tag() or binding.get("selectionMode") != "integratedrenewal"
            or binding.get("developerDirectory") != os.environ.get("DEVELOPER_DIR")
            or any(binding.get(key) != value for key, value in verified.items())):
        raise ValueError("SDK fixture source/generator/output binding changed")
    _, actual = _bounded_fact(smoke.REPO / SDK_RESOURCE, 8_388_608)
    if actual != {key: verified["resource"][key] for key in ("bytes", "sha256")}:
        raise ValueError("SDK source resource hash changed before/after native execution")
    record = {"schemaVersion": 1, "phase": phase, "sourceCommit": binding["sourceCommit"],
              "bindingSHA256": smoke.config.digest(work / "sdk-fixture-binding.json"),
              "resourceSHA256": actual["sha256"], "resourceBytes": actual["bytes"]}
    if phase == "after-tests":
        summary = smoke.verify_summary(smoke.read_json(work / "integratedrenewal-summary.json"), 140)
        actual_cases = verify_cases(smoke.read_json(work / "integratedrenewal-tests.json"), "integratedrenewal")
        if SDK_REQUIRED_CASE not in actual_cases["passedCaseIdentifiers"]: raise ValueError("Actual SDK method did not pass")
        entries = smoke.read_json(work / "sdk-test-build-settings.json")
        matches = [entry["buildSettings"] for entry in entries if entry.get("target") == "yuedu appTests"]
        if len(matches) != 1: raise ValueError("Expected exactly one actual XCTest bundle build setting")
        settings = matches[0]
        if settings.get("CONFIGURATION") != "Debug" or settings.get("PLATFORM_NAME") != "iphonesimulator":
            raise ValueError("SDK fixture test bundle must be actual Debug Simulator output")
        bundle = smoke.config.checked_path(Path(settings["TARGET_BUILD_DIR"]) / settings["FULL_PRODUCT_NAME"])
        if bundle.suffix != ".xctest": raise ValueError("Expected actual built XCTest bundle")
        _, built = _bounded_fact(bundle / "owned-sdk-package.json", 8_388_608)
        if built != actual: raise ValueError("Built SDK fixture resource hash differs")
        markers = _sdk_runtime_markers(work / "integratedrenewal-tests.log")
        expected = {"resourceSHA256": actual["sha256"], "resourceBytes": actual["bytes"],
                    "archiveSHA256": verified["archive"]["sha256"], "archiveBytes": verified["archive"]["bytes"]}
        if any(value != expected for value in markers): raise ValueError("Actual runtime loader read a different SDK fixture")
        record.update({"builtResource": built, "runtimeLoaderMarkers": markers,
                       "requiredSDKCasePassed": SDK_REQUIRED_CASE, "nativeCount": summary["totalTestCount"]})
    if save: smoke.config.write_new_json(work / ("sdk-fixture-" + phase + ".json"), record)
    return record


def decoded_strings_value(path, key):
    """Read source OpenStep strings and Xcode's binary/XML compiled strings."""
    raw = path.read_bytes()
    if len(raw) > 64 * 1024:
        raise ValueError("Oversized privacy localization table")
    if raw.startswith(b"bplist") or raw.lstrip().startswith((b"<?xml", b"<plist")):
        table = plistlib.loads(raw)
        value = table.get(key) if isinstance(table, dict) else None
    else:
        text = raw.decode("utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig")
        matches = re.findall(r'^\s*"' + re.escape(key) + r'"\s*=\s*("(?:[^"\\\r\n]|\\.)*")\s*;\s*$',
                             text, flags=re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("Privacy localization must contain exactly one usage description")
        # OpenStep supports uppercase four-digit Unicode escapes as well as JSON's escapes.
        value = json.loads(re.sub(r"(?<!\\)((?:\\\\)*)\\U([0-9a-fA-F]{4})", r"\1\\u\2", matches[0]))
    if not isinstance(value, str) or not value.strip() or len(value) > 1024:
        raise ValueError("Missing or invalid local-network usage description")
    return value


def verify_built_discovery_metadata(app, info):
    services = info.get("NSBonjourServices")
    if (not isinstance(services, list) or len(services) != len(BONJOUR_SERVICES)
            or any(not isinstance(value, str) for value in services)
            or set(services) != set(BONJOUR_SERVICES)):
        raise ValueError("Built Bonjour services must preserve Calibre and declare exactly one RemotePairing type")
    project = (smoke.REPO / smoke.config.PROJECT).read_text(encoding="utf-8")
    fallbacks = re.findall(r'^\s*INFOPLIST_KEY_NSLocalNetworkUsageDescription\s*=\s*("(?:[^"\\\r\n]|\\.)*")\s*;\s*$',
                           project, flags=re.MULTILINE)
    if len(fallbacks) != 2:
        raise ValueError("Both project configurations must declare the local-network privacy fallback")
    values = [json.loads(value) for value in fallbacks]
    if not values[0].strip() or values[0] != values[1] or info.get(USAGE_KEY) != values[0]:
        raise ValueError("Built local-network privacy fallback differs from both source project configurations")
    localized = []
    for language in LANGUAGES:
        relative = language + ".lproj/InfoPlist.strings"
        source = smoke.REPO / "Resources" / relative
        built = app / relative
        if decoded_strings_value(built, USAGE_KEY) != decoded_strings_value(source, USAGE_KEY):
            raise ValueError("Built local-network privacy localization differs from source: " + language)
        localized.append({"language": language, "sourceSHA256": smoke.config.digest(source),
                          "builtSHA256": smoke.config.digest(built), "usageDescriptionMatchesSource": True})
    return {"bonjourServices": list(BONJOUR_SERVICES), "fallbackMatchesBothSourceConfigurations": True,
            "localizedUsageDescriptions": localized}


def prepare(work):
    mode = selection_mode()
    cases = selected_cases()
    require_source_only()
    if (work / "overlays.json").exists() or (work / "source-inputs.json").exists():
        raise ValueError("Refusing to overwrite prior renewal preparation evidence")
    records = source_inputs()
    audit = smoke.prepare(work, tag_prefix=TAG_PREFIX)
    record = {"schemaVersion": 1, "sourceCommit": audit["sourceCommit"],
              "sourceTag": TAG_PREFIX + audit["sourceCommit"][:7],
              "sourceInputs": records, "runtimeSourceOnly": True,
              "selectionMode": mode,
              "intendedTests": {key: sorted(value) for key, value in cases.items()}}
    smoke.config.write_new_json(work / "source-inputs.json", record)
    return record


def verify_cases(tree, group):
    if group not in EXPECTED_CASES:
        raise ValueError("Unknown renewal test group")
    if not isinstance(tree, dict) or not isinstance(tree.get("testNodes"), list):
        raise ValueError("Expected xcresulttool test-results tests JSON with testNodes")
    cases = []

    def visit(node, suites):
        if not isinstance(node, dict):
            raise ValueError("Malformed xcresult test node")
        if node.get("nodeType") == "Test Suite":
            suites = suites + [node.get("name", "")]
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier")
            if not isinstance(identifier, str) or not identifier:
                raise ValueError("Every executed test case must have a nodeIdentifier")
            # Xcode may qualify an identifier with its test target. Preserve
            # exactly the final suite/method; never count only display labels.
            components = identifier.removesuffix("()").split("/")
            case = "/".join(components[-2:])
            if case not in EXPECTED_CASES[group] or node.get("result") != "Passed":
                raise ValueError("Unexpected, skipped or failed renewal test case: " + identifier)
            cases.append(case)
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("Malformed xcresult child nodes")
        for child in children:
            visit(child, suites)

    for node in tree["testNodes"]:
        visit(node, [])
    if len(cases) != len(EXPECTED_CASES[group]) or set(cases) != EXPECTED_CASES[group]:
        raise ValueError("The actual xcresult test identities differ from the fixed renewal selection")
    return {"expectedTests": len(EXPECTED_CASES[group]), "passedCaseIdentifiers": sorted(cases)}


def result(work):
    mode = selection_mode()
    cases = selected_cases()
    require_source_only()
    source = validate_tag()
    audit = smoke.read_json(work / "overlays.json")
    smoke.review_overlays(audit)
    if audit.get("infoOverlay", {}).get("sourceCommitStamped") != source:
        raise ValueError("Renewal preparation must stamp its exact source in Info.plist")
    inputs = smoke.read_json(work / "source-inputs.json")
    if (inputs.get("sourceCommit") != source or inputs.get("runtimeSourceOnly") is not True
            or inputs.get("sourceTag") != TAG_PREFIX + source[:7]
            or inputs.get("sourceInputs") != source_inputs(audit)
            or inputs.get("selectionMode") != mode
            or inputs.get("intendedTests") != {key: sorted(value) for key, value in cases.items()}):
        raise ValueError("Renewal source-input audit changed or differs from this source")
    settings = smoke.read_json(work / "build-settings.json")
    matches = [entry["buildSettings"] for entry in settings if entry.get("target") == smoke.config.MAIN_TARGET]
    if len(matches) != 1:
        raise ValueError("Expected exactly one main reader diagnostic test host")
    actual = matches[0]
    for name, expected in {"CONFIGURATION": "Debug", "SWIFT_VERSION": "5.0",
                           "PLATFORM_NAME": "iphonesimulator",
                           "PRODUCT_BUNDLE_IDENTIFIER": smoke.config.MAIN_BUNDLE}.items():
        if actual.get(name) != expected:
            raise ValueError("Unexpected renewal test-host build setting: " + name)
    app = smoke.config.checked_path(Path(actual["TARGET_BUILD_DIR"]) / actual["FULL_PRODUCT_NAME"])
    info = smoke.config.read_info(app)
    smoke.require_local_info(info)
    smoke.require_source_stamp(info, source)
    if (info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]
            or info.get("CFBundleIdentifier") != smoke.config.MAIN_BUNDLE):
        raise ValueError("Renewal test host must be the isolated Simulator reader")
    metadata = verify_built_discovery_metadata(app, info)
    if plistlib.loads((app / "GoogleService-Info.plist").read_bytes()) != smoke.config.synthetic_config():
        raise ValueError("The diagnostic test host must include only synthetic Firebase configuration")
    smoke.config.no_jvm_payload(app)
    groups = {}
    for group in cases:
        groups[group] = {
            **smoke.verify_summary(smoke.read_json(work / (group + "-summary.json")), len(EXPECTED_CASES[group])),
            **verify_cases(smoke.read_json(work / (group + "-tests.json")), group),
        }
    sdk_evidence = None
    if mode == "integratedrenewal":
        for phase in ("before-build", "after-tests"):
            stored = smoke.read_json(work / ("sdk-fixture-" + phase + ".json"))
            current = verify_sdk_fixture(work, phase, save=False)
            if stored != current: raise ValueError("SDK runtime resource audit changed after execution")
        sdk_evidence = smoke.read_json(work / "sdk-fixture-after-tests.json")
    evidence = {}
    evidence_names = ["build-settings.json", "source-inputs.json", "overlays.json", "project-overlay.json", "info-overlay.json"]
    evidence_names += [group + suffix for group in cases for suffix in ("-summary.json", "-tests.json")]
    if mode == "integratedrenewal":
        evidence_names += ["sdk-fixture-binding.json", "sdk-fixture-before-build.json", "sdk-fixture-after-tests.json", "sdk-test-build-settings.json"]
    for name in evidence_names:
        evidence[name] = smoke.config.digest(work / name)
    return {"schemaVersion": 2, "sourceCommit": source, "sourceTag": TAG_PREFIX + source[:7],
            "status": "passed", "configuration": "Debug", "executionPlatform": "ios-simulator",
            "simulatorDestination": os.environ.get("YUEDU_DEST"),
            "developerDirectory": os.environ.get("DEVELOPER_DIR"), "selectionMode": mode,
            "targetedTests": groups, "unselectedTestGroups": [group for group in EXPECTED_CASES if group not in cases],
            "unselectedTestGroupsMeaning": "Artifact groups not accepted independently; their test identities may overlap the selected group.",
            "testedInfoSHA256": smoke.config.digest(app / "Info.plist"),
            "sourceOverlays": audit, "sourceInputs": inputs["sourceInputs"], "evidenceSHA256": evidence,
            "builtDiscoveryMetadata": metadata,
            "runtimeSourceOnly": True, "ipaGenerated": mode == "integratedrenewal", "ipaUploaded": mode == "integratedrenewal",
            "ipaKind": "owned-sdk-fixture-only" if mode == "integratedrenewal" else "none",
            "distributionIPAGenerated": False, "sdkFixtureRuntimeEvidence": sdk_evidence,
            "appleAccountUsed": False, "pairingRecordUsed": False,
            "iphoneTransportVerified": False, "physicalDeviceValidationPassed": False,
            "serviceIdentityVerified": False,
            "selfRenewalVerified": False, "unattendedRenewalVerified": False,
            "computerPoweredOff": "notMeasured", "companionAppsAbsent": "notMeasured",
            "limitations": ["Only the selected Simulator groups are accepted; not a delivered IPA or iPhone test.",
                            "No Apple login, real pairing, installation or renewal operation is performed."] + (
                           ["This selection executes exactly 140 unique qualified native methods in one integratedrenewal xcresult: bound78 union controlled23 plus nine App owner, twelve BookChapterStorage methods excluding the benchmark, eleven whole-package and seven authenticated-installation cases.",
                            "Historical modes retain their exact leaf sets and cold/warm budgets; overlaps count once in this selected union and never become additional acceptances.",
                            "The same job executes the fixed xcrun clang/codesign producer with a short-lived owned Keychain identity. Source/commands/public raw Mach-O and generated IPA hashes are bound, the generated JSON is copied as an untracked XCTest resource, and both built bytes and the actual loader's runtime SHA marker must match before acceptance.",
                            "The IPA flags refer only to that synthetic public SDK fixture; no delivered app/distribution IPA or user archive is generated or uploaded. Private keys/P12 stay in memory or the one temporary Keychain and never enter artifacts.",
                            "Owned whole-package tests exercise actual profile/resource/nested/Mach-O signing and final raw archive verification. Authenticated-installation cases use owned local TLS/AFC/installation fixtures, not an iPhone or real pairing record.",
                            "App owner fixtures and selected chapter storage regressions do not establish Kotlin/JNI App routing, delivered persistence migration or unattended operation.",
                            "Generic explicit anchors do not establish Apple authority, real account/device/profile authorization, installation permission, cold launch, user data preservation or automatic self-renewal.",
                            "No independent package XCTest run is triggered or accepted by this selection; the earlier ten-method package checkpoint has its own result. No unchanged diagnostic network/UI or replacement-policy suite executes."]
                             if mode == "integratedrenewal" else [
                              "This selection executes exactly 23 owned cases in one controlledsigning xcresult: nine IPA validation/unpack, seven signing-material vault and seven controlled Mach-O signer cases.",
                              "Historical native selections retain their exact method sets and budgets; no prior native group is accepted or rerun by this selection. The independent ten package XCTest methods have a separate result and never enter this count.",
                              "Owned archives exercise bounded stored/deflate bytes and staged whole-material rechecks. Keychain fixtures use owned namespaces, actual software key handles and signed public material with CAS, cancellation, recovery and revocation checks.",
                              "The signer handles supported already-signed thin64 arm64 MH_EXECUTE bytes. It rebuilds real page/special hashes, uses actual SecKey detached CMS, preserves identity/entitlement bytes, separately authenticates old and new CodeResources, and invokes existing code verifiers after signing.",
                              "Generic explicit anchors do not establish Apple authority. Full architecture/load-command coverage, package-wide bottom-up signing/profile/resource orchestration, trusted replacement/install and unattended renewal remain unverified.",
                              "Transport, discovery, replacement and diagnostic UI suites are not executed; no QueryType listener, RemotePairing browsing or diagnostic TCP probe is invoked."]
                             if mode == "controlledsigning" else [
                              "This selection executes exactly 78 cases in one boundmaterials xcresult: the original sealed-material 48 plus eight nested-requirement, eight modern-profile, five whole-application identity and nine Swift persistent-state host cases.",
                             "Historical artifact groups are not accepted independently; their qualified method identities are rechecked inside this one group because shared verification inputs changed.",
                             "Actual CodeDirectory CMS, recursive resource digests, supported nested expressions and every fat slice are checked against bounded owned material. Unavailable Apple/system-policy predicates and named fragments remain explicitly unresolved.",
                             "Modern profiles require both actual CMS layers; fields come from the inner DER source, not unrelated legacy XML. Actual signer certificate, prefix, team, App ID and selected groups are compared, and later profile bytes must match any earlier verified resource seal.",
                             "Generic explicit anchor trust does not establish Apple signing/provisioning authority, full entitlement authorization, device/account eligibility or installation permission. A trusted replacement adapter, signer and installer remain unverified.",
                              "The nine Swift host cases use owned injected persistence and cancellation fixtures; source-only execution does not run the JVM/JNI bridge, the Kotlin persistence suite or a delivered App database migration.",
                             "Unit, discovery, replacement and UI suites are not executed; no QueryType listener, RemotePairing browsing or diagnostic TCP probe is invoked."]
                            if mode == "boundmaterials" else [
                             "This selection executes exactly 48 cases in one sealedmaterials xcresult: nine signature-structure, seven CodeDirectory content-hash, seven generic CMS, two provisioning-envelope, six material-inventory, seven signed-code and ten resource-seal cases.",
                             "Signature, cryptography and materials artifact groups are not accepted separately; their method identities are included in the single sealedmaterials group because shared inventory, reader and CMS production inputs changed.",
                             "Detached CodeDirectory CMS and supported hash-agility encodings bind owned signatures to original CodeDirectory bytes; generic explicit anchors do not establish Apple provisioning authority.",
                             "Resource checks bind the consumed CodeResources bytes to re-read CodeDirectory slot 3 and check bounded resource digests and traversal. Nested requirements, strict Apple resource policy and Apple signing authority remain unverified.",
                             "Apple-specific profile DER content, entitlement/device eligibility, trusted replacement adapter, signer and installer integration remain unverified.",
                             "Unit, discovery, replacement and UI suites are not executed; no QueryType listener, RemotePairing browsing or diagnostic TCP probe is invoked."]
                            if mode == "sealedmaterials" else [
                             "This selection executes exactly 25 cases in one cryptography xcresult: nine signature-structure, seven CodeDirectory content-hash, seven generic CMS and two owned provisioning-envelope cases.",
                            "The independently named signature artifact group is not accepted separately; its nine test identities are executed inside this cryptography group because the shared reader changed.",
                            "Content-digest matching is checked against untrusted CodeDirectories; generic CMS signatures and explicit owned anchors do not establish Apple provisioning authority.",
                            "Apple-specific profile DER content, entitlement/device eligibility, resource-tree seals, signer and installer integration remain unverified.",
                            "Unit, discovery, replacement, material-inventory and UI suites are not executed; no QueryType listener, RemotePairing browsing or diagnostic TCP probe is invoked."]
                           if mode == "cryptography" else [
                            "This selection executes exactly nine owned-fixture Mach-O signature-structure cases; unit, discovery, replacement, materials and UI groups are not executed or accepted.",
                            "Thin/fat Mach-O, load commands, SuperBlob, CodeDirectory and CMS slot observations remain untrusted; no CMS ASN.1, certificate-chain, page-hash, resource-seal or profile authenticity is established.",
                            "No QueryType fixture listener, RemotePairing browsing or diagnostic TCP probe is invoked."]
                           if mode == "signature" else [
                            "Five replacement-policy cases check caller-supplied metadata only; no real platform adapter, signature or profile authenticity is established.",
                            "This selection executes only replacement metadata cases; unit, discovery, materials, signature and UI groups are not executed or accepted."]
                           if mode == "replacement" else [
                            "Five replacement-policy cases check caller-supplied metadata only; no real platform adapter, signature or profile authenticity is established.",
                            "This selection executes exactly five replacement-policy and six owned-file material-inventory cases; unit, discovery, signature and UI groups are not executed or accepted.",
                            "Material inventory reads bounded owned directory fixtures and untrusted metadata; it does not verify Mach-O signatures, resource seals, CMS profiles or certificate authority."]
                           if mode == "implementation" else [
                            "Five replacement-policy cases check caller-supplied metadata only; no real platform adapter, signature or profile authenticity is established.",
                            "Historical all mode retains only unit, discovery, replacement and UI groups; material-inventory and signature-structure cases are not executed or accepted.",
                            "Unit network responses come from owned temporary loopback fixture listeners.",
                            "The explicit UI operation browses only RemotePairing, filters numeric local ownership, opens TCP and closes without an application payload.",
                            "The existing eight QueryType fixture cases remain separate from sixteen discovery cases and one UI case.",
                            "A bare TCP connection does not establish service identity or an authenticated usable transport.",
                            "The previous fixed-loopback experiment does not exclude alternate transports; discovery fixtures and Simulator UI do not establish iPhone reachability."])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    commands.add_parser("validate-tag")
    for phase in ("prepare", "result"):
        item = commands.add_parser(phase)
        item.add_argument("--work", type=Path, required=True)
    stage = commands.add_parser("stage-sdk-fixture")
    stage.add_argument("--work", type=Path, required=True)
    stage.add_argument("--produced", type=Path, required=True)
    sdk = commands.add_parser("verify-sdk-fixture")
    sdk.add_argument("--work", type=Path, required=True)
    sdk.add_argument("--phase", dest="sdk_phase", choices=("before-build", "after-tests"), required=True)
    verify = commands.add_parser("verify-tests")
    verify.add_argument("--tests", type=Path, required=True)
    verify.add_argument("--summary", type=Path, required=True)
    verify.add_argument("--group", choices=tuple(EXPECTED_CASES), required=True)
    args = parser.parse_args()
    try:
        if args.phase == "validate-tag":
            record = {"sourceCommit": validate_tag()}
        elif args.phase == "prepare":
            record = prepare(smoke.config.checked_path(args.work))
        elif args.phase == "stage-sdk-fixture":
            record = stage_sdk_fixture(smoke.config.checked_path(args.work), smoke.config.checked_path(args.produced))
        elif args.phase == "verify-sdk-fixture":
            record = verify_sdk_fixture(smoke.config.checked_path(args.work), args.sdk_phase)
        elif args.phase == "verify-tests":
            if args.group not in selected_cases():
                raise ValueError("Test group is not part of YUEDU_RENEWAL_SELECTION")
            record = {**smoke.verify_summary(smoke.read_json(args.summary), len(EXPECTED_CASES[args.group])),
                      **verify_cases(smoke.read_json(args.tests), args.group)}
        else:
            work = smoke.config.checked_path(args.work)
            record = result(work)
            smoke.config.write_new_json(work / "result.json", record)
        print(json.dumps(record, indent=2))
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
