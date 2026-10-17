# Install the prototype from Windows

These instructions apply after a successful cloud build produces
`legado-probe-unsigned`. The user has self-signed, installed, and opened the first
build on an iPhone. A screenshot shows payload preflight passing, but the user
reports that running the synthetic fixture closes the app. No crash log has been
provided, and JVM startup and all device gates remain unverified. See
[device-validation.json](device-validation.json). The standalone probe requires
iOS/iPadOS 18 or later.

## Get the device build

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

The next version 0.2 build 3 keeps the diagnostics introduced in build 2 and fixes
the bootstrap Java-home layout; its runtime validation is pending. Staging uses
`Resources/LegadoRuntime/java-home`, while the final app build phase moves that
home to `LegadoRuntimeProbe.app/lib` without duplication or symbolic links. The
engine JAR and staging manifest remain in the app's `LegadoRuntime` directory.
Source inspection identified an early BSD VM lookup of `App.app/lib` before
`-Djava.home` is parsed, but has not confirmed the cause of the reported
termination. See the [bootstrap investigation](bootstrap-layout-investigation.json).

## Sign locally and install

Use [Sideloadly's official Windows download](https://sideloadly.io/).
Its current prerequisites are the web versions of Apple's iTunes and iCloud,
linked from that page. Check existing Apple software before changing drivers.
The tool supports free Apple accounts and accepts IPA files for signing.

1. Connect and unlock the iPhone over USB, and accept **Trust This Computer**.
2. Open Sideloadly, select the connected device and load the extracted IPA.
   Choose **Apple ID Sideload** as the installation mode.
3. Enter the Apple account and any authentication prompts in the local signing
   tool. Keep these credentials out of chat, the repository and Actions.
4. Install, then follow any device prompt to trust the developer account under
   **Settings → General → VPN & Device Management**.
5. Enable **Settings → Privacy & Security → Developer Mode**, restart and confirm
   when requested. See [Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
   and the [Sideloadly setup/trust FAQ](https://sideloadly.io/faq).

Free Personal Team provisioning expires after seven days; refresh the signature
to keep the test app usable. See [Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).
Paid membership is optional for this first test. Sideloadly also documents
refreshing in its FAQ.

## Preserve evidence if the app closes

Do not delete or reinstall the app before exporting available reports and app
diagnostics. The current report is a user-observed termination after starting the
fixture; a passed payload inspection does not show how far JVM startup reached.
The user has not found a report beginning with the app name. That absence does
not establish whether iOS generated a crash or memory-pressure report.

On the iPhone, open **Settings > Privacy & Security > Analytics & Improvements >
Analytics Data**. Look for a report beginning with `LegadoRuntimeProbe` near the
attempt, and also check `JetsamEvent` entries from that period. Open a matching
entry and use **Share** to save the complete `.ips` file to Files, then transfer
it to Windows. Export the original file instead of copying a long screen of
text. If no matching report is found, record that result; do not substitute an
unrelated report or infer a cause from a filename. See Apple's
[crash and diagnostic log instructions](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs).

For diagnostic version 0.2 build 3, once available, reopen the app after a
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
