#!/usr/bin/env bash
# Source-only Simulator diagnostics; no physical-device signing, installation or IPA export.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="$REPO_DIR/.build/reader-renewal-probe"
[[ $(uname -s) == Darwin ]] || { echo 'Renewal probe tests require macOS/Xcode.' >&2; exit 2; }
mkdir -p "$WORK"
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
export YUEDU_DEST=${YUEDU_DEST:-$(bash "$REPO_DIR/scripts/sim.sh" dest)}
export LEGADO_RUNTIME_SOURCE_ONLY=1
python3 "$SCRIPT_DIR/renewal-probe-tools.py" prepare --work "$WORK" > "$WORK/prepare.log"
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
# Only local Simulator ad-hoc signing permits the XCTest hosts to launch. No
# developer account, device provisioning or runtime payload is involved.
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/unit-tests.log" -t 2700 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/unit.xcresult" \
  -only-testing:'yuedu appTests/SelfRenewalTransportProbeTests'
xcrun xcresulttool get test-results summary --path "$WORK/unit.xcresult" > "$WORK/unit-summary.json"
xcrun xcresulttool get test-results tests --path "$WORK/unit.xcresult" > "$WORK/unit-tests.json"
python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group unit \
  --summary "$WORK/unit-summary.json" --tests "$WORK/unit-tests.json"
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/ui-tests.log" -t 1200 -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/ui.xcresult" \
  -only-testing:'yuedu appUITests/SelfRenewalProbeUITests'
xcrun xcresulttool get test-results summary --path "$WORK/ui.xcresult" > "$WORK/ui-summary.json"
xcrun xcresulttool get test-results tests --path "$WORK/ui.xcresult" > "$WORK/ui-tests.json"
python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group ui \
  --summary "$WORK/ui-summary.json" --tests "$WORK/ui-tests.json"
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json > "$WORK/build-settings.json"
python3 "$SCRIPT_DIR/renewal-probe-tools.py" result --work "$WORK" > "$WORK/result.log"
