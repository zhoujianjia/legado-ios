# Original Android reading-chain reference

Build 8 adds a 28-case `legado-interop-v1` matrix to the packaged JVM and iOS
probe, plus a finite JSON DTO implementation of the archive's `JsSourceMarshaller`
and selected `JsSourceBook` preparation. The original 25-case engine suite stays
unchanged. Passing desktop tests does not establish a new physical-device pass.

The DTO implementation filters malformed search/TOC items, preserves source
identity and source-type rules, merges permitted book-detail fields and supplies
chapter ownership, base URL and consecutive indices. It covers the declared
JSON fields only. Scripts currently receive JSON book objects, rather than the
original mutable Java/Room entities; timestamps, computed fields, arbitrary Java
Book methods and exact reference mutation behavior remain outside this slice.
Required search/chapter fields distinguish absent defaults from explicit `null`;
the latter preserves the original short-circuit validation failure. Multi-key
book-variable maps currently preserve values but can differ in serialized key
order from the original entity's mutable HashMap.

Actual Android execution first exposed a scope difference: the original enables
explicit shared globals only when `jsLib` is nonblank. The port now preserves
this condition. Both platforms test counts `1,1` without a library and `1,2`
with a library, while source variables/cookies/cache still survive calls.
The main reading fixture explicitly configures the same inert inline library on
both platforms. Its script bytes remain unchanged. Request snapshots retain
explicit JSON nulls rather than losing GET body metadata through Gson.

## Independent reference execution

The [Android reference workflow](../../.github/workflows/legado-android-reference.yml)
builds the original Android application and executes one added instrumentation
test in a fresh Linux-hosted emulator. Trigger it manually or with a
`legado-reference-<commit>` tag. It uses the original Application, WebBook,
JsSourceBook, custom engine, HTTP stack, database, cookies and cache. It does not
substitute the iOS port's host implementation. Only the selected added test runs;
unrelated original tests are not selected.

The committed snapshot derives from the pinned user ZIP. Its manifest hashes
every retained file. It excludes the entire original `.github` directory,
including its signing key, and the original Google services configuration.
Staging verifies every retained byte, adds an inert test Google configuration,
the test and shared fixture, and debug metadata disabling telemetry collection.
Original business files are verified again before and after execution. Failed
builds or partial reports cannot constitute an Android reference pass.

The archive declares Android API 23, while D8 rejects the bundled Rhino's
`MethodHandle.invoke/invokeExact` below API 26. An external Gradle init script
raises only the reference application's minimum SDK to 26; both APK compilation
and instrumentation use that same hashed script. The test verifies the installed
APK's declaration and runs on API 35. The original Gradle and engine files stay
unchanged. This reference therefore makes no Android API 23 compatibility claim.

Reproduce staging on Windows without an Android SDK:

```powershell
python -B scripts/legado-reference/test-prepare-reference.py -v
python -B scripts/legado-reference/prepare-reference.py stage --snapshot-directory Packages/LegadoRuntime/vendor/android-reference --destination .build/legado-reference/source
python -B scripts/legado-reference/run-reference.py stage
```

Staging requires a fresh destination and never overwrites an existing source
directory. Actual Android compilation/execution runs in CI; it does not require
an Android phone or a local Mac.

## Comparing traces

The Android artifact retains raw HTTP request headers/body bytes, full original
models, cache reads and a declared canonical trace. Build 8's iOS probe report
adds the matching `readingChain` section. Both execute the exact same hashed
`main-source.js`, using fixed loopback responses and explicit request headers.

```powershell
python -B scripts/legado-reference/test-compare-reference.py -v
python -B scripts/legado-reference/compare-reference.py --android android-golden.json --ios LegadoProbe-report.json --output reference-diff.json
```

The comparator checks the declared search/details/TOC/content/batch projection,
request body bytes, headers, variables, cookies, cached content, shared state and
exceptions. It normalizes only documented transport origin differences and
validated derived headers. It rejects missing fields, failed reports, duplicate
JSON keys, changed fixture hashes and unexplained requests. Raw Android wire
bytes remain available; the iOS fixture host currently captures logical request
bytes, not URLSession wire traffic, so HTTP protocol-version and wire-header
ordering parity are outside this comparison.

A matching pure-JS fixture is a scoped result, not a complete G4 pass. Declarative
rules, representative real sources, actual iPhone execution of the new interop
vectors, network/browser cancellation, concurrency and sustained performance
still require separate evidence. Historical device gates stay tied to their
original build and report hashes.
