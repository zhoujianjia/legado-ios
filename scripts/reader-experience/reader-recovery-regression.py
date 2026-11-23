#!/usr/bin/env python3
"""Bind the required build34 regressions to exact source methods and raw xcresults."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native = load("reader_recovery_native_helpers", "jimage-native-check.py")
SUITES = ("ReaderViewModelChapterStateTests", "BookshelfRefreshCoordinatorTests",
          "OfflineDownloadManagerTests", "OfflineDownloadSourceConcurrencyTests",
          "ChangeSourceCacheCoverageTests", "ReaderSourceChangeCacheTests", "LegadoChapterOwnerPersistenceTests")
NATIVE_METHOD = "LegadoNativeOriginalReaderTests/testNativeOriginalAuditedDownloadsOverlapHeldHTTPAndPreserveOwners()"
UI_METHOD = "ReaderChapterFailureExitUITests/testSecondChapterFailureCanExitWithChromeHidden()"
INPUTS = (".github/workflows/legado-reader.yml", "scripts/reader-experience/jimage-native-check.sh",
          "scripts/reader-experience/reader-recovery-regression.sh", "scripts/reader-experience/reader-recovery-regression.py",
          "scripts/reader-experience/run-reader-failure-smoke.py", "scripts/reader-experience/run-online-smoke.py",
          "scripts/reader-experience/online-source-fixture.py", "Tests/iOS/LegadoNativeOriginalReaderTests.swift",
          "Tests/iOS-UI/ReaderBookSourceSmokeUITests.swift",
          "Modules/Services/Online/ChangeSourceCache.swift", "Modules/Features/Reader/ReaderViewModel.swift",
          "Modules/Core/BookSource/BookSourceFetcher+OriginalPreview.swift",
          "Targets/Yuedu/SharedApp/AppDependencies.swift", "Modules/Services/Online/LegadoPersistentStateHost.swift",
          "scripts/reader-experience/reader-position-barrier.py", "Modules/Services/LibraryStore/BookChapterStore.swift")


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inventory(repo=REPO):
    methods, paths = {}, []
    for suite in SUITES:
        relative = "Tests/iOS/yuedu appTests/" + suite + ".swift"
        text = (repo / relative).read_text(encoding="utf-8-sig")
        require(re.search(r"\bstruct\s+" + suite + r"\b", text), "Missing selected suite: " + suite)
        annotations = list(re.finditer(r"(?m)^[ \t]*@Test\b", text))
        require(annotations, "Empty selected suite: " + suite)
        for index, annotation in enumerate(annotations):
            segment = text[annotation.end():annotations[index+1].start() if index+1 < len(annotations) else len(text)]
            method = re.search(r"\bfunc\s+(\w+)\s*\(([^)]*)\)", segment)
            require(method is not None and not method[2].strip() and "arguments:" not in segment[:method.start()],
                    "Unsupported selected parameterized declaration: " + suite)
            identity = suite + "/" + method[1] + "()"
            require(identity not in methods, "Duplicate selected method")
            methods[identity] = 1
        paths.append(relative)
    native_source = (repo / "Tests/iOS/LegadoNativeOriginalReaderTests.swift").read_text(encoding="utf-8")
    require("func " + NATIVE_METHOD.split("/")[1] in native_source, "Missing required native method")
    ui_source = (repo / "Tests/iOS-UI/ReaderBookSourceSmokeUITests.swift").read_text(encoding="utf-8")
    require("func " + UI_METHOD.split("/")[1] in ui_source, "Missing required failure UI method")
    return {"groups": {"unit": dict(sorted(methods.items())), "native-download": {NATIVE_METHOD: 1},
                       "failure-ui": {UI_METHOD: 1}},
            "sourceInputs": [{"path": path, "sha256": digest(repo/path)} for path in (*paths, *INPUTS)]}


def verify_tree(tree, expected):
    require(isinstance(tree, dict) and isinstance(tree.get("testNodes"), list), "Missing actual test tree")
    found, warnings = {}, []
    def visit(node):
        require(isinstance(node, dict) and node.get("result", "Passed") == "Passed", "Failed or skipped test node")
        children = node.get("children") or []
        require(isinstance(children, list), "Malformed test children")
        if node.get("nodeType") == "Test Case":
            identity = node.get("nodeIdentifier", "")
            for prefix in ("yuedu appTests/", "yuedu appUITests/"):
                identity = identity.removeprefix(prefix)
            require(identity in expected and identity not in found and node.get("result") == "Passed",
                    "Unrelated, duplicate, failed or skipped method: " + identity)
            for child in children:
                require(isinstance(child, dict) and set(child) == {"nodeType", "name"}
                        and child.get("nodeType") == "Runtime Warning" and isinstance(child.get("name"), str)
                        and child["name"].strip(), "Unexpected hidden execution or warning")
                warnings.append(child["name"])
            found[identity] = 1
            return
        require(node.get("nodeType") in ("Test Plan", "Unit test bundle", "UI test bundle", "Test Suite"), "Unexpected test node type")
        for child in children:
            visit(child)
    for node in tree["testNodes"]:
        visit(node)
    require(found == expected, "Missing selected test methods")
    return {"passedExecutionsByMethod": found, "runtimeWarnings": warnings}


def prepare(work):
    source = native.source()
    require(not native.smoke.git("status", "--porcelain", "--untracked-files=no"), "Regressions require a clean committed checkout")
    original = native.smoke.read_json(REPO / ".build/jimage-native-check/result.json")
    host = native.smoke.read_json(REPO / ".build/jimage-native-check/host.json")
    require(original.get("passed") is True and original.get("sourceCommit") == source
            and original.get("passedTests") == 3 and original.get("failedTests") == original.get("skippedTests") == 0,
            "The original three native gates must pass freshly in this run")
    require(host.get("sourceCommit") == source and host.get("nativeRequired") is True, "Missing this source's actual native host")
    require(host.get("developerDirectory") == os.environ.get("DEVELOPER_DIR")
            and host.get("destination") == (work/"destination.txt").read_text().strip(), "Changed native toolchain or Simulator")
    app = Path(host["appPath"])
    require(digest(app/"YueduReader") == host.get("executableSHA256")
            and digest(app/"Info.plist") == host.get("infoSHA256"), "Changed compiled native host")
    staged = native.smoke.read_json(REPO / "Resources/LegadoRuntime/runtime-manifest.json")
    require(staged.get("jarSHA256") == host.get("ordinaryJarSHA256")
            and staged.get("moduleImage", {}).get("sha256") == host.get("jimage", {}).get("sha256"),
            "Resources must still be this run's staged Simulator JVM, before device replacement")
    selected = inventory()
    selected.update(sourceCommit=source, nativeHostSHA256=digest(REPO/".build/jimage-native-check/host.json"),
                    originalNativeResultSHA256=digest(REPO/".build/jimage-native-check/result.json"))
    native.write(work/"selection.json", selected)


def verify(work):
    selection = native.smoke.read_json(work/"selection.json")
    require(selection.get("sourceCommit") == native.source(), "Stale regression source")
    for row in selection["sourceInputs"]:
        require(digest(REPO/row["path"]) == row["sha256"], "Changed regression source input")
    records = {}
    for group, methods in selection["groups"].items():
        summary = native.smoke.read_json(work/(group+"-summary.json"))
        counts = native.smoke.verify_summary(summary, len(methods), sum(methods.values()))
        checked = verify_tree(native.smoke.read_json(work/(group+"-tests.json")), methods)
        native.verify_test_verdict((work/(group+".log")).read_text(encoding="utf-8", errors="replace"))
        require((work/(group+"-exit-status.txt")).read_text().strip() == "0", "Test command failed: " + group)
        require((work/(group+"-artifact-exit-status.txt")).read_text().strip() == "0", "Raw result extraction failed: " + group)
        records[group] = {**counts, **checked, "summarySHA256": digest(work/(group+"-summary.json")),
                          "testsSHA256": digest(work/(group+"-tests.json")), "logSHA256": digest(work/(group+".log"))}
    ui = native.smoke.read_json(work/"failure-ui-result.json")
    require(ui.get("passedMethod") == UI_METHOD and ui.get("sourceCommit") == selection["sourceCommit"], "Missing independent UI/HTTP verdict")
    native.write(work/"result.json", {"schemaVersion": 1, "sourceCommit": selection["sourceCommit"], "passed": True,
                 "selectionSHA256": digest(work/"selection.json"), "groups": records,
                 "originalNativeResultSHA256": selection["originalNativeResultSHA256"],
                 "failureUIResultSHA256": digest(work/"failure-ui-result.json"),
                 "scope": "Fresh required unit, held real native download and failure-exit UI regressions on the same Simulator/build; no physical-device acceptance.",
                 "deviceValidationPassed": False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "verify"))
    parser.add_argument("--work", required=True, type=Path)
    args = parser.parse_args()
    (prepare if args.phase == "prepare" else verify)(args.work)


if __name__ == "__main__":
    main()
