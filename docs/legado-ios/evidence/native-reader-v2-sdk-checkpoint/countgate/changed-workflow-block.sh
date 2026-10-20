unset LEGADO_RUNTIME_SOURCE_ONLY
ARGS=(
  -configuration Debug -onlyUsePackageVersionsFromResolvedFile
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=
  GATEWAY_BASE_URL= YUEDU_LOCAL_EXPERIENCE=YES IPHONEOS_DEPLOYMENT_TARGET=18.0
  ENABLE_DEBUG_DYLIB=NO
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LEGADO_REQUIRE_NATIVE_MAINJS'
)
# The static JVM belongs to the main executable. Check its real exports
# before launching the host, rather than checking an Xcode debug stub.
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "$YUEDU_DEST" "${ARGS[@]}" build-for-testing 2>&1 | tee .build/native-reader-test/native-build.log
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json > .build/native-reader-test/build-settings.json
APP=$(python3 -c 'import json; from pathlib import Path; s=[i["buildSettings"] for i in json.load(open(".build/native-reader-test/build-settings.json")) if i.get("target")=="yuedu app"]; assert len(s)==1; print(Path(s[0]["TARGET_BUILD_DIR"])/s[0]["FULL_PRODUCT_NAME"])')
python -B scripts/legado-ios/verify-native-exports.py --executable "$APP/YueduReader" --report .build/native-reader-test/native-exports.json
# Reuse the same prepared app for independent local-product checks.
# The two native groups below require separate host launches. MainJS
# sets tracing before its JVM starts; no suite-order assumption is safe.
set +e
bash scripts/xctest.sh -l .build/native-reader-test/configuration.log -t 900 -- \
  "${ARGS[@]}" -resultBundlePath .build/native-reader-test/configuration.xcresult \
  -only-testing:'yuedu appTests/AuthAndICloudConfigurationTests'
CONFIGURATION_STATUS=$?
bash scripts/xctest.sh -l .build/native-reader-test/local-product-regressions.log -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath .build/native-reader-test/local-product-regressions.xcresult \
  -only-testing:'yuedu appTests/ReaderLocalProductTests' \
  -only-testing:'yuedu appTests/ReaderFontCatalogTests' \
  -only-testing:'yuedu appTests/CachedBookTXTExportTests' \
  -only-testing:'yuedu appTests/UserFontSettingsTests' \
  -only-testing:'yuedu appTests/SubscriptionPublicationTests' \
  -only-testing:'yuedu appTests/PublicLibraryAvailabilityTests' \
  -only-testing:'yuedu appTests/RemoteLibraryHTTPTests'
LOCAL_PRODUCT_STATUS=$?
bash scripts/xctest.sh -l .build/native-reader-test/cache-regressions.log -t 900 -- \
  "${ARGS[@]}" -resultBundlePath .build/native-reader-test/cache-regressions.xcresult \
  -only-testing:'yuedu appTests/ChapterCacheMigrationTests' \
  -only-testing:'yuedu appTests/ChapterCacheRepositoryWriteTests'
CACHE_STATUS=$?
python -B scripts/reader-experience/native-smoke-tools.py run-group --group mainjs
NATIVE_STATUS=$?
python -B scripts/reader-experience/native-smoke-tools.py run-group --group original
ORIGINAL_STATUS=$?
# Export every available group's evidence before evaluating verdicts.
# Missing bundles and failed exports remain failures, not empty passes.
export_test_results() {
  local bundle="$1" summary="$2" tests="$3"
  if [[ ! -d "$bundle" ]]; then
    echo "Missing test result bundle: $bundle" >&2
    return 1
  fi
  xcrun xcresulttool get test-results summary --path "$bundle" > "$summary"
  local summary_status=$?
  xcrun xcresulttool get test-results tests --path "$bundle" > "$tests"
  local tests_status=$?
  [[ $summary_status == 0 && $tests_status == 0 ]]
}
export_test_results .build/native-reader-test/configuration.xcresult \
  .build/native-reader-test/configuration-summary.json .build/native-reader-test/configuration-tests.json
CONFIGURATION_EXPORT_STATUS=$?
export_test_results .build/native-reader-test/local-product-regressions.xcresult \
  .build/native-reader-test/local-product-summary.json .build/native-reader-test/local-product-tests.json
LOCAL_PRODUCT_EXPORT_STATUS=$?
export_test_results .build/native-reader-test/cache-regressions.xcresult \
  .build/native-reader-test/cache-summary.json .build/native-reader-test/cache-tests.json
CACHE_EXPORT_STATUS=$?
# Both native runners already retain independent original exports,
# exact case gates and command/source ledgers, including on failure.
python -B scripts/reader-experience/smoke-tools.py verify-summary \
  --summary .build/native-reader-test/configuration-summary.json --expected 9
CONFIGURATION_COUNT_STATUS=$?
python -B scripts/reader-experience/smoke-tools.py verify-local-product \
  --summary .build/native-reader-test/local-product-summary.json \
  --tests .build/native-reader-test/local-product-tests.json
LOCAL_PRODUCT_COUNT_STATUS=$?
python -B scripts/reader-experience/native-smoke-tools.py verify-cache \
  --summary .build/native-reader-test/cache-summary.json \
  --tests .build/native-reader-test/cache-tests.json
CACHE_COUNT_STATUS=$?
NATIVE_RESULT_STATUS=1
if [[ $NATIVE_STATUS == 0 && $ORIGINAL_STATUS == 0 ]]; then
  python -B scripts/reader-experience/native-smoke-tools.py result
  NATIVE_RESULT_STATUS=$?
fi
set -e
[[ $CONFIGURATION_STATUS == 0 && $LOCAL_PRODUCT_STATUS == 0 && $CACHE_STATUS == 0 && $NATIVE_STATUS == 0 && $ORIGINAL_STATUS == 0 \
  && $CONFIGURATION_EXPORT_STATUS == 0 && $LOCAL_PRODUCT_EXPORT_STATUS == 0 && $CACHE_EXPORT_STATUS == 0 \
  && $CONFIGURATION_COUNT_STATUS == 0 && $LOCAL_PRODUCT_COUNT_STATUS == 0 && $CACHE_COUNT_STATUS == 0 && $NATIVE_RESULT_STATUS == 0 ]]
