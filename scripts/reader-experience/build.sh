#!/usr/bin/env bash
# Build the reader; the source-only configuration remains available for validation.
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
  python3 "$SCRIPT_DIR/runtime-notices.py" verify --directory "$REPO_DIR/Resources/LegadoRuntime/Notices"
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
python3 "$SCRIPT_DIR/stage-config.py" require-no-source-pack \
  --root "$REPO_DIR/Resources" > "$WORK_DIR/source-pack-exclusion.json"
python3 "$SCRIPT_DIR/stage-config.py" stage > "$WORK_DIR/synthetic-config.json"
python3 "$SCRIPT_DIR/stage-config.py" overlay-project \
  --report "$WORK_DIR/project-overlay.json" > "$WORK_DIR/project-overlay.log"
xcodebuild -version > "$WORK_DIR/xcode-version.log"
xcodebuild -showsdks > "$WORK_DIR/apple-sdks.log"
COMMON_SETTINGS=(
  -onlyUsePackageVersionsFromResolvedFile
  CURRENT_PROJECT_VERSION=32
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule ENABLE_DEBUG_DYLIB=NO
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
BUILD_ARGS=(
  -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -scheme Yuedu-Reader
  -configuration Release -destination 'generic/platform=iOS'
  "${COMMON_SETTINGS[@]}"
)
xcodebuild "${BUILD_ARGS[@]}" -resultBundlePath "$WORK_DIR/reader-device.xcresult" build
xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings -json > "$WORK_DIR/build-settings.json"
# Query every embedded target with the same Release settings for the package audit.
for target in 'Yuedu-Reader Widget' 'Yuedu-Reader ShareExtension'; do
  xcodebuild -project "$REPO_DIR/Yuedu-Reader.xcodeproj" -target "$target" \
    -configuration Release -sdk iphoneos "${COMMON_SETTINGS[@]}" \
    -showBuildSettings -json > "$WORK_DIR/settings-$target.json"
done
python3 - "$WORK_DIR" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
items = json.loads((root/'build-settings.json').read_bytes())
items = [item for item in items if item.get('target') == 'yuedu app']
for target in ('Yuedu-Reader Widget', 'Yuedu-Reader ShareExtension'):
    values = json.loads((root/('settings-' + target + '.json')).read_bytes())
    items.extend(item for item in values if item.get('target') == target)
(root/'build-settings.json').write_text(json.dumps(items), encoding='utf-8')
PY
APP=$(python3 "$SCRIPT_DIR/stage-config.py" inspect-settings \
  --settings "$WORK_DIR/build-settings.json" --output "$WORK_DIR/verified-settings.json" "${RUNTIME_ARGS[@]}")
[[ -d "$APP" ]] || { echo "Built reader app is absent: $APP" >&2; exit 4; }
python3 "$SCRIPT_DIR/stage-config.py" finalize --app "$APP" --source "$SOURCE_COMMIT" "${RUNTIME_ARGS[@]}" > "$WORK_DIR/bundle-validation.json"
python3 "$SCRIPT_DIR/clean-package-audit.py" --app "$APP" \
  --settings "$WORK_DIR/build-settings.json" --output "$OUTPUT/clean-package-audit.json"
python3 "$SCRIPT_DIR/stage-config.py" require-no-source-pack \
  --root "$APP" > "$WORK_DIR/built-source-pack-exclusion.json"
if [[ ${LEGADO_READER_WITH_JVM:-0} == 1 ]]; then
  python3 "$REPO_DIR/scripts/legado-ios/verify-native-exports.py" --executable "$APP/YueduReader" --report "$WORK_DIR/reader-native-exports.json" --module-image
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
Build32 adds the traditional-source AES chapter-URL decoder. JVM module resources retain jimage 1.1 packaging, avoiding SideStore treating loose Java classes as FAT Mach-O files. App ID registration defaults use English; localized desktop names remain available.
Automatic renewal is removed; SideStore or another installation tool handles signing and renewal. Physical-device installation and renewal still require validation.
阅读（unsigned，独立修改版）

本包的传统文本书源默认入口及有限 mainJs 流程接到本地 Rhino/JVM，正文使用原生 CoreText 阅读器。
书源及宿主能力仍未全部完成，完整 Legado 兼容尚未验证。
本包不内置书源，安装后自行导入；沿用原签名账号及应用标识覆盖安装，并核对已有书籍、书源和阅读进度。
build-manifest.json 记录了实际来源、普通 JVM JAR、书源资源未打包的检查结果和 IPA 的哈希。
本包最低 iOS 18。应用账号、会员、遥测及 CloudKit 关闭；不提供上游官方服务。
本项目与 Legado、Yuedu Reader 官方无关，也未获其背书。许可证和源码义务分别按组件核对。
小范围分享同样需要许可和对应源码；当前完整 JVM 包的再分发核验未完成，请勿直接转发旧包。
编译打包不代表真机运行或全部书源验收。安装前须自行签名主 App 和嵌入组件。
TEXT
else
cat > "$OUTPUT/README.txt" <<'TEXT'
阅读（unsigned，独立修改版）

这是用于验证 CoreText 阅读器的构建配置，不另设用户发行版本。
本包不内置书源；原生界面基于 Yuedu Reader。
本项目与原项目官方无关，也未获其背书。工程默认使用独立 App 标识；构建清单记录实际是否需要标识覆盖。
此配置没有嵌入 JVM，依赖 JVM 的书源默认入口不可用；本包不代表 Legado 全功能已迁移。
可安装后尝试导入本地书、导入书源和搜索阅读；本轮只证明编译打包，未逐项验收这些功能。
应用账号、会员、遥测及 CloudKit 关闭；使用合成配置，不提供上游官方服务。

安装前须自行签名主 App、嵌入扩展及所需框架；App Group/iCloud 等能力取决于签名授权。
请保留 build-manifest.json 以核对版本、来源 SHA 和 IPA SHA256。
TEXT
fi
echo "Unsigned reader experience exported: $OUTPUT/YueduReader-experience-unsigned.ipa"
