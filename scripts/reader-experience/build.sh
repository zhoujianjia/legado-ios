#!/usr/bin/env bash
# Build the native reader with an explicit JSC-only or Legado JVM configuration.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK_DIR=${YUEDU_READER_BUILD_DIR:-"$REPO_DIR/.build/reader-experience"}
OUTPUT="$WORK_DIR/output"
if [[ $(uname -s) != Darwin ]]; then
  echo 'Building the reader experience requires macOS and Xcode.' >&2
  exit 2
fi
for tool in python3 xcrun xcodebuild ditto lipo otool git; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 2; }
done
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(bash "$REPO_DIR/scripts/sim.sh" xcode)}
RUNTIME_ARGS=()
MIN_IOS=17.0
if [[ ${LEGADO_READER_WITH_JVM:-0} == 1 ]]; then
  unset LEGADO_RUNTIME_SOURCE_ONLY
  RUNTIME_ARGS+=(--with-jvm)
  MIN_IOS=18.0
else
  export LEGADO_RUNTIME_SOURCE_ONLY=1
fi
SOURCE_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD)
mkdir -p "$OUTPUT"
for path in "$OUTPUT/Payload" "$OUTPUT/YueduReader-experience-unsigned.ipa" "$WORK_DIR/reader-device.xcresult" "$WORK_DIR/build-settings.json"; do
  [[ ! -e "$path" ]] || { echo "Refusing to overwrite prior experience output: $path" >&2; exit 3; }
done
python3 "$SCRIPT_DIR/stage-config.py" stage > "$WORK_DIR/synthetic-config.json"
python3 "$SCRIPT_DIR/stage-config.py" overlay-project \
  --report "$WORK_DIR/project-overlay.json" > "$WORK_DIR/project-overlay.log"
xcodebuild -version > "$WORK_DIR/xcode-version.log"
xcodebuild -showsdks > "$WORK_DIR/apple-sdks.log"
BUILD_ARGS=(
  -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader
  -configuration Release -destination 'generic/platform=iOS'
  -onlyUsePackageVersionsFromResolvedFile
  CURRENT_PROJECT_VERSION=6
  IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS"
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= CODE_SIGN_ENTITLEMENTS=
  GATEWAY_BASE_URL=
  YUEDU_LOCAL_EXPERIENCE=YES
  INFOPLIST_KEY_YueduLocalExperience=YES
  INFOPLIST_KEY_FirebaseDataCollectionDefaultEnabled=NO
  INFOPLIST_KEY_FIREBASE_ANALYTICS_COLLECTION_ENABLED=NO
  INFOPLIST_KEY_FirebaseCrashlyticsCollectionEnabled=NO
  INFOPLIST_KEY_firebase_performance_collection_enabled=NO
  INFOPLIST_KEY_firebase_performance_instrumentation_enabled=NO
)
xcodebuild "${BUILD_ARGS[@]}" -resultBundlePath "$WORK_DIR/reader-device.xcresult" build
xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings -json > "$WORK_DIR/build-settings.json"
APP=$(python3 "$SCRIPT_DIR/stage-config.py" inspect-settings \
  --settings "$WORK_DIR/build-settings.json" --output "$WORK_DIR/verified-settings.json" "${RUNTIME_ARGS[@]}")
[[ -d "$APP" ]] || { echo "Built reader app is absent: $APP" >&2; exit 4; }
python3 "$SCRIPT_DIR/stage-config.py" finalize --app "$APP" --source "$SOURCE_COMMIT" "${RUNTIME_ARGS[@]}" > "$WORK_DIR/bundle-validation.json"
if [[ ${LEGADO_READER_WITH_JVM:-0} == 1 ]]; then
  python3 "$REPO_DIR/scripts/legado-ios/verify-native-exports.py" --executable "$APP/YueduReader" --report "$WORK_DIR/reader-native-exports.json"
fi
for executable in "$APP/YueduReader" "$APP/PlugIns/yuedu_app_Widget.appex/yuedu_app_Widget" "$APP/PlugIns/yuedu_app_ShareExtension.appex/yuedu_app_ShareExtension"; do
  [[ $(lipo -archs "$executable") == arm64 ]] || { echo "Expected ARM64-only device executable: $executable" >&2; exit 4; }
done
otool -L "$APP/YueduReader" > "$WORK_DIR/reader-linked-libraries.log"
mkdir -p "$OUTPUT/Payload"
ditto "$APP" "$OUTPUT/Payload/YueduReader.app"
ditto -c -k --keepParent "$OUTPUT/Payload" "$OUTPUT/YueduReader-experience-unsigned.ipa"
python3 "$SCRIPT_DIR/stage-config.py" manifest \
  --app "$OUTPUT/Payload/YueduReader.app" --ipa "$OUTPUT/YueduReader-experience-unsigned.ipa" \
  --settings "$WORK_DIR/verified-settings.json" --source "$SOURCE_COMMIT" \
  --xcode-file "$WORK_DIR/xcode-version.log" --overlay "$WORK_DIR/project-overlay.json" \
  --output "$OUTPUT/build-manifest.json" "${RUNTIME_ARGS[@]}"
if [[ ${LEGADO_READER_WITH_JVM:-0} == 1 ]]; then
cat > "$OUTPUT/README.txt" <<'TEXT'
Legado iOS 阅读原型（unsigned）

本包将有限的 mainJs 书源流程接到本地 Rhino/JVM，正文使用原生 CoreText 阅读器。
传统规则书源仍使用现有 JavaScriptCore 实现，尚未证明完整 Legado 兼容。
build-manifest.json 记录了实际来源、普通 JVM JAR、内置书源资源和 IPA 的哈希。
本包最低 iOS 18。账户、云服务和订阅后端未配置；使用合成配置并禁用遥测及 CloudKit。
编译打包不代表真机运行或全部书源验收。安装前须自行签名主 App 和嵌入组件。
TEXT
else
cat > "$OUTPUT/README.txt" <<'TEXT'
Yuedu 本地阅读体验版（unsigned）

本包提供现有 Yuedu 界面、CoreText 阅读器和 JavaScriptCore 书源流程。
体验版使用独立 App 标识，不覆盖原版 Yuedu；构建清单记录了打包时的十处标识覆盖。
实验性 JVM 尚未接入阅读主流程；本包不代表 Legado 全功能已迁移。
可安装后尝试导入本地书、导入书源和搜索阅读；本轮只证明编译打包，未逐项验收这些功能。
使用合成配置，账户、云服务和订阅验证不可用；本地模式禁用遥测及 CloudKit。

安装前须自行签名主 App、嵌入扩展及所需框架；App Group/iCloud 等能力取决于签名授权。
请保留 build-manifest.json 以核对版本、来源 SHA 和 IPA SHA256。
TEXT
fi
echo "Unsigned reader experience exported: $OUTPUT/YueduReader-experience-unsigned.ipa"
