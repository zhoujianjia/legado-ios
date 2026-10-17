#!/usr/bin/env bash
# Compile/link the real native runtime for both platforms; export an unsigned IPA.
# No signing accounts, provisioning profiles, or connected devices are accessed.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK_DIR=${LEGADO_IOS_BUILD_DIR:-"$REPO_DIR/.build/legado-ios"}
if [[ $(uname -s) != Darwin ]]; then
  echo 'Building the native iOS probe requires macOS and Xcode.' >&2
  exit 2
fi
if [[ ${LEGADO_RUNTIME_SOURCE_ONLY:-0} == 1 ]]; then
  echo 'Unset LEGADO_RUNTIME_SOURCE_ONLY: this build must link the native JVM.' >&2
  exit 2
fi
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
PROJECT="$REPO_DIR/Prototypes/LegadoRuntimeProbe/LegadoRuntimeProbe.xcodeproj"
ARTIFACT="$REPO_DIR/Packages/LegadoRuntime/Artifacts/OpenJDK.xcframework"
JAR="$REPO_DIR/Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar"
RESOURCE="$REPO_DIR/Resources/LegadoRuntime"
OUTPUT="$WORK_DIR/probe-output"
mkdir -p "$OUTPUT"

# Preserve prior results; use a new work directory instead of silently overwriting evidence.
for platform in simulator device; do
  JAVA_HOME_DIR="$WORK_DIR/$platform-static/java-home"
  python3 "$SCRIPT_DIR/verify-runtime.py" --java-home "$JAVA_HOME_DIR" --jar "$JAR" --xcframework "$ARTIFACT"
done
[[ ! -e "$OUTPUT/LegadoRuntimeProbe-unsigned.ipa" && ! -e "$OUTPUT/Payload" ]] || {
  echo "Probe output already exists in $OUTPUT; preserve it and select a new LEGADO_IOS_BUILD_DIR." >&2
  exit 3
}

# A staged Java home is platform-specific even though its class files are similar.
STAGE_ARGS=(--java-home "$WORK_DIR/simulator-static/java-home" --jar "$JAR" --destination "$RESOURCE")
if [[ -f "$RESOURCE/runtime-manifest.json" ]]; then STAGE_ARGS+=(--replace); fi
python3 "$SCRIPT_DIR/stage-runtime.py" "${STAGE_ARGS[@]}"
xcodebuild -project "$PROJECT" -scheme LegadoRuntimeProbe -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -resultBundlePath "$WORK_DIR/probe-simulator.xcresult" \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build

python3 "$SCRIPT_DIR/stage-runtime.py" --java-home "$WORK_DIR/device-static/java-home" \
  --jar "$JAR" --destination "$RESOURCE" --replace
xcodebuild -project "$PROJECT" -scheme LegadoRuntimeProbe -configuration Release \
  -destination 'generic/platform=iOS' -resultBundlePath "$WORK_DIR/probe-device.xcresult" \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
SETTINGS="$WORK_DIR/probe-device-build-settings.json"
xcodebuild -project "$PROJECT" -scheme LegadoRuntimeProbe -configuration Release \
  -destination 'generic/platform=iOS' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO -showBuildSettings -json > "$SETTINGS"
APP=$(python3 - "$SETTINGS" <<'PY'
import json, pathlib, sys
targets = [item for item in json.loads(pathlib.Path(sys.argv[1]).read_text()) if item['target'] == 'LegadoRuntimeProbe']
if len(targets) != 1:
    raise SystemExit('Expected exactly one LegadoRuntimeProbe target')
settings = targets[0]['buildSettings']
print(pathlib.Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME'])
PY
)
[[ -d "$APP" ]] || { echo "Built app missing: $APP" >&2; exit 4; }
[[ $(lipo -archs "$APP/LegadoRuntimeProbe") == arm64 ]] || {
  echo 'The device executable must contain only the arm64 slice.' >&2
  exit 4
}
python3 "$SCRIPT_DIR/verify-runtime.py" --java-home "$APP/LegadoRuntime/java-home" \
  --jar "$APP/LegadoRuntime/legado-runtime.jar"
otool -L "$APP/LegadoRuntimeProbe" > "$WORK_DIR/probe-device-linked-libraries.log"
mkdir -p "$OUTPUT/Payload"
ditto "$APP" "$OUTPUT/Payload/LegadoRuntimeProbe.app"
# ditto preserves the executable bits and bundle layout needed by later signing.
ditto -c -k --keepParent "$OUTPUT/Payload" "$OUTPUT/LegadoRuntimeProbe-unsigned.ipa"
python3 - "$REPO_DIR" "$OUTPUT" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
repo, output = map(pathlib.Path, sys.argv[1:])
ipa = output / 'LegadoRuntimeProbe-unsigned.ipa'
with ipa.open('rb') as stream:
    ipa_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
record = {
    'schemaVersion': 1,
    'sourceCommit': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
    'workingTreeDirty': bool(subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True).strip()),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'developerDirectory': os.environ['DEVELOPER_DIR'],
    'runtimePins': json.loads((repo / 'scripts/legado-ios/runtime-lock.json').read_text()),
    'payloadManifest': json.loads((output / 'Payload/LegadoRuntimeProbe.app/LegadoRuntime/runtime-manifest.json').read_text()),
    'ipaSHA256': ipa_hash,
    'ipaBytes': ipa.stat().st_size,
    'simulatorCompilationPassed': True,
    'deviceCompilationPassed': True,
    'signed': False,
    'deviceValidationPassed': False,
}
(output / 'build-manifest.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
(output / 'README.txt').write_text('Unsigned prototype: sign before installing on iPhone/iPad.\nCompilation does not pass any on-device JVM validation gate.\n', encoding='utf-8')
print(json.dumps(record, indent=2))
PY
echo "Unsigned probe exported: $OUTPUT/LegadoRuntimeProbe-unsigned.ipa"
