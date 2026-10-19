#!/usr/bin/env bash
# Separate source-only observations: memory1/UI1/UMD11, never old smoke groups.
set -uo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="$REPO_DIR/.build/reader-measurements"
[[ $(uname -s) == Darwin ]] || { echo 'Reader measurements require macOS/Xcode.' >&2; exit 2; }
[[ ! -e "$WORK" ]] || { echo 'Refusing existing measurement evidence.' >&2; exit 2; }
mkdir -p "$WORK" || exit 2
cd "$REPO_DIR" || exit 2
export LEGADO_RUNTIME_SOURCE_ONLY=1
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
export YUEDU_DEST=${YUEDU_DEST:-$(bash "$REPO_DIR/scripts/sim.sh" dest)}
setup_status=0
# This first call creates the audited Info/project overlays. Source provenance
# checks requiring those overlays must occur only after prepare succeeds.
python3 "$SCRIPT_DIR/smoke-tools.py" prepare --tag-prefix reader-measurements- --directory "$WORK" \
  > "$WORK/prepare.log" 2> "$WORK/prepare.stderr" || setup_status=$?
if (( setup_status != 0 )); then
  echo 'Local-mode preparation failed; no test host will be launched.' >&2
  exit "$setup_status"
fi
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
xcodebuild -version > "$WORK/xcode-version.log" 2> "$WORK/xcode-version.stderr" || setup_status=$?
xcrun simctl bootstatus "${YUEDU_DEST#id=}" -b > "$WORK/boot-status.log" 2>&1 || setup_status=$?
xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" "${ARGS[@]}" -showBuildSettings -json \
  > "$WORK/build-settings.json" 2> "$WORK/build-settings.stderr" || setup_status=$?
xcrun --sdk iphonesimulator --show-sdk-version > "$WORK/sdk-version.log" 2> "$WORK/sdk-version.stderr" || setup_status=$?
xcrun simctl list --json > "$WORK/simulators.json" 2> "$WORK/simulators.stderr" || setup_status=$?
# Reuse only stage environment capture; the old fifty-row method is not run.
python3 "$SCRIPT_DIR/reader-stage-baseline.py" capture-environment \
  --audit "$WORK/overlays.json" --settings "$WORK/build-settings.json" \
  --xcode "$WORK/xcode-version.log" --sdk "$WORK/sdk-version.log" --simulators "$WORK/simulators.json" \
  --destination "$YUEDU_DEST" --developer-directory "$DEVELOPER_DIR" --output "$WORK/environment.json" \
  > "$WORK/environment-capture.log" 2> "$WORK/environment-capture.stderr" || setup_status=$?
python3 "$SCRIPT_DIR/collect-reader-measurements.py" prepare --audit "$WORK/overlays.json" \
  --environment "$WORK/environment.json" --output "$WORK/preparation.json" \
  > "$WORK/source-preparation.log" 2> "$WORK/source-preparation.stderr" || setup_status=$?

run_group() {
  local group=$1 selector=$2 timeout=$3 test_status=0 artifact_status=0 collection_status=0
  # A dedicated -l log is the original xcodebuild output, not the outer tee.
  # The workflow bounds this whole step at 70min (job80 leaves upload time).
  # Wrapper deadlines are 45min initial compile+memory, 15min UI, 5min UMD.
  bash "$REPO_DIR/scripts/xctest.sh" -l "$WORK/$group-tests.log" -t "$timeout" -- \
    "${ARGS[@]}" -resultBundlePath "$WORK/$group.xcresult" -only-testing:"$selector" \
    > "$WORK/$group-wrapper.log" 2>&1 || test_status=$?
  xcrun xcresulttool get test-results summary --path "$WORK/$group.xcresult" \
    > "$WORK/$group-summary.json" 2> "$WORK/$group-summary.stderr" || artifact_status=$?
  xcrun xcresulttool get test-results tests --path "$WORK/$group.xcresult" \
    > "$WORK/$group-tests.json" 2> "$WORK/$group-tests.stderr" || artifact_status=$?
  python3 "$SCRIPT_DIR/collect-reader-measurements.py" collect --group "$group" \
    --audit "$WORK/overlays.json" --environment "$WORK/environment.json" --preparation "$WORK/preparation.json" \
    --log "$WORK/$group-tests.log" --summary "$WORK/$group-summary.json" --tests "$WORK/$group-tests.json" \
    --result-bundle "$WORK/$group.xcresult" --test-exit-status "$test_status" --artifact-exit-status "$artifact_status" \
    --raw "$WORK/$group-raw.log" --output "$WORK/$group-result.json" \
    > "$WORK/$group-collection.log" 2> "$WORK/$group-collection.stderr" || collection_status=$?
  python3 - "$WORK/$group-status.json" "$group" "$test_status" "$artifact_status" "$collection_status" <<'PY'
import json, sys
from pathlib import Path
output, group, test, artifact, collection = sys.argv[1:]
with Path(output).open("x", encoding="utf-8") as stream:
    json.dump({"group": group, "testExitStatus": int(test), "artifactExitStatus": int(artifact),
               "collectionExitStatus": int(collection)}, stream, indent=2)
    stream.write("\n")
PY
  local status_record=$?
  (( test_status == 0 && artifact_status == 0 && collection_status == 0 && status_record == 0 ))
}
memory_status=0; launch_status=0; umd_status=0
# Recoverable group failures never set -e-abort the other two selections. There
# are no retries; a timeout/fatal job abort remains incomplete evidence.
run_group memory 'yuedu appTests/ReaderProcessMemoryMeasurementsTests/sampleOwnedCoreTextChapters' 2700 || memory_status=$?
run_group launch 'yuedu appUITests/ReaderProcessLaunchMeasurementsUITests/testFiveProcessLaunchesToSubmittedReadableTXTAnchor' 900 || launch_status=$?
run_group umd 'yuedu appTests/UMDTextDecoderTests' 300 || umd_status=$?
python3 - "$WORK/execution-status.json" "$setup_status" "$memory_status" "$launch_status" "$umd_status" <<'PY'
import json, sys
from pathlib import Path
output, setup, memory, launch, umd = sys.argv[1:]
with Path(output).open("x", encoding="utf-8") as stream:
    json.dump({"setupExitStatus": int(setup), "memoryGroupExitStatus": int(memory),
               "launchGroupExitStatus": int(launch), "umdGroupExitStatus": int(umd)}, stream, indent=2)
    stream.write("\n")
PY
status_record=$?
(( setup_status == 0 && memory_status == 0 && launch_status == 0 && umd_status == 0 && status_record == 0 ))
