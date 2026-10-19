#!/usr/bin/env bash
# Target local-mode configuration, search paging, TXT and one loopback JSC source.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="$REPO_DIR/.build/reader-smoke"
[[ $(uname -s) == Darwin ]] || { echo 'Reader smoke requires macOS/Xcode.' >&2; exit 2; }
mkdir -p "$WORK"
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
export YUEDU_DEST=${YUEDU_DEST:-$(bash "$REPO_DIR/scripts/sim.sh" dest)}
export LEGADO_RUNTIME_SOURCE_ONLY=1
python3 "$SCRIPT_DIR/smoke-tools.py" prepare --directory "$WORK" > "$WORK/prepare.log"
xcodebuild -version > "$WORK/xcode-version.log"
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
# Simulator ad-hoc signing is local and uses no developer account. Unlike an
# unsigned device package, XCTest must launch/attach to these executable hosts.
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/cloudkit-tests.log" -t 2700 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/cloudkit.xcresult" \
  -only-testing:'yuedu appTests/AuthAndICloudConfigurationTests'
xcrun xcresulttool get test-results summary --path "$WORK/cloudkit.xcresult" > "$WORK/cloudkit-summary.json"
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/cloudkit-summary.json" --expected 9
# Product changes have their own exact gate: account policy, real bundled fonts,
# cache-only TXT output, simplified UI and disabled upstream library requests.
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/local-product-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/local-product.xcresult" \
  -only-testing:'yuedu appTests/ReaderLocalProductTests' \
  -only-testing:'yuedu appTests/ReaderFontCatalogTests' \
  -only-testing:'yuedu appTests/CachedBookTXTExportTests' \
  -only-testing:'yuedu appTests/UserFontSettingsTests' \
  -only-testing:'yuedu appTests/SubscriptionPublicationTests' \
  -only-testing:'yuedu appTests/PublicLibraryAvailabilityTests' \
  -only-testing:'yuedu appTests/RemoteLibraryHTTPTests'
xcrun xcresulttool get test-results summary --path "$WORK/local-product.xcresult" > "$WORK/local-product-summary.json"
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/local-product-summary.json" --expected 41
# Check actual position files, cold scroll restoration and the TXT migration
# journal contract independently of the unchanged local-product verdict.
# Counts include the four content variants and interrupted migration arguments:
# 5 persistence cases + 12 scroll executions + 6 migration executions = 23.
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/reading-position-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/reading-position.xcresult" \
  -only-testing:'yuedu appTests/ReadingPositionStorePersistenceTests' \
  -only-testing:'yuedu appTests/ContinuousScrollRestoreTests' \
  -only-testing:'yuedu appTests/TXTReaderIndexMigrationTests'
xcrun xcresulttool get test-results summary --path "$WORK/reading-position.xcresult" > "$WORK/reading-position-summary.json"
xcrun xcresulttool get test-results tests --path "$WORK/reading-position.xcresult" > "$WORK/reading-position-tests.json"
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/reading-position-summary.json" --expected 13 --expected-executions 23
# Keep paging separate from configuration and product tests: a skipped or empty
# SearchAutoPagingTests invocation cannot satisfy either group's count.
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/paging-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/paging.xcresult" \
  -only-testing:'yuedu appTests/SearchAutoPagingTests'
xcrun xcresulttool get test-results summary --path "$WORK/paging.xcresult" > "$WORK/paging-summary.json"
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/paging-summary.json" --expected 12
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json > "$WORK/build-settings.json"
# Batch-end reader comfort checks reuse the same prepared host and incremental
# build. Keep this result independent from every unchanged acceptance group above.
# Methods/executions: publications 9/9 + scope 20/20 + panel 2/2 + viewport 6/6
# + viewport hosting 1/1 + layout import 10/10 + export 6/6 + live style 2/4
# + restore/commit offsets 3/3 + reader-stage baseline 1/1 = 60/62.
# The single Swift Testing method selector follows the existing selector form in
# docs/browser-layout/extraction/commands.md. No source-session benchmark is run.
xcrun --sdk iphonesimulator --show-sdk-version > "$WORK/reader-stage-sdk-version.log"
xcrun simctl list --json > "$WORK/reader-stage-simulators.json"
python3 "$SCRIPT_DIR/reader-stage-baseline.py" capture-environment \
  --audit "$WORK/overlays.json" --settings "$WORK/build-settings.json" \
  --xcode "$WORK/xcode-version.log" --sdk "$WORK/reader-stage-sdk-version.log" \
  --simulators "$WORK/reader-stage-simulators.json" --destination "$YUEDU_DEST" \
  --developer-directory "$DEVELOPER_DIR" --output "$WORK/reader-stage-environment.json" \
  > "$WORK/reader-stage-environment-capture.log"
# A failed run must still retain its raw metric lines. Gather raw xcresult output
# and invoke the collector before enforcing the wrapper/artifact exit codes.
reader_test_status=0
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/reader-experience-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/reader-experience.xcresult" \
  -only-testing:'yuedu appTests/ReaderSettingsPublicationTests' \
  -only-testing:'yuedu appTests/ReadingSettingsScopeTests' \
  -only-testing:'yuedu appTests/ReaderQuickThemePanelLayoutTests' \
  -only-testing:'yuedu appTests/ReaderViewportSizeObserverTests' \
  -only-testing:'yuedu appTests/ReaderViewportSizeObserverHostingTests' \
  -only-testing:'yuedu appTests/ReaderLayoutPresetImporterTests' \
  -only-testing:'yuedu appTests/ReaderSettingsExportTests' \
  -only-testing:'yuedu appTests/ReaderLiveStyleRefreshTests' \
  -only-testing:'yuedu appTests/ScrollOffsetEquivalenceTests' \
  -only-testing:'yuedu appTests/ReaderArchitectureBenchmarkTests/readerStageLatency' || reader_test_status=$?
reader_artifact_status=0
xcrun xcresulttool get test-results summary --path "$WORK/reader-experience.xcresult" > "$WORK/reader-experience-summary.json" || reader_artifact_status=$?
xcrun xcresulttool get test-results tests --path "$WORK/reader-experience.xcresult" > "$WORK/reader-experience-tests.json" || reader_artifact_status=$?
reader_baseline_status=0
python3 "$SCRIPT_DIR/reader-stage-baseline.py" collect \
  --audit "$WORK/overlays.json" --log "$WORK/reader-experience-tests.log" \
  --test-exit-status "$reader_test_status" \
  --summary "$WORK/reader-experience-summary.json" --environment "$WORK/reader-stage-environment.json" \
  --raw "$WORK/reader-stage-raw.log" --output "$WORK/reader-stage-baseline.json" \
  > "$WORK/reader-stage-collection.log" 2>&1 || reader_baseline_status=$?
reader_count_status=0
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/reader-experience-summary.json" \
  --expected 60 --expected-executions 62 > "$WORK/reader-experience-result.json" || reader_count_status=$?
# Fixed synthetic chapter-supply scenarios have their own gate. Do not change
# the established reader-experience 60/62 contract to absorb these new cases.
# Prefetch 1 method / 2 executions + modern cache 2 methods / 4 executions = 3/6.
# Logs retain READER_PREFETCH_SCENARIO peaks/order/cancellation observations.
supply_test_status=0
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/reader-supply-scenarios-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/reader-supply-scenarios.xcresult" \
  -only-testing:'yuedu appTests/ReaderPrefetchScenarioTests' \
  -only-testing:'yuedu appTests/ModernChapterCacheScenarioTests' || supply_test_status=$?
supply_artifact_status=0
xcrun xcresulttool get test-results summary --path "$WORK/reader-supply-scenarios.xcresult" > "$WORK/reader-supply-scenarios-summary.json" || supply_artifact_status=$?
xcrun xcresulttool get test-results tests --path "$WORK/reader-supply-scenarios.xcresult" > "$WORK/reader-supply-scenarios-tests.json" || supply_artifact_status=$?
supply_count_status=0
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/reader-supply-scenarios-summary.json" \
  --expected 3 --expected-executions 6 > "$WORK/reader-supply-scenarios-result.json" || supply_count_status=$?
# Preserve original content/review fields and guard the existing mainJs import /
# storage / sharing paths. This is schema preservation, not rule execution.
# Content 6/23 + review 7/21 + existing mainJs regression 6/6 = 19/50.
schema_test_status=0
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/source-schema-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/source-schema.xcresult" \
  -only-testing:'yuedu appTests/BookSourceContentRulePreservationTests' \
  -only-testing:'yuedu appTests/BookSourceReviewRulePreservationTests' \
  -only-testing:'yuedu appTests/BookSourceMainJSPreservationTests' || schema_test_status=$?
schema_artifact_status=0
xcrun xcresulttool get test-results summary --path "$WORK/source-schema.xcresult" > "$WORK/source-schema-summary.json" || schema_artifact_status=$?
xcrun xcresulttool get test-results tests --path "$WORK/source-schema.xcresult" > "$WORK/source-schema-tests.json" || schema_artifact_status=$?
schema_count_status=0
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/source-schema-summary.json" \
  --expected 19 --expected-executions 50 > "$WORK/source-schema-result.json" || schema_count_status=$?
# Owned three-file WebDAV restore faults are independent from rule compatibility.
# 12 methods / 27 executions; real BookStore writer coordination is included.
restore_test_status=0
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/webdav-restore-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/webdav-restore.xcresult" \
  -only-testing:'yuedu appTests/WebDAVRestoreIntegrityTests' || restore_test_status=$?
restore_artifact_status=0
xcrun xcresulttool get test-results summary --path "$WORK/webdav-restore.xcresult" > "$WORK/webdav-restore-summary.json" || restore_artifact_status=$?
xcrun xcresulttool get test-results tests --path "$WORK/webdav-restore.xcresult" > "$WORK/webdav-restore-tests.json" || restore_artifact_status=$?
restore_count_status=0
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/webdav-restore-summary.json" \
  --expected 12 --expected-executions 27 > "$WORK/webdav-restore-result.json" || restore_count_status=$?
# Collect all four new groups before enforcing their independent verdicts, so
# an incomplete baseline cannot hide supply/schema evidence. Earlier gates and
# the TXT/loopback acceptance protocols keep their established behavior.
[[ $reader_test_status == 0 && $reader_artifact_status == 0 && $reader_baseline_status == 0 && $reader_count_status == 0 \
   && $supply_test_status == 0 && $supply_artifact_status == 0 && $supply_count_status == 0 \
   && $schema_test_status == 0 && $schema_artifact_status == 0 && $schema_count_status == 0 \
   && $restore_test_status == 0 && $restore_artifact_status == 0 && $restore_count_status == 0 ]]
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/txt-ui-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/txt-ui.xcresult" \
  -only-testing:'yuedu appUITests/ReaderLocalSmokeUITests'
xcrun xcresulttool get test-results summary --path "$WORK/txt-ui.xcresult" > "$WORK/txt-ui-summary.json"
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/txt-ui-summary.json" --expected 1
python3 "$SCRIPT_DIR/smoke-tools.py" result --audit "$WORK/overlays.json" --settings "$WORK/build-settings.json" \
  --unit "$WORK/cloudkit-summary.json" --paging "$WORK/paging-summary.json" \
  --ui "$WORK/txt-ui-summary.json" --product "$WORK/local-product-summary.json" --output "$WORK/result.json"
# Preserve the independent TXT verdict even if this additional source case fails.
# The fixture process belongs to this invocation; bind/readiness errors never
# fall back to an existing server. Its requests and cleanup record are retained.
python3 "$SCRIPT_DIR/run-online-smoke.py" run --work "$WORK" -- \
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/online-ui-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/online-ui.xcresult" \
  -only-testing:'yuedu appUITests/ReaderBookSourceSmokeUITests'
xcrun xcresulttool get test-results summary --path "$WORK/online-ui.xcresult" > "$WORK/online-ui-summary.json"
python3 "$SCRIPT_DIR/run-online-smoke.py" result --work "$WORK" \
  --summary "$WORK/online-ui-summary.json" --output "$WORK/online-result.json"
