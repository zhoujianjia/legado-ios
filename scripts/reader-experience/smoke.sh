#!/usr/bin/env bash
# Target only local-mode construction and the self-contained real TXT UI loop.
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
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/cloudkit-summary.json" --expected 6
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/txt-ui-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/txt-ui.xcresult" \
  -only-testing:'yuedu appUITests/ReaderLocalSmokeUITests'
xcrun xcresulttool get test-results summary --path "$WORK/txt-ui.xcresult" > "$WORK/txt-ui-summary.json"
python3 "$SCRIPT_DIR/smoke-tools.py" verify-summary --summary "$WORK/txt-ui-summary.json" --expected 1
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json > "$WORK/build-settings.json"
python3 "$SCRIPT_DIR/smoke-tools.py" result --audit "$WORK/overlays.json" --settings "$WORK/build-settings.json" \
  --unit "$WORK/cloudkit-summary.json" --ui "$WORK/txt-ui-summary.json" --output "$WORK/result.json"
