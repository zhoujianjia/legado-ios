# Legado compatibility baseline

The Legado reference files in the root `manifest.json` are copied without modification from `F:\legado-master.zip`.
Archive SHA-256: `724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd`.
`manifest.json` records each vendored file's original archive path and SHA-256.

- `legado-rhino`: `modules/rhino/src/main/java`, including the custom Context,
  bindings, Java wrappers, concurrent global objects, and E4X implementation.
- `legado-analyzers`: the CSS, JSONPath, XPath and regex analyzers, their rule
  tokenizer, and the source-specific HTML parser from `app/src/main/java`.
- `maven`: original local Maven artifact `org.htmlunit:htmlunit-core-js:5.3.0-legado.4`.
  Its JAR SHA-256 is `d720f34285515025e4ccc80a5b92aed42cb26c03a7715ca53583d2c74ae51df7`.
- `licenses`: the engine's notices, licenses, source revisions and changes supplied
  by the archive. The original project license is retained in `LICENSE`.

The executable adaptations are under `../jvm/src/main`, keeping these reference
copies available for review. The standalone build removes Android imports,
replaces the two AndroidX bounded caches with a synchronized JVM cache, replaces
`TextUtils.join`, and reports JSONPath failures instead of Android debug logging.
The class shutter additionally hides new embedding internals. It retains the
original runtime semantics and does not replace the custom engine with a generic
Rhino release.

`openjdk-notices` is a separate import from the immutable OpenJDK Mobile,
ios-tools and libffi source pins. It preserves original legal materials, module
source candidates and the native build's archive composition. See its manifest
and `docs/legado-ios/runtime-notices.md` at the repository root. This import is
not part of the Legado archive provenance and does not establish complete
corresponding dependency source or a license-combination/distribution verdict.
