# Build the Legado iOS prototype without a local Mac

The available devices are a Windows computer, an iPhone, and an iPad. Windows can
develop and test the portable Legado core. A manually triggered GitHub Actions
macOS runner can build the native prototype; the iPhone or iPad is still needed
for installation and actual runtime validation. No Mac SSH connection is needed.

See [cloud-validation.json](cloud-validation.json) for observed cloud runs,
failures, and verified fixes. Build 5 at `203b352` in
[run 39042657077](https://github.com/zhoujianjia/legado-ios/actions/runs/39042657077)
started the actual Simulator JVM (`JNI_CreateJavaVM` returned 0 in 4.725 seconds),
created a session, read diagnostics and closed it without a hard exit. The
original suite then failed to load with `java.lang.VerifyError: Could not link
verifier`; none of its 25 cases ran. Candidate version 0.2 build 6 at `78930be`
adds the static verifier and a ten-export gate; its fresh source build is pending
in [run 39044188251](https://github.com/zhoujianjia/legado-ios/actions/runs/39044188251).
Retained IPAs from failed runs are diagnostic evidence, not validated candidates.
The user's earlier iPhone installation and preflight succeeded, but fixture
execution terminated the app for an unconfirmed reason; see
[device-validation.json](device-validation.json). All physical-device gates
remain pending.
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
Actions page's manual trigger. The repository was temporarily private, causing
unauthenticated API requests to return 404; the user has since temporarily made
it public again. If it becomes private later, SSH Git access and permission to
read Actions through the API remain separate: the API/CLI login or GitHub app
must have access to this repository. An unauthenticated 404 does not establish
that the repository or build was deleted. Private artifacts can also be retrieved
through the signed-in Actions page.

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
   as an unsigned IPA after checking ten source-proven bootstrap/verifier exports in the
   final executable's dyld export trie.
5. Launch the Simulator app and attempt its synthetic fixture, preserving reports
   and logs. A produced IPA is retained even if this runtime check fails.

The pinned Zero backend requires a local source adaptation: its Apple ARM64 W^X
state implementation is copied from the same revision's AArch64 backend. Both
full source hashes and the prepared hash are checked before writing; the iOS
guard excluding the actual pthread JIT switch is retained. See
[prepare-zero-wx.py](../../scripts/legado-ios/prepare-zero-wx.py). This changes
neither the locked JavaScript engine nor the no-JIT device acceptance criteria.

The build uses
[prepare-zero-code-cache.py](../../scripts/legado-ios/prepare-zero-code-cache.py).
It verifies the complete original and prepared source hashes, then passes
`!ExecMem` to `CodeMemoryReserver` only under `__IOS__ && ZERO`. Zero stores
metadata and pointers to precompiled C++ interpreter functions in this cache.
Diagnostic run 39043099245 confirmed the old runtime's 32 MiB reservation
succeeded, then `mprotect` on its initial 160 KiB failed with `Permission denied`.
The executable-memory request follows the pinned source chain. Build 5 started
the repaired Simulator JVM; the original iPhone failure remains unexplained. See the
[code-cache investigation](code-cache-investigation.json).

Build 6 adds the source-built `libverify.a`, precisely retains
`_VerifyClassForMajorVersion`, and checks ten final dynamic exports to address
the subsequent verifier-link error. This repair requires a fresh native build
and remains under runtime validation; bytecode verification is not bypassed.

The source-only Swift tests run on macOS. The Simulator smoke launches the app;
it is separate from iOS XCTest and physical-device validation. Build 5 initialized
the JVM successfully but failed before the original semantic cases could run.
A successful cloud run cannot pass the physical-device gates.

For later app or packaging fixes with unchanged native/JVM inputs, the
[Legado iOS Runtime Replay workflow](../../.github/workflows/legado-ios-replay.yml)
accepts a `legado-replay-<sourceRunID>-<currentSHA prefix>` tag. It checks six
native input files (`build-zero.sh`, `prepare-zero-wx.py`,
`prepare-zero-code-cache.py`, `prepare-symbol-keeper.py`, `fetch-sources.py`, and
`runtime-lock.json`) and the full JVM tree against the source run before reusing
its matching products. The current app is compiled and linked again before its
Simulator attempt. Keep `runtime-reuse.json` with the result; replay does not
claim a new runtime compilation. Changed inputs require the full source build.

## Download the result or inspect a failure

The run's **Artifacts** section contains:

| Artifact | Purpose |
| --- | --- |
| `legado-jvm-payload` | The assembled portable JVM payload used by the native build. |
| `legado-portable-test-logs` | Python/JVM test logs and available JUnit reports. |
| `legado-zero-source-build` | Source-built native framework, Java homes and lock used by a matching follow-up replay. |
| `legado-macos-build-logs` | Available macOS build logs and diagnostic reports, including evidence from a failed build. |
| `legado-replay-logs` | Follow-up replay provenance, app-build and Simulator diagnostics. |
| `legado-probe-unsigned` | The unsigned IPA, build manifest, and signing reminder produced after successful native builds. |

If a job fails, open that job and the first failed step, then download
`legado-macos-build-logs` when it is available. A failure before the macOS job
starts will have its evidence in the Linux job log instead. Preserve the run URL,
failed step, and relevant log with any fix; do not mark a gate passed from an
artifact name or an incomplete build.
Wait for a candidate with the required successful Simulator fixture result before
the next phone installation; a retained IPA from a failed fixture is for diagnosis.

## Sign and test on iPhone or iPad

The unsigned IPA cannot be installed directly as a working iOS app. Signing and
provisioning are a separate, account-dependent step. The account/team, bundle
identifier, and target device must be decided before preparing an installable
build. The user completed the initial installation locally with iloader; no
Apple signing credentials are configured in the cloud workflow.
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
