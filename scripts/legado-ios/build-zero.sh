#!/usr/bin/env bash
# Source-only build, based on pinned openjdk-mobile/ios-tools workflows.
# A successful build is NOT an on-device compatibility verdict.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK_DIR=${LEGADO_IOS_BUILD_DIR:-"$REPO_DIR/.build/legado-ios"}
BUILD_JOBS=${LEGADO_IOS_BUILD_JOBS:-2}
REQUIRED_MODULES=(java.base java.xml java.desktop java.datatransfer java.prefs java.logging jdk.charsets java.compiler java.instrument java.net.http java.sql java.transaction.xa jdk.unsupported)
[[ $BUILD_JOBS =~ ^[1-9][0-9]*$ ]] || { echo 'LEGADO_IOS_BUILD_JOBS must be a positive integer.' >&2; exit 2; }
if [[ $(uname -s) != Darwin ]]; then
  echo 'OpenJDK Mobile iOS builds require macOS, Xcode, GNU make, autoconf and boot JDK 26.' >&2
  exit 2
fi
for tool in python3 xcrun xcodebuild autoconf gmake; do command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 2; }; done
BOOT_JDK=${LEGADO_BOOT_JDK:-$(/usr/libexec/java_home -v 26)}
python3 "$SCRIPT_DIR/fetch-sources.py" --work-dir "$WORK_DIR"
MOBILE="$WORK_DIR/mobile"
TOOLS="$WORK_DIR/ios-tools"
FFI="$WORK_DIR/libffi-3.5.2"
SDK_DEVICE=$(xcrun --sdk iphoneos --show-sdk-path)
SDK_SIM=$(xcrun --sdk iphonesimulator --show-sdk-path)
SDK_MAC=$(xcrun --sdk macosx --show-sdk-path)

# Configure arm64 targets directly, using the same target triples as upstream's
# Darwin generator. Do not require its obsolete armv7 or x86_64 targets.
for sdk in iphoneos iphonesimulator; do
  FFI_BUILD="$WORK_DIR/ffi-build/$sdk"
  mkdir -p "$FFI_BUILD"
  cd "$FFI_BUILD"
  if [[ $sdk == iphoneos ]]; then FFI_TRIPLE=arm64-apple-ios; FFI_MIN='-miphoneos-version-min=18.0';
  else FFI_TRIPLE=arm64-apple-ios-simulator; FFI_MIN='-mios-simulator-version-min=18.0'; fi
  CC="xcrun -sdk $sdk clang -target $FFI_TRIPLE" LD="xcrun -sdk $sdk ld -target $FFI_TRIPLE" CFLAGS="$FFI_MIN" \
    "$FFI/configure" --host="$FFI_TRIPLE" --build="$(uname -m)-apple-darwin" \
      --disable-shared --enable-static --prefix="$FFI_BUILD/install"
  gmake -j"$BUILD_JOBS"
  gmake -j"$BUILD_JOBS" install
done
FFI_DEVICE="$WORK_DIR/ffi-build/iphoneos/install/lib"
FFI_SIM="$WORK_DIR/ffi-build/iphonesimulator/install/lib"
FFI_HEADERS="$WORK_DIR/ffi-build/iphoneos/install/include"
[[ -f "$FFI_HEADERS/ffi.h" ]] || { echo "libffi headers missing at $FFI_HEADERS" >&2; exit 3; }

# Upstream requires this unit for loadfunctions(). The exact pinned tools retain
# one method removed from the pinned JDK; reject changed inputs before adapting.
python3 "$SCRIPT_DIR/prepare-symbol-keeper.py" \
  --source "$TOOLS/openjdk-ext/src/hotspot/symbol_keeper.cpp" \
  --destination "$MOBILE/src/hotspot/os/bsd/symbol_keeper.cpp"
# The pinned Zero backend predates shared Apple ARM64 W^X state hooks.
# Port their complete same-revision implementation, retaining iOS's no-JIT guard.
python3 "$SCRIPT_DIR/prepare-zero-wx.py" --mobile-root "$MOBILE"
cd "$MOBILE"
for target in device simulator; do
  if [[ $target == device ]]; then
    CONF=ios-aarch64-zero-release; SDK=$SDK_DEVICE; FFI_LIB=$FFI_DEVICE
    EXTRA_FLAGS='-miphoneos-version-min=18.0'
  else
    CONF=iossim-aarch64-zero-release; SDK=$SDK_SIM; FFI_LIB=$FFI_SIM
    EXTRA_FLAGS='-target arm64-apple-ios-simulator -mios-simulator-version-min=18.0'
  fi
  bash configure --with-conf-name="$CONF" --disable-warnings-as-errors --with-jvm-variants=zero \
    --openjdk-target=aarch64-macos-ios --with-boot-jdk="$BOOT_JDK" --with-sysroot="$SDK" \
    --with-libffi-include="$FFI_HEADERS" --with-libffi-lib="$FFI_LIB" \
    --with-cups-include="$SDK_MAC/usr/include" --with-extra-cflags="$EXTRA_FLAGS" --with-extra-cxxflags="$EXTRA_FLAGS"
  # static-libs-image omits modules without native libraries, such as jdk.charsets.
  # The dependency-aware -java phase also runs each module's generators. Explicit
  # base gendata supplies java.security, crypto policies, cacerts and tzdb.dat.
  # Hosted ARM64 Macs have limited RAM; OpenJDK accepts JOBS as its worker limit.
  gmake CONF="$CONF" JOBS="$BUILD_JOBS" static-libs-image \
    "${REQUIRED_MODULES[@]/%/-java}" java.base-gendata
  BUILD="$MOBILE/build/$CONF"
  SLICE="$WORK_DIR/$target-static"
  mkdir -p "$SLICE/headers" "$SLICE/java-home/modules"
  cp "$BUILD/jdk/include/"*.h "$SLICE/headers/"
  cp "$BUILD/jdk/include/ios/"*.h "$SLICE/headers/"
  cat > "$SLICE/headers/module.modulemap" <<'MODULEMAP'
module OpenJDK { header "jni.h" export * }
MODULEMAP
  libtool -static -o "$SLICE/libOpenJDK.a" \
    "$BUILD/images/static-libs/lib/zero/libjvm.a" "$FFI_LIB/libffi.a" \
    "$BUILD/images/static-libs/lib/libjava.a" "$BUILD/images/static-libs/lib/libzip.a" \
    "$BUILD/images/static-libs/lib/libnet.a" "$BUILD/images/static-libs/lib/libnio.a" \
    "$BUILD/images/static-libs/lib/libjimage.a"
  for module in "${REQUIRED_MODULES[@]}"; do
    [[ -d "$BUILD/jdk/modules/$module" ]] || { echo "Required module not built: $module; java.beans/E4X gate failed" >&2; exit 4; }
    cp -R "$BUILD/jdk/modules/$module" "$SLICE/java-home/modules/"
  done
  # Classes alone are not a usable JavaHome: Security/Cipher read conf, Rhino
  # Date uses tzdb.dat, and Java HTTPS uses cacerts. Dereference build symlinks
  # so the app bundle never points back into the runner's build directory.
  [[ -d "$BUILD/jdk/conf" ]] || { echo "JDK runtime configuration missing: $BUILD/jdk/conf" >&2; exit 4; }
  cp -RL "$BUILD/jdk/conf" "$SLICE/java-home/"
  for data_file in lib/tzdb.dat lib/security/cacerts; do
    [[ -s "$BUILD/jdk/$data_file" ]] || { echo "JDK runtime data missing: $data_file" >&2; exit 4; }
    mkdir -p "$SLICE/java-home/$(dirname "$data_file")"
    cp -L "$BUILD/jdk/$data_file" "$SLICE/java-home/$data_file"
  done
  [[ ! -f "$BUILD/jdk/release" ]] || cp "$BUILD/jdk/release" "$SLICE/java-home/"
  [[ ! -d "$BUILD/jdk/legal" ]] || cp -R "$BUILD/jdk/legal" "$SLICE/java-home/"
  for notice in LICENSE ADDITIONAL_LICENSE_INFO ASSEMBLY_EXCEPTION; do
    [[ ! -f "$MOBILE/$notice" ]] || cp "$MOBILE/$notice" "$SLICE/java-home/"
  done
  mkdir -p "$SLICE/java-home/legal/libffi"
  cp "$FFI/LICENSE" "$SLICE/java-home/legal/libffi/"
done
ARTIFACT="$REPO_DIR/Packages/LegadoRuntime/Artifacts/OpenJDK.xcframework"
[[ ! -e "$ARTIFACT" ]] || { echo "Artifact already exists: $ARTIFACT; move it aside before rebuilding" >&2; exit 5; }
mkdir -p "$(dirname -- "$ARTIFACT")"
xcodebuild -create-xcframework \
  -library "$WORK_DIR/device-static/libOpenJDK.a" -headers "$WORK_DIR/device-static/headers" \
  -library "$WORK_DIR/simulator-static/libOpenJDK.a" -headers "$WORK_DIR/simulator-static/headers" \
  -output "$ARTIFACT"
python3 "$SCRIPT_DIR/verify-runtime.py" --java-home "$WORK_DIR/device-static/java-home" --xcframework "$ARTIFACT"
# The manifest conditionally exposes the local binary. Change its mtime so Xcode/
# SwiftPM re-evaluates an earlier source-only graph without deleting user caches.
touch "$REPO_DIR/Packages/LegadoRuntime/Package.swift"
echo "Source build complete. Stage the fat JAR and selected device/simulator java-home; then run the device gate."
