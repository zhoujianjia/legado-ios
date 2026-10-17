# Build the Legado iOS prototype without a local Mac

The available devices are a Windows computer, an iPhone, and an iPad. Windows can
develop and test the portable Legado core. A manually triggered GitHub Actions
macOS runner can build the native prototype; the iPhone or iPad is still needed
for installation and actual runtime validation. No Mac SSH connection is needed.

The first cloud run started through an SSH-pushed build tag. Its Python tests
passed; the portable JVM build stopped at dependency verification before the
macOS job. See [cloud-validation.json](cloud-validation.json) for the run and
failure evidence. Apple compilation, signing, and device execution remain
unverified, and all device validation gates remain pending. Pinned source
revisions make the inputs reviewable; they do not guarantee that the Zero build
will succeed on the selected runner.

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
   and run its packaged interpreter smoke test.
2. On `macos-15`, run source-only Swift package unit tests and build the pinned
   OpenJDK Mobile Zero device and arm64 simulator slices.
3. Stage the simulator payload and compile/link the standalone iOS simulator app
   against the actual native bridge.
4. Stage the device payload, compile the unsigned iOS device app, and package it
   as an unsigned IPA.

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
