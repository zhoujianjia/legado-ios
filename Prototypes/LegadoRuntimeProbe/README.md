# Standalone Legado runtime probe

This iOS 18+ SwiftUI app depends only on the local `Packages/LegadoRuntime` package.
It does not resolve Yuedu's Firebase, authentication, or other remote packages. It
uses the same JVM facade and synthetic `main-source.js` fixture as the desktop
tests. No source engine is implemented in this app, and no HTTP request leaves it.

**Status:** source prepared on Windows; Xcode compilation, signing, JVM startup,
and device execution remain unverified. No OpenJDK binaries are included.

With Windows, an iPhone, and an iPad but no local Mac, follow the
[manual cloud-build guide](../../docs/legado-ios/cloud-build.md). The prepared
**Legado iOS Prototype** workflow can compile this project on a macOS runner and
produce an unsigned IPA. It has not run yet; signing and actual device validation
remain separate steps. The local Mac instructions below are an alternative when
a macOS development environment is available.

## Prepare the payload on a Mac

From the repository root, follow the runtime build prerequisites and run:

```bash
bash scripts/legado-ios/build-zero.sh
cd Packages/LegadoRuntime/jvm
JAVA_HOME="$(/usr/libexec/java_home -v 21)" ./gradlew runtimeJar
cd ../../..
python3 scripts/legado-ios/stage-runtime.py \
  --java-home .build/legado-ios/device-static/java-home \
  --jar Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar
```

The project copies `../../Resources/LegadoRuntime` as a folder, preserving
`java-home/modules`. To rebuild an already staged payload, explicitly add
`--replace`. Simulator runs require the simulator Java home instead.

The source-only app also builds without these artifacts: its diagnostic report
then lists the missing bridge/modules/JAR. It does not silently substitute JSC.

## Self-sign and install

Without a local Mac, use the [Windows signing and installation guide](../../docs/legado-ios/windows-install.md)
after the cloud workflow has exported its unsigned IPA.

Open `LegadoRuntimeProbe.xcodeproj`, select your Personal Team and a connected
iPhone, and choose a unique bundle identifier. The checked-in team is blank.
The shared scheme uses Release and disables the debugger for launch.

Alternatively, resolve your active Xcode and attached device at run time:

```bash
xcode-select -p
xcrun devicectl list devices
export TEAM_ID='YOUR_TEAM_ID'
export DEVICE_ID='YOUR_CONNECTED_DEVICE_UDID'
export PROBE_BUNDLE_ID='your.unique.legado-probe'
PROJECT='Prototypes/LegadoRuntimeProbe/LegadoRuntimeProbe.xcodeproj'
xcodebuild -project "$PROJECT" -scheme LegadoRuntimeProbe \
  -configuration Release -destination "id=$DEVICE_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$PROBE_BUNDLE_ID" \
  -allowProvisioningUpdates build
APP_DIR=$(xcodebuild -project "$PROJECT" -scheme LegadoRuntimeProbe \
  -configuration Release -destination "id=$DEVICE_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$PROBE_BUNDLE_ID" \
  -showBuildSettings | awk '/ TARGET_BUILD_DIR = / {sub(/^.* = /, ""); print; exit}')
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_DIR/LegadoRuntimeProbe.app"
```

Unlock the phone, trust your development signing profile if iOS requests it, and
launch from the **Home Screen** with Xcode detached. No JIT entitlement, debugger
attachment, jailbreak, or server should be needed. Successful installation alone
does not pass the JVM gate.

## Read the results

“Inspect runtime payload” only checks files and native bridge presence. “Run
synthetic reading fixture” actually starts the same process-scoped JVM and checks
custom Rhino/E4X semantics, login request bytes, Cookie/header persistence,
search → details → TOC → content → batch, variables/cache, and cancellation.
An infinite-script test uses a host handshake and a 5-second JVM deadline; it
does not sleep to guess when the engine has started.

The selectable JSON report includes per-operation times, first-session/startup
time, total time, uncompressed payload bytes, current RSS and process-lifetime
peak RSS. Startup/session time combines JVM startup and session creation; later
runs reuse the JVM and are explicitly marked warm. Payload bytes are not an IPA
size estimate. Errors remain visible. These results cover synthetic `mainJs`
fixtures only; they do not pass declarative-rule or real-source compatibility.

If startup fails, relaunch the process before retrying: an embedded JVM cannot be
restarted. After Gate 1 succeeds, validate browser/platform adapters, original
Android golden traces, sustained memory use, and real-source behavior separately.
