# Install the prototype from Windows

These instructions apply after a successful cloud build produces
`legado-probe-unsigned`. No IPA has been installed or validated on a device yet.
The standalone probe requires iOS/iPadOS 18 or later.

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
