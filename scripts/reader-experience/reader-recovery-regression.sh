#!/usr/bin/env bash
# Reuse this run's compiled native test host; retain all new verdicts separately.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="$REPO_DIR/.build/reader-recovery-regression"
NATIVE="$REPO_DIR/.build/jimage-native-check"
[[ $(uname -s) == Darwin ]] || { echo 'Reader recovery regression requires macOS/Xcode.' >&2; exit 2; }
[[ ! -e "$WORK" ]] || { echo 'Preserve prior reader-recovery evidence.' >&2; exit 2; }
mkdir -p "$WORK"
unset LEGADO_RUNTIME_SOURCE_ONLY
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
export YUEDU_DEST="$(cat "$NATIVE/destination.txt")"
SIMULATOR_UDID=${YUEDU_DEST#id=}
printf '%s\n' "$YUEDU_DEST" > "$WORK/destination.txt"
python3 -B "$SCRIPT_DIR/reader-recovery-regression.py" prepare --work "$WORK"
python3 -B "$SCRIPT_DIR/jimage-native-check.py" prepare --work "$WORK"
trap 'python3 -B "$SCRIPT_DIR/jimage-native-check.py" restore --work "$WORK"' EXIT
ARGS=(
  -configuration Debug -onlyUsePackageVersionsFromResolvedFile
  ARCHS=arm64 IPHONEOS_DEPLOYMENT_TARGET=18.0
  ENABLE_DEBUG_DYLIB=NO
  'OTHER_SWIFT_FLAGS=$(inherited) -DLEGADO_REQUIRE_NATIVE_MAINJS -DLEGADO_REQUIRE_MODULE_IMAGE'
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
xcodebuild -version > "$WORK/xcode-version.log"
run_group() {
  local name=$1
  shift
  # The original three gates leave this Simulator shut down. Every later group
  # gets a real shutdown/boot boundary, including the additional JNI method.
  if [[ $name != unit ]]; then
    xcrun simctl shutdown "$SIMULATOR_UDID" > "$WORK/$name-lifecycle.log" 2>&1
  fi
  xcrun simctl bootstatus "$SIMULATOR_UDID" -b >> "$WORK/$name-lifecycle.log" 2>&1
  local status=0
  if [[ $name == failure-ui ]]; then
    YUEDU_TEST_ACTION=test-without-building python3 -B "$SCRIPT_DIR/run-reader-failure-smoke.py" run --work "$WORK" -- \
      bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/$name.log" -t 1200 -- "${ARGS[@]}" \
      -resultBundlePath "$WORK/$name.xcresult" "$@" || status=$?
  else
    YUEDU_TEST_ACTION=test-without-building bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/$name.log" -t 1200 -- \
      "${ARGS[@]}" -resultBundlePath "$WORK/$name.xcresult" "$@" || status=$?
  fi
  printf '%s\n' "$status" > "$WORK/$name-exit-status.txt"
  local artifacts=0
  xcrun xcresulttool get test-results summary --path "$WORK/$name.xcresult" > "$WORK/$name-summary.json" || artifacts=$?
  xcrun xcresulttool get test-results tests --path "$WORK/$name.xcresult" > "$WORK/$name-tests.json" || artifacts=$?
  printf '%s\n' "$artifacts" > "$WORK/$name-artifact-exit-status.txt"
}
run_group unit \
  -only-testing:'yuedu appTests/ReaderViewModelChapterStateTests' \
  -only-testing:'yuedu appTests/BookshelfRefreshCoordinatorTests' \
  -only-testing:'yuedu appTests/OfflineDownloadManagerTests' \
  -only-testing:'yuedu appTests/OfflineDownloadSourceConcurrencyTests'
run_group native-download \
  -only-testing:'yuedu appTests/LegadoNativeOriginalReaderTests/testNativeOriginalAuditedDownloadsOverlapHeldHTTPAndPreserveOwners'
run_group failure-ui \
  -only-testing:'yuedu appUITests/ReaderChapterFailureExitUITests/testSecondChapterFailureCanExitWithChromeHidden'
ui=0
python3 -B "$SCRIPT_DIR/run-reader-failure-smoke.py" result --work "$WORK" \
  --summary "$WORK/failure-ui-summary.json" --tests "$WORK/failure-ui-tests.json" \
  --output "$WORK/failure-ui-result.json" || ui=$?
xcrun simctl shutdown "$SIMULATOR_UDID" > "$WORK/final-shutdown.log" 2>&1
python3 -B "$SCRIPT_DIR/reader-recovery-regression.py" verify --work "$WORK"
[[ $ui == 0 ]]
