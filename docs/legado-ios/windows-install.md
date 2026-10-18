# Windows 安装说明

目前只维护一个用户版本，暂名「本地书架」，最低 iOS / iPadOS 18。后续安装包不内置书源，在 App 内自行导入即可；覆盖更新保留已经导入的书源和阅读数据。当前新版仍在验证，本文下面的旧 IPA、旧名称和 Probe 构建属于历史记录，不是新版下载推荐。

1. 取得已核对版本和哈希的 IPA，在 Windows 上连接并解锁设备。
2. 打开已用过的 iloader，选中设备，导入 IPA，使用原 Apple ID 覆盖安装；更新前不要卸载旧版。
3. 打开 App 正常阅读。首次安装时，按设备提示信任开发者并开启开发者模式。

账号密码和验证码只在本机签名工具中输入。签名续期不由本 App 完成。暂时不分发安装包；旧个人包含私人书源，不要转发。

## 历史构建与安装排障记录

These instructions apply after a successful cloud build produces
`legado-probe-unsigned`. Build 6 at `78930be` now has a hash-checked `ios-device`
report with `passed=true` on `iPhone18,3` / iOS 27.0.1. Its 25 original engine
cases (0 failed/skipped), JavaBeans, custom semantics and fixed reading/state/
cancellation-handshake fixture passed. The earlier termination did not recur;
its original cause remains unconfirmed. The user confirmed direct Home Screen
launch of the self-signed app without a debugger, extra JIT tooling or jailbreak.
G1 and G2 passed; G3–G5 are partially covered. See
[device-validation.json](device-validation.json). The probe requires iOS/iPadOS
18 or later; full feature migration remains gated.

## Install the reading experience

For the bookshelf and actual reader UI, use the separate unsigned
`reader-experience-unsigned` artifact from
[run 39088051622](https://github.com/zhoujianjia/legado-ios/actions/runs/39088051622).
The locally exported file is `ReaderExperience-c6c89b8.ipa`, version 3.0.0 (3),
with desktop name **閱讀**. Use the same signing workflow that installed the
probe, then import [the TXT sample](fixtures/阅读体验样书.txt) to begin.
Keep its `build-manifest.json`; [reader-experience.json](reader-experience.json)
records the package hashes and current acceptance limits.

This package includes the local Apple Account prompt repair and full directory
row hit regions. It uses Yuedu's existing JavaScriptCore/CoreText reader and
does not include the experimental JVM. The standalone **Legado Probe** app is
for runtime validation. A passing package audit does not establish device reading
or full Legado compatibility.

## Get the runtime probe device build

Download `legado-probe-unsigned` from the successful Actions run and extract the
downloaded artifact ZIP. Use the contained `LegadoRuntimeProbe-unsigned.ipa`;
the outer artifact ZIP is not itself an IPA. Preserve `build-manifest.json`
with the build's run URL and revision.
The first successful build, run 39003367690, records its source commit only in
that accompanying manifest; its on-device JSON can say `not_injected` for the
commit field. Keep both files together. Later packaging stamps the bundle field.

Compare the IPA hash with `ipaSHA256`:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\LegadoRuntimeProbe-unsigned.ipa
```

The workflow exports an arm64 iPhoneOS app. Its simulator compilation is a
separate check; simulator products cannot be installed on the phone.

If Windows PowerShell shows an `Invoke-WebRequest` page-parsing security prompt,
choose **No** and download through the browser or use `-UseBasicParsing` for that
request. This is PowerShell's HTML parser prompt, separate from IPA signing and
the phone's developer trust setting. See [Microsoft's command documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/Invoke-WebRequest?view=powershell-5.1).

A runtime replay can also produce this artifact after reusing source-built Zero
and JVM products with matching inputs. The app is compiled again from the tagged
current commit; its `runtime-reuse.json` records the source run and checks. The
trigger tag is `legado-replay-<sourceRunID>-<currentSHA prefix>`; see the
[replay requirements](README.md#build-and-validation-sequence). An exported IPA
does not imply that Simulator or physical-device execution passed.

Version 0.2 build 6 at `78930be` passed both CI jobs and the actual Simulator
fixture in [run 39044188251](https://github.com/zhoujianjia/legado-ios/actions/runs/39044188251).
Its 25 original engine tests, JavaBeans probe and fixed reading chain passed;
the downloaded device IPA also passed hash, bundle, payload and ten-export
checks. See [simulator-validation.json](simulator-validation.json). Use this
build to reproduce the successful device fixture and collect remaining gate evidence.

The unsigned IPA is 48,830,136 bytes with SHA256
`ae0a90eddadcb1f6b54df08370fe1971a97478717e074426b139ea4759eb3afc`.
Build 5 had started the JVM but failed to link its legacy verifier; build 6 adds
the missing static verifier and exact linker root. Earlier failed IPAs remain
diagnostic artifacts.

The build retains persistent diagnostics, the corrected bootstrap layout and
the non-executable Zero code-cache adaptation. A diagnostic run confirmed the
old Simulator runtime's `mprotect` failed with `Permission denied`; the repaired
runtime then initialized successfully. This does not establish the original
iPhone termination's cause. See the
[code-cache investigation](code-cache-investigation.json). Staging uses
`Resources/LegadoRuntime/java-home`, while the final app build phase moves that
home to `LegadoRuntimeProbe.app/lib` without duplication or symbolic links. The
engine JAR and staging manifest remain in the app's `LegadoRuntime` directory.
Source inspection identified an early BSD VM lookup of `App.app/lib` before
`-Djava.home` is parsed, but has not confirmed the cause of the reported
termination. See the [bootstrap investigation](bootstrap-layout-investigation.json).

## Sign locally and install

The successful Windows installation used **iloader v2.3.9**, available from
[iloader.app](https://iloader.app/) or its
[official release](https://github.com/nab138/iloader/releases/tag/v2.3.9).
The [versioned README](https://github.com/nab138/iloader/blob/v2.3.9/README.md)
documents importing an IPA; SideStore installation is not required for this probe.

1. Connect and unlock the iPhone over USB, and accept **Trust This Computer**.
2. Open iloader, select the phone and choose **Import IPA**. Select the extracted
   `LegadoRuntimeProbe-unsigned.ipa` from the intended build.
3. Sign in with the Apple account used for the existing installation. Approve
   two-factor authentication on the trusted iPhone and enter its verification
   code in iloader. Keep the account credentials and code out of chat and Actions.
4. Install, then follow any device prompt to trust the developer account under
   **Settings → General → VPN & Device Management**.
5. Enable **Settings → Privacy & Security → Developer Mode**, restart and confirm
   when requested. See [Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
   if it is not already enabled.

For a new probe build, use the same Apple account to update the existing app and
retain its diagnostics. Export available reports first and keep the old app
installed; deleting it removes its app-owned diagnostic files.

In this session, Sideloadly encountered a GSA HTTP 503 error. After switching to
iloader, its default `mac-ani.jkcoxson.com/v3/client_info` returned HTTP 502.
Selecting **Jkcoxson (Windows)** (`ani.jkcoxson.com`) in iloader's anisette settings
then allowed installation to complete. This is a built-in choice in the
[v2.3.9 settings source](https://github.com/nab138/iloader/blob/v2.3.9/src/pages/Settings.tsx);
server availability can change. [Sideloadly](https://sideloadly.io/) remains an
alternative signing tool, but iloader is the working route recorded here.

Free Personal Team provisioning expires after seven days; refresh the signature
to keep the test app usable. See [Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).
Paid membership is optional for this test.

To reduce weekly signing work, [SideStore](https://docs.sidestore.io/docs/faq)
can refresh apps on the phone after its initial computer-assisted installation.
This renews the free seven-day profile rather than removing its expiration;
check that refreshing succeeds before it expires. SideStore itself also needs
refreshing and occupies one of the free account's three app slots.
The probe does not currently implement in-app signing or automatic refresh.

An account enrolled in the [Apple Developer Program](https://developer.apple.com/programs/whats-included/)
costs 99 USD per membership year or the local price. SideStore documents a
365-day expiry with a paid account; the actual profile/certificate expiration
still applies. The standard [TrollStore supported range](https://github.com/opa334/TrollStore)
does not include this project's iOS 18+ devices. These options were checked on
2026-10-17; they do not alter the prototype's runtime acceptance criteria.

## Preserve evidence if the app closes

Do not delete or reinstall the app before exporting available reports and app
diagnostics. An earlier attempt terminated after starting the fixture, and the
user did not find a matching crash report. Build 6 completed the device fixture;
that success does not independently establish the earlier termination's cause.
For any future unexpected exit, preserve available logs before another attempt.

On the iPhone, open **Settings > Privacy & Security > Analytics & Improvements >
Analytics Data**. Look for a report beginning with `LegadoRuntimeProbe` near the
attempt, and also check `JetsamEvent` entries from that period. Open a matching
entry and use **Share** to save the complete `.ips` file to Files, then transfer
it to Windows. Export the original file instead of copying a long screen of
text. If no matching report is found, record that result; do not substitute an
unrelated report or infer a cause from a filename. See Apple's
[crash and diagnostic log instructions](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs).

For diagnostic version 0.2 build 5, once available, reopen the app after a
termination and share its technical JSON report with the report's Share action
(`ShareLink`). Preserve
`savedDiagnostics` and `probeProgress`, including any recovered JVM error report,
with the matching build manifest. These fields are intended to survive a failed
attempt and identify the last recorded phase; they do not guarantee that a native
crash produced a log. The Share action exports an actual JSON file that can be
saved to Files. The first IPA from run 39003367690 predates this persistence and
sharing support, so its absence there is expected. Reported timings include
diagnostic I/O and do not measure production performance.

## Capture the actual runtime result

Disconnect USB and launch **Legado Probe** from the Home Screen. Inspect the
payload, run the synthetic reading fixture and save its JSON report. The
diagnostic payload also executes the unchanged original 25-case engine
suite and a JavaBeans functionality probe; preserve every case result and the
device/OS, source commit, runtime versions and payload manifest in that report.
For a cold start, terminate the app and relaunch before running the fixture. Record the
device model, OS version, build manifest and run URL alongside the report.

Repeat on iPad after the initial iPhone run. Installation and a file preflight
alone do not pass the JVM gate: startup, semantics, request/state behavior and
cancellation must execute successfully. Preserve any error instead of reporting
the gate passed. See the [probe guide](../../Prototypes/LegadoRuntimeProbe/README.md)
and [acceptance ledger](validation-gates.json).
