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
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/txt-ui-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/txt-ui.xcresult" \
  -only-testing:'yuedu appUITests/ReaderLocalSmokeUITests'
xcrun xcresulttool get test-results summary --path "$WORK/txt-ui.xcresult" > "$WORK/txt-ui-summary.json"
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/txt-ui-summary.json" --expected 1
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json > "$WORK/build-settings.json"
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
# Batch-end reader comfort checks reuse the same prepared host and incremental
# build. Keep this result independent from every unchanged acceptance group above.
# Methods/executions: publications 9/9 + scope 20/20 + panel 2/2 + viewport 6/6
# + viewport hosting 1/1 + layout import 10/10 + export 6/6 + live style 2/4
# + restore/commit offsets 3/3 + reader-stage baseline 1/1 = 60/62.
# The single Swift Testing method selector follows the existing selector form in
# docs/browser-layout/extraction/commands.md. No source-session benchmark is run.
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
  -only-testing:'yuedu appTests/ReaderArchitectureBenchmarkTests/readerStageLatency'
xcrun xcresulttool get test-results summary --path "$WORK/reader-experience.xcresult" > "$WORK/reader-experience-summary.json"
xcrun xcresulttool get test-results tests --path "$WORK/reader-experience.xcresult" > "$WORK/reader-experience-tests.json"
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/reader-experience-summary.json" \
  --expected 60 --expected-executions 62 > "$WORK/reader-experience-result.json"
