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
import threading
import signal
import subprocess
import time


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
SDK_TOOL_NAMES = ("generate-sdk-owned-package.py", "ImportOwnedIdentity.swift", "OwnedIdentitySearch.h", "OwnedIdentitySearch.c", "main.c", "extension.c", "framework.c")
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
TRANSACTION_ADDITIONAL_CASES = {'LegadoBookMetadataOwnerTests': ['actualBookCallbacksRestoreShelfAndReadingVariables', 'olderQueuedMetadataCannotEraseAcceptedVariables', 'queuedTXTBookmarksKeepOtherBookVariables', 'failedTXTBookmarkWriteKeepsOldMetadata', 'exactTXTJournalRecoversPublicationConflicts', 'failedWritesAndCancellationKeepOldMetadata', 'failedShelfReplacementKeepsBothDurableBookCopies'], 'LegadoPersistentStateHostTests': ['malformedStateInputsHaveTypedErrorsAndRetainProofs'], 'BookStoreShelfRecoveryTests': ['unreadableShelfIsKeptAside', 'shelfThatCannotBeKeptAsideIsNotOverwritten', 'relaunchReusesTheExistingCopy'], 'BookStoreMetadataWriteBudgetTests': ['tinyProgressChangesStayInMemoryUntilForcedSave', 'clearingDownloadAnnouncesCacheClear', 'completedOfflineDownloadPersistsImmediately', 'leavingForegroundFlushesDebouncedSave'], 'BookStoreBackgroundPublishTests': ['cacheMarkDoesNotPublish', 'refreshPublishesOnce', 'reparsedUnchangedListIsNoChange'], 'TXTReaderIndexMigrationTests': ['migrationPreservesBookmarksAndReplaysInterruptedCommit', 'newImportPublishesOnlyThroughTheCommitOwner'], 'AozoraTXTTests': ['storedV6LocationsMigrateOnce'], 'WebDAVRestoreIntegrityTests': ['localSummaryAndTXTWriterRespectBoundary'], 'SelfRenewalTransactionJournalTests': ['excludesSecondOwnerAndReopensDurableCheckpoint', 'rejectsContradictoryDurablePhaseInsteadOfResubmitting', 'rejectsFailedCandidateWithoutAcknowledgingOrReplacingState', 'reclaimsAbandonedOwnedTemporaryAfterProcessInterruption'], 'SelfRenewalControlledRenewalCoordinatorTests': ['persistsAndSubmitsActualVerifiedPackageWithoutTouchingUserStores', 'recoversUnknownUpgradeWithoutUploadingOrSubmittingTwice', 'rejectsChangedCandidateBeforeOpeningAuthenticatedTransport', 'rejectsRevokedMaterialBeforeAnyUploadOrUpgrade', 'retainsUploadOwnershipAfterActualPartialAFCFailure', 'recoversActualPackageUploadWithFreshAuthenticatedCleanup'], 'SelfRenewalInstallationRecoveryTests': ['removesPersistedOwnedUploadAfterFreshMutualTLSAndClearsJournalPhase', 'acceptsActualMissingACKAndRetainsRemovalWhenStopDisconnects', 'retainsUnknownSubmittedUpgradeAndUsesOnlyAuthenticatedLookup', 'rejectsStaleMalformedAndWrongDeviceGrantsBeforeAnyRemoval', 'cancellationAndDeadlineReleaseGrantForFreshAuthenticatedRetry', 'keepsOriginalErrorSeparateFromRemoteCleanupAndJournalFailures']}
PARAMETER_CASES = {"TXTReaderIndexMigrationTests/migrationPreservesBookmarksAndReplaysInterruptedCommit": "interrupt", "AozoraTXTTests/storedV6LocationsMigrateOnce": "interrupt"}
EXPECTED_CASES["transactionrenewal"] = EXPECTED_CASES["integratedrenewal"] | {suite + "/" + method for suite, methods in TRANSACTION_ADDITIONAL_CASES.items() for method in methods}
assert len(EXPECTED_CASES["transactionrenewal"]) == 178
HANDOFF_NEW_CASES = {'SelfRenewalInstalledMaterialObserverTests': ['matchesActualCodeDirectoriesCertificatesProfilesAndOrderedGroups', 'rejectsOldSignedMaterialWithTheSameReportedIdentityAndVersion', 'unavailableCurrentProcessDoesNotAdvanceOrEraseThePendingTransaction', 'preservesOneActualProcessIdentityWithoutObservingAnUnsubmittedCandidate'], 'SelfRenewalUserDataHandoffTests': ['submitsOnlyAfterActualAppOwnerReceiptsAreDurable', 'actualSourceWriteFailurePreventsUpgradeAndKeepsPendingOwnership', 'rejectsUnboundAndForeignPositionOwnersBeforeSaving'], 'BookStoreMetadataHandoffTests': ['actualSaveAndNormalReopenBindBothRawFiles', 'unchangedSaveCannotUseOnlyCachedBytes', 'missingAndFailedNormalLoadsRemainDifferent', 'realWriteFailureRetainsOldFilesAndRetry', 'partialSaveReportsRealFilesAndRetainsProtectedCopy', 'cancellationAndRestorePauseCannotAcknowledgeAWrite', 'checkedWriterPreservesAcceptedRuntimeVariables', 'realChapterFlushFailurePreventsMetadataReceipt'], 'BookSourceStoreHandoffTests': ['streamedSaveMatchesNewOwnerNormalLoad', 'normalLoadPreservesRawBytesAndTypedFailures', 'actualWriteFailuresPreserveOriginalTargets', 'restoreAndPreAdmissionCancellationAreExplicit', 'bootstrapUsesTheSameConcreteWriterProof', 'admittedCancellationAndCoalescingKeepActualFileOrder'], 'ReadingPositionStorePersistenceTests': ['testCheckedAtomicReceiptMatchesRawFileAndReopenedOwner', 'testCheckedLoadHashesOriginalJSONAndDistinguishesMissingCorruptAndBounds', 'testCheckedWriteFailureAndUnsupportedBackendsNeverReturnSuccess', 'testNavigatorHandoffPersistsCapturedTranslationAndRejectsLegacyOwner', 'testCheckedAdmissionCompletesAfterCancellationBehindTheExistingWriter', 'testNavigatorHandoffAndOtherBooksKeepTheSameCrossInstanceAdmissionOrder']}
HANDOFF_REGRESSION_CASES = {'ReadingPositionStorePersistenceTests': ['testSavingRecreatesAReadingPositionDirectoryRemovedAfterInitialization', 'testFailedWritePreservesPreviousFileAndDoesNotPublishASuccess', 'testCorruptProgressIsPreservedAndNeverPublishedAsASuccess', 'testCompletedSaveIsRestoredByANewStoreIncludingTranslationOffset', 'testMissingProgressDoesNotCreateOrPublishAReplacement', 'testAdmittedSavesAndFlushKeepOrderWhenTheFirstCallerIsCancelled', 'testDifferentInstancesShareAdmissionOrderAndAsyncLoadWaits', 'testHeldWriteFailureDoesNotPublishSuccessOrStopTheLaterSave', 'testDirectoryRemovedDuringAHeldWriteIsRecreatedByTheNextSave', 'testSyncReplacementUsesTheSameOrderedWorkerWithoutEchoingASave'], 'BookSourceStoreTests': ['burstOfEditsPersistsTheNewestLibrary', 'streamedLibraryMatchesOneShotEncode', 'storeReloadsStreamedSave'], 'BuiltInBookSourcesTests': ['freshInstallPreservesSourceConfiguration', 'invalidPackagesPreserveExistingLibrary', 'unreadableExistingLibraryIsProtected', 'failedWritesStayPendingAndCanRetry']}
# XCTest methods in the ordering file extend the SAME concrete XCTestCase.
# File names are source paths, never executable suite aliases.
HANDOFF_TEST_SOURCE_PATHS = {"ReadingPositionStorePersistenceTests": (
    "Tests/iOS/yuedu appTests/ReadingPositionStorePersistenceTests.swift",
    "Tests/iOS/yuedu appTests/ReadingPositionWriteOrderingTests.swift",
)}
HANDOFF_COOKIE_NEW_CASES = {'LegadoCookieOwnerTests': ['legacyFileMigratesWithoutInventedProofs', 'nativeAttributesSurviveActualFileRestart', 'failedOwnerIOPreservesOldCookieState', 'scriptWritesExposeTypedOwnerFailure', 'browserObservationKeepsNewerHTTPState', 'browserRemovalDoesNotReviveLegacyText', 'actualHTTPRedirectAndRestart', 'actualHTTPWriteFailureDoesNotAcknowledge', 'cancelledHTTPCommitKeepsOldCookieState', 'actualBrowserRequestRespectsCookieScope', 'staleWebViewCookieDecisionCannotEndReusedLease', 'nativeBrowserPreparationFailureRemainsTyped', 'formLoginRemovalPreservesCredentials']}
HANDOFF_COOKIE_REGRESSION_CASES = {'WebFetcherPersistedCookieTests': ['nativeRequestRestoresPersistedCookie'], 'WebFetcherChallengeResponseTests': ['challengeStatusIsAnHTTPError', 'challengeBodyIsReturned'], 'StageLoginCheckTests': ['forbiddenResponseCanBeReplaced', 'untouchedForbiddenResponseThrows', 'successfulResponsePassesThrough', 'sourceWithoutCheckIsUnchanged'], 'SourceBrowserAuthenticationTests': ['authenticatedFirstLoad', 'currentCredentialsAndIsolation', 'nativeMarkerAuthentication'], 'BookSourceLoginTests': ['browserInitialLoadUsesStoredCookies', 'fanqieSessionCookieReadableByJSBridge', 'loginInfoChangeInvalidatesResolvedHeaderCache'], 'JSCoreEngineTests': ['sourceBrowserRequestCarriesHeaders'], 'WebViewNavigationWaitTests': ['cancellationResumesSuspendedWait', 'resultResumesWaiter']}
HANDOFF_COOKIE_SOURCE_PATHS = {'WebFetcherPersistedCookieTests': 'Tests/iOS/yuedu appTests/WebFetcherPersistedCookieTests.swift', 'WebFetcherChallengeResponseTests': 'Tests/iOS/yuedu appTests/WebFetcherChallengeResponseTests.swift', 'StageLoginCheckTests': 'Tests/iOS/yuedu appTests/StageLoginCheckTests.swift', 'SourceBrowserAuthenticationTests': 'Tests/iOS/yuedu appTests/SourceBrowserAuthenticationTests.swift', 'BookSourceLoginTests': 'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift', 'JSCoreEngineTests': 'Tests/iOS/yuedu appTests/ModernParserTests.swift', 'WebViewNavigationWaitTests': 'Tests/iOS/yuedu appTests/WebViewNavigationWaitTests.swift'}
HANDOFF_COOKIE_READ_CASES = {'LegadoCookieReadHostTests': ['actualUnknownWKValuesReachReadCallbackWithoutJarReconstruction', 'actualReadCallbackKeepsOwnerAndFailureBoundaries']}
HANDOFF_ADDITIONAL_CASES = {suite + "/" + method for table in (HANDOFF_NEW_CASES, HANDOFF_REGRESSION_CASES, HANDOFF_COOKIE_NEW_CASES, HANDOFF_COOKIE_REGRESSION_CASES, HANDOFF_COOKIE_READ_CASES) for suite, methods in table.items() for method in methods}
EXPECTED_CASES["handoffrenewal"] = EXPECTED_CASES["transactionrenewal"] | HANDOFF_ADDITIONAL_CASES
assert len(HANDOFF_ADDITIONAL_CASES) == 75 and len(EXPECTED_CASES["handoffrenewal"]) == 253

# Current canonical App/core delta: actual Swift declaration union with old253.
# No whole-stage acceptance is inferred from these definitions.
CURRENTCORE_ADDITIONAL_CASES = {'SelfRenewalTransactionRetirementTests': ['retiresNeverUploadedCandidateAndCreatesOneBoundedSuccessor', 'preservesLegacyReadyWithUnknownRemoteHistory', 'resumesActualPendingCandidateRemovalWindows', 'retainsCheckpointOnWriteFailureAndCancelledRetirement', 'nextActualPreparationRetiresOnlyProvenUnsubmittedCandidate', 'retiresAuthenticatedCleanupAfterRealUploadInterruptionAndReopen', 'preservesActualSubmittedReceiptAndLookupWithoutAutomaticResubmission'], 'SelfRenewalAppOwnerTests': ['persistsUnconfiguredStatusAndReopensTheSameLocalOwner', 'retainsExistingTransactionWhenSigningMaterialsAreMissing', 'rejectsCorruptLinkedAndOversizedConfigurationWithoutReset', 'validatesRealCertificateInputsAndRejectsMissingAuthenticationHandles', 'preservesCancelledAndFailedConfigurationWrites', 'appOwnerBootstrapsItsSharedHandoffWithoutCreatingSigningCredentials'], 'LegadoCookieTextHostTests': ['rawTextMethodsUseTheExistingFileAndOriginalStringSemantics', 'responseTextPrecedenceAndNativeMetadataSurviveTheirCorrectLifetimes', 'originalRawExpiryAndRandomPruningBoundaryRemainExplicit', 'failedCancelledAndRevokedMutationsKeepOldBytes', 'unsupportedAndMalformedRequestsPreflightTheWholeOperation'], 'LegadoBookMetadataOwnerTests': ['actualBookCallbacksRestoreShelfAndReadingVariables', 'olderQueuedMetadataCannotEraseAcceptedVariables', 'queuedTXTBookmarksKeepOtherBookVariables', 'failedTXTBookmarkWriteKeepsOldMetadata', 'exactTXTJournalRecoversPublicationConflicts', 'failedWritesAndCancellationKeepOldMetadata', 'failedShelfReplacementKeepsBothDurableBookCopies', 'unicodeVariableEditsSurviveMetadataOverlayAndOldCAS', 'unicodeBookURLChangeRevokesOldMetadataIdentity'], 'LegadoPreviewStateOwnerTests': ['explicitBusinessPreviewUsesExistingContextAndRestart', 'previewSourceRevisionAndURLAreExplicit', 'staleCASAndForeignEntityScopesAreRejected', 'failedBusinessKeepsAcceptedVariables', 'changedContextRejectsReturnedSetter', 'explicitRevocationSurvivesContextRestart', 'cancellationPreventsLateContextCommit', 'realContextWriteFailurePreservesPriorRecord', 'corruptOversizedAndLinkedContextsFailBeforeExecution', 'transferUsesExistingOffShelfIdentityAndOriginalFile', 'transferRejectsInventedIdentityAndChangedAppVariables', 'failedAppWriteRetainsTransferIntentAndReopens', 'rawVariableMapsRejectAliasingBeforeDictionaryDecode', 'unicodeHostNamesAndCompartmentProjectionFailClosed', 'transferRequiresExactVariableNamesAndValues'], 'LegadoCookieBrowserHostTests': ['clearKeepsCacheAcrossNewBindingsButFreshOwnerReadsOnlyRemainingRows', 'setWebCookieUsesActualExistingWKStoreAndLeavesRawDBUntouched', 'removeKeepsOtherPathsAndUnrelatedBrowserDomains', 'issuedBrowserEffectsCannotBeRolledBackOrPublishedThroughARevokedGrant', 'clearFailureAndRejectedGrantRetainTheOwnedState'], 'LegadoExploreOwnerTests': ['stableIdentityDoesNotUseTheEphemeralRuntimeGrant', 'scopeStillChecksTheActualGrantAndCannotAuthorizeCacheWrites'], 'SelfRenewalForegroundMaterialRevalidationTests': ['revalidatesActualLeaseBeforeNilAndUnsubmittedReturns', 'revokedUploadRetainsOnlyExistingAuthenticatedRecovery', 'appForegroundExpiresKnownProfileWithoutRereadingApplication', 'appForegroundRevocationKeepsUploadCleanupExplicit', 'preservesTypedKeychainFailureAndForegroundCancellation', 'refusesOwnedApplicationAsCurrentProcessEvidence'], 'LegadoMainJSSourceServiceTests': ['readingChainSurvivesContextReload', 'streamingUsesExplicitEngine', 'runtimeFailureDoesNotFallBack', 'missingContextIsExplicit', 'sourceSignatureRejectsStaleContext', 'recordIntegrityIsChecked', 'largeTOCDoesNotDuplicateBookDTO', 'sessionsAreReusedAndRevised', 'sourceClockHighWaterRejectsDelayedRevision', 'cancellationReleasesSourceGate', 'queuedDeadlineDoesNotDependOnHolderProgress', 'unsupportedFormatsDoNotInvokeJSC', 'oldChapterCacheDoesNotMaskFailure'], 'LegadoPersistentStateHostTests': ['sourceBridgeRemovalPreservesCredentials', 'isolatesSourcesAndPreservesVerbatimValues', 'rejectsStaleSourceLoginAndBindingRevisions', 'commitsSameOwnerAtomicallyAndSkipsUnchangedWrites', 'preservesOldStateWhenOwnerWritesFail', 'reusesLegacyCacheAndPreservesTTL', 'rejectsUnsupportedTransactionsBeforeAnyWrite', 'enforcesCancellationDeadlineAndBoundedLeases', 'preservesExplicitOptionsAndRawLoginPayloads', 'malformedStateInputsHaveTypedErrorsAndRetainProofs'], 'LegadoBookStateOwnerTests': ['hostCommitUsesOriginalChapterFileAndRestart', 'staleTocAndTaskCancellationRejectOldHostProofs', 'rejectsUnmappedIdentityAndUnsupportedTransactions', 'corruptAndUnreadableChapterOwnersRemainErrors', 'hostWriteFailureAndGenerationRevocationPreserveOldState'], 'LegadoCookieReadHostTests': ['actualUnknownWKValuesReachReadCallbackWithoutJarReconstruction', 'actualReadCallbackKeepsOwnerAndFailureBoundaries']}
EXPECTED_CASES["currentcore"] = EXPECTED_CASES["handoffrenewal"] | {
    suite+"/"+method for suite,methods in CURRENTCORE_ADDITIONAL_CASES.items() for method in methods
}
CURRENTCORE_ACCOUNT_CASES = {'SelfRenewalSigningMaterialVaultTests': ['requestsCertificateWithPersistedKeyAndIndependentPublicVerification',
                                          'rejectsStaleRevokedForeignAndMissingCertificateRequestKeys',
                                          'rejectsInvalidCertificateRequestSubjectsAndCancellationWithoutPublication',
                                          'observesPublicationBaselineWithoutGrantingMaterialAuthority'],
 'SelfRenewalDeveloperAccountClientTests': ['submitsRealVaultCSRAndPublishesOnlyVerifiedOriginalIdentity',
                                            'rejectsWrongCertificateKeyBeforeProfileRequests',
                                            'rejectsTamperedRemoteProfilesWithoutChangingPublication',
                                            'invalidatesExpiredOrChangedPortalSession',
                                            'cancellationRetainsRemoteIntentAndPreventsDuplicateIssuance',
                                            'retainsCommittedPublicationWhenAccountFinalizationFails',
                                            'rejectsStaleKeysAndMissingOriginalAppIDsBeforeRemoteMutation',
                                            'rejectsUnsafeResponseEnvelopesAndRedactsCredentialDescriptions',
                                            'erasesStoredCredentialsWithoutMaterialAuthorityAndPreservesIntent',
                                            'appSessionRefreshesTheActualPublishedKeyAndReopensIt',
                                            'appSessionChecksDurableRetirementBeforeAcceptingNewMaterialGeneration',
                                            'appSessionErasesCredentialsAfterExpiryAndRetainsFailedWriteFacts',
                                            'appSessionSerializesHeldEnrollmentAndPreservesCancelledRemoteIntent',
                                            'reconcilesLostCertificateACKWithUniqueActualCandidate',
                                            'excludesBaselineAndPublishedLeafWhenReusingTheKey',
                                            'retainsIntentForAmbiguousMissingAndIncompleteCertificateLists',
                                            'rejectsLegacyCSRBindingAndChangedGenerationWithoutReissue',
                                            'resumesObservedCertificateAndFinalizesItsActualPublicationLocally',
                                            'cancellationDuringCertificateListRetainsUnknownIntent',
                                            'appSessionReconcilesLostCSRAcknowledgementWithoutAnotherIssue',
                                            'appSessionEnrollsAfterRealInstalledAndPublishedProfileExpiry',
                                            'appSessionReconcilesExpiredEnrollmentAndRetainsLogoutDenial',
                                            'appSessionEnrollmentRejectsChangedBundleAndMissingManifest',
                                            'appSessionExpiredEnrollmentRetainsRealUploadIntentBarrier'],
 'SelfRenewalDeveloperAuthenticationTests': ['matchesIndependentPasswordAndAuthenticatedResponseVectors',
                                             'refusesInvalidServerKeysAndWorkBudgets',
                                             'rejectsTamperedProofNegotiationAndTokenEnvelope',
                                             'connectsOnlyThroughActualMaterialAccountValidation',
                                             'rejectsWrongTeamAfterValidGSACryptoWithoutPersistingCredentials',
                                             'submitsTrustedDeviceCodeAndRestartsAuthenticatedHandshake',
                                             'cancellationTerminatesActualLoginAndClearsPendingState',
                                             'refusesUnverifiedCryptoMissingMetadataAndStorageFailure',
                                             'appSessionAuthenticatesThroughSameVaultAndReopensStoredSession',
                                             'appSessionCancelsSecondaryChallengeAndRejectsOldTicket',
                                             'appOwnerDrainsHeldLoginBeforeLogoutAndRejectsLateResult']}
CURRENTCORE_ACCOUNT_SOURCE_PATHS = {
    "SelfRenewalSigningMaterialVaultTests": ("Tests/iOS/yuedu appTests/SelfRenewalSigningMaterialVaultTests.swift",),
    "SelfRenewalDeveloperAccountClientTests": ("Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift", "Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift"),
    "SelfRenewalDeveloperAuthenticationTests": ("Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift",),
}
CURRENTCORE_ACCOUNT_QUALIFIED_CASES = {suite+"/"+method for suite,methods in CURRENTCORE_ACCOUNT_CASES.items() for method in methods}
assert len(EXPECTED_CASES["currentcore"]) == 314  # Preserved prior core definitions, not prior acceptance.
assert len(CURRENTCORE_ACCOUNT_QUALIFIED_CASES) == 39 and not (EXPECTED_CASES["currentcore"] & CURRENTCORE_ACCOUNT_QUALIFIED_CASES)
CURRENTCORE_PUBLIC_CASES = {'ChapterCacheTransactionTests': ['cancellationBetweenRenamesRestoresCompleteOldPackage',
                                  'restorationFailureNeverAcknowledgesOrDeletesBackup',
                                  'foreignWriteAndLateCleanupPreserveNewestFiles',
                                  'unchangedAndReconcileDoNotRewriteOrDeleteNewIdentity',
                                  'legacyReadCannotInstallItsOlderCandidateAfterNewBody'],
 'LegadoContentBatchOwnerTests': ['managerToHostToChapterFilesAndRestartPreservesDuplicateUrlIndexes',
                                  'managerFailureCarriesSavedPrefixWithoutRollingItBack',
                                  'bodyCasCannotOverwriteOrAdoptAnotherWriter',
                                  'bodyOwnerUsesTaskGenerationAndCurrentActualToc',
                                  'finalBookSetterPersistsSmallAndPreservesAcceptedLargeCompanion',
                                  'finalBookCasRejectsUserEditAndFailedIoWithoutLosingBodyPrefix',
                                  'markupCallbackUsesExistingArtifactsAndReopensWithoutRefetch',
                                  'sameBodyUpgradesRenderArtifactsThenKeepsAllBytesUnchanged',
                                  'deferredImageDoesNotBorrowLegacyEngineAndAudioUrlStaysExact'],
 'ChapterFetchLateFailureTests': ['lateBrowserFailureDoesNotDeleteNewSuccessfulPackage']}
CURRENTCORE_PUBLIC_SOURCE_PATHS = {
    suite: ("Tests/iOS/yuedu appTests/"+suite+".swift",) for suite in CURRENTCORE_PUBLIC_CASES
}
CURRENTCORE_PUBLIC_QUALIFIED_CASES = {suite+"/"+method for suite,methods in CURRENTCORE_PUBLIC_CASES.items() for method in methods}
assert len(CURRENTCORE_PUBLIC_QUALIFIED_CASES) == 15
assert not ((EXPECTED_CASES["currentcore"] | CURRENTCORE_ACCOUNT_QUALIFIED_CASES) & CURRENTCORE_PUBLIC_QUALIFIED_CASES)
# Selected existing media regressions exercise the unchanged default-nil option
# path; this does not select the live-network test or either entire media suite.
CURRENTCORE_RENDERER_REGRESSION_CASES = {
    "OnlineChapterImageHeaderTests": ["perImageHeadersSurviveSanitizing", "plainSourcesAreUntouched"],
    "OnlineInlineVideoTests": ["singleQuotedOptionHeaders", "optionWithoutHeadersIsDropped", "mediaOnlyChapterIsNotEmpty"],
}
CURRENTCORE_RENDERER_SOURCE_PATHS = {suite: ("Tests/iOS/yuedu appTests/"+suite+".swift",)
    for suite in CURRENTCORE_RENDERER_REGRESSION_CASES}
CURRENTCORE_RENDERER_QUALIFIED_CASES = {suite+"/"+method
    for suite,methods in CURRENTCORE_RENDERER_REGRESSION_CASES.items() for method in methods}
assert len(CURRENTCORE_RENDERER_QUALIFIED_CASES) == 5
assert not ((EXPECTED_CASES["currentcore"] | CURRENTCORE_ACCOUNT_QUALIFIED_CASES |
    CURRENTCORE_PUBLIC_QUALIFIED_CASES) & CURRENTCORE_RENDERER_QUALIFIED_CASES)
CURRENTCORE_NEW_QUALIFIED_CASES = (CURRENTCORE_ACCOUNT_QUALIFIED_CASES | CURRENTCORE_PUBLIC_QUALIFIED_CASES |
    CURRENTCORE_RENDERER_QUALIFIED_CASES)
CURRENTCORE_NEW_SOURCE_PATHS = (CURRENTCORE_ACCOUNT_SOURCE_PATHS | CURRENTCORE_PUBLIC_SOURCE_PATHS |
    CURRENTCORE_RENDERER_SOURCE_PATHS)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_NEW_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 373  # Retained source boundary; not prior acceptance.

# Later production owners extend currentcore only. Historical modes retain
# their exact selections, parameter identities, SDK requirement and budgets.
CURRENTCORE_LIVE_CASES = {'SelfRenewalAppExecutionTests': ('appOwnerPreparesAndSubmitsActualCandidateWithoutAutomaticRetry',
                                  'appSubmissionKeepsUploadIntentWhenActualSourceSaveFails',
                                  'appSessionCancellationDrainsActualTransportAndKeepsCandidate',
                                  'appOwnerRevokesFailedFreshSigningProofAndKeepsActualCandidate'),
 'SelfRenewalAutomaticRenewalTests': ('capturesActualCurrentBundleAndRejectsChangedSignedResources',
                                      'persistsOptInThrottleAndClockRollbackWithoutRemoteWork',
                                      'performsFullActualAutomaticRenewalAndNeverRepostsAReceipt',
                                      'cancellationDrainsActualAutomaticTransportAndPersistsInterruption'),
 'SelfRenewalRealBundleBoundsTests': ('distinguishesShippedJavaClassHeaderWithoutFilenameBypass',
                                      'inventoriesSeventeenThousandClassResourcesWithinHardBounds',
                                      'reopensOwnedDirectoriesWithoutHoldingOneDescriptorPerDirectory',
                                      'rejectsReboundDirectoryAndPreservesUnrelatedReplacementBytes',
                                      'streamsStoredArchiveOnceAndUsesExactMetadataBudget',
                                      'rejectsTruncatedStoredProviderAndCleansStaging'),
 'SelfRenewalRealResourceEnvelopeTests': ('verifiesJavaSizedXMLAndRejectsChangedClassDigest',),
 'SelfRenewalAnisetteV3ProviderTests': ('persistsSuccessBeforeHeadersAndReopensWithoutProvisioning',
                                        'interruptedProvisioningRequiresExplicitRecovery',
                                        'rejectedRegistrationNeverReprovisions',
                                        'failedSuccessSaveRetainsUnknownIntent',
                                        'resetsUnknownRegistrationAndReusesTheSameNewIdentity',
                                        'confirmsCredentialRemovalBeforeRegistrationResetCanProceed',
                                        'endpointSelectionIsLocalAndBackwardCompatible',
                                        'realTransportSeparatesProviderAndAppleRequests'),
 'SelfRenewalPairingIdentityImportTests': ('realIdentityReadBackAndBoundedRejections',
                                           'sameSessionReopenFailureAndActiveTransaction',
                                           'lostAcknowledgementRetainsBothRealIdentitiesAndRetrySelector'),
 'LegadoOriginalExploreLifecycleTests': ('pauseVisitsEveryOpenedSourceAndRetainsIndividualFailure',
                                         'pauseRejectsChangedSourceWithoutGrantingUnopenedContext',
                                         'cancelledPauseDrainsBeforeItReturns'),
 'SelfRenewalDeveloperAccountClientTests': ('appSessionInitialEnrollmentCreatesNamespaceAndPublishesRealMaterials',
                                            'appSessionInitialEnrollmentReconcilesItsActualUnknownCSR',
                                            'appSessionInitialEnrollmentReusesKeyAfterPreCSRFailure',
                                            'appSessionInitialBindingReopensExactNamespaceAfterFinalWriteFailure',
                                            'appSessionInitialBindingLockedReadNeverCreatesAndOwnerPreservesClassification',
                                            'appSessionInitialBindingLostAckSurvivesRenewalFailure'),
 'ChapterRetryLogTests': ('countsArePerChapter',
                          'successClearsHistory',
                          'successIsScoped',
                          'loopingChapterEscalatesOnce',
                          'escalationRearmsAfterSuccess',
                          'trackingIsBounded',
                          'nilBookIdIsItsOwnBucket',
                          'paginationRecoveryIsOwnerScoped',
                          'paginationLoopStillEscalates'),
 'ReaderChapterSupplyTests': ('completedPaginationAnnouncesChapter',
                              'joiningAbandonedPaginationRetries',
                              'sharedPaginationRecoveryClearsOnlyLayoutRetries',
                              'reopenedEngineStartsItsOwnRetryRun',
                              'readyCallbackDoesNotLoseNewerRetryHistory',
                              'unavailableChapterDoesNotLoop',
                              'laidOutChapterReportsLaidOut',
                              'missingContentReportsContentUnavailable',
                              'outOfRangeChapterReportsOutOfRange',
                              'supersededChapterReportsSuperseded',
                              'unresolvedChapterNotifiesTheView',
                              'distantDestinationSurvivesFullLayoutCache',
                              'reverseJumpKeepsLatestDestination',
                              'availabilityPreservesInstalledDocument',
                              'availabilityJoinsExistingDocumentBuild',
                              'replacementStillInvalidatesOldDocument')}
CURRENTCORE_LIVE_SOURCE_PATHS = {'SelfRenewalAppExecutionTests': ('Tests/iOS/yuedu appTests/SelfRenewalAppExecutionTests.swift',),
 'SelfRenewalAutomaticRenewalTests': ('Tests/iOS/yuedu '
                                      'appTests/SelfRenewalAutomaticRenewalTests.swift',),
 'SelfRenewalRealBundleBoundsTests': ('Tests/iOS/yuedu '
                                      'appTests/SelfRenewalRealBundleBoundsTests.swift',),
 'SelfRenewalRealResourceEnvelopeTests': ('Tests/iOS/yuedu '
                                          'appTests/SelfRenewalRealResourceEnvelopeTests.swift',),
 'SelfRenewalAnisetteV3ProviderTests': ('Tests/iOS/yuedu '
                                        'appTests/SelfRenewalAnisetteV3ProviderTests.swift',),
 'SelfRenewalPairingIdentityImportTests': ('Tests/iOS/yuedu '
                                           'appTests/SelfRenewalPairingIdentityImportTests.swift',),
 'LegadoOriginalExploreLifecycleTests': ('Tests/iOS/yuedu '
                                         'appTests/LegadoOriginalExploreLifecycleTests.swift',),
 'SelfRenewalDeveloperAccountClientTests': ('Tests/iOS/yuedu '
                                            'appTests/SelfRenewalAccountSessionTests.swift',),
 'ChapterRetryLogTests': ('Tests/iOS/yuedu appTests/ChapterRetryLogTests.swift',),
 'ReaderChapterSupplyTests': ('Tests/iOS/yuedu appTests/ReaderChapterSupplyTests.swift',)}
CURRENTCORE_LIVE_QUALIFIED_CASES = {suite + "/" + method
    for suite, methods in CURRENTCORE_LIVE_CASES.items() for method in methods}
assert len(CURRENTCORE_LIVE_QUALIFIED_CASES) == 60
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_LIVE_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_LIVE_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 433

# The glyph checkpoint selects only its four new methods and seven named regressions.
CURRENTCORE_GLYPH_CASES = {'CoreTextPagedScrollAppearanceTests': ('tallerPagePreservesGlyphPixelsAndSelection',
                                        'pageGeometryPreservesAspectAndRoundTrips',
                                        'resizedLivePageRedrawsWithoutStretching',
                                        'authoredCompositionMatchesScroll'),
 'ReaderViewportSizeObserverHostingTests': ('testFullBleedProbeMatchesReaderSurfaceWithSafeAreaInsets',
                                            'testBackgroundMeasuresReaderSurfaceInsteadOfWindowAndReportsResize'),
 'ReaderPageTurnSmoothnessTests': ('prefetchedPageIsShownWithoutDrawing',),
 'ReaderPageSnapshotPerformanceTests': ('resizedLayoutInvalidatesSnapshots',),
 'ReaderPresentationContractTests': ('curlBackMirrorsRenderedPageMaterial',),
 'CoreTextWritingModeTests': ('verticalPaginationStoresWritingModeAndVerticalGlyphAttribute',
                              'verticalLatinRangesLieOnTheirSideCentred')}
CURRENTCORE_GLYPH_SOURCE_PATHS = {'CoreTextPagedScrollAppearanceTests': ('Tests/iOS/yuedu '
                                        'appTests/CoreTextPagedScrollAppearanceTests.swift',),
 'ReaderViewportSizeObserverHostingTests': ('Tests/iOS/yuedu '
                                            'appTests/ReaderViewportSizeObserverTests.swift',),
 'ReaderPageTurnSmoothnessTests': ('Tests/iOS/yuedu appTests/ReaderPageTurnSmoothnessTests.swift',),
 'ReaderPageSnapshotPerformanceTests': ('Tests/iOS/yuedu '
                                        'appTests/ReaderPageSnapshotPerformanceTests.swift',),
 'ReaderPresentationContractTests': ('Tests/iOS/yuedu appTests/ReaderPresentationContractTests.swift',),
 'CoreTextWritingModeTests': ('Tests/iOS/yuedu appTests/CoreTextWritingModeTests.swift',)}
CURRENTCORE_GLYPH_QUALIFIED_CASES = {suite + "/" + method
    for suite, methods in CURRENTCORE_GLYPH_CASES.items() for method in methods}
assert len(CURRENTCORE_GLYPH_QUALIFIED_CASES) == 11
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_GLYPH_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_GLYPH_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 444  # Preserve the preceding checkpoint.

# Raw source login-info adds three declarations to the existing App suite.
# Cookie-owner fixture changes and the separate JNI selectors add no App leaves.
CURRENTCORE_SOURCE_LOGIN_CASES = {'LegadoPersistentStateHostTests': ('rawLoginInfoUsesCredentialOwnerAndSurvivesReopen', 'rawLoginInfoRejectsFailedWritesAndCancelledMutations', 'rawLoginInfoMigratesLegacyAndClaimsCommitBeforeMutation')}
CURRENTCORE_SOURCE_LOGIN_QUALIFIED_CASES = {suite + "/" + method
    for suite, methods in CURRENTCORE_SOURCE_LOGIN_CASES.items() for method in methods}
assert len(CURRENTCORE_SOURCE_LOGIN_QUALIFIED_CASES) == 3
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_SOURCE_LOGIN_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_SOURCE_LOGIN_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 447  # Preserve the preceding source checkpoint.
CURRENTCORE_MATERIAL_REFRESH_CASES = {'SelfRenewalDeveloperAccountClientTests': ('appOwnerInitialMaterialPublicationConnectsWithoutLifecycleRestart', 'appSessionMaterialReconnectRejectsChangedCurrentBundleAndKeepsPublication', 'appSessionCancelledPostPublicationReconnectRetainsItsActualReceipt', 'appOwnerMaterialFinalizationConnectsWithoutRepeatedEnrollment')}
CURRENTCORE_MATERIAL_REFRESH_QUALIFIED_CASES = {suite + "/" + method
    for suite, methods in CURRENTCORE_MATERIAL_REFRESH_CASES.items() for method in methods}
assert len(CURRENTCORE_MATERIAL_REFRESH_QUALIFIED_CASES) == 4
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_MATERIAL_REFRESH_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_MATERIAL_REFRESH_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 451
# The traditional form caller changes this existing regression's behavior.
CURRENTCORE_LOGIN_ACTION_REGRESSION_CASES = {"BookSourceLoginTests": ("blankLoginFieldIsRequired",)}
CURRENTCORE_LOGIN_ACTION_REGRESSION_QUALIFIED_CASES = {suite + "/" + method
    for suite, methods in CURRENTCORE_LOGIN_ACTION_REGRESSION_CASES.items() for method in methods}
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_LOGIN_ACTION_REGRESSION_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_LOGIN_ACTION_REGRESSION_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 452  # Preserve the preceding source checkpoint.
CURRENTCORE_EXPLORE_LIFECYCLE_CASES = {'DiscoverViewModelReloadTests': ('failedContextOpenDoesNotPublishCachedCategories', 'cachedCategoriesBuildThePage', 'reloadStartsSectionsAnew', 'exploreOffGivesAnEmptyPage'), 'LegadoOriginalExploreLifecycleTests': ('pagePauseDrainsCategoryLoadBeforeReentry', 'failedPagePauseRetainsPendingUntilNextPageLifetime', 'pagePauseRejectsEditedSourceBeforeSaving')}
CURRENTCORE_EXPLORE_LIFECYCLE_QUALIFIED_CASES = {suite + "/" + method
    for suite, methods in CURRENTCORE_EXPLORE_LIFECYCLE_CASES.items() for method in methods}
assert len(CURRENTCORE_EXPLORE_LIFECYCLE_QUALIFIED_CASES) == 7
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_EXPLORE_LIFECYCLE_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_EXPLORE_LIFECYCLE_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 459

CURRENTCORE_FOREGROUND_LIFECYCLE_CASES = {
    'SelfRenewalAppOwnerTests': (
        'startupBootstrapCannotLaunchAfterBackground',
        'latestActivationWaitsForBootstrapAndRunsOnce',
        'backgroundGrantUsesSameWorkerAndSurvivesSceneCleanup',
        'cancelledForegroundBootstrapCannotCreateWorker',
    ),
}
CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES = {suite + '/' + method
    for suite, methods in CURRENTCORE_FOREGROUND_LIFECYCLE_CASES.items() for method in methods}
assert len(CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES) == 4
assert not (EXPECTED_CASES['currentcore'] & CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES)
EXPECTED_CASES['currentcore'] |= CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES
assert len(EXPECTED_CASES['currentcore']) == 463

CURRENTCORE_CERTIFICATE_PREUPDATE_CASES = {'SelfRenewalDeveloperAccountClientTests': ('reusesPublishedCertificateAcrossProfileExpiryWithoutAnotherCSR', 'expiredCertificateUsesExistingIssuanceAndReconciliationPath', 'refusesUnextendedOrTamperedProfilesWithoutCertificateChurn', 'heldReuseRejectsCancellationAndRevokedGenerationWithoutIssuance'), 'LegadoPreviewStateOwnerTests': ('preUpdateIdentityGrantRequiresTaskTOCAndOptIn', 'preUpdateIdentityRefreshRejectsStaleEntityAndTOCLeases', 'preUpdateSuccessfulTOCReopensSameRecordWithoutOldURLState', 'preUpdateFailureAndCancellationKeepOldContextUsable')}
CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES = {suite + "/" + method
    for suite, methods in CURRENTCORE_CERTIFICATE_PREUPDATE_CASES.items() for method in methods}
assert len(CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES) == 8
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 471

CURRENTCORE_FIRST_REGISTRATION_CASES = {'SelfRenewalDeveloperAccountClientTests': ('registersOriginalPortalScopeAndReusesObservedRemoteIdentity', 'registrationFailuresRetainScopeAndAcceptedFactsBeforeCSR', 'appSessionRegistersOnlyItsConfiguredPairedTargetBeforeFirstProfiles'), 'SelfRenewalAuthenticatedInstallationClientTests': ('registrationDeviceObservationUsesAuthenticatedSessionAndExpiresAtStop',)}
CURRENTCORE_FIRST_REGISTRATION_QUALIFIED_CASES = {suite + "/" + method for suite, methods in CURRENTCORE_FIRST_REGISTRATION_CASES.items() for method in methods}
assert len(CURRENTCORE_FIRST_REGISTRATION_QUALIFIED_CASES) == 4
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_FIRST_REGISTRATION_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_FIRST_REGISTRATION_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 475

# Later observed-installation and resumed-ready tests extend currentcore only.
CURRENTCORE_S5_READINESS_CASES = {'SelfRenewalAutomaticRenewalTests': ('resumedReadyCandidateRequiresExpiryAdvanceAndReadableCurrentApplication',), 'SelfRenewalTransactionRetirementTests': ('retiresPersistedObservedAdmissionAcrossCrashWindowsAndCreatesSuccessor', 'refusesIncompleteOrMixedObservedAdmissionWithoutMutation', 'sealsActualReportedCompleteCleanupWithoutPromotingLookup')}
CURRENTCORE_S5_READINESS_SOURCE_PATHS = {'SelfRenewalAutomaticRenewalTests': 'Tests/iOS/yuedu appTests/SelfRenewalAutomaticRenewalTests.swift', 'SelfRenewalTransactionRetirementTests': 'Tests/iOS/yuedu appTests/SelfRenewalTransactionRetirementTests.swift'}
CURRENTCORE_S5_READINESS_QUALIFIED_CASES = {suite + "/" + method
    for suite, methods in CURRENTCORE_S5_READINESS_CASES.items() for method in methods}
assert len(CURRENTCORE_S5_READINESS_QUALIFIED_CASES) == 4
assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_S5_READINESS_QUALIFIED_CASES)
EXPECTED_CASES["currentcore"] |= CURRENTCORE_S5_READINESS_QUALIFIED_CASES
assert len(EXPECTED_CASES["currentcore"]) == 479

PARAMETER_MODES = ("transactionrenewal", "handoffrenewal", "currentcore")
SDK_MODES = ("integratedrenewal", "transactionrenewal", "handoffrenewal", "currentcore")

CURRENTCORE_GLYPH_PARAMETER_CASES = {
    "CoreTextPagedScrollAppearanceTests/authoredCompositionMatchesScroll": "nestedBackdrop",
}

def parameter_cases(group):
    if group not in PARAMETER_MODES: return {}
    return PARAMETER_CASES | CURRENTCORE_GLYPH_PARAMETER_CASES if group == "currentcore" else PARAMETER_CASES

def expected_leaf_count(group):
    return len(EXPECTED_CASES[group]) + len(parameter_cases(group))


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
    "transactionrenewal": ("transactionrenewal",),
    "handoffrenewal": ("handoffrenewal",),
    "currentcore": ("currentcore",),
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
    'scripts/reader-experience/owned-package-fixture/OwnedIdentitySearch.h',
    'scripts/reader-experience/owned-package-fixture/OwnedIdentitySearch.c',
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

SOURCE_INPUTS += ('Modules/Services/SelfRenewal/SelfRenewalTransactionJournal.swift', 'Modules/Services/SelfRenewal/SelfRenewalControlledRenewalCoordinator.swift', 'Modules/Services/SelfRenewal/SelfRenewalInstallationRecovery.swift', 'Tests/iOS/yuedu appTests/SelfRenewalTransactionJournalTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalControlledRenewalCoordinatorTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalInstallationRecoveryTests.swift', 'Tests/iOS/yuedu appTests/LegadoBookMetadataOwnerTests.swift', 'Tests/iOS/yuedu appTests/BookStoreShelfRecoveryTests.swift', 'Tests/iOS/yuedu appTests/BookStoreMetadataWriteBudgetTests.swift', 'Tests/iOS/yuedu appTests/BookStoreBackgroundPublishTests.swift', 'Tests/iOS/yuedu appTests/TXTReaderIndexMigrationTests.swift', 'Tests/iOS/yuedu appTests/AozoraTXTTests.swift', 'Tests/iOS/yuedu appTests/WebDAVRestoreIntegrityTests.swift', 'Modules/Services/LibraryStore/OriginalRuntimeBookMetadataOwner.swift', 'Modules/Services/LibraryStore/BackgroundTaskHold.swift', 'Modules/Core/TXT/TXTReaderIndexMigrationService.swift', 'Modules/Core/TXT/TXTReaderPreparationService.swift', 'Modules/Core/TXT/TXTLocationMigration.swift', 'Modules/Core/TXT/TXTChapterParser.swift', 'Modules/Core/ReaderCore/ReadingPositionStore.swift', 'Modules/Core/ReaderCore/CoreText/CoreTextReadingPosition.swift', 'Modules/Services/WebDAV/WebDAVRestoreTransaction.swift', 'Modules/Services/WebDAV/WebDAVManager.swift')

SOURCE_INPUTS += ("scripts/reader-experience/owned-package-fixture/test-producer-diagnostics.py",)


SOURCE_INPUTS += ('Modules/Core/BookSource/BookSourceStore.swift', 'Modules/Core/BookSource/BuiltInBookSourceBootstrap.swift', 'Modules/Core/ReaderCore/ReaderNavigator.swift', 'Modules/Features/Reader/ReaderView.swift', 'Modules/Services/SelfRenewal/SelfRenewalInstalledMaterialObserver.swift', 'Modules/Services/SelfRenewal/SelfRenewalUserDataHandoff.swift', 'Targets/Yuedu/SharedApp/yuedu_appApp.swift', 'Tests/iOS/yuedu appTests/SelfRenewalInstalledMaterialObserverTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalUserDataHandoffTests.swift', 'Tests/iOS/yuedu appTests/BookStoreMetadataHandoffTests.swift', 'Tests/iOS/yuedu appTests/BookSourceStoreHandoffTests.swift', 'Tests/iOS/yuedu appTests/ReadingPositionStorePersistenceTests.swift', 'Tests/iOS/yuedu appTests/ReadingPositionWriteOrderingTests.swift', 'Tests/iOS/yuedu appTests/BookSourceStoreTests.swift', 'Tests/iOS/yuedu appTests/BuiltInBookSourcesTests.swift', 'scripts/reader-experience/owned-package-fixture/test-producer-timeouts.py')

SOURCE_INPUTS += tuple(path for path in ('Modules/Core/RuleEngine/ModernParser/CookiePersistenceOwner.swift', 'Modules/Core/RuleEngine/ModernParser/CookieStore.swift', 'Modules/Core/RuleEngine/ModernParser/JS/JSCoreEngine.swift', 'Modules/Core/RuleEngine/ModernParser/JS/LegadoHeadlessWebView.swift', 'Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift', 'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift', 'Modules/Core/RuleEngine/ModernParser/ModernParserBridge.swift', 'Modules/Features/BookSource/BookSourceFormLoginView.swift', 'Modules/Features/BookSource/JsBridgeBrowserView.swift', 'Modules/Features/Reader/ReaderView+Toolbars.swift', 'Modules/Features/WebBrowser/BrowserView.swift', 'Modules/Services/Network/CookieStore+HTTP.swift', 'Modules/Services/Network/CookieStore+WebKit.swift', 'Modules/Services/Network/WebFetcher.swift', 'Modules/Services/Network/WebViewCookieMirror.swift', 'Modules/Services/Network/WebViewFetcher.swift', 'Modules/Services/Online/LegadoReviewActionRunner.swift', 'Modules/SharedUI/Components/SourceLoginWebView.swift', 'Tests/iOS/yuedu appTests/LegadoCookieOwnerTests.swift', 'Tests/iOS/yuedu appTests/SourceBrowserAuthenticationTests.swift', 'Tests/iOS/yuedu appTests/WebFetcherPersistedCookieTests.swift', 'Tests/iOS/yuedu appTests/WebFetcherChallengeResponseTests.swift', 'Tests/iOS/yuedu appTests/StageLoginCheckTests.swift', 'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift', 'Tests/iOS/yuedu appTests/ModernParserTests.swift', 'Tests/iOS/yuedu appTests/WebViewNavigationWaitTests.swift') if path not in SOURCE_INPUTS)

assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS))

def validate_tag():
    selection_mode()
    return smoke.validate_tag(TAG_PREFIX)

SOURCE_INPUTS += ("Tests/iOS/yuedu appTests/LegadoCookieReadHostTests.swift",)
SOURCE_INPUTS += ('Modules/Core/BookSource/BookSourceFetcher+OriginalPreview.swift', 'Modules/Services/Online/LegadoPreviewStateOwner.swift', 'Modules/Services/SelfRenewal/SelfRenewalAppOwner.swift', 'Modules/Services/SelfRenewal/SelfRenewalAppSession.swift', 'Packages/LegadoRuntime/Package.swift', 'Packages/LegadoRuntime/Sources/CLegadoJNI/LegadoJNI.m', 'Packages/LegadoRuntime/Sources/CLegadoJNI/include/LegadoJNI.h', 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoHTTPHeaders.swift', 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoPlatformHost.swift', 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoSavedDiagnostics.swift', 'Packages/LegadoRuntime/Sources/LegadoRuntime/NativeLegadoTransport.swift', 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoCookieTextAPITests.swift', 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoExploreAPITests.swift', 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoHTTPHeadersTests.swift', 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoHostEffectsTests.swift', 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift', 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoRuntimeTests.swift', 'Tests/iOS/yuedu appTests/LegadoCookieBrowserHostTests.swift', 'Tests/iOS/yuedu appTests/LegadoCookieTextHostTests.swift', 'Tests/iOS/yuedu appTests/LegadoExploreOwnerTests.swift', 'Tests/iOS/yuedu appTests/LegadoMainJSSourceServiceTests.swift', 'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalAppOwnerTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalForegroundMaterialRevalidationTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalTransactionRetirementTests.swift', 'scripts/reader-experience/original-api-package-tests.sh', 'scripts/reader-experience/original-api-package-tools.py', 'scripts/reader-experience/test-original-api-package-tools.py')
SOURCE_INPUTS += ('Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountClient.swift', 'Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountTransport.swift', 'Modules/Services/SelfRenewal/SelfRenewalGSASRP.swift', 'Modules/Services/SelfRenewal/SelfRenewalDeveloperAuthentication.swift', 'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift')
CURRENTCORE_PUBLIC_SOURCE_INPUTS = ('Modules/Core/BookSource/BookSourceFetcher+Chapter.swift',
 'Modules/Core/BookSource/BookSourceFetcher+ChapterCache.swift',
 'Modules/Core/BookSource/BookSourceFetcher.swift',
 'Modules/Features/Settings/CacheManagementView.swift',
 'Modules/Services/LibraryStore/BookChapterStore.swift',
 'Modules/Services/LibraryStore/BookStore.swift',
 'Modules/Services/LibraryStore/CacheManagementService.swift',
 'Modules/Services/LibraryStore/Models.swift',
 'Modules/Services/Offline/OfflineChapterStore.swift',
 'Modules/Services/Online/ChapterCacheRepository.swift',
 'Modules/Services/Online/LegadoBookStateOwner.swift',
 'Modules/Services/Online/LegadoContentBatchOwner.swift',
 'Modules/Services/Online/LegadoMainJSSourceService.swift',
 'Modules/Services/Online/LegadoPersistentStateHost.swift',
 'Modules/Services/Online/LegadoPreviewStateOwner.swift',
 'Modules/Services/Online/OnlineChapterContentService.swift',
 'Modules/Services/Online/OnlineReadingPipeline.swift',
 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift',
 'Tests/iOS/yuedu appTests/CachedBookTXTExportTests.swift',
 'Tests/iOS/yuedu appTests/CacheManagementServiceTests.swift',
 'Tests/iOS/yuedu appTests/ChapterCacheMigrationTests.swift',
 'Tests/iOS/yuedu appTests/ChapterCacheRepositoryWriteTests.swift',
 'Tests/iOS/yuedu appTests/ChapterCacheTransactionTests.swift',
 'Tests/iOS/yuedu appTests/ChapterContentValidationTests.swift',
 'Tests/iOS/yuedu appTests/ChapterFetchLateFailureTests.swift',
 'Tests/iOS/yuedu appTests/LegadoChapterOwnerPersistenceTests.swift',
 'Tests/iOS/yuedu appTests/LegadoContentBatchOwnerTests.swift',
 'Tests/iOS/yuedu appTests/ModernChapterCacheScenarioTests.swift',
 'Tests/iOS/yuedu appTests/OfflineChapterStoreTests.swift',
 'Tests/iOS/yuedu appTests/yuedu_appTests.swift')
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_PUBLIC_SOURCE_INPUTS if path not in SOURCE_INPUTS)
CURRENTCORE_TRUST_GUARD_SOURCE = SDK_TOOL_ROOT + "test-producer-user-trust.py"
SOURCE_INPUTS += (CURRENTCORE_TRUST_GUARD_SOURCE,)
# The five changed render owners are already bound except these two helpers.
# Bind their retained reader consumers plus only the two newly selected suites.
CURRENTCORE_RENDERER_SOURCE_INPUTS = (
    "Modules/Core/ReaderCore/OnlineImageRequestOptions.swift",
    "Modules/Core/ReaderCore/ReaderHTMLUtilities.swift",
    "Modules/Core/TTS/TTSAudioProvider.swift",
    "Modules/Core/ReaderCore/CoreText/OnlineProviderAttributedStringBuilder.swift",
    "Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift",
    "Tests/iOS/yuedu appTests/OnlineChapterImageHeaderTests.swift",
    "Tests/iOS/yuedu appTests/OnlineInlineVideoTests.swift",
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_RENDERER_SOURCE_INPUTS if path not in SOURCE_INPUTS)
CURRENTCORE_HEALTH_CONFORMANCE_SOURCE = "Modules/Core/BookSource/BookSourceHealthChecker.swift"
SOURCE_INPUTS += (CURRENTCORE_HEALTH_CONFORMANCE_SOURCE,)
# The filesystem-synchronized App test target compiles this real JNI fixture
# even though currentcore does not select its JNI cases (native-reader does).
CURRENTCORE_NATIVE_READER_COMPILE_SOURCE = "Tests/iOS/LegadoNativeOriginalReaderTests.swift"
SOURCE_INPUTS += (CURRENTCORE_NATIVE_READER_COMPILE_SOURCE,)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 241  # Preserved prior input roster.
CURRENTCORE_LIVE_SOURCE_INPUTS = ('Tests/iOS/yuedu appTests/SelfRenewalAppExecutionTests.swift',
 'Modules/Features/Settings/SelfRenewalSettingsView.swift',
 'Modules/Services/SelfRenewal/SelfRenewalBackgroundTaskBridge.swift',
 'Modules/Services/RSS/RSSNotificationManager.swift',
 'Tests/iOS/yuedu appTests/SelfRenewalAutomaticRenewalTests.swift',
 'Tests/iOS/yuedu appTests/SelfRenewalRealBundleBoundsTests.swift',
 'Tests/iOS/yuedu appTests/SelfRenewalRealResourceEnvelopeTests.swift',
 'Modules/Core/BookSource/BookSourceFetcher+Search.swift',
 'Modules/Core/BookSource/BookSourceFetcher+BookInfo.swift',
 'Modules/Core/BookSource/BookSourceFetcher+TOC.swift',
 'Modules/Core/BookSource/BookSourceFetcher+Discover.swift',
 'Modules/Services/Online/DiscoverQuickActions.swift',
 'Modules/Features/BookDetail/OnlineBookView.swift',
 'Modules/Services/SelfRenewal/SelfRenewalAnisetteV3Provider.swift',
 'Modules/Services/SelfRenewal/SelfRenewalPairingIdentityImport.swift',
 'Tests/iOS/yuedu appTests/SelfRenewalAnisetteV3ProviderTests.swift',
 'Tests/iOS/yuedu appTests/SelfRenewalPairingIdentityImportTests.swift',
 'Tests/iOS/yuedu appTests/SelfRenewalPairingOwnedPKCS12Fixture.swift',
 'Tests/iOS/yuedu appTests/LegadoOriginalExploreLifecycleTests.swift',
 'Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift',
 'Modules/Services/Diagnostics/ChapterRetryLog.swift',
 'Tests/iOS/yuedu appTests/ChapterRetryLogTests.swift',
 'Tests/iOS/yuedu appTests/ReaderChapterSupplyTests.swift',
 'Tests/iOS/yuedu appTests/CoverImagePipelineTests.swift',
 'Modules/Services/Diagnostics/DiagnosticLog.swift',
 'Targets/Yuedu/SharedApp/AppLogger.swift',
 'Modules/Core/ReaderCore/CoreText/CharOffsetStore.swift',
 'Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift',
 'Modules/Core/ReaderCore/CoreText/AttributedStringBuilding.swift',
 'Modules/Core/ReaderCore/ReaderChapterPresentation.swift',
 'Modules/Features/BookDetail/AudiobookDetailView.swift',
 'Modules/Features/Reader/ReaderView+SourceCallBack.swift',
 'Modules/Features/Reader/TTS/AudiobookView.swift',
 'Modules/Services/Online/SourceCallBackService.swift',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalRuleDto.kt',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalBookCallbackTest.kt',
 'Modules/Core/ReaderCore/CoreText/CoreTextPageView.swift',
 'Tests/iOS/yuedu appTests/CoreTextPagedScrollAppearanceTests.swift',
 'Tests/iOS/yuedu appTests/ReaderPresentationContractTests.swift',
 'Tests/iOS/yuedu appTests/ReaderViewportSizeObserverTests.swift',
 'Tests/iOS/yuedu appTests/ReaderPageTurnSmoothnessTests.swift',
 'Tests/iOS/yuedu appTests/ReaderPageSnapshotPerformanceTests.swift',
 'Tests/iOS/yuedu appTests/CoreTextWritingModeTests.swift',
 'Modules/Features/Reader/ReaderViewportSizeObserver.swift',
 'Tests/iOS/yuedu appTests/EPUBTestFixtures.swift')
assert not (set(SOURCE_INPUTS) & set(CURRENTCORE_LIVE_SOURCE_INPUTS))
SOURCE_INPUTS += CURRENTCORE_LIVE_SOURCE_INPUTS
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 288
# Bind the actual integrated shelf-refresh and raw-login production/fixture closure.
CURRENTCORE_SOURCE_STATE_INPUTS = ('Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift', 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt', 'Modules/Services/Online/LegadoPreviewStateOwner.swift', 'Modules/Services/Online/LegadoMainJSSourceService.swift', 'Modules/Services/Online/LegadoPersistentStateHost.swift', 'Modules/Services/Online/SourceCallBackService.swift', 'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift', 'Tests/iOS/LegadoNativeOriginalReaderTests.swift', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceCallbackTest.kt', 'Packages/LegadoRuntime/vendor/original-rule/manifest.json', 'Modules/Core/RuleEngine/ModernParser/Login/KeychainHelper.swift', 'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginInfoTest.kt', 'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift', 'Tests/iOS/yuedu appTests/LegadoCookieOwnerTests.swift', 'Tests/iOS/yuedu appTests/LegadoPersistentStateHostTests.swift')
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_SOURCE_STATE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 294
# Future raw-login Map/defaults changes do not add App test definitions.
CURRENTCORE_LOGIN_MAP_INPUTS = (
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/BaseSource.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/rule/FlexChildStyle.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/rule/RowUi.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalWebBookSession.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/LockedLoginMapReference.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginMapTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Packages/LegadoRuntime/vendor/original-rule/sources/data/entities/rule/FlexChildStyle.kt',
    'Packages/LegadoRuntime/vendor/original-rule/sources/data/entities/rule/RowUi.kt',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_LOGIN_MAP_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 302
# One reviewed login-action/material-publication production and fixture closure.
CURRENTCORE_LOGIN_ACTION_MATERIAL_INPUTS = (
    'Modules/Services/SelfRenewal/SelfRenewalAppSession.swift',
    'Modules/Services/SelfRenewal/SelfRenewalAppOwner.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift',
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeRule.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeUrl.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleCompat.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceFormLoginTest.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_LOGIN_ACTION_MATERIAL_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 308
# Reviewed login-UI and exploration-page production/fixture/owner closure.
CURRENTCORE_LOGIN_UI_EXPLORE_INPUTS = (
    'Modules/Core/RuleEngine/ModernParser/Login/LoginFieldStyle.swift',
    'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift',
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoOriginalLoginUIForm.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUITest.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
    'Modules/Services/Online/DiscoverViewModel.swift',
    'Modules/Services/Online/DiscoverQuickActions.swift',
    'Modules/Features/Explore/ExploreSourcePage.swift',
    'Tests/iOS/yuedu appTests/DiscoverViewModelReloadTests.swift',
    'Tests/iOS/yuedu appTests/LegadoOriginalExploreLifecycleTests.swift',
    'Tests/iOS/LegadoNativeOriginalReaderTests.swift',
    'Modules/Services/Online/DiscoverKindsCache.swift',
    'Modules/Services/Online/ExploreSettings.swift',
    'Modules/Services/LibraryStore/BackgroundTaskHold.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_LOGIN_UI_EXPLORE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 318
# Row actions reuse the same reviewed source task and add no App definitions.
CURRENTCORE_ROW_ACTION_INPUTS = (
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginActionRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginActionTest.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_ROW_ACTION_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 320
CURRENTCORE_LOGIN_EVENTS_DISMISS_LIFECYCLE_INPUTS = (
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoOriginalLoginUIForm.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/Services/SelfRenewal/SelfRenewalAppOwner.swift',
    'Modules/Services/SelfRenewal/SelfRenewalBackgroundTaskBridge.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginActionTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUIEventsTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUITest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourcePersistLoginInfoTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Targets/Yuedu/SharedApp/yuedu_appApp.swift',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAppExecutionTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAppOwnerTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAutomaticRenewalTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalForegroundMaterialRevalidationTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_LOGIN_EVENTS_DISMISS_LIFECYCLE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 322
CURRENTCORE_DELTA_REUSE_INPUTS = (
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoOriginalLoginUIForm.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginActionRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIReuse.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginActionTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginDeltaTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUIEventsTest.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_DELTA_REUSE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 324
CURRENTCORE_LOGIN_V2_NATIVE_REPAIR_INPUTS = (
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoOriginalLoginUIForm.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/login/LoginUiV2.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginV2Runtime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUITest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginV2Test.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalLoginV2Models.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
    'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_LOGIN_V2_NATIVE_REPAIR_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 328
CURRENTCORE_NATIVE_READER_REPAIR_INPUTS = (
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleWebBookState.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalWebBookExecutionTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalReaderTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_NATIVE_READER_REPAIR_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 330
CURRENTCORE_ORIGINAL_LOGIN_BROWSER_INPUTS = (
    'Modules/Features/BookSource/SourceBrowserPresenter.swift',
    'Modules/Services/Online/LegadoPersistentStateHost.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeUrl.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginBrowserTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Modules/Features/BookSource/JsBridgeBrowserView.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoPlatformHost.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_ORIGINAL_LOGIN_BROWSER_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 332
CURRENTCORE_ORIGINAL_LOGIN_BROWSER_AWAIT_INPUTS = (
    'Modules/Features/BookSource/JsBridgeBrowserView.swift',
    'Modules/Features/BookSource/SourceBrowserPresenter.swift',
    'Modules/Services/Online/LegadoPersistentStateHost.swift',
    'Modules/SharedUI/Components/SourceWebUIDelegate.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginBrowserAwaitTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginBrowserTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeUrl.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleWebBookState.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoPlatformHost.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_ORIGINAL_LOGIN_BROWSER_AWAIT_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 334
CURRENTCORE_ORIGINAL_LOGIN_BROWSER_POST_INPUTS = (
    'Modules/Features/BookSource/JsBridgeBrowserView.swift',
    'Modules/Features/BookSource/SourceBrowserPresenter.swift',
    'Modules/Services/Online/LegadoPersistentStateHost.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginBrowserAwaitTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginBrowserPostTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginBrowserTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_ORIGINAL_LOGIN_BROWSER_POST_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 335
CURRENTCORE_ORIGINAL_LOGIN_HEADER_V2_BROWSER_INPUTS = (
    'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift',
    'Modules/Services/Online/LegadoPersistentStateHost.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/AppCookieOwnerTextTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginHeaderTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginV2BrowserTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_ORIGINAL_LOGIN_HEADER_V2_BROWSER_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 338
CURRENTCORE_SPD_WEBJS_COLD_INPUTS = ('Modules/Services/SelfRenewal/SelfRenewalAuthenticatedInstallationClient.swift', 'Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationFixture.swift', 'Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests.swift', '.github/workflows/legado-native-reader-test.yml', 'scripts/reader-experience/original-cold-process-tools.py', 'scripts/reader-experience/test-native-smoke-tools.py', 'scripts/reader-experience/test-original-cold-process-tools.py', 'scripts/xctest.sh', 'Tests/iOS/LegadoNativeOriginalReaderTests.swift', 'Modules/Services/SelfRenewal/SelfRenewalDeveloperAuthentication.swift', 'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift', 'Modules/Core/BookSource/BookSourceStore.swift', 'Modules/Features/BookSource/JsBridgeBrowserView.swift', 'Modules/Features/BookSource/SourceBrowserPresenter.swift', 'Modules/Services/Online/LegadoMainJSSourceService.swift', 'Modules/Services/Online/LegadoPersistentStateHost.swift', 'Modules/Services/Online/LegadoPreviewStateOwner.swift', 'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalWebJsPageRuntime.kt', 'Packages/LegadoRuntime/vendor/original-rule/manifest.json')
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_SPD_WEBJS_COLD_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 343

CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS = (
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/BaseSource.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeRule.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeUrl.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalGeneralWebJsRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleBase64.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalWebJsPageRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalGeneralWebJsTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Modules/Core/RuleEngine/ModernParser/JS/LegadoHeadlessWebView.swift',
    'Modules/Services/Online/LegadoPersistentStateHost.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/Services/Online/LegadoContentBatchOwner.swift',
    'Modules/Services/Online/SourceCallBackService.swift',
    'Tests/iOS/LegadoNativeOriginalReaderTests.swift',
    'Modules/Services/SelfRenewal/SelfRenewalAuthenticatedDeviceStream.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationFixture.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalInstallationRecoveryTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAnisetteV3ProviderTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift',
    'Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalCMSVerifierTests.swift',
    'Tests/iOS/yuedu appTests/LegadoCookieTextHostTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 346

CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS = (
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalAnalyzeRuleTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalUrlExecutionTest.kt',
    'Tests/iOS/LegadoNativeWebRequestCharacterizationTests.swift',
)
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 349


CURRENTCORE_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS = ('Modules/Core/RuleEngine/ModernParser/JS/LegadoCacheBridge.swift', 'Modules/Services/LibraryStore/BookStore.swift', 'Modules/Services/LibraryStore/Models.swift', 'Modules/Services/Online/LegadoMainJSSourceService.swift', 'Modules/Services/Online/LegadoPersistentStateHost.swift', 'Modules/Services/Online/LegadoPreviewStateOwner.swift', 'Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountClient.swift', 'Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/help/http/HttpProxyConfig.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/help/http/OriginalProxyClient.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/help/http/Socks5Proxy.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeRule.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeUrl.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/webBook/WebBook.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/ProductionHttpTransport.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/SourceHosts.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalBookRefresh.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleScopes.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleStateStore.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/legado/app/help/http/ProxyConfigTest.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/legado/app/help/http/Socks5ProtocolTest.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalAnalyzeRuleTest.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalPreUpdateRefreshTest.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalProxyExecutionTest.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalRemoteJsLibTest.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalUrlExecutionTest.kt', 'Packages/LegadoRuntime/vendor/original-rule/manifest.json', 'Packages/LegadoRuntime/vendor/runtime-http/manifest.json', 'Tests/iOS/LegadoNativeOriginalReaderTests.swift', 'Tests/iOS/yuedu appTests/LegadoPersistentStateHostTests.swift', 'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift')
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 364


CURRENTCORE_FIRST_REGISTRATION_FULL_APPLICATION_INPUTS = ('.github/workflows/legado-native-reader-test.yml', 'Modules/Core/BookSource/SourcePerfTrace.swift', 'Modules/Services/SelfRenewal/SelfRenewalAnisetteV3Provider.swift', 'Modules/Services/SelfRenewal/SelfRenewalAppOwner.swift', 'Modules/Services/SelfRenewal/SelfRenewalAppSession.swift', 'Modules/Services/SelfRenewal/SelfRenewalApplicationMaterialVerifier.swift', 'Modules/Services/SelfRenewal/SelfRenewalAuthenticatedDeviceStream.swift', 'Modules/Services/SelfRenewal/SelfRenewalAuthenticatedInstallationClient.swift', 'Modules/Services/SelfRenewal/SelfRenewalBackgroundTaskBridge.swift', 'Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift', 'Modules/Services/SelfRenewal/SelfRenewalCodeDirectoryHashVerifier.swift', 'Modules/Services/SelfRenewal/SelfRenewalControlledMachOSigner.swift', 'Modules/Services/SelfRenewal/SelfRenewalControlledPackageSigner.swift', 'Modules/Services/SelfRenewal/SelfRenewalControlledRenewalCoordinator.swift', 'Modules/Services/SelfRenewal/SelfRenewalDERPropertyList.swift', 'Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountClient.swift', 'Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountTransport.swift', 'Modules/Services/SelfRenewal/SelfRenewalDeveloperAuthentication.swift', 'Modules/Services/SelfRenewal/SelfRenewalGSASRP.swift', 'Modules/Services/SelfRenewal/SelfRenewalIPAArchiveValidator.swift', 'Modules/Services/SelfRenewal/SelfRenewalIPAUnpacker.swift', 'Modules/Services/SelfRenewal/SelfRenewalInstallationRecovery.swift', 'Modules/Services/SelfRenewal/SelfRenewalInstalledMaterialObserver.swift', 'Modules/Services/SelfRenewal/SelfRenewalMachOSignatureReader.swift', 'Modules/Services/SelfRenewal/SelfRenewalMaterialInventory.swift', 'Modules/Services/SelfRenewal/SelfRenewalNestedCodeRequirementsVerifier.swift', 'Modules/Services/SelfRenewal/SelfRenewalPackageResourceUpdater.swift', 'Modules/Services/SelfRenewal/SelfRenewalPairingIdentityImport.swift', 'Modules/Services/SelfRenewal/SelfRenewalProvisioningProfileVerifier.swift', 'Modules/Services/SelfRenewal/SelfRenewalReplacementPolicy.swift', 'Modules/Services/SelfRenewal/SelfRenewalResourceSealVerifier.swift', 'Modules/Services/SelfRenewal/SelfRenewalSignedCodeVerifier.swift', 'Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift', 'Modules/Services/SelfRenewal/SelfRenewalTransactionJournal.swift', 'Modules/Services/SelfRenewal/SelfRenewalUserDataHandoff.swift', 'Packages/LegadoRuntime/Package.swift', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalProxyExecutionTest.kt', 'Packages/LegadoRuntime/vendor/openjdk-notices/ios-tools/LICENSE', 'Packages/LegadoRuntime/vendor/openjdk-notices/libffi/LICENSE', 'Packages/LegadoRuntime/vendor/openjdk-notices/manifest.json', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/ADDITIONAL_LICENSE_INFO', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/ASSEMBLY_EXCEPTION', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/LICENSE', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/share/legal/c-libutl.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/share/legal/cldr.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/share/legal/gcc.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/share/legal/icu.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/share/legal/public_suffix.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/share/legal/siphash.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/share/legal/unicode.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/share/legal/zlib.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.base/windows/legal/wepoll.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/share/legal/colorimaging.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/share/legal/freetype.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/share/legal/giflib.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/share/legal/harfbuzz.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/share/legal/jpeg.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/share/legal/lcms.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/share/legal/libpng.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/share/legal/mesa3d.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/unix/legal/pipewire.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.desktop/unix/legal/xwd.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/bcel.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/dom.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/jcup.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/schema10part1.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/schema10part2.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/xalan.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/xerces.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/xhtml10.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/xhtml10schema.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/xhtml11.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/xhtml11schema.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/xmlspec.md', 'Packages/LegadoRuntime/vendor/openjdk-notices/openjdk/src/java.xml/share/legal/xmlxsd.md', 'Packages/LegadoRuntime/vendor/original-rule/manifest.json', 'Packages/LegadoRuntime/vendor/runtime-http/manifest.json', 'Resources/Yuedu-Reader.entitlements', 'ShareExtension/Yuedu-Reader-ShareExtension.entitlements', 'Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationFixture.swift', 'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalFullApplicationSignerTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalSigningOwnedPKIFixture.swift', 'Widget/Yuedu-Reader-Widget.entitlements', 'Yuedu-Reader.xcodeproj/project.pbxproj', 'Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'scripts/legado-ios/runtime-lock.json', 'scripts/legado-ios/stage-runtime.py', 'scripts/legado-ios/verify-native-exports.py', 'scripts/legado-ios/verify-native-reuse.py', 'scripts/legado-ios/verify-runtime.py', 'scripts/reader-experience/build.sh', 'scripts/reader-experience/full-application-signing-tools.py', 'scripts/reader-experience/native-smoke-tools.py', 'scripts/reader-experience/owned-package-fixture/ImportOwnedIdentity.swift', 'scripts/reader-experience/owned-package-fixture/OwnedIdentitySearch.c', 'scripts/reader-experience/owned-package-fixture/OwnedIdentitySearch.h', 'scripts/reader-experience/owned-package-fixture/extension.c', 'scripts/reader-experience/owned-package-fixture/framework.c', 'scripts/reader-experience/owned-package-fixture/full-application-package.py', 'scripts/reader-experience/owned-package-fixture/generate-sdk-owned-package.py', 'scripts/reader-experience/owned-package-fixture/main.c', 'scripts/reader-experience/runtime-notices.py', 'scripts/reader-experience/runtime-packaging.py', 'scripts/reader-experience/smoke-tools.py', 'scripts/reader-experience/stage-config.py', 'scripts/reader-experience/test-full-application-signing-tools.py', 'scripts/sim.sh', 'scripts/xctest.sh')
SOURCE_INPUTS += tuple(path for path in CURRENTCORE_FIRST_REGISTRATION_FULL_APPLICATION_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 418


def selection_mode():
    mode = os.environ.get("YUEDU_RENEWAL_SELECTION", "all")
    if mode not in SELECTION_GROUPS:
        raise ValueError("YUEDU_RENEWAL_SELECTION must be all, replacement, implementation, signature, cryptography, sealedmaterials, boundmaterials, controlledsigning, integratedrenewal, transactionrenewal, handoffrenewal or currentcore")
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
    if selection_mode() not in SDK_MODES: raise ValueError("SDK fixture generation belongs only to reviewed owned SDK selections")
    require_source_only()
    inputs = smoke.read_json(work / "source-inputs.json")
    if inputs.get("selectionMode") != selection_mode() or inputs.get("sourceCommit") != validate_tag():
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
    record = {"schemaVersion": 1, "sourceCommit": inputs["sourceCommit"], "selectionMode": selection_mode(),
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
    if selection_mode() not in SDK_MODES or phase not in ("before-build", "after-tests"):
        raise ValueError("Invalid SDK runtime resource phase")
    inputs = smoke.read_json(work / "source-inputs.json")
    binding = smoke.read_json(work / "sdk-fixture-binding.json")
    verified = _verify_sdk_public(work / "sdk-produced-public", inputs["sourceInputs"])
    if (binding.get("sourceCommit") != validate_tag() or binding.get("selectionMode") != selection_mode()
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
        summary = verify_group_summary(smoke.read_json(work / (selection_mode() + "-summary.json")), selection_mode())
        actual_cases = verify_cases(smoke.read_json(work / (selection_mode() + "-tests.json")), selection_mode())
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
        markers = _sdk_runtime_markers(work / (selection_mode() + "-tests.log"))
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
    if mode in PARAMETER_MODES:
        record["intendedArgumentCases"] = {case: {"parameter": name, "values": [False, True]} for case, name in parameter_cases(mode).items()}
        record["intendedQualifiedMethodDefinitions"] = len(EXPECTED_CASES[mode])
        record["intendedArgumentLeafCount"] = expected_leaf_count(mode)
    smoke.config.write_new_json(work / "source-inputs.json", record)
    return record


def _test_nodes(tree):
    if not isinstance(tree, dict) or not isinstance(tree.get("testNodes"), list):
        raise ValueError("Expected actual xcresult testNodes")
    result = []; count = 0
    def visit(node, depth=0):
        nonlocal count
        count += 1
        if not isinstance(node, dict) or depth > 32 or count > 10000:
            raise ValueError("Malformed or oversized xcresult tree")
        children = node.get("children", [])
        if not isinstance(children, list): raise ValueError("Malformed xcresult children")
        if node.get("nodeType") == "Test Case":
            result.append(node)
        else:
            for child in children: visit(child, depth + 1)
    for node in tree["testNodes"]: visit(node)
    return result


def _qualified_method(identifier):
    if not isinstance(identifier, str) or len(identifier) > 4096:
        raise ValueError("Missing bounded qualified test identifier")
    parts = identifier.split("/")
    if len(parts) not in (2, 3): raise ValueError("Ambiguous qualified test identifier")
    method = parts[-1]
    match = re.fullmatch(r"([A-Za-z_][A-Za-z_0-9]*)(?:\(\)|\(interrupt:\)|\(nestedBackdrop:\))?", method)
    if match is None: raise ValueError("Unreviewed qualified method syntax: " + identifier)
    qualified = parts[-2] + "/" + match[1]
    if method.endswith("(nestedBackdrop:)") and qualified not in CURRENTCORE_GLYPH_PARAMETER_CASES:
        raise ValueError("Unreviewed qualified argument label")
    if method.endswith("(interrupt:)") and qualified in CURRENTCORE_GLYPH_PARAMETER_CASES:
        raise ValueError("Wrong qualified glyph argument label")
    return qualified


def _argument_values(node, expected_parameter):
    values = []; visited = 0
    def visit(current, inside_argument=False, depth=0):
        nonlocal visited
        visited += 1
        if not isinstance(current, dict) or visited > 1000 or depth > 16:
            raise ValueError("Malformed argument execution tree")
        kind = current.get("nodeType")
        if kind == "Repetition": raise ValueError("Retry/repetition cannot replace one exact argument execution")
        if kind in ("Test Case Run", "Arguments", "Device", "Test Plan Configuration") and current.get("result") != "Passed":
            raise ValueError("Skipped/failed/incomplete argument execution")
        if kind == "Test Case": raise ValueError("Nested test case cannot impersonate an argument")
        children = current.get("children", [])
        if not isinstance(children, list): raise ValueError("Malformed argument children")
        if kind == "Arguments":
            if inside_argument: raise ValueError("Nested argument groups are ambiguous")
            name = current.get("name")
            # The value field of an actual xcresult Arguments node, bound to its
            # qualified parent, is distinct from a test's human display title.
            if not isinstance(name, str): raise ValueError("Missing argument value")
            match = re.fullmatch(r"(?:" + re.escape(expected_parameter) + r":\s*)?(false|true)", name)
            if match is None: raise ValueError("Unreviewed/missing exact Bool argument: " + name)
            runs = []
            def runs_in(value):
                if not isinstance(value, dict): raise ValueError("Malformed argument run")
                if value.get("nodeType") == "Test Case Run": runs.append(value)
                for child in value.get("children", []): runs_in(child)
            for child in children: runs_in(child)
            if len(runs) > 1: raise ValueError("Duplicate actual argument executions")
            values.append(match[1]); inside_argument = True
        elif kind == "Test Case Run" and not inside_argument:
            raise ValueError("Argument execution has no explicit input value")
        for child in children: visit(child, inside_argument, depth + 1)
    for child in node.get("children", []): visit(child)
    if len(values) != 2 or sorted(values) != ["false", "true"]:
        raise ValueError("Each qualified parameter method requires false and true exactly once")
    return values


def verify_transaction_cases(tree, group="transactionrenewal"):
    methods = []; leaves = []; argument_rows = []
    parameters = parameter_cases(group)
    for node in _test_nodes(tree):
        method = _qualified_method(node.get("nodeIdentifier"))
        if method not in EXPECTED_CASES[group] or node.get("result") != "Passed":
            raise ValueError("Unexpected/skipped/failed transaction test method")
        methods.append(method)
        if method in parameters:
            values = _argument_values(node, parameters[method])
            argument_rows.append({"method": method, "parameter": parameters[method], "values": values,
                                  "nodeIdentifier": node["nodeIdentifier"], "nodeIdentifierURL": node.get("nodeIdentifierURL")})
            leaves.extend(method + "[" + parameters[method] + "=" + value + "]" for value in values)
        else:
            stack = list(node.get("children", [])); runs = 0
            while stack:
                child = stack.pop()
                if not isinstance(child, dict): raise ValueError("Malformed ordinary run")
                kind = child.get("nodeType")
                if kind in ("Arguments", "Repetition", "Test Case"): raise ValueError("Unexpected ordinary arguments/retries/duplicate case")
                if kind == "Test Case Run":
                    runs += 1
                    if child.get("result") != "Passed": raise ValueError("Incomplete ordinary test run")
                stack.extend(child.get("children", []))
            if runs > 1: raise ValueError("Duplicate actual ordinary executions")
            leaves.append(method)
    expected = EXPECTED_CASES[group]
    count = expected_leaf_count(group)
    if len(methods) != len(expected) or set(methods) != expected or len(leaves) != count or len(set(leaves)) != count:
        raise ValueError("Actual qualified methods or exact argument leaves differ from " + group)
    return {"expectedTests": count, "expectedQualifiedMethodDefinitions": len(expected),
            "passedMethodIdentifiers": sorted(methods), "passedCaseIdentifiers": sorted(leaves),
            "passedArgumentCases": sorted(argument_rows, key=lambda row: row["method"])}


def _capture_xcresult(argv, output, seconds=45, maximum=16_777_216):
    """Fixed public tool, bounded pipes/time; no credentials or shell strings."""
    if output.exists(): raise ValueError("Refusing to overwrite original xcresult export")
    started = time.monotonic(); data = bytearray(); stderr = bytearray()
    lock = threading.Lock(); changed = threading.Event(); state = {"ended": 0, "oversized": False}
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    def read_pipe(stream, target):
        try:
            while True:
                raw = stream.read1(65536)
                if not raw: break
                with lock:
                    if len(data) + len(stderr) + len(raw) > maximum:
                        state["oversized"] = True; changed.set(); break
                    target.extend(raw)
        finally:
            with lock: state["ended"] += 1
            changed.set()
    readers = [threading.Thread(target=read_pipe, args=(stream, target), daemon=True)
               for stream, target in ((process.stdout, data), (process.stderr, stderr))]
    for reader in readers: reader.start()
    timed_out = False
    def stop():
        if os.name == "posix":
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
        elif process.poll() is None: process.kill()
    try:
        while True:
            with lock: done = state["ended"] == 2; oversized = state["oversized"]
            if oversized or (done and process.poll() is not None): break
            remaining = seconds - (time.monotonic() - started)
            if remaining <= 0: timed_out = True; break
            changed.wait(min(remaining, 0.1)); changed.clear()
        if timed_out or oversized: stop()
        status = process.wait(timeout=5)
    finally:
        if process.poll() is None: stop(); process.wait(timeout=5)
        for reader in readers: reader.join(timeout=5)
        for stream in (process.stdout, process.stderr): stream.close()
    if any(reader.is_alive() for reader in readers): raise ValueError("xcresult pipe did not drain after termination")
    output.write_bytes(data)
    error_path = output.with_suffix(output.suffix + ".stderr.log"); error_path.write_bytes(stderr)
    return {"argv": argv, "exitCode": status, "timedOut": timed_out, "oversized": oversized,
            "output": output.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "stderr": error_path.name, "stderrBytes": len(stderr), "stderrSHA256": hashlib.sha256(stderr).hexdigest()}


def collect_xcresult(work, group, native_exit):
    if group not in selected_cases() or type(native_exit) is not int or not 0 <= native_exit <= 255:
        raise ValueError("Invalid selected xcresult export")
    bundle = smoke.config.checked_path(work / (group + ".xcresult"))
    commands = []
    for name in ("summary", "tests"):
        target = work / (group + ("-summary.json" if name == "summary" else "-tests.json"))
        if not target.exists():
            commands.append(_capture_xcresult(["xcrun", "xcresulttool", "get", "test-results", name, "--path", str(bundle)], target))
    parameter_exports = []
    if group in PARAMETER_MODES:
        for command in ("tests", "test-details"):
            target = work / ("xcresulttool-" + command + "-help.log")
            if not target.exists(): commands.append(_capture_xcresult(["xcrun", "xcresulttool", "get", "test-results", command, "--help"], target, maximum=1_048_576))
        try:
            nodes = _test_nodes(smoke.read_json(work / (group + "-tests.json")))
            for index, method in enumerate(sorted(parameter_cases(group))):
                matches = [node for node in nodes if _qualified_method(node.get("nodeIdentifier")) == method]
                if len(matches) != 1: raise ValueError("Actual parameter method is missing or duplicated")
                node = matches[0]; identifier = node.get("nodeIdentifierURL") or node["nodeIdentifier"]
                target = work / ("transaction-parameter-" + str(index) + ".json")
                if target.exists(): raise ValueError("Refusing to overwrite parameter detail evidence")
                command = _capture_xcresult(["xcrun", "xcresulttool", "get", "test-results", "test-details", "--path", str(bundle), "--test-id", identifier], target)
                commands.append(command); parameter_exports.append({"method": method, "testID": identifier, "file": target.name})
        except (ValueError, KeyError, FileNotFoundError, json.JSONDecodeError) as error:
            parameter_exports.append({"error": str(error)[:1024]})
    record = {"schemaVersion": 1, "group": group, "originalXCTestExitCode": native_exit,
              "commands": commands, "parameterExports": parameter_exports,
              "meaning": "Original raw exports only; nonzero XCTest exit never becomes passing methods."}
    smoke.config.write_new_json(work / (group + "-extraction.json"), record)
    return record


def verify_transaction_details(work, tree, group="transactionrenewal"):
    cases = verify_transaction_cases(tree, group)
    extraction = smoke.read_json(work / (group + "-extraction.json"))
    if extraction.get("group") != group or type(extraction.get("originalXCTestExitCode")) is not int or extraction["originalXCTestExitCode"] != 0:
        raise ValueError("Actual XCTest invocation did not succeed")
    commands = extraction.get("commands")
    if not isinstance(commands, list) or len(commands) != 4 + len(parameter_cases(group)) or any(type(row.get("exitCode")) is not int or row["exitCode"] != 0 or row.get("timedOut") is not False or row.get("oversized") is not False for row in commands):
        raise ValueError("Missing/failed bounded original xcresult exports")
    bundle = str(smoke.config.checked_path(work / (group + ".xcresult")))
    wanted = {
        group + "-summary.json": ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle],
        group + "-tests.json": ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
        "xcresulttool-tests-help.log": ["xcrun", "xcresulttool", "get", "test-results", "tests", "--help"],
        "xcresulttool-test-details-help.log": ["xcrun", "xcresulttool", "get", "test-results", "test-details", "--help"],
    }
    for index, row in enumerate(cases["passedArgumentCases"]):
        wanted["transaction-parameter-" + str(index) + ".json"] = ["xcrun", "xcresulttool", "get", "test-results", "test-details", "--path", bundle, "--test-id", row["nodeIdentifierURL"] or row["nodeIdentifier"]]
    if len({row.get("output") for row in commands}) != 4 + len(parameter_cases(group)) or {row.get("output") for row in commands} != set(wanted):
        raise ValueError("Missing/duplicate/unreviewed raw exporter command set")
    for row in commands:
        if row.get("argv") != wanted[row["output"]]: raise ValueError("Raw export is not bound to this one actual xcresult")
        for path_key, size_key, hash_key in (("output", "bytes", "sha256"), ("stderr", "stderrBytes", "stderrSHA256")):
            name = row.get(path_key)
            if not isinstance(name, str) or Path(name).name != name: raise ValueError("Unsafe xcresult evidence path")
            raw, fact = _bounded_fact(work / name, 16_777_216)
            if fact != {"bytes": row.get(size_key), "sha256": row.get(hash_key)}: raise ValueError("xcresult raw export changed")
    exports = extraction.get("parameterExports")
    if not isinstance(exports, list) or len(exports) != len(parameter_cases(group)): raise ValueError("Missing actual parameter details")
    for row in cases["passedArgumentCases"]:
        export = [item for item in exports if item.get("method") == row["method"]]
        if len(export) != 1: raise ValueError("Parameter details are duplicated or missing")
        item = export[0]; expected_id = row["nodeIdentifierURL"] or row["nodeIdentifier"]
        if item.get("testID") != expected_id or Path(item.get("file", "")).name != item.get("file"):
            raise ValueError("Parameter detail is not bound to the actual qualified node")
        detail = smoke.read_json(work / item["file"])
        if (detail.get("testIdentifier") != row["nodeIdentifier"] or detail.get("testResult") != "Passed"
                or (row["nodeIdentifierURL"] is not None and detail.get("testIdentifierURL") != row["nodeIdentifierURL"])):
            raise ValueError("Actual qualified parameter detail identity/result differs")
        if not isinstance(detail.get("testRuns"), list) or not detail["testRuns"]:
            raise ValueError("Missing actual detailed parameter runs")
        # Detailed expression/value nesting varies by Xcode version. Exact Bool
        # leaves are the Arguments nodes of the qualified tests tree above;
        # preserve full raw test-details and independently bind its identity/result.
    tests_help = (work / "xcresulttool-tests-help.log").read_text(encoding="utf-8")
    details_help = (work / "xcresulttool-test-details-help.log").read_text(encoding="utf-8")
    if any(field not in tests_help for field in ("Arguments", "nodeIdentifier", "result")) or any(field not in details_help for field in ("testIdentifier", "testResult", "testRuns")):
        raise ValueError("Installed xcresulttool does not declare the reviewed argument/result schema")
    return cases


def verify_cases(tree, group):
    if group in PARAMETER_MODES: return verify_transaction_cases(tree, group)
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
    if mode in PARAMETER_MODES:
        contract = {case: {"parameter": name, "values": [False, True]} for case, name in parameter_cases(mode).items()}
        if json.dumps(inputs.get("intendedArgumentCases"), sort_keys=True) != json.dumps(contract, sort_keys=True) or inputs.get("intendedQualifiedMethodDefinitions") != len(EXPECTED_CASES[mode]) or inputs.get("intendedArgumentLeafCount") != expected_leaf_count(mode):
            raise ValueError("Transaction argument source-input audit changed")
        verify_transaction_details(work, smoke.read_json(work / (mode + "-tests.json")), mode)
    if mode == "currentcore":
        if os.environ.get("YUEDU_RENEWAL_PORTABLE_GUARDS_OUTCOME") != "success":
            raise ValueError("Actual workflow portable guards did not succeed")
        verify_currentcore_pipeline(work)
    if mode == "handoffrenewal":
        if os.environ.get("YUEDU_RENEWAL_PORTABLE_GUARDS_OUTCOME") != "success":
            raise ValueError("Required workflow portable guards did not succeed; native diagnostics cannot accept the full gate")
        verify_handoff_pipeline(work)
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
            **verify_group_summary(smoke.read_json(work / (group + "-summary.json")), group),
            **verify_cases(smoke.read_json(work / (group + "-tests.json")), group),
        }
    sdk_evidence = None
    if mode in SDK_MODES:
        for phase in ("before-build", "after-tests"):
            stored = smoke.read_json(work / ("sdk-fixture-" + phase + ".json"))
            current = verify_sdk_fixture(work, phase, save=False)
            if stored != current: raise ValueError("SDK runtime resource audit changed after execution")
        sdk_evidence = smoke.read_json(work / "sdk-fixture-after-tests.json")
    evidence = {}
    evidence_names = ["build-settings.json", "source-inputs.json", "overlays.json", "project-overlay.json", "info-overlay.json"]
    evidence_names += [group + suffix for group in cases for suffix in ("-summary.json", "-tests.json")]
    if mode in SDK_MODES:
        evidence_names += ["sdk-fixture-binding.json", "sdk-fixture-before-build.json", "sdk-fixture-after-tests.json", "sdk-test-build-settings.json"]
    if mode in PARAMETER_MODES:
        extraction = smoke.read_json(work / (mode + "-extraction.json"))
        evidence_names += [mode + "-extraction.json"] + [key for row in extraction["commands"] for key in (row["output"], row["stderr"])]
    if mode == "handoffrenewal":
        evidence_names += ["handoff-pipeline.json", "historical-package-evidence.json"]
    if mode == "currentcore":
        evidence_names += ["currentcore-pipeline.json", "historical-package-evidence.json"]
    for name in evidence_names:
        evidence[name] = smoke.config.digest(work / name)
    output = {"schemaVersion": 2, "sourceCommit": source, "sourceTag": TAG_PREFIX + source[:7],
            "status": "passed", "configuration": "Debug", "executionPlatform": "ios-simulator",
            "simulatorDestination": os.environ.get("YUEDU_DEST"),
            "developerDirectory": os.environ.get("DEVELOPER_DIR"), "selectionMode": mode,
            "targetedTests": groups, "unselectedTestGroups": [group for group in EXPECTED_CASES if group not in cases],
            "unselectedTestGroupsMeaning": "Artifact groups not accepted independently; their test identities may overlap the selected group.",
            "testedInfoSHA256": smoke.config.digest(app / "Info.plist"),
            "sourceOverlays": audit, "sourceInputs": inputs["sourceInputs"], "evidenceSHA256": evidence,
            "builtDiscoveryMetadata": metadata,
            "runtimeSourceOnly": True, "ipaGenerated": mode in SDK_MODES, "ipaUploaded": mode in SDK_MODES,
            "ipaKind": "owned-sdk-fixture-only" if mode in SDK_MODES else "none",
            "distributionIPAGenerated": False, "sdkFixtureRuntimeEvidence": sdk_evidence,
            "appleAccountUsed": False, "pairingRecordUsed": False,
            "iphoneTransportVerified": False, "physicalDeviceValidationPassed": False,
            "serviceIdentityVerified": False,
            "selfRenewalVerified": False, "unattendedRenewalVerified": False,
            "computerPoweredOff": "notMeasured", "companionAppsAbsent": "notMeasured",
            "limitations": (["handoffrenewal requires 253 unique definitions and 255 exact leaves in one cold 2700-second native invocation; all 178 prior definitions and the required SDK-produced case remain mandatory.", "Every producer/staging/native/export/verification phase must actually succeed. The first nonzero exit is preserved while the full native selection still runs after producer failure. Missing owned SDK resources are real test failures, never skips or fallback fixtures.", "The a835f8b package ten-case pass remains historical only. Cookie read changes a Package12 compilation input; the workflow now requires a separate new-tag ten-case SwiftPM execution with its own exact19 closure, never counted in native255.", "App data-owner receipts and installed-material entry points do not implement automatic App startup orchestration, real cold launch, Apple authorization, kernel replacement or complete user-data retention. Cookie ingress cases do not complete original storedSnapshot or cross-owner CAS handoff."] if mode == "handoffrenewal" else []) + ["Only the selected Simulator groups are accepted; not a delivered IPA or iPhone test.",
                            "No Apple login, real pairing, installation or renewal operation is performed."] + (
                           ["This selection prepares 178 unique qualified method definitions and requires 180 actual leaves: each of the two reviewed Bool parameter methods must show false and true once, with zero retries/skips/failures.",
                            "One source-bound transactionrenewal xcresult combines the prior 140 with 16 durable transaction/recovery, eight Book owner, ten metadata and four TXT/restore definitions. Actual Arguments nodes bind each Bool to its qualified parent; original raw details and installed help remain independently bound.",
                            "The unchanged same-job owned SDK producer/resource/built-loader hash chain remains mandatory. Producer diagnostics do not establish codesign success or native methods.",
                            "The independent ten SwiftPM XCTest cases must be re-executed after their historical compile failure; they have their own exact 19-input result and do not enter the native count.",
                            "Durable intent and fresh cleanup/Lookup fixtures do not establish real iPhone installation, a renewed installed profile, user data retention, cold launch or automatic renewal."] if mode == "transactionrenewal" else (
                           ["This selection executes exactly 140 unique qualified native methods in one integratedrenewal xcresult: bound78 union controlled23 plus nine App owner, twelve BookChapterStorage methods excluding the benchmark, eleven whole-package and seven authenticated-installation cases.",
                            "Historical modes retain their exact leaf sets and cold/warm budgets; overlaps count once in this selected union and never become additional acceptances.",
                            "The same job executes the fixed xcrun clang/codesign producer with a short-lived owned Keychain identity. Source/commands/public raw Mach-O and generated IPA hashes are bound, the generated JSON is copied as an untracked XCTest resource, and both built bytes and the actual loader's runtime SHA marker must match before acceptance.",
                            "The IPA flags refer only to that synthetic public SDK fixture; no delivered app/distribution IPA or user archive is generated or uploaded. Private keys/P12 stay in memory or the one temporary Keychain and never enter artifacts.",
                            "Owned whole-package tests exercise actual profile/resource/nested/Mach-O signing and final raw archive verification. Authenticated-installation cases use owned local TLS/AFC/installation fixtures, not an iPhone or real pairing record.",
                            "App owner fixtures and selected chapter storage regressions do not establish Kotlin/JNI App routing, delivered persistence migration or unattended operation.",
                            "Generic explicit anchors do not establish Apple authority, real account/device/profile authorization, installation permission, cold launch, user data preservation or automatic self-renewal.",
                            "No independent package XCTest run is triggered or accepted by this selection; the earlier ten-method package checkpoint has its own result. No unchanged diagnostic network/UI or replacement-policy suite executes."]
                             if mode in SDK_MODES else [
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
                            "The previous fixed-loopback experiment does not exclude alternate transports; discovery fixtures and Simulator UI do not establish iPhone reachability."]))}


    if mode == "handoffrenewal":
        output["limitations"] = output["limitations"][:6]
        output["historicalIndependentPackageEvidence"] = smoke.read_json(work / "historical-package-evidence.json")
    if mode == "currentcore":
        output["limitations"] = [
            "Currentcore requires exactly463 definitions and466 argument leaves in one cold3600-second invocation/xcresult, retaining both original Bool false/true pairs and the glyph nestedBackdrop pair and the required same-job SDK fixture case.",
            "All producer/stage/native/export/verification phases and actual portable guards must succeed. Producer or guard failure remains failure while the complete native selection is still attempted for diagnostics.",
            "AppOwner/retirement/foreground, Cookie text/WK, preview/Unicode, all-source pause, public content batch, first enrollment/durable binding, explicit and automatic execution, measured JVM bundle bounds, anisette v3, pairing import, pagination recovery, raw source login-info and CSR/account/GSA definitions are checked only within this current source boundary. This does not establish whole compatibility, real cold launch, Apple authority, installation, data retention or unattended renewal.",
            "The independent explicitly selected currentcore SwiftPM loginv2 selection is24 methods with16 actual compilation inputs plus7 controls. It must execute freshly for these changed inputs; historical10/default16/publicbatch17/effects18/loginui22/deltareuse23 modes retain their exact sets and are not included in native466.",
            "Existing eleven mode method/parameter identities and budgets remain unchanged. Benchmarks, diagnostic UI, unmerged later source work and unrelated JVM replay are excluded."]
        output["historicalIndependentPackageEvidence"] = smoke.read_json(work / "historical-package-evidence.json")
    return output


HISTORICAL_PACKAGE_INPUTS = [{'path': 'Packages/LegadoRuntime/Package.swift', 'bytes': 4171, 'sha256': '183cd2b775956d8c5b6f16bd97bbec13e7fca59fc26d3e03ef1569907f7c3e57'}, {'path': 'Packages/LegadoRuntime/Sources/CLegadoJNI/include/LegadoJNI.h', 'bytes': 1442, 'sha256': 'cf59d8119a24139c83c0ee1e445eeed9325fa1c1e14323db33bf4485d734434d'}, {'path': 'Packages/LegadoRuntime/Sources/CLegadoJNI/LegadoJNI.m', 'bytes': 35615, 'sha256': '304c7e15c7bc1fb539f43dbf1cc55c33853251c703d7830fb136cc45722b9f0d'}, {'path': 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoHTTPHeaders.swift', 'bytes': 2709, 'sha256': '8b29823799a1d433ea778df43ea5abc30f3d58c65cb5a9a1e96cc9783ceb9e4f'}, {'path': 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift', 'bytes': 4792, 'sha256': 'e52ff760d2d8ffa094283f531ae140962bb38f91e990771f353cf357c7b99a60'}, {'path': 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoPlatformHost.swift', 'bytes': 6621, 'sha256': '24cfdb60f63cfcbb458f4471cf2e59a37ec899df7e9dfc8d3656c91724cb7b4e'}, {'path': 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift', 'bytes': 18274, 'sha256': '113d34549166041b0c6c975068cca021fa4295ca58d97441149f4160c0b27be7'}, {'path': 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoSavedDiagnostics.swift', 'bytes': 3933, 'sha256': 'dc1f2a7cba3d5952b9097eb97105a8ff3f66e9db298f9e4f493b4537e3785839'}, {'path': 'Packages/LegadoRuntime/Sources/LegadoRuntime/NativeLegadoTransport.swift', 'bytes': 5698, 'sha256': '67a1e5f6607b6639fc5a20ac312e917e480c44ac5cb6b57cfdc53f3fa62287d2'}, {'path': 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoHTTPHeadersTests.swift', 'bytes': 4197, 'sha256': '3d934f8beb733c79c6be06d9688bba6517d0f6eec5f6bdf4ddc16bcdacb97c49'}, {'path': 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift', 'bytes': 9114, 'sha256': 'f158a8c618268901849edc6238b6cfbc98edb3149e1eaba3ce9c7d7f7fb79dbc'}, {'path': 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoRuntimeTests.swift', 'bytes': 16964, 'sha256': '7fe1c059b72a2633d813afc8683232f3ebd6de89ca74a4262571598aaa75c726'}, {'path': 'scripts/reader-experience/original-api-package-tools.py', 'bytes': 17626, 'sha256': '9075019b7e91ee677cc76cf5d8586a9771b2b9f2902a9f6b102e83f33258b39d'}, {'path': 'scripts/reader-experience/original-api-package-tests.sh', 'bytes': 511, 'sha256': 'eb729ca6267b92a66610a35acaafa734a97bd128b69df1ab9e341f48f0c3704b'}, {'path': 'scripts/reader-experience/test-original-api-package-tools.py', 'bytes': 15186, 'sha256': '6e943465dd09f1775e4d02be1f194a8714c52935ffbcceaf3f13f5cd22fc298e'}, {'path': 'scripts/reader-experience/smoke-tools.py', 'bytes': 27526, 'sha256': '2aef24263e9f7f52287a3704f539a038009c768c2f9a2296752e5cddff424765'}, {'path': 'scripts/reader-experience/stage-config.py', 'bytes': 26097, 'sha256': 'bd43e49da06d69611e6c258bea3b493715c90585caf09f4f96d16f338f856607'}, {'path': 'scripts/sim.sh', 'bytes': 10507, 'sha256': 'd526c909dcab8a0f605edcaba3c5870a19efbb2d04f17997e93bdc2e16e7bb5a'}, {'path': '.github/workflows/reader-renewal-probe.yml', 'bytes': 7321, 'sha256': '347bd7b0c921f7542bd5405917107e802322d7e2633f276ad892d5535808dac8'}]


def historical_package_evidence():
    if len(HISTORICAL_PACKAGE_INPUTS) != 19 or len({row["path"] for row in HISTORICAL_PACKAGE_INPUTS}) != 19:
        raise ValueError("Historical package contract requires exactly 19 distinct inputs")
    comparisons = []
    for expected in HISTORICAL_PACKAGE_INPUTS:
        path = expected["path"]
        raw = smoke.git("show", "HEAD:" + path, binary=True)
        if (smoke.REPO / path).read_bytes() != raw:
            raise ValueError("Historical package comparison input changed from this Git source: " + path)
        current = {"path": path, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        comparisons.append({"historical": expected, "current": current, "unchanged": current == expected})
    package = [row for row in comparisons if row["historical"]["path"].startswith("Packages/LegadoRuntime/")]
    return {"schemaVersion": 1, "historicalSourceCommit": "a835f8b0bae9d77bc2bb43d11cd8fdcf32d00804",
            "historicalSourceTag": "reader-renewal-a835f8b", "historicalQualifiedXCTestPasses": 10,
            "historicalArtifactID": 12243290501,
            "historicalArtifactZIPBytes": 22424,
            "historicalArtifactZIPSHA256": "489bd81a89e038b22d3cd3540ee6a073be43bb64e687302f9451a8b559d30931",
            "historicalRawResultSHA256": "fb32b8b7ad732d11a850ebe72eee095def35b3487381f580492439a42eaa3b28",
            "independentOfflineAuditSHA256": "2a39392ce06e12a74efc58c827f483a698bb475eb4d1faa22f4089bd1f0adad3",
            "comparisons": comparisons, "unchangedInputs": sum(row["unchanged"] for row in comparisons),
            "inputCount": 19, "packageCompilationInputs": len(package),
            "package12Unchanged": len(package) == 12 and all(row["unchanged"] for row in package),
            "all19Unchanged": len(comparisons) == 19 and all(row["unchanged"] for row in comparisons),
            "newTagPackageExecutionPerformed": False, "newTagPackageAcceptance": False,
            "meaning": "Actual independent historical ten-case XML/verbose pass. No package execution or acceptance for this new tag; changed controls cannot be ignored for exact 19-input reuse."}

# One reviewed source-only stage. Older modes keep their existing shell paths.
HANDOFF_PHASES = ("producer", "stage", "before-build", "boot", "native", "export", "cases", "test-settings", "after-tests", "build-settings")
HANDOFF_TIMEOUTS = (600, 90, 90, 180, 2820, 330, 90, 120, 120, 120)


def _source_closure_sha(records):
    return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _handoff_source_state(work):
    require_source_only()
    prepared = smoke.read_json(work / "source-inputs.json")
    current = source_inputs(smoke.read_json(work / "overlays.json"))
    if (selection_mode() != "handoffrenewal" or prepared.get("selectionMode") != "handoffrenewal"
            or prepared.get("sourceCommit") != validate_tag() or prepared.get("sourceInputs") != current
            or prepared.get("intendedTests") != {"handoffrenewal": sorted(EXPECTED_CASES["handoffrenewal"])}
            or prepared.get("intendedQualifiedMethodDefinitions") != 253 or prepared.get("intendedArgumentLeafCount") != 255
            or prepared.get("intendedArgumentCases") != {case: {"parameter": name, "values": [False, True]} for case, name in PARAMETER_CASES.items()}):
        raise ValueError("Handoff phase cannot run with changed preparation/source")
    return {"sourceCommit": prepared["sourceCommit"], "sourceTag": prepared["sourceTag"],
            "sourceInputCount": len(current), "sourceInputsSHA256": _source_closure_sha(current),
            "preparation": _handoff_fact(work, "source-inputs.json"),
            "overlays": _handoff_fact(work, "overlays.json"),
            "xcodeVersion": _handoff_fact(work, "xcode-version.log"),
            "runtimeSourceOnly": True, "developerDirectory": os.environ.get("DEVELOPER_DIR"),
            "simulatorDestination": os.environ.get("YUEDU_DEST"),
            "requiredPortableGuardsOutcome": os.environ.get("YUEDU_RENEWAL_PORTABLE_GUARDS_OUTCOME")}


def _handoff_build_args():
    return ["-configuration", "Debug", "-onlyUsePackageVersionsFromResolvedFile",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_IDENTITY=-",
            "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGN_ENTITLEMENTS=",
            "GATEWAY_BASE_URL=", "YUEDU_LOCAL_EXPERIENCE=YES", "INFOPLIST_KEY_YueduLocalExperience=YES",
            "INFOPLIST_KEY_FirebaseDataCollectionDefaultEnabled=NO", "INFOPLIST_KEY_FIREBASE_ANALYTICS_COLLECTION_ENABLED=NO",
            "INFOPLIST_KEY_FirebaseCrashlyticsCollectionEnabled=NO", "INFOPLIST_KEY_firebase_performance_collection_enabled=NO",
            "INFOPLIST_KEY_firebase_performance_instrumentation_enabled=NO"]


def _handoff_commands(work, native_exit=1):
    repo = smoke.REPO; script = repo / "scripts/reader-experience/renewal-probe-tools.py"
    tool = [sys.executable, str(script)]; args = _handoff_build_args()
    settings = ["xcodebuild", "-project", str(repo / "Yuedu-Reader.xcodeproj"), "-scheme", "Yuedu-Reader",
                "-destination", os.environ.get("YUEDU_DEST", ""), *args, "-showBuildSettings", "-json"]
    only = ["-only-testing:yuedu appTests/" + case + ("(interrupt:)" if case in PARAMETER_CASES else "")
            for case in sorted(EXPECTED_CASES["handoffrenewal"])]
    return {
        "producer": [sys.executable, str(repo / (SDK_TOOL_ROOT + "generate-sdk-owned-package.py")), "--output", str(repo / ".build/reader-renewal-sdk-produced-public")],
        "stage": tool + ["stage-sdk-fixture", "--work", str(work), "--produced", str(repo / ".build/reader-renewal-sdk-produced-public")],
        "before-build": tool + ["verify-sdk-fixture", "--work", str(work), "--phase", "before-build"],
        "boot": ["xcrun", "simctl", "bootstatus", os.environ.get("YUEDU_DEST", "").removeprefix("id="), "-b"],
        "native": ["bash", str(repo / "scripts/xctest.sh"), "-l", str(work / "handoffrenewal-tests.log"), "-t", "2700", "--", *args,
                   "-resultBundlePath", str(work / "handoffrenewal.xcresult"), *only],
        "export": tool + ["collect-xcresult", "--work", str(work), "--group", "handoffrenewal", "--native-exit", str(native_exit)],
        "cases": tool + ["verify-tests", "--group", "handoffrenewal", "--summary", str(work / "handoffrenewal-summary.json"), "--tests", str(work / "handoffrenewal-tests.json")],
        "test-settings": settings + ["test"],
        "after-tests": tool + ["verify-sdk-fixture", "--work", str(work), "--phase", "after-tests"],
        "build-settings": settings,
        "result": tool + ["result", "--work", str(work)],
    }


def _handoff_output(work, name):
    return work / {"test-settings": "sdk-test-build-settings.json", "build-settings": "build-settings.json"}.get(name, "handoff-" + name + ".log")


def _phase_exit(row):
    if row.get("state") == "blocked": return None
    command = row.get("command")
    if not isinstance(command, dict): return 1
    if command.get("timedOut") is True: return 124
    if command.get("oversized") is True: return 125
    status = command.get("exitCode")
    if type(status) is not int: return 1
    if status < 0: return min(255, 128 - status)
    if status != 0: return min(255, status)
    return 0 if row.get("state") == "succeeded" else 1


def _run_handoff_phase(work, name, argv, timeout, source, blocked_by=()):
    row = {"schemaVersion": 1, "phase": name, "timeoutSeconds": timeout,
           "sourceBefore": None, "sourceAfter": None, "state": "blocked" if blocked_by else "failed",
           "blockedBy": list(blocked_by), "intendedArgv": argv, "command": None}
    started = time.monotonic()
    try:
        row["sourceBefore"] = _handoff_source_state(work)
        if row["sourceBefore"] != source: raise ValueError("Source/toolchain/destination changed before phase")
        if not blocked_by:
            row["state"] = "running"
            row["command"] = _capture_xcresult(argv, _handoff_output(work, name), seconds=timeout, maximum=67_108_864)
            if name == "native":
                path = work / "handoffrenewal-tests.log"
                if path.exists():
                    _, fact = _bounded_fact(path, 268_435_456)
                    row["nativeLog"] = {"path": path.name, **fact}
                raw = _handoff_output(work, name).read_text(encoding="utf-8", errors="replace")
                stderr = _handoff_output(work, name).with_suffix(".log.stderr.log").read_text(encoding="utf-8", errors="replace")
                statuses = re.findall(r"(?m)^xcodebuild status: (-?\d+); wrapper verdict stop: (true|false)$", raw)
                row["reportedXcodebuildStatuses"] = [{"exitCode": int(status), "wrapperVerdictStop": stopped == "true"} for status, stopped in statuses]
                row["wrapperReportedBudgetTimeout"] = "!! no verdict after 2700s; killing" in stderr
        row["sourceAfter"] = _handoff_source_state(work)
        if row["sourceAfter"] != source: raise ValueError("Source/toolchain/destination changed during phase")
        if not blocked_by:
            command = row["command"]
            row["state"] = "succeeded" if command["exitCode"] == 0 and not command["timedOut"] and not command["oversized"] else "failed"
    except Exception as error:
        row["state"] = "failed"
        row["error"] = type(error).__name__ + ": " + str(error)[:2048]
    row["elapsedSeconds"] = round(time.monotonic() - started, 6)
    smoke.config.write_new_json(work / ("handoff-phase-" + name + ".json"), row)
    return row


def _handoff_first_failure(rows):
    for row in rows:
        code = _phase_exit(row)
        if code not in (None, 0): return {"phase": row["phase"], "exitCode": code}
    return None


def _handoff_fact(work, name):
    _, fact = _bounded_fact(work / name, 67_108_864)
    return {"path": name, **fact}


def _handoff_blockers(name, rows):
    # A producer/stage failure intentionally does not block boot/native/export,
    # case diagnostics or build settings. It only blocks invalid SDK staging.
    dependencies = {"stage": ("producer",), "before-build": ("producer", "stage"),
                    "native": ("boot",), "after-tests": ("producer", "stage", "before-build", "native", "export", "cases", "test-settings")}
    by_name = {row["phase"]: row for row in rows}
    result = [phase for phase in dependencies.get(name, ()) if _phase_exit(by_name[phase]) != 0]
    if rows and (rows[-1].get("sourceBefore") != rows[0].get("sourceBefore")
                 or rows[-1].get("sourceAfter") != rows[0].get("sourceBefore")):
        result.append("sourceIntegrity")
    return result


def run_handoff(work):
    source = _handoff_source_state(work)
    # A resource surviving from another invocation is never a valid missing-
    # fixture substitute. Preparation itself remains a fatal integrity gate.
    if (smoke.REPO / SDK_RESOURCE).exists(): raise ValueError("Refusing pre-existing untracked SDK resource")
    if (work / "handoff-pipeline.json").exists(): raise ValueError("Refusing to rerun the same handoff stage")
    historical = historical_package_evidence()
    smoke.config.write_new_json(work / "historical-package-evidence.json", historical)
    rows = []
    for name, timeout in zip(HANDOFF_PHASES, HANDOFF_TIMEOUTS):
        by_name = {row["phase"]: row for row in rows}
        native_exit = _phase_exit(by_name["native"]) if "native" in by_name else 1
        command = _handoff_commands(work, native_exit if native_exit is not None else 1)[name]
        rows.append(_run_handoff_phase(work, name, command, timeout, source, _handoff_blockers(name, rows)))
    failure = _handoff_first_failure(rows)
    ledger = {"schemaVersion": 1, "selectionMode": "handoffrenewal", "source": source,
              "qualifiedMethodDefinitions": 253, "argumentLeaves": 255,
              "phaseOrder": list(HANDOFF_PHASES), "phases": rows, "firstFailure": failure,
              "phaseRecords": [_handoff_fact(work, "handoff-phase-" + name + ".json") for name in HANDOFF_PHASES],
              "historicalPackageEvidence": _handoff_fact(work, "historical-package-evidence.json"),
              "allPhasesSucceeded": all(row["state"] == "succeeded" and _phase_exit(row) == 0 for row in rows),
              "nativeMeaning": "One complete same-source native invocation. Missing SDK resources remain actual failures; partial results are diagnostic only."}
    smoke.config.write_new_json(work / "handoff-pipeline.json", ledger)
    if ledger["allPhasesSucceeded"]:
        final = _run_handoff_phase(work, "result", _handoff_commands(work)["result"], 180, source)
    else:
        final = _run_handoff_phase(work, "result", _handoff_commands(work)["result"], 180, source,
                                   [row["phase"] for row in rows if row["state"] != "succeeded"])
    failure = failure or _handoff_first_failure([final])
    completion = {"schemaVersion": 1, "source": source, "ledgerSHA256": smoke.config.digest(work / "handoff-pipeline.json"),
                  "resultPhase": final, "firstFailure": failure, "exitCode": failure["exitCode"] if failure else 0,
                  "resultProduced": (work / "result.json").is_file()}
    if completion["resultProduced"]: completion["resultSHA256"] = smoke.config.digest(work / "result.json")
    smoke.config.write_new_json(work / "handoff-completion.json", completion)
    return completion


def verify_handoff_pipeline(work):
    ledger = smoke.read_json(work / "handoff-pipeline.json")
    source = _handoff_source_state(work)
    if (ledger.get("schemaVersion") != 1 or ledger.get("selectionMode") != "handoffrenewal"
            or ledger.get("source") != source or ledger.get("qualifiedMethodDefinitions") != 253
            or ledger.get("argumentLeaves") != 255 or ledger.get("phaseOrder") != list(HANDOFF_PHASES)
            or ledger.get("firstFailure") is not None or ledger.get("allPhasesSucceeded") is not True):
        raise ValueError("Missing/failed/changed same-source handoff pipeline")
    rows = ledger.get("phases")
    if not isinstance(rows, list) or [row.get("phase") for row in rows] != list(HANDOFF_PHASES):
        raise ValueError("Missing/reordered/duplicate handoff phases")
    if (ledger.get("phaseRecords") != [_handoff_fact(work, "handoff-phase-" + name + ".json") for name in HANDOFF_PHASES]
            or ledger.get("historicalPackageEvidence") != _handoff_fact(work, "historical-package-evidence.json")):
        raise ValueError("Original raw handoff phase/history receipt changed")
    commands = _handoff_commands(work, 0)
    for row, timeout in zip(rows, HANDOFF_TIMEOUTS):
        name = row["phase"]
        if row != smoke.read_json(work / ("handoff-phase-" + name + ".json")):
            raise ValueError("Handoff phase differs from its original raw ledger")
        if (row.get("state") != "succeeded" or row.get("blockedBy") != [] or _phase_exit(row) != 0
                or row.get("sourceBefore") != source or row.get("sourceAfter") != source
                or row.get("timeoutSeconds") != timeout or row.get("error") is not None):
            raise ValueError("Handoff phase failed, timed out, blocked or changed source")
        command = row["command"]
        if (row.get("intendedArgv") != commands[name] or command.get("argv") != commands[name] or type(command.get("exitCode")) is not int
                or command["exitCode"] != 0 or command.get("timedOut") is not False or command.get("oversized") is not False
                or command.get("output") != _handoff_output(work, name).name):
            raise ValueError("Unreviewed/failed handoff phase invocation")
        if name == "native":
            native = row.get("nativeLog")
            if not isinstance(native, dict) or native.get("path") != "handoffrenewal-tests.log" or row.get("wrapperReportedBudgetTimeout") is not False:
                raise ValueError("Missing native raw log or reported wrapper budget timeout")
            _, fact = _bounded_fact(work / native["path"], 268_435_456)
            if fact != {"bytes": native.get("bytes"), "sha256": native.get("sha256")}:
                raise ValueError("Native raw log changed after execution")
            raw = _handoff_output(work, name).read_text(encoding="utf-8", errors="replace")
            statuses = re.findall(r"(?m)^xcodebuild status: (-?\d+); wrapper verdict stop: (true|false)$", raw)
            expected_statuses = [{"exitCode": int(status), "wrapperVerdictStop": stopped == "true"} for status, stopped in statuses]
            if len(expected_statuses) != 1 or row.get("reportedXcodebuildStatuses") != expected_statuses:
                raise ValueError("Missing/ambiguous original xcodebuild exit observation")
            actual_status = expected_statuses[0]
            if actual_status["exitCode"] != 0 and not (actual_status["wrapperVerdictStop"] and actual_status["exitCode"] >= 128):
                raise ValueError("Actual xcodebuild status failed outside the existing post-verdict stop contract")
        for path_key, size_key, hash_key in (("output", "bytes", "sha256"), ("stderr", "stderrBytes", "stderrSHA256")):
            name = command.get(path_key)
            if not isinstance(name, str) or Path(name).name != name: raise ValueError("Unsafe handoff raw evidence path")
            _, fact = _bounded_fact(work / name, 67_108_864)
            if fact != {"bytes": command.get(size_key), "sha256": command.get(hash_key)}:
                raise ValueError("Original handoff phase output changed")
    original = smoke.read_json(work / "historical-package-evidence.json")
    if original != historical_package_evidence(): raise ValueError("Historical package source comparison changed")
    return ledger




CURRENTCORE_PHASES = ("producer", "stage", "before-build", "boot", "native", "export", "cases", "test-settings", "after-tests", "build-settings")
CURRENTCORE_TIMEOUTS = (600, 90, 90, 180, 3720, 330, 90, 120, 120, 120)



def _currentcore_source_state(work):
    require_source_only()
    prepared = smoke.read_json(work / "source-inputs.json")
    current = source_inputs(smoke.read_json(work / "overlays.json"))
    if (selection_mode() != "currentcore" or prepared.get("selectionMode") != "currentcore"
            or prepared.get("sourceCommit") != validate_tag() or prepared.get("sourceInputs") != current
            or prepared.get("intendedTests") != {"currentcore": sorted(EXPECTED_CASES["currentcore"])}
            or prepared.get("intendedQualifiedMethodDefinitions") != 479 or prepared.get("intendedArgumentLeafCount") != 482
            or prepared.get("intendedArgumentCases") != {case: {"parameter": name, "values": [False, True]} for case, name in parameter_cases("currentcore").items()}):
        raise ValueError("Current core phase cannot run with changed preparation/source")
    return {"sourceCommit": prepared["sourceCommit"], "sourceTag": prepared["sourceTag"],
            "sourceInputCount": len(current), "sourceInputsSHA256": _source_closure_sha(current),
            "preparation": _currentcore_fact(work, "source-inputs.json"),
            "overlays": _currentcore_fact(work, "overlays.json"),
            "xcodeVersion": _currentcore_fact(work, "xcode-version.log"),
            "runtimeSourceOnly": True, "developerDirectory": os.environ.get("DEVELOPER_DIR"),
            "simulatorDestination": os.environ.get("YUEDU_DEST"),
            "requiredPortableGuardsOutcome": os.environ.get("YUEDU_RENEWAL_PORTABLE_GUARDS_OUTCOME")}


def _currentcore_build_args():
    return ["-configuration", "Debug", "-onlyUsePackageVersionsFromResolvedFile",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_IDENTITY=-",
            "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGN_ENTITLEMENTS=",
            "GATEWAY_BASE_URL=", "YUEDU_LOCAL_EXPERIENCE=YES", "INFOPLIST_KEY_YueduLocalExperience=YES",
            "INFOPLIST_KEY_FirebaseDataCollectionDefaultEnabled=NO", "INFOPLIST_KEY_FIREBASE_ANALYTICS_COLLECTION_ENABLED=NO",
            "INFOPLIST_KEY_FirebaseCrashlyticsCollectionEnabled=NO", "INFOPLIST_KEY_firebase_performance_collection_enabled=NO",
            "INFOPLIST_KEY_firebase_performance_instrumentation_enabled=NO"]


# The 210fb05 xcresult contains all18 selected XCTest methods, but only
# the three parameterized Swift Testing functions. Bare Swift function names
# are not their Xcode identifiers: zero-argument functions require (). Keep
# XCTest method selectors unchanged and retain each real parameter label.
CURRENTCORE_XCTEST_SUITES = frozenset({
    "ReadingPositionStorePersistenceTests", "ReaderViewportSizeObserverHostingTests",
})


def currentcore_test_selector(case):
    if case not in EXPECTED_CASES["currentcore"]:
        raise ValueError("Unselected current-core test identifier")
    parameters = parameter_cases("currentcore")
    if case in parameters:
        return case + "(" + parameters[case] + ":)"
    if case.split("/", 1)[0] in CURRENTCORE_XCTEST_SUITES:
        return case
    return case + "()"


def verify_group_summary(summary, group):
    if group == "currentcore":
        # Actual210 xcresult reports unique definitions at the top level and
        # parameter executions on the sole device/configuration. Require both;
        # neither count substitutes for the qualified-case/raw-argument gates.
        return smoke.verify_summary(summary, len(EXPECTED_CASES[group]), expected_leaf_count(group))
    return smoke.verify_summary(summary, expected_leaf_count(group))


def _currentcore_commands(work, native_exit=1):
    repo = smoke.REPO; script = repo / "scripts/reader-experience/renewal-probe-tools.py"
    tool = [sys.executable, str(script)]; args = _currentcore_build_args()
    settings = ["xcodebuild", "-project", str(repo / "Yuedu-Reader.xcodeproj"), "-scheme", "Yuedu-Reader",
                "-destination", os.environ.get("YUEDU_DEST", ""), *args, "-showBuildSettings", "-json"]
    only = ["-only-testing:yuedu appTests/" + currentcore_test_selector(case)
            for case in sorted(EXPECTED_CASES["currentcore"])]
    return {
        "producer": [sys.executable, str(repo / (SDK_TOOL_ROOT + "generate-sdk-owned-package.py")), "--output", str(repo / ".build/reader-renewal-sdk-produced-public")],
        "stage": tool + ["stage-sdk-fixture", "--work", str(work), "--produced", str(repo / ".build/reader-renewal-sdk-produced-public")],
        "before-build": tool + ["verify-sdk-fixture", "--work", str(work), "--phase", "before-build"],
        "boot": ["xcrun", "simctl", "bootstatus", os.environ.get("YUEDU_DEST", "").removeprefix("id="), "-b"],
        "native": ["bash", str(repo / "scripts/xctest.sh"), "-l", str(work / "currentcore-tests.log"), "-t", "3600", "--", *args,
                   "-resultBundlePath", str(work / "currentcore.xcresult"), *only],
        "export": tool + ["collect-xcresult", "--work", str(work), "--group", "currentcore", "--native-exit", str(native_exit)],
        "cases": tool + ["verify-tests", "--group", "currentcore", "--summary", str(work / "currentcore-summary.json"), "--tests", str(work / "currentcore-tests.json")],
        "test-settings": settings + ["test"],
        "after-tests": tool + ["verify-sdk-fixture", "--work", str(work), "--phase", "after-tests"],
        "build-settings": settings,
        "result": tool + ["result", "--work", str(work)],
    }


def _currentcore_output(work, name):
    return work / {"test-settings": "sdk-test-build-settings.json", "build-settings": "build-settings.json"}.get(name, "currentcore-" + name + ".log")



def _run_currentcore_phase(work, name, argv, timeout, source, blocked_by=()):
    row = {"schemaVersion": 1, "phase": name, "timeoutSeconds": timeout,
           "sourceBefore": None, "sourceAfter": None, "state": "blocked" if blocked_by else "failed",
           "blockedBy": list(blocked_by), "intendedArgv": argv, "command": None}
    started = time.monotonic()
    try:
        row["sourceBefore"] = _currentcore_source_state(work)
        if row["sourceBefore"] != source: raise ValueError("Source/toolchain/destination changed before phase")
        if not blocked_by:
            row["state"] = "running"
            row["command"] = _capture_xcresult(argv, _currentcore_output(work, name), seconds=timeout, maximum=67_108_864)
            if name == "native":
                path = work / "currentcore-tests.log"
                if path.exists():
                    _, fact = _bounded_fact(path, 268_435_456)
                    row["nativeLog"] = {"path": path.name, **fact}
                raw = _currentcore_output(work, name).read_text(encoding="utf-8", errors="replace")
                stderr = _currentcore_output(work, name).with_suffix(".log.stderr.log").read_text(encoding="utf-8", errors="replace")
                statuses = re.findall(r"(?m)^xcodebuild status: (-?\d+); wrapper verdict stop: (true|false)$", raw)
                row["reportedXcodebuildStatuses"] = [{"exitCode": int(status), "wrapperVerdictStop": stopped == "true"} for status, stopped in statuses]
                row["wrapperReportedBudgetTimeout"] = "!! no verdict after 3600s; killing" in stderr
        row["sourceAfter"] = _currentcore_source_state(work)
        if row["sourceAfter"] != source: raise ValueError("Source/toolchain/destination changed during phase")
        if not blocked_by:
            command = row["command"]
            row["state"] = "succeeded" if command["exitCode"] == 0 and not command["timedOut"] and not command["oversized"] else "failed"
    except Exception as error:
        row["state"] = "failed"
        row["error"] = type(error).__name__ + ": " + str(error)[:2048]
    row["elapsedSeconds"] = round(time.monotonic() - started, 6)
    smoke.config.write_new_json(work / ("currentcore-phase-" + name + ".json"), row)
    return row


def _currentcore_first_failure(rows):
    for row in rows:
        code = _phase_exit(row)
        if code not in (None, 0): return {"phase": row["phase"], "exitCode": code}
    return None


def _currentcore_fact(work, name):
    _, fact = _bounded_fact(work / name, 67_108_864)
    return {"path": name, **fact}


def _currentcore_blockers(name, rows):
    # A producer/stage failure intentionally does not block boot/native/export,
    # case diagnostics or build settings. It only blocks invalid SDK staging.
    dependencies = {"stage": ("producer",), "before-build": ("producer", "stage"),
                    "native": ("boot",), "after-tests": ("producer", "stage", "before-build", "native", "export", "cases", "test-settings")}
    by_name = {row["phase"]: row for row in rows}
    result = [phase for phase in dependencies.get(name, ()) if _phase_exit(by_name[phase]) != 0]
    if rows and (rows[-1].get("sourceBefore") != rows[0].get("sourceBefore")
                 or rows[-1].get("sourceAfter") != rows[0].get("sourceBefore")):
        result.append("sourceIntegrity")
    return result


def run_currentcore(work):
    source = _currentcore_source_state(work)
    # A resource surviving from another invocation is never a valid missing-
    # fixture substitute. Preparation itself remains a fatal integrity gate.
    if (smoke.REPO / SDK_RESOURCE).exists(): raise ValueError("Refusing pre-existing untracked SDK resource")
    if (work / "currentcore-pipeline.json").exists(): raise ValueError("Refusing to rerun the same currentcore stage")
    historical = historical_package_evidence()
    smoke.config.write_new_json(work / "historical-package-evidence.json", historical)
    rows = []
    for name, timeout in zip(CURRENTCORE_PHASES, CURRENTCORE_TIMEOUTS):
        by_name = {row["phase"]: row for row in rows}
        native_exit = _phase_exit(by_name["native"]) if "native" in by_name else 1
        command = _currentcore_commands(work, native_exit if native_exit is not None else 1)[name]
        rows.append(_run_currentcore_phase(work, name, command, timeout, source, _currentcore_blockers(name, rows)))
    failure = _currentcore_first_failure(rows)
    ledger = {"schemaVersion": 1, "selectionMode": "currentcore", "source": source,
              "qualifiedMethodDefinitions": 479, "argumentLeaves": 482,
              "phaseOrder": list(CURRENTCORE_PHASES), "phases": rows, "firstFailure": failure,
              "phaseRecords": [_currentcore_fact(work, "currentcore-phase-" + name + ".json") for name in CURRENTCORE_PHASES],
              "historicalPackageEvidence": _currentcore_fact(work, "historical-package-evidence.json"),
              "allPhasesSucceeded": all(row["state"] == "succeeded" and _phase_exit(row) == 0 for row in rows),
              "nativeMeaning": "One complete same-source native invocation. Missing SDK resources remain actual failures; partial results are diagnostic only."}
    smoke.config.write_new_json(work / "currentcore-pipeline.json", ledger)
    if ledger["allPhasesSucceeded"]:
        final = _run_currentcore_phase(work, "result", _currentcore_commands(work)["result"], 180, source)
    else:
        final = _run_currentcore_phase(work, "result", _currentcore_commands(work)["result"], 180, source,
                                   [row["phase"] for row in rows if row["state"] != "succeeded"])
    failure = failure or _currentcore_first_failure([final])
    completion = {"schemaVersion": 1, "source": source, "ledgerSHA256": smoke.config.digest(work / "currentcore-pipeline.json"),
                  "resultPhase": final, "firstFailure": failure, "exitCode": failure["exitCode"] if failure else 0,
                  "resultProduced": (work / "result.json").is_file()}
    if completion["resultProduced"]: completion["resultSHA256"] = smoke.config.digest(work / "result.json")
    smoke.config.write_new_json(work / "currentcore-completion.json", completion)
    return completion


def verify_currentcore_pipeline(work):
    ledger = smoke.read_json(work / "currentcore-pipeline.json")
    source = _currentcore_source_state(work)
    if (ledger.get("schemaVersion") != 1 or ledger.get("selectionMode") != "currentcore"
            or ledger.get("source") != source or ledger.get("qualifiedMethodDefinitions") != 479
            or ledger.get("argumentLeaves") != 482 or ledger.get("phaseOrder") != list(CURRENTCORE_PHASES)
            or ledger.get("firstFailure") is not None or ledger.get("allPhasesSucceeded") is not True):
        raise ValueError("Missing/failed/changed same-source currentcore pipeline")
    rows = ledger.get("phases")
    if not isinstance(rows, list) or [row.get("phase") for row in rows] != list(CURRENTCORE_PHASES):
        raise ValueError("Missing/reordered/duplicate handoff phases")
    if (ledger.get("phaseRecords") != [_currentcore_fact(work, "currentcore-phase-" + name + ".json") for name in CURRENTCORE_PHASES]
            or ledger.get("historicalPackageEvidence") != _currentcore_fact(work, "historical-package-evidence.json")):
        raise ValueError("Original raw handoff phase/history receipt changed")
    commands = _currentcore_commands(work, 0)
    for row, timeout in zip(rows, CURRENTCORE_TIMEOUTS):
        name = row["phase"]
        if row != smoke.read_json(work / ("currentcore-phase-" + name + ".json")):
            raise ValueError("Current core phase differs from its original raw ledger")
        if (row.get("state") != "succeeded" or row.get("blockedBy") != [] or _phase_exit(row) != 0
                or row.get("sourceBefore") != source or row.get("sourceAfter") != source
                or row.get("timeoutSeconds") != timeout or row.get("error") is not None):
            raise ValueError("Current core phase failed, timed out, blocked or changed source")
        command = row["command"]
        if (row.get("intendedArgv") != commands[name] or command.get("argv") != commands[name] or type(command.get("exitCode")) is not int
                or command["exitCode"] != 0 or command.get("timedOut") is not False or command.get("oversized") is not False
                or command.get("output") != _currentcore_output(work, name).name):
            raise ValueError("Unreviewed/failed handoff phase invocation")
        if name == "native":
            native = row.get("nativeLog")
            if not isinstance(native, dict) or native.get("path") != "currentcore-tests.log" or row.get("wrapperReportedBudgetTimeout") is not False:
                raise ValueError("Missing native raw log or reported wrapper budget timeout")
            _, fact = _bounded_fact(work / native["path"], 268_435_456)
            if fact != {"bytes": native.get("bytes"), "sha256": native.get("sha256")}:
                raise ValueError("Native raw log changed after execution")
            raw = _currentcore_output(work, name).read_text(encoding="utf-8", errors="replace")
            statuses = re.findall(r"(?m)^xcodebuild status: (-?\d+); wrapper verdict stop: (true|false)$", raw)
            expected_statuses = [{"exitCode": int(status), "wrapperVerdictStop": stopped == "true"} for status, stopped in statuses]
            if len(expected_statuses) != 1 or row.get("reportedXcodebuildStatuses") != expected_statuses:
                raise ValueError("Missing/ambiguous original xcodebuild exit observation")
            actual_status = expected_statuses[0]
            if actual_status["exitCode"] != 0 and not (actual_status["wrapperVerdictStop"] and actual_status["exitCode"] >= 128):
                raise ValueError("Actual xcodebuild status failed outside the existing post-verdict stop contract")
        for path_key, size_key, hash_key in (("output", "bytes", "sha256"), ("stderr", "stderrBytes", "stderrSHA256")):
            name = command.get(path_key)
            if not isinstance(name, str) or Path(name).name != name: raise ValueError("Unsafe handoff raw evidence path")
            _, fact = _bounded_fact(work / name, 67_108_864)
            if fact != {"bytes": command.get(size_key), "sha256": command.get(hash_key)}:
                raise ValueError("Original handoff phase output changed")
    original = smoke.read_json(work / "historical-package-evidence.json")
    if original != historical_package_evidence(): raise ValueError("Historical package source comparison changed")
    return ledger



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    commands.add_parser("validate-tag")
    for phase in ("prepare", "result", "run-handoff", "run-currentcore"):
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
    collect = commands.add_parser("collect-xcresult")
    collect.add_argument("--work", type=Path, required=True)
    collect.add_argument("--group", choices=tuple(EXPECTED_CASES), required=True)
    collect.add_argument("--native-exit", type=int, required=True)
    args = parser.parse_args()
    try:
        if args.phase == "validate-tag":
            record = {"sourceCommit": validate_tag()}
        elif args.phase == "prepare":
            record = prepare(smoke.config.checked_path(args.work))
        elif args.phase == "run-currentcore":
            record = run_currentcore(smoke.config.checked_path(args.work))
            print(json.dumps(record, indent=2))
            return record["exitCode"]
        elif args.phase == "run-handoff":
            record = run_handoff(smoke.config.checked_path(args.work))
            print(json.dumps(record, indent=2))
            return record["exitCode"]
        elif args.phase == "stage-sdk-fixture":
            record = stage_sdk_fixture(smoke.config.checked_path(args.work), smoke.config.checked_path(args.produced))
        elif args.phase == "verify-sdk-fixture":
            record = verify_sdk_fixture(smoke.config.checked_path(args.work), args.sdk_phase)
        elif args.phase == "collect-xcresult":
            record = collect_xcresult(smoke.config.checked_path(args.work), args.group, args.native_exit)
            if args.group in ("handoffrenewal", "currentcore"):
                rows = record["commands"]
                if (len(rows) != 4 + len(parameter_cases(args.group)) or any(type(row.get("exitCode")) is not int or row["exitCode"] != 0
                        or row.get("timedOut") is not False or row.get("oversized") is not False for row in rows)
                        or len(record["parameterExports"]) != len(parameter_cases(args.group)) or any("error" in row for row in record["parameterExports"])):
                    print(json.dumps(record, indent=2))
                    return 1
        elif args.phase == "verify-tests":
            if args.group not in selected_cases():
                raise ValueError("Test group is not part of YUEDU_RENEWAL_SELECTION")
            record = {**verify_group_summary(smoke.read_json(args.summary), args.group),
                      **verify_cases(smoke.read_json(args.tests), args.group)}
            if args.group in ("handoffrenewal", "currentcore"):
                verify_transaction_details(smoke.config.checked_path(args.tests.parent), smoke.read_json(args.tests), args.group)
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
