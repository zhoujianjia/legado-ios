#!/usr/bin/env bash
# One compilation, three real JNI product methods, a fresh Simulator host for each.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="$REPO_DIR/.build/jimage-native-check"
[[ $(uname -s) == Darwin ]] || { echo 'The native jimage check requires macOS/Xcode.' >&2; exit 2; }
[[ ! -e "$WORK/overlays.json" ]] || { echo 'Preserve prior jimage native evidence.' >&2; exit 2; }
mkdir -p "$WORK"
unset LEGADO_RUNTIME_SOURCE_ONLY
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
export YUEDU_DEST="$(bash "$REPO_DIR/scripts/sim.sh" dest)"
SIMULATOR_UDID=${YUEDU_DEST#id=}
printf '%s\n' "$YUEDU_DEST" > "$WORK/destination.txt"
xcodebuild -version > "$WORK/xcode-version.log"
xcrun --sdk iphonesimulator --show-sdk-version > "$WORK/sdk-version.log"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b > "$WORK/initial-boot.log" 2>&1
xcrun simctl list --json > "$WORK/simulators.json"
python3 -B "$REPO_DIR/scripts/legado-ios/stage-runtime.py" \
  --java-home "$REPO_DIR/.build/legado-ios/simulator-static/java-home" \
  --jar "$REPO_DIR/Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar" \
  --destination "$REPO_DIR/Resources/LegadoRuntime" --module-format jimage \
  > "$WORK/staging.log"
python3 -B "$SCRIPT_DIR/jimage-native-check.py" image \
  --image "$REPO_DIR/Resources/LegadoRuntime/java-home/lib/modules" --output "$WORK/staged-jimage.json"
python3 -B "$SCRIPT_DIR/runtime-notices.py" verify \
  --directory "$REPO_DIR/Resources/LegadoRuntime/Notices" > "$WORK/notices.json"
python3 -B "$SCRIPT_DIR/jimage-native-check.py" prepare --work "$WORK"
OVERLAY_ACTIVE=1
restore_source() {
  if [[ $OVERLAY_ACTIVE == 1 ]]; then
    python3 -B "$SCRIPT_DIR/jimage-native-check.py" restore --work "$WORK"
  fi
}
trap restore_source EXIT
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
SELECTORS=(
  'yuedu appTests/LegadoNativeMainJSReaderTests/testNativeMainJSProductReadingChain'
  'yuedu appTests/LegadoNativeOriginalReaderTests/testNativeOriginalPublicConsumersUseOwnedReaderAndOfflineReopen'
  'yuedu appTests/LegadoNativeOriginalReaderTests/testNativeOriginalWebBookPreviewTransferAndReopen'
)
SELECTION=()
for selector in "${SELECTORS[@]}"; do SELECTION+=("-only-testing:$selector"); done
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -parallel-testing-enabled NO \
  -resultBundlePath "$WORK/build.xcresult" "${SELECTION[@]}" build-for-testing \
  > "$WORK/build.log" 2>&1
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json > "$WORK/app-build-settings.json"
# Scheme settings can omit test targets. Query the actual XCTest target with
# the same compilation settings rather than inferring its flags from the app.
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -target 'yuedu appTests' \
  -sdk iphonesimulator "${ARGS[@]}" -showBuildSettings -json > "$WORK/test-build-settings.json"
python3 -B "$SCRIPT_DIR/jimage-native-check.py" merge-settings --work "$WORK"
python3 -B "$SCRIPT_DIR/jimage-native-check.py" host --work "$WORK"
NAMES=(mainjs original-public original-preview)
for index in 0 1 2; do
  name=${NAMES[$index]}
  # Stop this dedicated CI Simulator before each method. Await its real boot
  # signal, so no process-wide JVM or source owner survives from the prior host.
  xcrun simctl shutdown "$SIMULATOR_UDID" > "$WORK/$name-lifecycle.log" 2>&1
  xcrun simctl bootstatus "$SIMULATOR_UDID" -b >> "$WORK/$name-lifecycle.log" 2>&1
  status=0
  YUEDU_TEST_ACTION=test-without-building bash "$REPO_DIR/scripts/xctest.sh" \
    -l "$WORK/$name.log" -t 600 -- "${ARGS[@]}" \
    -resultBundlePath "$WORK/$name.xcresult" "-only-testing:${SELECTORS[$index]}" || status=$?
  # Retain result diagnostics before enforcing either the wrapper or exact gate.
  xcrun xcresulttool get test-results summary --path "$WORK/$name.xcresult" > "$WORK/$name-summary.json"
  xcrun xcresulttool get test-results tests --path "$WORK/$name.xcresult" > "$WORK/$name-tests.json"
  python3 -B "$SCRIPT_DIR/jimage-native-check.py" case --work "$WORK" --case "$name"
  [[ $status == 0 ]] || exit "$status"
done
restore_source
OVERLAY_ACTIVE=0
python3 -B "$SCRIPT_DIR/jimage-native-check.py" finish --work "$WORK"
