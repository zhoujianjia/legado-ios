# Runtime notice materials

The original Probe 12 native archive and reader build10 contain the OpenJDK root
`LICENSE`, `ADDITIONAL_LICENSE_INFO`, `ASSEMBLY_EXCEPTION`, and libffi's `LICENSE`.
Their Java homes contain no module-local OpenJDK `legal` files. This supplement
preserves original notice materials as separate App resources; it does not modify
that native archive, Java home, ordinary JAR, or the seven native-producer inputs.

`Packages/LegadoRuntime/vendor/openjdk-notices/manifest.json` identifies **37
original files / 370,325 bytes**, with immutable upstream paths, Git blob IDs,
sizes and SHA-256 values. GitHub raw bytes were compared against the fixed source
trees; libffi's license was read from its whole-archive SHA-256-verified release
tarball. No license text was reformatted.

| Source | Material inventory |
| --- | --- |
| [OpenJDK Mobile c1ed06a](https://github.com/openjdk/mobile/tree/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb) | Three root notices; 32 module-local legal source candidates: `java.base` 8 shared + 1 Windows, `java.xml` 13 shared, `java.desktop` 8 shared + 2 Unix. The other ten required modules have no independent legal source files at this revision and are explicitly listed with empty inventories. |
| [ios-tools 2f0a489](https://github.com/openjdk-mobile/ios-tools/blob/2f0a489b48cdb13901185be051004f7a9c23bf14/LICENSE) | Original root `LICENSE` containing the GNU Affero General Public License v3 text. Its `symbol_keeper.cpp` is a separate injected input to HotSpot; the manifest records the original Git blob and source/prepared SHA values. Its effective license application remains under review. |
| [libffi 3.5.2 release](https://github.com/libffi/libffi/releases/tag/v3.5.2) | Original `LICENSE` from the tarball locked in `scripts/legado-ios/runtime-lock.json`. Its bytes also match the existing native and build10 payload. |

All module platform candidates are retained with their original directory names.
This deliberately includes Windows/GCC/Unix texts without claiming those
components are selected, linked, or applicable on iOS. Upstream's
[CopyCommon](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/common/modules/CopyCommon.gmk)
and module Copy rules normally select/filter legal materials according to the
target and external libraries; this supplement is not a reconstructed jlink
legal image.

The build-script composition is recorded separately: HotSpot `libjvm.a`; the six
`java.base` archives `libjava`, `libzip`, `libverify`, `libnet`, `libnio`, and
`libjimage`; and external `libffi.a`. HotSpot has no independent `legal`
directory in the locked source tree. Its source headers, the ios-tools injection,
and any other object-level license boundaries still need review. Enumerating
thirteen Java modules alone cannot establish those boundaries.

`scripts/legado-ios/stage-runtime.py` is the single staging entry for all native
reader and probe workflows. It verifies the committed notice inventory and
stages an independent runtime-owned `Notices` directory alongside the unchanged
Java home/JAR. `runtime-notices.py` performs offline path, exact inventory,
manifest-fingerprint, SHA-256 and Git-blob checks. The reader checks it before
compilation and again in the built App; the package manifest records its result
under `bundleValidation.runtimePayload.notices`. A missing, extra, modified or
linked notice stops acceptance. Merely copying documentation cannot make the
runtime or a book source pass execution tests.

Replacement additionally requires an existing `Notices` directory to match this
fixed original manifest and its fingerprint declared by the prior runtime
staging marker. A legacy Java-home/JAR marker cannot authorize removing a
user-created sibling `Notices` directory; unrecognized materials are preserved.

Portable validation:

```text
python -B scripts/reader-experience/runtime-notices.py verify
python -B scripts/reader-experience/test-runtime-notices.py -v
python -B scripts/legado-ios/test-runtime-tools.py -v
python -B scripts/reader-experience/test-stage-config.py -v
```

The focused staging regression compares every source/staged Java-home file and
the JAR before and after ordinary staging/replacement. Filesystem link tests
report a skip when the host cannot create that link; Windows junctions and the
link-rejection guard are checked separately. These tests do not compile native
code or validate an updated IPA.

This is a bounded notice-material supplement. Complete corresponding dependency
source, native/source-header license coverage, the engine/JDK build closure and
the component-license combination remain unverified. Existing release blocks
and historical build evidence remain in force; this does not establish legal
redistribution clearance or change the licenses of any component.
