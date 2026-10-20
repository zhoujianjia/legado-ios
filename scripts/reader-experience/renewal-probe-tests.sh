#!/usr/bin/env bash
# Source-only Simulator diagnostics; no physical-device signing, installation or IPA export.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="$REPO_DIR/.build/reader-renewal-probe"
export YUEDU_RENEWAL_SELECTION=${YUEDU_RENEWAL_SELECTION-all}
case "$YUEDU_RENEWAL_SELECTION" in
  all|replacement|implementation) ;;
  *) echo 'YUEDU_RENEWAL_SELECTION must be all, replacement or implementation.' >&2; exit 2 ;;
esac
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
REPLACEMENT_TIMEOUT=2700
if [[ $YUEDU_RENEWAL_SELECTION == all ]]; then REPLACEMENT_TIMEOUT=900; fi
bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/replacement-tests.log" -t "$REPLACEMENT_TIMEOUT" -- \
  "${ARGS[@]}" -resultBundlePath "$WORK/replacement.xcresult" \
  -only-testing:'yuedu appTests/SelfRenewalReplacementPolicyTests'
xcrun xcresulttool get test-results summary --path "$WORK/replacement.xcresult" > "$WORK/replacement-summary.json"
xcrun xcresulttool get test-results tests --path "$WORK/replacement.xcresult" > "$WORK/replacement-tests.json"
python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group replacement \
  --summary "$WORK/replacement-summary.json" --tests "$WORK/replacement-tests.json"
if [[ $YUEDU_RENEWAL_SELECTION == implementation ]]; then
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/materials-tests.log" -t 900 -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/materials.xcresult" \
    -only-testing:'yuedu appTests/SelfRenewalMaterialInventoryTests'
  xcrun xcresulttool get test-results summary --path "$WORK/materials.xcresult" > "$WORK/materials-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/materials.xcresult" > "$WORK/materials-tests.json"
  python3 "$SCRIPT_DIR/renewal-probe-tools.py" verify-tests --group materials \
    --summary "$WORK/materials-summary.json" --tests "$WORK/materials-tests.json"
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
