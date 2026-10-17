# Local Legado runtime prototype

This work tests whether the original Java/Kotlin parsing behavior can run locally
inside the native Yuedu reader through OpenJDK Mobile Zero. It is an opt-in
compatibility prototype. It does not establish full Legado parity or replace the
production JavaScriptCore parser. The accepted migration gate requires a signed
iPhone build to start without a debugger or JIT before full feature migration.

## Baseline and acceptance inventory

- [desktop-validation.json](desktop-validation.json) records 45 passing JVM tests,
  18 passing Python tests and an assembled-payload smoke run with `-Xint` and
  a 128 MiB Java heap. This is the earlier desktop snapshot; current cloud
  compilation evidence is in [cloud-validation.json](cloud-validation.json).
- [packaged-suite-validation.json](packaged-suite-validation.json) validates
  optional packaging of the unchanged original 25-case suite and JavaBeans probe.

- [provenance-lock.json](provenance-lock.json) pins the user-provided Legado ZIP,
  custom engine JAR/POM, source-revision claims and Yuedu source snapshot. The ZIP
  comment is an unauthenticated revision hint; its upstream origin is unknown.
- [feature-matrix.md](feature-matrix.md) lists 64 source-evidenced feature domains,
  proposed iOS mappings, acceptance scenarios and platform differences. All parity
  statuses remain pending.
- [inventory.json](inventory.json) fingerprints all 2,792 regular files in the
  3,249-entry ZIP, indexes Kotlin main-source declarations, and extracts all 13
  MCP tool registrations. The declaration index uses regular expressions and is
  an audit aid, not an exhaustive semantic analysis.
- [validation-gates.json](validation-gates.json) separates passing inventory checks
  from pending device gates. A desktop or cloud compile never changes a device gate to
  passed.

Regenerate or verify the inventory from the repository root with Python 3.11+:

```powershell
python -B scripts/legado-inventory.py --archive F:/legado-master.zip
python -B scripts/legado-inventory.py --archive F:/legado-master.zip --check
python -B -m unittest discover -s scripts/tests -p test_legado_inventory.py -v
```

The scanner reads ZIP entries without extraction or execution. It verifies the
archive hash and embedded engine artifacts, rejects duplicate/unsafe paths and
symbolic links, checks every evidence anchor, and writes deterministic output
without timestamps or machine-specific source paths. `--check` never rewrites
generated output. Edit `feature-catalog.json` to refine a feature or its evidence;
do not edit generated files by hand. Changing the source baseline requires an
explicit provenance-lock update and revalidation rather than accepting a newer
download automatically.

## Runtime boundary

The experimental package lives at [Packages/LegadoRuntime](../../Packages/LegadoRuntime).
Swift owns the native
UI and calls session creation, operation execution, cancellation and session
release. A small Objective-C/JNI bridge exchanges UTF-8 JSON, byte buffers and
task/session identifiers. Java objects, scopes and source state stay within the
JVM. Native platform operations use a host adapter; unsupported operations must
return an explicit error.

The package may build diagnostic support without an OpenJDK artifact. A missing
runtime is reported as unavailable; this is not a successful JVM startup. The
original Kotlin/Rhino wrappers, custom JAR, migrated parser tests and a JVM facade
provide an independently testable desktop slice. A fixture-backed chain only
proves the operations it exercises; it does not prove every traditional rule,
host overload, LoginUiV2 component or production network path.

Keep original request/response bytes and record variable, cookie, exception and
cache changes in fixtures. Comparing only visible chapter text misses behavioral
differences. Keep a source's shared state separate from each call's bindings, and
exercise cancellation on a different worker from the executing script. Browser
UI must run on the iOS main thread without blocking it while a JVM worker waits.

## Build and validation sequence

For Windows development with an iPhone/iPad and no local Mac, use the
[manual cloud-build guide](cloud-build.md). It explains how the prepared GitHub
Actions workflow builds an unsigned prototype on macOS, which results still need
signing and device validation, and what must first exist in your own repository.
[Cloud run 39003367690](https://github.com/zhoujianjia/legado-ios/actions/runs/39003367690)
passed and produced an unsigned iOS 18+ IPA after both app links and a nine-entry
dynamic export check. Follow [Windows signing and installation](windows-install.md)
to collect device evidence. Build 6 now has a passing physical-iPhone fixture
report; current gate coverage is recorded in [device-validation.json](device-validation.json).

For app, packaging or runner fixes that leave the native/JVM inputs unchanged,
the [Legado iOS Runtime Replay workflow](../../.github/workflows/legado-ios-replay.yml)
reuses matching source-built products instead of rebuilding Zero and the JAR.
Its trigger tag is `legado-replay-<sourceRunID>-<currentSHA prefix>`, where the
source run belongs to this repository and the 7–40 hexadecimal-character prefix
matches the tagged current commit.

The replay checks Git objects for six native input files (including
`prepare-zero-code-cache.py`) and the complete JVM tree, then validates the
selected source artifacts and runtime files. Changed
inputs require a fresh source build. Only the matching Zero framework, Java homes
and JVM payload are reused; the current iOS app is compiled and linked again
before attempting the Simulator fixture. Keep `runtime-reuse.json` with the
artifact and `legado-replay-logs` to distinguish reused provenance from a fresh
runtime compilation. Earlier run 39039281290 failed at
Simulator CLI argument handling before launch, and run 39039849269 failed on
Python 3.9 union annotations in Xcode's script environment. Later build 4 replays
actually launched the Simulator app and captured a `JNI_CreateJavaVM` exit with
`Could not reserve enough space in CodeCache (160K)`.

Build 5 at `203b352` started the actual Simulator JVM in
[run 39042657077](https://github.com/zhoujianjia/legado-ios/actions/runs/39042657077):
`JNI_CreateJavaVM` returned 0 in 4.725 seconds; session creation, diagnostics and
close succeeded without a hard exit. Suite loading then failed with
`java.lang.VerifyError: Could not link verifier`, before any of the 25 cases ran.
The [code-cache adaptation](../../scripts/legado-ios/prepare-zero-code-cache.py)
checks complete original/prepared source hashes and passes `!ExecMem` to
`CodeMemoryReserver` only for `__IOS__ && ZERO`. Zero stores pointers to precompiled
C++ interpreter functions. Independent diagnostic run 39043099245 confirmed the
old runtime reserved 32 MiB, then failed `mprotect` on the first 160 KiB with
`Permission denied`. The executable-memory path follows the pinned source chain;
the repaired Simulator startup does not explain the original iPhone termination.
See [code-cache-investigation.json](code-cache-investigation.json).

Version 0.2 build 6 at `78930be` adds `libverify.a`, retains the exact
`_VerifyClassForMajorVersion` archive root and requires ten final dynamic exports.
Its portable and macOS jobs, both native app links, ten-export gate and actual
Simulator smoke passed in
[run 39044188251](https://github.com/zhoujianjia/legado-ios/actions/runs/39044188251).
The downloaded, hash-checked Simulator report confirms 25 original
`JsEngineCapabilitiesTest` cases passed with 0 failures and 0 skips, JavaBeans
property discovery/read/write, `dynamicThis=true`, `e4x=ok`, `indirect=function`
and `legacy=42`, plus fixed `mainJs` login/search/details/TOC/content/batch/state
and cancellation-handshake checks. The unsigned IPA also passed integrity,
version/source metadata, payload-layout and independent ARM64 ten-export checks;
see [simulator-validation.json](simulator-validation.json). Download the run's
`legado-probe-unsigned` artifact for [Windows signing and installation](windows-install.md).
The cancellation check observes interruption after an active-host handshake; it
does not prove interruption after entering a CPU-only infinite loop. Real network
behavior, full G4 reference traces and G5 sustained/browser/concurrency cases remain
pending.

The hash-checked build 6 `ios-device` report from `iPhone18,3` / iOS 27.0.1 has
`passed=true`: 25 original cases passed with 0 failures/skips, JavaBeans and custom
semantics passed, and the fixed `mainJs` reading/state/cancellation-handshake
fixture completed. JVM creation took 1.911987 seconds, startup/session
2062.754458 ms and the full run 2953.558042 ms; final and peak RSS were
111067136 bytes (about 111 MB). These are one-run diagnostic measurements with
logging I/O, not production performance results. The user confirmed direct Home
Screen launch of the self-signed app without a debugger, extra JIT tooling or
jailbreak. G1 and G2 passed; G3–G5 are partially covered. Full feature
migration remains gated. See [device-validation.json](device-validation.json).
The changed native inputs require a fresh build; bytecode verification remains
enabled. Earlier failed IPAs are retained as diagnostic evidence.

Use JDK 21 for the portable JVM module. On Windows, the
[validation runner](../../scripts/test-legado.ps1) discovers the local JDK or uses
`-JdkHome`, resolves the current Windows HTTP proxy for Gradle, and restores its
environment changes when it exits. It does not persist proxy or JDK settings.
From the repository root:

```powershell
./scripts/test-legado.ps1
# Or specify a JDK 21 installation:
./scripts/test-legado.ps1 -JdkHome C:/path/to/jdk-21
```

On macOS, use the same wrapper through `bash`:

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 21) bash Packages/LegadoRuntime/jvm/gradlew -p Packages/LegadoRuntime/jvm test runtimeJar runtimeBundle
```

`runtimeJar` creates the fat JAR at
`Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar`; `runtimeBundle` also
collects dependency JARs. Neither artifact contains the native iOS JVM.

The macOS Zero build requires Xcode with iPhoneOS/iPhoneSimulator SDKs, boot
JDK 26, Python 3.12+, GNU make (`gmake`) and autoconf. Source revisions, libffi hash,
minimum iOS version and the complete required module list are pinned in
[runtime-lock.json](../../scripts/legado-ios/runtime-lock.json).
[fetch-sources.py](../../scripts/legado-ios/fetch-sources.py) checks out those
revisions and verifies libffi. [build-zero.sh](../../scripts/legado-ios/build-zero.sh)
calls it automatically, then builds arm64 device and simulator slices.

The build copies the JDK security configuration, cryptographic policy, time-zone
data and default TLS trust store alongside the exploded modules. A hash-guarded
[symbol preparation step](../../scripts/legado-ios/prepare-symbol-keeper.py)
removes one stale JNI registration from the pinned tools to match the pinned
Mobile sources; the other 449 registrations are preserved. This adaptation is
recorded in the build log and [cloud validation evidence](cloud-validation.json).

Start the build from the repository root:

```bash
bash scripts/legado-ios/build-zero.sh
```

The default work directory is `.build/legado-ios`; `LEGADO_IOS_BUILD_DIR` overrides
it, and `LEGADO_BOOT_JDK` can select the boot JDK explicitly. The output is
`Packages/LegadoRuntime/Artifacts/OpenJDK.xcframework`, with separate
`device-static/java-home` and `simulator-static/java-home` directories in the work
directory. In these build/staging outputs, exploded class modules remain under
`java-home/modules`, not `java-home/lib/modules`.

[verify-runtime.py](../../scripts/legado-ios/verify-runtime.py) statically checks
module descriptors, XML/beans probe classes, facade/engine classes and XCFramework
slices. [stage-runtime.py](../../scripts/legado-ios/stage-runtime.py) copies the
selected payload into the app's folder resource and writes its manifest:

```bash
python3 scripts/legado-ios/verify-runtime.py --java-home .build/legado-ios/device-static/java-home --jar Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar --xcframework Packages/LegadoRuntime/Artifacts/OpenJDK.xcframework
python3 scripts/legado-ios/stage-runtime.py --java-home .build/legado-ios/device-static/java-home --jar Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar
```

Staging targets `Resources/LegadoRuntime` by default and refuses an existing
payload unless `--replace` is supplied. For a simulator build, stage
`simulator-static/java-home` instead. Version 0.2 build 6's final **Prepare static
JVM bootstrap home** app build phase moves the staged `LegadoRuntime/java-home`
tree to the final `App.app/lib`; exploded classes then live at `App.app/lib/modules`.
The home is moved without duplication or symbolic links, and the JAR and staging
manifest stay in `App.app/LegadoRuntime`. The pinned BSD VM derives this home
before parsing `-Djava.home`; source inspection identified the previous mismatch
as a packaging defect. See [bootstrap-layout-investigation.json](bootstrap-layout-investigation.json).
Build 5 reached successful Simulator JVM initialization with this layout; the
reported iPhone termination's exact cause remains unconfirmed. File checks and staging do not establish
successful runtime execution. Preserve upstream license and notice files with
redistributed artifacts.

When an iOS XCFramework already exists, select the diagnostic implementation for
host-only Swift package tests so it does not try to link iOS libraries on macOS:

```bash
LEGADO_RUNTIME_SOURCE_ONLY=1 swift test --package-path Packages/LegadoRuntime
```

For the first device gate, use the
[standalone probe app](../../Prototypes/LegadoRuntimeProbe/README.md). It links
only the local runtime package and provides signing/install instructions plus a
synthetic reading-chain report, without resolving the production app's remote
packages. The build 6 fixture passed on Simulator and a physical iPhone. The
earlier reported termination did not recur; its original cause remains unconfirmed. See
[device-validation.json](device-validation.json).

Version 0.2 build 2 introduced persistent `probeProgress`, native
`current`/`previous` logs, VM `vfprintf`/`hs_err` capture, and a JSON file shared
through `ShareLink` that can be saved to Files. Build 6 retains this support, the
layout correction and the repaired code cache, adding the verifier fix that
passed the actual Simulator smoke. Recorded times
include diagnostic I/O and are not production performance measurements.
JVM startup and the audited synthetic fixture now succeed on Simulator and the
reported iPhone. This covers the recorded fixtures rather than complete parity.

The production app exposes the opt-in probe at **Settings → Advanced → Legado
Runtime Verification**. It runs only an included synthetic, network-free source
and an E4X check. A successful result covers that fixture rather than the full
feature matrix. Resolve Xcode and simulator destinations with the existing
`scripts/sim.sh` tooling; do not hardcode a local Xcode path or device name.

Run the gates in order:

1. Install a signed build on iPhone, disconnect the debugger, relaunch and prove
   JVM startup without JIT or jailbreak. Capture the runtime revision, iOS/device
   versions, cold-start time and startup log.
2. Load the locked engine and module image. Exercise E4X and Java interop to
   verify `java.xml` and any `java.beans` dependency rather than checking only
   file presence.
3. Run original semantics tests for dynamic `this`, indirect `eval`, `Function`,
   legacy scope rewriting, E4X, object wrapping, overloads and exceptions.
4. Compare the complete fixed-response search/details/TOC/content chain with the
   reference behavior; include pure-JS sources, login and batch content.
5. Exercise infinite-loop cancellation, network/browser timeouts, concurrent
   isolation and repeated sessions. Measure cold startup, package-size increase,
   peak memory and rule latency on the same device and build.

The current workspace is Windows; cloud Xcode builds and user-operated iPhone
testing have produced runtime evidence. G1 and G2 passed, while G3–G5 retain
uncovered cases. Do not proceed to full feature migration
before gates 1 through 4 pass. If the JVM route fails those gates, retain the same
semantic tests when evaluating a different engine.

## Platform and rollout constraints

The prototype default is iOS 18+, while existing project deployment targets stay
unchanged. Preserve native CoreText rendering and the established production
source-session path during evaluation. Any promotion into production requires
explicit runtime selection, one owner for source state, migrated compatibility
tests and a reversible opt-in rollout.

iOS equivalents include file pickers, share extensions, App Intents,
AVFoundation, system TTS, PDFKit and Picture in Picture. Android Intents,
arbitrary overlay windows and device identifiers need documented mappings.
Automatic tasks use system-scheduled background execution and foreground
catch-up. HTTP, WebSocket and MCP services are foreground capabilities; exact
Cron timing and availability while the app is suspended are not promised.

Track three independent outcomes: feature coverage, protocol/data compatibility
and source-runtime compatibility. Mark a feature complete only when its own
acceptance scenario passes on iOS and its evidence is linked from the gate
ledger.
