#!/usr/bin/env bash
# Source-only owned Simulator fixtures; no physical-device installation or distribution IPA export.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="$REPO_DIR/.build/reader-renewal-probe"
export YUEDU_RENEWAL_SELECTION=${YUEDU_RENEWAL_SELECTION-all}
case "$YUEDU_RENEWAL_SELECTION" in
  all|replacement|implementation|signature|cryptography|sealedmaterials|boundmaterials|controlledsigning|integratedrenewal|transactionrenewal|handoffrenewal|currentcore) ;;
  *) echo 'YUEDU_RENEWAL_SELECTION must be all, replacement, implementation, signature, cryptography, sealedmaterials, boundmaterials, controlledsigning, integratedrenewal, transactionrenewal, handoffrenewal or currentcore.' >&2; exit 2 ;;
esac
[[ $(uname -s) == Darwin ]] || { echo 'Renewal probe tests require macOS/Xcode.' >&2; exit 2; }
mkdir -p "$WORK"
preserve_failed_xcresults() {
  local original_exit=$?
  trap - EXIT
  if [[ $original_exit != 0 ]]; then
    for result in "$WORK"/*.xcresult; do
      [[ -d $result ]] || continue
      local group=${result##*/}; group=${group%.xcresult}
      [[ ! -e "$WORK/$group-extraction.json" ]] || continue
      # Export is bounded and diagnostic only. It never replaces XCTest's exit.
      python3 "$SCRIPT_DIR/renewal-probe-tools.py" collect-xcresult --work "$WORK" --group "$group" --native-exit "$original_exit" > "$WORK/$group-failure-export.log" 2>&1 || true
    done
  fi
  exit "$original_exit"
}
trap preserve_failed_xcresults EXIT
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
export YUEDU_DEST=${YUEDU_DEST:-$(bash "$REPO_DIR/scripts/sim.sh" dest)}
export LEGADO_RUNTIME_SOURCE_ONLY=1
python3 "$SCRIPT_DIR/renewal-probe-tools.py" prepare --work "$WORK" > "$WORK/prepare.log"
xcodebuild -version > "$WORK/xcode-version.log"
if [[ $YUEDU_RENEWAL_SELECTION == currentcore ]]; then
  # 471 definitions,474 argument leaves: one cold3600-second invocation/xcresult.
  # Run control-reuse checks in the separate native and Package groups.
  # First failure never gets overwritten; all mandatory producer/fixture gates remain.
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" run-currentcore --work "$WORK"
  exit $?
fi
if [[ $YUEDU_RENEWAL_SELECTION == handoffrenewal ]]; then
  # This sole future-mode pipeline preserves first failure and still attempts
  # the complete same-source native selection after producer/staging failures.
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" run-handoff --work "$WORK"
  exit $?
fi
if [[ $YUEDU_RENEWAL_SELECTION == integratedrenewal || $YUEDU_RENEWAL_SELECTION == transactionrenewal ]]; then
  # Raw producer output stays outside the always-uploaded evidence directory.
  # Only the verified allowlisted public outputs enter the artifact.
  SDK_PRODUCED="$REPO_DIR/.build/reader-renewal-sdk-produced-public"
  python3 "$SCRIPT_DIR/owned-package-fixture/generate-sdk-owned-package.py" --output "$SDK_PRODUCED" > "$WORK/sdk-producer.log"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" stage-sdk-fixture --work "$WORK" --produced "$SDK_PRODUCED" > "$WORK/sdk-stage.log"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-sdk-fixture --work "$WORK" --phase before-build > "$WORK/sdk-before-build.log"
fi
xcrun simctl bootstatus "${YUEDU_DEST#id=}" -b > "$WORK/boot-status.log" 2>&1
ARGS=(
  -configuration Debug -onlyUsePackageVersionsFromResolvedFile
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=
  GATEWAY_BASE_URL= YUEDU_LOCAL_EXPERIENCE=YES
  INFOPLIST_KEY_YueduLocalExperience=YES
  INFOPLIST_KEY_FirebaseDataCollectionDefaultEnabled=NO
  INFOPLIST_KEY_FIREBASE_ANALYTICS_COLLECTION_ENABLED=NO
  INFOPLIST_KEY_FirebaseCrashlyticsCollectionEnabled=NO
  INFOPLIST_KEY_firebase_performance_collection_enabled=NO
  INFOPLIST_KEY_firebase_performance_instrumentation_enabled=NO
)
# Only local Simulator ad-hoc signing permits the XCTest hosts to launch. No
# developer account, device provisioning or runtime payload is involved.
if [[ $YUEDU_RENEWAL_SELECTION == all ]]; then
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/unit-tests.log" -t 2700 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/unit.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalTransportProbeTests'
  xcrun xcresulttool get test-results summary --path "$WORK/unit.xcresult" > "$WORK/unit-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/unit.xcresult" > "$WORK/unit-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group unit \
    --summary "$WORK/unit-summary.json" --tests "$WORK/unit-tests.json"
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/discovery-tests.log" -t 1200 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/discovery.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalDiscoveryProbeTests'
  xcrun xcresulttool get test-results summary --path "$WORK/discovery.xcresult" > "$WORK/discovery-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/discovery.xcresult" > "$WORK/discovery-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group discovery \
    --summary "$WORK/discovery-summary.json" --tests "$WORK/discovery-tests.json"
fi
# The selected cases still compile the complete shared App/test targets. The
# source-bound 4ada44e failure reached ongoing cold compilation at the old 900s
# cap without a test verdict. Match the existing first unit invocation budget;
# all mode already paid that cold-build cost and keeps its 900s warm limit.
if [[ $YUEDU_RENEWAL_SELECTION != signature && $YUEDU_RENEWAL_SELECTION != cryptography && $YUEDU_RENEWAL_SELECTION != sealedmaterials && $YUEDU_RENEWAL_SELECTION != boundmaterials && $YUEDU_RENEWAL_SELECTION != controlledsigning && $YUEDU_RENEWAL_SELECTION != integratedrenewal && $YUEDU_RENEWAL_SELECTION != transactionrenewal ]]; then
  REPLACEMENT_TIMEOUT=2700
  if [[ $YUEDU_RENEWAL_SELECTION == all ]]; then REPLACEMENT_TIMEOUT=900; fi
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/replacement-tests.log" -t "$REPLACEMENT_TIMEOUT" -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/replacement.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalReplacementPolicyTests'
  xcrun xcresulttool get test-results summary --path "$WORK/replacement.xcresult" > "$WORK/replacement-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/replacement.xcresult" > "$WORK/replacement-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group replacement \
    --summary "$WORK/replacement-summary.json" --tests "$WORK/replacement-tests.json"
fi
if [[ $YUEDU_RENEWAL_SELECTION == implementation ]]; then
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/materials-tests.log" -t 900 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/materials.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests'
  xcrun xcresulttool get test-results summary --path "$WORK/materials.xcresult" > "$WORK/materials-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/materials.xcresult" > "$WORK/materials-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group materials \
    --summary "$WORK/materials-summary.json" --tests "$WORK/materials-tests.json"
fi
if [[ $YUEDU_RENEWAL_SELECTION == signature ]]; then
  # New signature cases compile the same shared targets on a cold runner; keep
  # the established 2700-second cold limit without executing historical groups.
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/signature-tests.log" -t 2700 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/signature.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests'
  xcrun xcresulttool get test-results summary --path "$WORK/signature.xcresult" > "$WORK/signature-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/signature.xcresult" > "$WORK/signature-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group signature \
    --summary "$WORK/signature-summary.json" --tests "$WORK/signature-tests.json"
fi
if [[ $YUEDU_RENEWAL_SELECTION == cryptography ]]; then
  # The shared reader changed: recheck its nine structure cases together with
  # the new hash/CMS/profile cases in one cold build and one exact-leaf result.
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/cryptography-tests.log" -t 2700 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/cryptography.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests' \
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalProvisioningProfileVerifierTests'
  xcrun xcresulttool get test-results summary --path "$WORK/cryptography.xcresult" > "$WORK/cryptography-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/cryptography.xcresult" > "$WORK/cryptography-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group cryptography \
    --summary "$WORK/cryptography-summary.json" --tests "$WORK/cryptography-tests.json"
fi
if [[ $YUEDU_RENEWAL_SELECTION == sealedmaterials ]]; then
  # Shared inventory, file I/O and CMS changed. Recheck all affected contracts
  # in one cold build, preserving one exact 48-method xcresult acceptance set.
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/sealedmaterials-tests.log" -t 2700 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/sealedmaterials.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests' \
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalProvisioningProfileVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests' \
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests'
  xcrun xcresulttool get test-results summary --path "$WORK/sealedmaterials.xcresult" > "$WORK/sealedmaterials-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/sealedmaterials.xcresult" > "$WORK/sealedmaterials-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group sealedmaterials \
    --summary "$WORK/sealedmaterials-summary.json" --tests "$WORK/sealedmaterials-tests.json"
fi
if [[ $YUEDU_RENEWAL_SELECTION == boundmaterials ]]; then
  # One cold build and one exact 78-method result for affected material and host paths.
  # Historical groups retain their original selections and timeout budgets.
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/boundmaterials-tests.log" -t 2700 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/boundmaterials.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests' \
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalProvisioningProfileVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests' \
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests' \
    -only-testing:'yuedu appTests/SelfRenewalApplicationMaterialVerifierTests' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/commitsSameOwnerAtomicallyAndSkipsUnchangedWrites' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/enforcesCancellationDeadlineAndBoundedLeases' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/isolatesSourcesAndPreservesVerbatimValues' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/preservesExplicitOptionsAndRawLoginPayloads' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/preservesOldStateWhenOwnerWritesFail' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/rejectsStaleSourceLoginAndBindingRevisions' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/rejectsUnsupportedTransactionsBeforeAnyWrite' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/reusesLegacyCacheAndPreservesTTL' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/sourceBridgeRemovalPreservesCredentials'
  xcrun xcresulttool get test-results summary --path "$WORK/boundmaterials.xcresult" > "$WORK/boundmaterials-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/boundmaterials.xcresult" > "$WORK/boundmaterials-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group boundmaterials \
    --summary "$WORK/boundmaterials-summary.json" --tests "$WORK/boundmaterials-tests.json"
fi
if [[ $YUEDU_RENEWAL_SELECTION == controlledsigning ]]; then
  # Preserve the historical23 cases. Vault now has later current-core tests,
  # so its seven original methods must be qualified rather than suite-wide.
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/controlledsigning-tests.log" -t 2700 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/controlledsigning.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests' \
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/boundsLifetimeAndPreservesUnrelatedKeychainItems' \
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/preservesPublicationWhenManifestSaveFails' \
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/publishesReloadsSignsAndRevokesOwnedKeychainMaterial' \
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/recoversPendingKeyJournalWithoutDeletingPublishedKey' \
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsExpiredProfilesAndLocallyRevokedLeases' \
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsSignedIdentityAndKeyChangesWithoutReplacingOldMaterial' \
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsStaleCASAndCancellationBeforePublication' \
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests'
  xcrun xcresulttool get test-results summary --path "$WORK/controlledsigning.xcresult" > "$WORK/controlledsigning-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/controlledsigning.xcresult" > "$WORK/controlledsigning-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group controlledsigning \
    --summary "$WORK/controlledsigning-summary.json" --tests "$WORK/controlledsigning-tests.json"
fi
if [[ $YUEDU_RENEWAL_SELECTION == integratedrenewal ]]; then
  # Exact affected union, one cold build/result; no historical replay or SPM.
  INTEGRATED_TESTS=(
    -only-testing:'yuedu appTests/BookChapterStorageTests/audiobookPlayerSeesTheTableOfContents'
    -only-testing:'yuedu appTests/BookChapterStorageTests/cachedChapterMarkRewritesOnlyItsBook'
    -only-testing:'yuedu appTests/BookChapterStorageTests/deletingBookDeletesItsTableOfContents'
    -only-testing:'yuedu appTests/BookChapterStorageTests/inlineListFromOlderBuildWinsOverStaleFile'
    -only-testing:'yuedu appTests/BookChapterStorageTests/inlineShelfOpensCompleteAndMovesListsOut'
    -only-testing:'yuedu appTests/BookChapterStorageTests/positionSaveLeavesTablesOfContentsUntouched'
    -only-testing:'yuedu appTests/BookChapterStorageTests/readingRecordKeepsItsListOutsideItsFile'
    -only-testing:'yuedu appTests/BookChapterStorageTests/recordsCarrySummaryAndOpenedBookCarriesList'
    -only-testing:'yuedu appTests/BookChapterStorageTests/restoredShelfRegainsSummaryFromStoredLists'
    -only-testing:'yuedu appTests/BookChapterStorageTests/shelfFileCarriesNoTableOfContents'
    -only-testing:'yuedu appTests/BookChapterStorageTests/syncLeavesTableOfContentsLocal'
    -only-testing:'yuedu appTests/BookChapterStorageTests/unreadableShelfLeavesTablesOfContentsAlone'
    -only-testing:'yuedu appTests/LegadoBookStateOwnerTests'
    -only-testing:'yuedu appTests/LegadoChapterOwnerPersistenceTests'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/commitsSameOwnerAtomicallyAndSkipsUnchangedWrites' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/enforcesCancellationDeadlineAndBoundedLeases' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/isolatesSourcesAndPreservesVerbatimValues' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/preservesExplicitOptionsAndRawLoginPayloads' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/preservesOldStateWhenOwnerWritesFail' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/rejectsStaleSourceLoginAndBindingRevisions' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/rejectsUnsupportedTransactionsBeforeAnyWrite' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/reusesLegacyCacheAndPreservesTTL' \
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/sourceBridgeRemovalPreservesCredentials'
    -only-testing:'yuedu appTests/SelfRenewalApplicationMaterialVerifierTests'
    -only-testing:'yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests'
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests'
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests'
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests'
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests'
    -only-testing:'yuedu appTests/SelfRenewalProvisioningProfileVerifierTests'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests'
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/boundsLifetimeAndPreservesUnrelatedKeychainItems'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/preservesPublicationWhenManifestSaveFails'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/publishesReloadsSignsAndRevokesOwnedKeychainMaterial'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/recoversPendingKeyJournalWithoutDeletingPublishedKey'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsExpiredProfilesAndLocallyRevokedLeases'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsSignedIdentityAndKeyChangesWithoutReplacingOldMaterial'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsStaleCASAndCancellationBeforePublication'
  )
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/integratedrenewal-tests.log" -t 2700 -- "${ARGS[@]}" -resultBundlePath "$WORK/integratedrenewal.xcresult" "${INTEGRATED_TESTS[@]}"
  xcrun xcresulttool get test-results summary --path "$WORK/integratedrenewal.xcresult" > "$WORK/integratedrenewal-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/integratedrenewal.xcresult" > "$WORK/integratedrenewal-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group integratedrenewal --summary "$WORK/integratedrenewal-summary.json" --tests "$WORK/integratedrenewal-tests.json"
  # Test-action build settings only: no second test or compile invocation.
  xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json test > "$WORK/sdk-test-build-settings.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-sdk-fixture --work "$WORK" --phase after-tests > "$WORK/sdk-after-tests.log"
fi

if [[ $YUEDU_RENEWAL_SELECTION == transactionrenewal ]]; then
  # 178 qualified definitions, 180 actual Bool argument leaves, one cold result.
  TRANSACTION_TESTS=(
    -only-testing:'yuedu appTests/AozoraTXTTests/storedV6LocationsMigrateOnce(interrupt:)'
    -only-testing:'yuedu appTests/BookChapterStorageTests/audiobookPlayerSeesTheTableOfContents'
    -only-testing:'yuedu appTests/BookChapterStorageTests/cachedChapterMarkRewritesOnlyItsBook'
    -only-testing:'yuedu appTests/BookChapterStorageTests/deletingBookDeletesItsTableOfContents'
    -only-testing:'yuedu appTests/BookChapterStorageTests/inlineListFromOlderBuildWinsOverStaleFile'
    -only-testing:'yuedu appTests/BookChapterStorageTests/inlineShelfOpensCompleteAndMovesListsOut'
    -only-testing:'yuedu appTests/BookChapterStorageTests/positionSaveLeavesTablesOfContentsUntouched'
    -only-testing:'yuedu appTests/BookChapterStorageTests/readingRecordKeepsItsListOutsideItsFile'
    -only-testing:'yuedu appTests/BookChapterStorageTests/recordsCarrySummaryAndOpenedBookCarriesList'
    -only-testing:'yuedu appTests/BookChapterStorageTests/restoredShelfRegainsSummaryFromStoredLists'
    -only-testing:'yuedu appTests/BookChapterStorageTests/shelfFileCarriesNoTableOfContents'
    -only-testing:'yuedu appTests/BookChapterStorageTests/syncLeavesTableOfContentsLocal'
    -only-testing:'yuedu appTests/BookChapterStorageTests/unreadableShelfLeavesTablesOfContentsAlone'
    -only-testing:'yuedu appTests/BookStoreBackgroundPublishTests/cacheMarkDoesNotPublish'
    -only-testing:'yuedu appTests/BookStoreBackgroundPublishTests/refreshPublishesOnce'
    -only-testing:'yuedu appTests/BookStoreBackgroundPublishTests/reparsedUnchangedListIsNoChange'
    -only-testing:'yuedu appTests/BookStoreMetadataWriteBudgetTests/clearingDownloadAnnouncesCacheClear'
    -only-testing:'yuedu appTests/BookStoreMetadataWriteBudgetTests/completedOfflineDownloadPersistsImmediately'
    -only-testing:'yuedu appTests/BookStoreMetadataWriteBudgetTests/leavingForegroundFlushesDebouncedSave'
    -only-testing:'yuedu appTests/BookStoreMetadataWriteBudgetTests/tinyProgressChangesStayInMemoryUntilForcedSave'
    -only-testing:'yuedu appTests/BookStoreShelfRecoveryTests/relaunchReusesTheExistingCopy'
    -only-testing:'yuedu appTests/BookStoreShelfRecoveryTests/shelfThatCannotBeKeptAsideIsNotOverwritten'
    -only-testing:'yuedu appTests/BookStoreShelfRecoveryTests/unreadableShelfIsKeptAside'
    -only-testing:'yuedu appTests/LegadoBookMetadataOwnerTests/actualBookCallbacksRestoreShelfAndReadingVariables'
    -only-testing:'yuedu appTests/LegadoBookMetadataOwnerTests/exactTXTJournalRecoversPublicationConflicts'
    -only-testing:'yuedu appTests/LegadoBookMetadataOwnerTests/failedShelfReplacementKeepsBothDurableBookCopies'
    -only-testing:'yuedu appTests/LegadoBookMetadataOwnerTests/failedTXTBookmarkWriteKeepsOldMetadata'
    -only-testing:'yuedu appTests/LegadoBookMetadataOwnerTests/failedWritesAndCancellationKeepOldMetadata'
    -only-testing:'yuedu appTests/LegadoBookMetadataOwnerTests/olderQueuedMetadataCannotEraseAcceptedVariables'
    -only-testing:'yuedu appTests/LegadoBookMetadataOwnerTests/queuedTXTBookmarksKeepOtherBookVariables'
    -only-testing:'yuedu appTests/LegadoBookStateOwnerTests/corruptAndUnreadableChapterOwnersRemainErrors'
    -only-testing:'yuedu appTests/LegadoBookStateOwnerTests/hostCommitUsesOriginalChapterFileAndRestart'
    -only-testing:'yuedu appTests/LegadoBookStateOwnerTests/hostWriteFailureAndGenerationRevocationPreserveOldState'
    -only-testing:'yuedu appTests/LegadoBookStateOwnerTests/rejectsUnmappedIdentityAndUnsupportedTransactions'
    -only-testing:'yuedu appTests/LegadoBookStateOwnerTests/staleTocAndTaskCancellationRejectOldHostProofs'
    -only-testing:'yuedu appTests/LegadoChapterOwnerPersistenceTests/chapterVariableCasIsDurableAndKeepsFailedWritesInvisible'
    -only-testing:'yuedu appTests/LegadoChapterOwnerPersistenceTests/concurrentChapterMutationUsesOnePersistenceOwner'
    -only-testing:'yuedu appTests/LegadoChapterOwnerPersistenceTests/strictFlushFailurePreservesPreviousFileAndCanRetry'
    -only-testing:'yuedu appTests/LegadoChapterOwnerPersistenceTests/strictFlushTargetsOnlyTheBoundBook'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/commitsSameOwnerAtomicallyAndSkipsUnchangedWrites'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/enforcesCancellationDeadlineAndBoundedLeases'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/isolatesSourcesAndPreservesVerbatimValues'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/malformedStateInputsHaveTypedErrorsAndRetainProofs'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/preservesExplicitOptionsAndRawLoginPayloads'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/preservesOldStateWhenOwnerWritesFail'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/rejectsStaleSourceLoginAndBindingRevisions'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/rejectsUnsupportedTransactionsBeforeAnyWrite'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/reusesLegacyCacheAndPreservesTTL'
    -only-testing:'yuedu appTests/LegadoPersistentStateHostTests/sourceBridgeRemovalPreservesCredentials'
    -only-testing:'yuedu appTests/SelfRenewalApplicationMaterialVerifierTests/acceptsNewProfileUUIDWithPreservedBundleGroupsAndIdentity'
    -only-testing:'yuedu appTests/SelfRenewalApplicationMaterialVerifierTests/bindsRereadProfileBytesToEarlierResourceSeals'
    -only-testing:'yuedu appTests/SelfRenewalApplicationMaterialVerifierTests/rejectsSignedButInconsistentProfileAndEntitlementIdentities'
    -only-testing:'yuedu appTests/SelfRenewalApplicationMaterialVerifierTests/rejectsWholeChainResourceTamperingExpiryAndCancellation'
    -only-testing:'yuedu appTests/SelfRenewalApplicationMaterialVerifierTests/verifiesActualThreeBundleChainWithoutClaimingAppleAuthority'
    -only-testing:'yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests/cancellationWakesActualStalledTLSHandshakeWithoutLateWrites'
    -only-testing:'yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests/enforcesActualFrameProgressDeadlineAndArchiveBudgets'
    -only-testing:'yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests/rejectsActualAFCSequenceTruncationErrorsAndChangedArchiveDigest'
    -only-testing:'yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests/rejectsActualWrongDeviceHostAndExpiredTLSCertificates'
    -only-testing:'yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests/rejectsInvalidSessionServicePortsAndPlaintextDowngrades'
    -only-testing:'yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests/requiresTerminalCompleteAndExactPostUpgradeLookupIdentity'
    -only-testing:'yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests/uploadsRealTLSChunksAndRequiresCompleteLookupCleanupAndStop'
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests/rejectsCancelledVerification'
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests/rejectsChangedContentAndSignatures'
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests/rejectsMalformedDERAndOversizedInputs'
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests/rejectsMissingAndAmbiguousContent'
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests/rejectsUntrustedAndExpiredChains'
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests/verifiesECDSAAndEverySigner'
    -only-testing:'yuedu appTests/SelfRenewalCMSVerifierTests/verifiesIndependentRSAAndDetachedVectors'
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests/matchesIndependentDigestVectors'
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests/readsOwnedApplicationAndUsesBoundedMaterialIO'
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests/rejectsBudgetsTruncatedReadsAndCancellation'
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests/rejectsChangedPagesDigestsAndSpecialMaterials'
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests/rejectsMissingExtraAndUnsupportedSpecialSlots'
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests/verifiesFatAlternateAndUnpagedContentWithBoundedChunks'
    -only-testing:'yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests/verifiesFourAlgorithmsAndAllKnownSpecialMaterials'
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests/allocatesBeforeHashingAndErasesOldSignatureTail'
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests/cancelsAndEnforcesReadAndCapacityBudgets'
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests/preservesIdentityAndEverySpecialBlobByte'
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests/rebuildsAllDigestKindsAndAgileCodeDirectories'
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests/refusesWrongKeysAnchorsAndTamperedOriginal'
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests/rejectsUnsupportedLayoutAndUnboundInputs'
    -only-testing:'yuedu appTests/SelfRenewalControlledMachOSignerTests/signsRealRSAAndECDSAAndAuthenticatesActualLeaf'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/bindsExactRawCMSProfileBytesToReopenedLease'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/preservesOwnedFilesOnWrongPreimageAndInvalidatesEscapedScope'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/rejectsCancelledPackageWithoutChangingInput'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/rejectsDifferentActualGroupsWithinSameVerifiedProfileAllowance'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/rejectsDynamicSymbolTableBoundsAndMissingSymbolTable'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/rejectsFalseAndUnresolvedOriginalNestedRequirements'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/rejectsRevokedAndStaleLeasesWithoutChangingInput'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/resignsDynamicSymbolTablesAndDylibAtStableOffsets'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/signsOwnedThreeBundlePackageAndReverifiesActualArchiveBytes'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/signsSDKProducedMainExtensionsAndFrameworkInSameJob'
    -only-testing:'yuedu appTests/SelfRenewalControlledPackageSignerTests/updatesVerifiedResourceSealsWithoutWideningRulesOrRequirements'
    -only-testing:'yuedu appTests/SelfRenewalControlledRenewalCoordinatorTests/persistsAndSubmitsActualVerifiedPackageWithoutTouchingUserStores'
    -only-testing:'yuedu appTests/SelfRenewalControlledRenewalCoordinatorTests/recoversActualPackageUploadWithFreshAuthenticatedCleanup'
    -only-testing:'yuedu appTests/SelfRenewalControlledRenewalCoordinatorTests/recoversUnknownUpgradeWithoutUploadingOrSubmittingTwice'
    -only-testing:'yuedu appTests/SelfRenewalControlledRenewalCoordinatorTests/rejectsChangedCandidateBeforeOpeningAuthenticatedTransport'
    -only-testing:'yuedu appTests/SelfRenewalControlledRenewalCoordinatorTests/rejectsRevokedMaterialBeforeAnyUploadOrUpgrade'
    -only-testing:'yuedu appTests/SelfRenewalControlledRenewalCoordinatorTests/retainsUploadOwnershipAfterActualPartialAFCFailure'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/cleansOwnedStagingOnArchiveAndMaterialFailure'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/enforcesCompressedExpandedAndEntryBudgets'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/rejectsCRCDeflateTailTruncationAndActualExpansion'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/rejectsHeaderLayoutAndDescriptorDisagreements'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/rejectsLinksTypesDuplicatesAndEncodingOverrides'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/rejectsSourceLinksAndPropagatesCancellation'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/rejectsTraversalAndAmbiguousPaths'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/verifiesDeflateAndBothDataDescriptorForms'
    -only-testing:'yuedu appTests/SelfRenewalIPAUnpackerTests/verifiesOwnedStoredIPAThroughSealedMaterials'
    -only-testing:'yuedu appTests/SelfRenewalInstallationRecoveryTests/acceptsActualMissingACKAndRetainsRemovalWhenStopDisconnects'
    -only-testing:'yuedu appTests/SelfRenewalInstallationRecoveryTests/cancellationAndDeadlineReleaseGrantForFreshAuthenticatedRetry'
    -only-testing:'yuedu appTests/SelfRenewalInstallationRecoveryTests/keepsOriginalErrorSeparateFromRemoteCleanupAndJournalFailures'
    -only-testing:'yuedu appTests/SelfRenewalInstallationRecoveryTests/rejectsStaleMalformedAndWrongDeviceGrantsBeforeAnyRemoval'
    -only-testing:'yuedu appTests/SelfRenewalInstallationRecoveryTests/removesPersistedOwnedUploadAfterFreshMutualTLSAndClearsJournalPhase'
    -only-testing:'yuedu appTests/SelfRenewalInstallationRecoveryTests/retainsUnknownSubmittedUpgradeAndUsesOnlyAuthenticatedLookup'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/handlesUnsignedTruncatedAndCancelledInputs'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/readsFat32And64InBothByteOrders'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/readsKnownDirectoryVersionsAndEmptyCMSWithoutAssumingTrust'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/readsOwnedUnpackedAppThroughInventoryAndRejectsLinkedCode'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/readsThinSignaturesWithoutReadingExecutableBodiesOrClaimingTrust'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/rejectsDamagedEmbeddedSignatureStructures'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/rejectsInvalidCodeDirectoryOffsetsAndUnsupportedLayouts'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/rejectsMalformedAndUnknownRequiredLoadCommands'
    -only-testing:'yuedu appTests/SelfRenewalMachOSignatureReaderTests/rejectsMalformedFatTablesAndOverlappingSlices'
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests/enforcesDirectoryAndByteLimits'
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests/parsesBoundedMetadataAndRejectsDamagedOrUnsafeValues'
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests/readsThreeBundleFactsWithoutTrustAssertion'
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests/rejectsLinkedMaterials'
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests/reportsIncompleteAndConflictingRoleStructure'
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests/retainsAdditionalPotentialSignedComponents'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests/authenticatesBothCMSLayersAndUsesModernSourceOfTruth'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests/decodesCanonicalDatesAndRejectsInvalidCalendarValues'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests/decodesIndependentTypedPropertyValues'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests/decodesVersionedCoreEntitlementsAndRejectsUnknownVersion'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests/enforcesPropertyBudgetsAndCancellation'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests/readsModernProfileFromSameInventoryAndRejectsReplacedLinks'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests/rejectsAmbiguousAndMalformedProperties'
    -only-testing:'yuedu appTests/SelfRenewalModernProfileVerifierTests/rejectsInvalidInnerCMSAndAuthoritativeValidity'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests/evaluatesBooleanCertificateAndAttributeGrammar'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests/preservesHintAndLegacyAuthenticationMeaning'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests/preservesUnresolvedPolicyWithoutRejectingComplexSupportedExpressions'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests/rejectsChangedBoundAttributesAndCancellation'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests/rejectsFalseRequirementAndWrongSelectedOrUniversalIdentity'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests/rejectsNestedResourceAndCMSTampering'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests/retainsActualSystemPolicyAsUnresolved'
    -only-testing:'yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests/verifiesActualNestedBundlesAndPublishesBoundDERAttributes'
    -only-testing:'yuedu appTests/SelfRenewalProvisioningProfileVerifierTests/readsSignedSummaryAndRejectsValidityFailures'
    -only-testing:'yuedu appTests/SelfRenewalProvisioningProfileVerifierTests/verifiesOwnedProfileThroughInventory'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/appliesPOSIXWeightedRules'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/hashesIndependentVectorsWithBoundedChunks'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/preservesOptionalSealSemantics'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/rejectsChangedAddedMissingAndWrongTypes'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/rejectsEnvelopeOrCodeDirectoryChangedAfterHashPass'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/rejectsMalformedEnvelopeAndLimits'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/rejectsShortReadsAndCancellation'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/selectsEnvelopeVersionAndLegacyHashFallback'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/traversesNestedAndOmittedDirectoriesWithoutTrustClaims'
    -only-testing:'yuedu appTests/SelfRenewalResourceSealVerifierTests/verifiesOwnedApplicationAndRejectsResourceChanges'
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests/authenticatesDetachedPrimaryAndPreservesLegacyUnboundAlternate'
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests/bindsOriginalHashAgilityEncodingsAndRejectsWrongValues'
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests/enforcesSharedOwnedFileReadBoundaryIncludingEmptyFiles'
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests/preservesOriginalAlternateOrderAndAdHocSemantics'
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests/readsOwnedAppAndKeepsGenericAnchorsSeparateFromAppleAuthority'
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests/rejectsChangedReadBudgetsAndCancellationAcrossSlices'
    -only-testing:'yuedu appTests/SelfRenewalSignedCodeVerifierTests/supportsOriginalTruncatedCDHashAndRejectsAgilityOIDCollisions'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/boundsLifetimeAndPreservesUnrelatedKeychainItems'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/preservesPublicationWhenManifestSaveFails'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/publishesReloadsSignsAndRevokesOwnedKeychainMaterial'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/recoversPendingKeyJournalWithoutDeletingPublishedKey'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsExpiredProfilesAndLocallyRevokedLeases'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsSignedIdentityAndKeyChangesWithoutReplacingOldMaterial'
    -only-testing:'yuedu appTests/SelfRenewalSigningMaterialVaultTests/rejectsStaleCASAndCancellationBeforePublication'
    -only-testing:'yuedu appTests/SelfRenewalTransactionJournalTests/excludesSecondOwnerAndReopensDurableCheckpoint'
    -only-testing:'yuedu appTests/SelfRenewalTransactionJournalTests/reclaimsAbandonedOwnedTemporaryAfterProcessInterruption'
    -only-testing:'yuedu appTests/SelfRenewalTransactionJournalTests/rejectsContradictoryDurablePhaseInsteadOfResubmitting'
    -only-testing:'yuedu appTests/SelfRenewalTransactionJournalTests/rejectsFailedCandidateWithoutAcknowledgingOrReplacingState'
    -only-testing:'yuedu appTests/TXTReaderIndexMigrationTests/migrationPreservesBookmarksAndReplaysInterruptedCommit(interrupt:)'
    -only-testing:'yuedu appTests/TXTReaderIndexMigrationTests/newImportPublishesOnlyThroughTheCommitOwner'
    -only-testing:'yuedu appTests/WebDAVRestoreIntegrityTests/localSummaryAndTXTWriterRespectBoundary'
  )
  set +e
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/transactionrenewal-tests.log" -t 2700 -- "${ARGS[@]}" -resultBundlePath "$WORK/transactionrenewal.xcresult" "${TRANSACTION_TESTS[@]}"
  NATIVE_EXIT=$?
  set -e
  # Preserve raw summary/tree/details even on compile/test failure. Collection
  # cannot turn a nonzero native result into a successful test invocation.
  set +e
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" collect-xcresult --work "$WORK" --group transactionrenewal --native-exit "$NATIVE_EXIT" > "$WORK/transactionrenewal-export.log"
  EXPORT_EXIT=$?
  set -e
  [[ $NATIVE_EXIT == 0 ]] || exit "$NATIVE_EXIT"
  [[ $EXPORT_EXIT == 0 ]] || exit "$EXPORT_EXIT"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group transactionrenewal --summary "$WORK/transactionrenewal-summary.json" --tests "$WORK/transactionrenewal-tests.json"
  xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json test > "$WORK/sdk-test-build-settings.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-sdk-fixture --work "$WORK" --phase after-tests > "$WORK/sdk-after-tests.log"
fi

if [[ $YUEDU_RENEWAL_SELECTION == all ]]; then
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/ui-tests.log" -t 1200 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/ui.xcresult" \
    -only-testing:'yuedu appUITests/SelfRenewalProbeUITests'
  xcrun xcresulttool get test-results summary --path "$WORK/ui.xcresult" > "$WORK/ui-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/ui.xcresult" > "$WORK/ui-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group ui \
    --summary "$WORK/ui-summary.json" --tests "$WORK/ui-tests.json"
fi
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json > "$WORK/build-settings.json"
python3 "$SCRIPT_DIR/renewal-probe-tools.py" result --work "$WORK" > "$WORK/result.log"
