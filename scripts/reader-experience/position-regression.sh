#!/usr/bin/env bash
# Gate the real reader's position fixes before the ordinary JVM reader is packaged.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="$REPO_DIR/.build/reader-position-regression"
[[ $(uname -s) == Darwin ]] || { echo 'Reader position regression requires macOS/Xcode.' >&2; exit 2; }
[[ ! -e "$WORK" ]] || { echo 'Preserve prior reader-position evidence.' >&2; exit 2; }
mkdir -p "$WORK"
export LEGADO_RUNTIME_SOURCE_ONLY=1
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
export YUEDU_DEST=${YUEDU_DEST:-$(bash "$REPO_DIR/scripts/sim.sh" dest)}
printf '%s\n' "$YUEDU_DEST" > "$WORK/destination.txt"
python3 -B "$SCRIPT_DIR/position-regression.py" sources --work "$WORK"
# Reuse the clean-reader tag validation and audited synthetic Info/project
# overlays. This helper's prepare/restore phases do not load the native JVM.
python3 -B "$SCRIPT_DIR/jimage-native-check.py" prepare --work "$WORK"
trap 'python3 -B "$SCRIPT_DIR/jimage-native-check.py" restore --work "$WORK"' EXIT
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
status=0
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/tests.log" -t 3600 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/tests.xcresult" \
  -only-testing:'yuedu appTests/ReaderPositionSentryTests' \
  -only-testing:'yuedu appTests/ReaderPagedPositionSyncTests' \
  -only-testing:'yuedu appTests/ReaderCoverPositionTests' \
  -only-testing:'yuedu appTests/ReaderPositionWalkTests' \
  -only-testing:'yuedu appTests/ReaderPageTransitionQueueTests' \
  -only-testing:'yuedu appTests/ReaderStackWriteGateTests' \
  -only-testing:'yuedu appTests/ReaderRenderRefreshTests' || status=$?
printf '%s\n' "$status" > "$WORK/test-exit-status.txt"
# Keep the raw summary/tree on assertion failure before enforcing either verdict.
artifacts=0
xcrun xcresulttool get test-results summary --path "$WORK/tests.xcresult" > "$WORK/summary.json" || artifacts=$?
xcrun xcresulttool get test-results tests --path "$WORK/tests.xcresult" > "$WORK/tests.json" || artifacts=$?
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json > "$WORK/build-settings.json" || artifacts=$?
python3 -B "$SCRIPT_DIR/position-regression.py" verify --work "$WORK"
[[ $status == 0 && $artifacts == 0 ]] || exit 1
