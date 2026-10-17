# Legado JVM prototype

Requires JDK 21. From this directory:

```sh
./gradlew test runtimeJar runtimeBundle runtimeSmoke
```

`build/libs/legado-runtime.jar` is a self-contained JNI payload. Source classes
(including the upstream E4X overrides) precede dependency classes during assembly;
service-provider files are merged. `build/runtime/lib` is the equivalent thin
classpath; put `legado-runtime-0.1.0-prototype.jar` before its dependencies.

The compiler, coroutine, custom engine and parser dependencies retain their
archive versions. Okio is a standalone JVM dependency used by the original class
shutter; Android networking has been replaced by explicit native callbacks.
Gradle's wrapper distribution is SHA-256 pinned.

`runtimeSmoke` launches a separate JVM using only the assembled JAR, with `-Xint`
and a 128 MB Java heap, to exercise the packaged E4X overrides and read chain.
It is a desktop packaging gate, not an iOS Zero performance result.

## JNI interface

All methods are static on `io.yuedu.legado.LegadoRuntime` and return JSON strings:

| Method | Arguments | Success |
| --- | --- | --- |
| `createSession` | `sourceJson` | `{ "ok": true, "sessionId": "..." }` |
| `execute` | `sessionId, taskId, operation, inputJson` | `{ "ok": true, "taskId": "...", "result": ... }` |
| `cancel` | `taskId` | `{ "ok": true, "taskId": "...", "cancelled": true/false }` |
| `closeSession` | `sessionId` | `{ "ok": true }` |

Failure envelopes contain `ok:false` and `error:{code,message}`. `execute` is
synchronous and must run off the UI thread. `cancel` runs independently; a bounded
60-second cancellation record covers cancellation before the worker registers.
Task IDs must be unique. `timeoutMs` defaults to 30,000 and accepts 1–300,000.
Call-local bindings are isolated; the original shared-global handle retains its
first prototype parent, so intrinsic mutations can survive within one source
session. Other sessions retain separate prototype parents. A reference test
compares this behavior directly with the copied upstream bindings.

Operations: `search {key,page}`, `explore {url,page}`, `details {book}`,
`toc {book}`, `content {chapter,book,nextChapterUrl}`, `batch {chapters,book}`,
`login {…}`, `evaluate {script}`, `semanticProbe {}`, `diagnostics {}`,
and `snapshot {}`. The original function names `getBookInfo`, `getChapters`,
`getContent`, `getContentBatch` are aliases. Chapter identities accept both `url`
and `chapterUrl`. `batch` returns `exists`, saved URLs and missing chapters.
`snapshot` exposes fixture requests, cookies, variables and cache changes for
comparison and is intended for the diagnostic tool.

The embedding app registers static native
`io.yuedu.legado.NativeHost.dispatch(String taskId, String operation, String requestJson)`.
`setHostCallback` supplies an equivalent in-process Java interface for tests.

| Host operation | Request | Response |
| --- | --- | --- |
| `http.request` | `url, method, headers, body, bodyBase64, timeoutMs` | `status, url, headers, body` and/or `bodyBase64` |
| `browser.open` | `html, url, js, cacheFirst` | `body` |
| `task.cancel` | `{}` | ignored |

Network/browser requests include `deadlineEpochMs` and `remainingTimeoutMs`.
Header values in responses can be strings or arrays (required to preserve
multiple `Set-Cookie` fields). Host errors use `{ok:false,error:{code,message}}`.

## Current boundaries

This is the first runtime gate, not a complete Legado feature migration. It
executes actual `mainJs` source scripts with the original dynamic-eval/this,
legacy declarations, Java wrappers, E4X and coroutine instruction cancellation.
The implemented host subset covers fixture HTTP, cookies, session variables,
in-memory cache, batch content saves, a browser callback, Base64, MD5 and URL
encoding. Platform file/media APIs, full crypto/font/archive helpers, persisted
data, remote `jsLib`, rate limiting and full `AnalyzeUrl` remain unported.

The traditional source path delegates CSS, JSONPath, XPath and regex extraction
to the copied original analyzers. Its orchestration supports one response per
stage and literal `{{key}}`/`{{page}}` URLs. JS transforms, replacement/state
directives, dynamic URLs, pagination and other `AnalyzeRule` features fail with
`UNSUPPORTED_CAPABILITY`; they are not approximated.

Tests include the original engine capability and DOM regression suites, fixed
search→details→TOC→content/batch/login fixtures, request/body/cookie/state
comparisons, call/session isolation and reference prototype behavior, native host failure propagation,
deadlines, cancellation races and missing platform hosts. iOS Zero launch without
a debugger, VM footprint, signing and device performance still require the Mac
and iPhone gate; desktop test success does not certify those gates.
