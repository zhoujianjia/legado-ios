# Build the Legado iOS prototype without a local Mac

The available devices are a Windows computer, an iPhone, and an iPad. Windows can
develop and test the portable Legado core. A manually triggered GitHub Actions
macOS runner can build the native prototype; the iPhone or iPad is still needed
for installation and actual runtime validation. No Mac SSH connection is needed.

See [cloud-validation.json](cloud-validation.json) for observed cloud runs,
failures, and verified fixes. The initial runs exposed missing dependency
checksum entries, which have been added and checked with a fresh dependency
cache and forced JVM rebuild/tests. The cloud has passed eight Swift tests,
built both native Zero slices with complete Java module/data payloads, linked
both apps and verified all nine required dynamic exports. Successful
[run 39003367690](https://github.com/zhoujianjia/legado-ios/actions/runs/39003367690)
provides an unsigned IPA. Signing and device execution remain unverified, and all
device validation gates remain pending.
Pinned source revisions make the inputs reviewable; they do not guarantee that
the Zero build will succeed on the selected runner.

## Prepare your own repository

The user-controlled destination is
[`zhoujianjia/legado-ios`](https://github.com/zhoujianjia/legado-ios). The local
`origin` targets that repository; the original Yuedu remote is retained as
`upstream`. Before the cloud workflow can run, the prepared implementation must
be pushed to the destination, with GitHub Actions enabled. SSH authentication
has been verified as `zhoujianjia` and the prepared prototype has been pushed.
The browser-based CLI login is optional when using SSH build tags or the
Actions page's manual trigger.

Include the implementation, vendored runtime JARs and their license/provenance
files, the Gradle wrapper, and the workflow at
[.github/workflows/legado-ios-prototype.yml](../../.github/workflows/legado-ios-prototype.yml).
Do not upload local `.tools`, `.build`, Gradle caches, generated native binaries,
or signing credentials. The original `F:/legado-master.zip` is not required by
this workflow: inventory regression tests use small generated ZIP fixtures, and
the committed inventory records the original archive baseline.

GitHub provides macOS-hosted runners. Runner availability, usage limits, and any
charges depend on the repository and GitHub plan; check the account's Actions
settings before running the build. See GitHub's
[hosted runner documentation](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Start the manual build

Once the implementation exists in your own repository:

The workflow file must also exist on the repository's default branch for GitHub
to offer its manual trigger. The branch selected below determines the code built.

1. Open the repository on GitHub and select **Actions**.
2. Select **Legado iOS Prototype**.
3. Select **Run workflow**, choose the branch containing the implementation, and
   select **Run workflow** again.
4. Open the resulting run to watch its jobs and download its artifacts.

The workflow accepts `workflow_dispatch` and pushes of dedicated
`legado-probe-*` tags. A build tag can be pushed using an existing SSH key,
without a GitHub CLI/API login:

```bash
git tag legado-probe-<unique-build-id> <reviewed-commit>
git push origin refs/tags/legado-probe-<unique-build-id>
```

Replace the placeholders with an unused build name and the commit to validate.
Normal branch pushes do not start this expensive workflow. A build tag starts
validation only; the workflow does not publish a GitHub Release, sign an app,
or upload an app to Apple. No Apple account credentials are needed for these
unsigned compilation steps.

The jobs perform these checks in order:

1. Run the portable Python/JVM tests on Linux, assemble the pinned JVM payload,
   and run its packaged interpreter smoke tests. The diagnostic payload opts in
   with `-PincludeEngineTests=true`, carrying the unchanged original 25-case
   engine suite and separately retained JUnit/Hamcrest licenses for device use.
2. On `macos-15`, run source-only Swift package unit tests and build the pinned
   OpenJDK Mobile Zero device and arm64 simulator slices.
3. Stage the simulator payload and compile/link the standalone iOS simulator app
   against the actual native bridge.
4. Stage the device payload, compile the unsigned iOS device app, and package it
   as an unsigned IPA after checking nine source-proven bootstrap exports in the
   final executable's dyld export trie.

The pinned Zero backend requires a local source adaptation: its Apple ARM64 W^X
state implementation is copied from the same revision's AArch64 backend. Both
full source hashes and the prepared hash are checked before writing; the iOS
guard excluding the actual pthread JIT switch is retained. See
[prepare-zero-wx.py](../../scripts/legado-ios/prepare-zero-wx.py). This changes
neither the locked JavaScript engine nor the no-JIT device acceptance criteria.

The source-only Swift tests run on macOS. The simulator step compiles and links
the iOS app; it does not launch the simulator, execute the JVM on iOS, or run iOS
XCTest. A successful cloud run is build evidence, not a passed device gate.

## Download the result or inspect a failure

The run's **Artifacts** section contains:

| Artifact | Purpose |
| --- | --- |
| `legado-jvm-payload` | The assembled portable JVM payload used by the native build. |
| `legado-portable-test-logs` | Python/JVM test logs and available JUnit reports. |
| `legado-macos-build-logs` | Available macOS build logs and diagnostic reports, including evidence from a failed build. |
| `legado-probe-unsigned` | The unsigned IPA, build manifest, and signing reminder produced after successful native builds. |

If a job fails, open that job and the first failed step, then download
`legado-macos-build-logs` when it is available. A failure before the macOS job
starts will have its evidence in the Linux job log instead. Preserve the run URL,
failed step, and relevant log with any fix; do not mark a gate passed from an
artifact name or an incomplete build.

## Sign and test on iPhone or iPad

The unsigned IPA cannot be installed directly as a working iOS app. Signing and
provisioning are a separate, account-dependent step. The account/team, bundle
identifier, and target device must be decided before preparing an installable
build. No signing service or account has been configured by this prototype.
For the Windows route, follow [local signing and USB installation](windows-install.md)
after a successful device build.

After an appropriately signed build is installed, use an iPhone for the first
accepted device gate and use the iPad for additional compatibility checks. Launch
from the Home Screen without a debugger, then run the synthetic reading fixture
and save its JSON report. Record the device/iOS version and build revision along
with startup, memory, semantics, request bytes, state, and cancellation results.
See the [standalone probe instructions](../../Prototypes/LegadoRuntimeProbe/README.md)
and [validation gates](validation-gates.json).

Full feature migration remains gated on actual device results for gates 1 through
4. A cloud build, successful signing, or installation alone does not satisfy
those gates.
