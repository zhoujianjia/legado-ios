#!/usr/bin/env python3
"""Exact source/xcresult gate for the November reader-position regression selection."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location("position_native_helpers", HERE / "jimage-native-check.py")
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)
smoke = native.smoke
SUITES = ("ReaderPositionSentryTests", "ReaderPagedPositionSyncTests", "ReaderCoverPositionTests",
          "ReaderPositionWalkTests", "ReaderPageTransitionQueueTests", "ReaderStackWriteGateTests",
          "ReaderRenderRefreshTests")
ARGUMENTS = {
    "ReaderCoverPositionTests/tappedCoverTurnCommitsItsTarget(delta:)": [-1, 1],
    "ReaderCoverPositionTests/coverTurnSurvivesPageReindex(delta:)": [-1, 1],
    "ReaderCoverPositionTests/coverBurstKeepsItsLatestTarget(lastDelta:)": [-1, 3],
}
NEW_CASES = {
    "ReaderPositionSentryTests/chapterResetNoticeExportsEvidenceWithVerboseOff()": 1,
    "ReaderPagedPositionSyncTests/queuedPageReindexDoesNotCommitAReadingPosition()": 1,
    "ReaderPagedPositionSyncTests/queuedPageReindexUsesTheLatestSettledPosition()": 1,
    "ReaderPagedPositionSyncTests/supersededPositionPublicationIsDropped()": 1,
    **{method: len(values) for method, values in ARGUMENTS.items()},
}
INPUTS = (
    ".github/workflows/legado-reader.yml", "scripts/xctest.sh", "scripts/sim.sh",
    "scripts/reader-experience/position-regression.sh", "scripts/reader-experience/position-regression.py",
    "scripts/reader-experience/test-position-regression.py", "scripts/reader-experience/jimage-native-check.py",
    "scripts/reader-experience/smoke-tools.py", "scripts/reader-experience/stage-config.py",
    "Modules/Core/ReaderCore/ReaderPositionSentry.swift", "Targets/Yuedu/SharedApp/AppLogger.swift",
    "Modules/Features/Reader/CoreTextPagedView.swift", "Modules/Features/Reader/ReaderView.swift",
    "Modules/Features/Reader/ReaderView+Logic.swift",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inventory(repo=REPO):
    expected, sources = {}, []
    pattern = re.compile(r"^[ \t]*@Test(?:\(([^\r\n]*)\))?\s+func (\w+)\(([^)]*)\)", re.MULTILINE)
    for suite in SUITES:
        relative = "Tests/iOS/yuedu appTests/" + suite + ".swift"
        data = (repo / relative).read_bytes()
        text = data.decode("utf-8-sig")
        require(re.search(r"\bstruct " + suite + r"\b", text), "Missing selected suite: " + suite)
        methods = pattern.findall(text)
        require(len(methods) == len(re.findall(r"^[ \t]*@Test\b", text, re.MULTILINE)),
                "Unsupported selected @Test declaration: " + suite)
        for attributes, name, parameters in methods:
            parameter = re.fullmatch(r"\s*(\w+)\s*:\s*Int\s*", parameters) if parameters else None
            require(not parameters or parameter is not None, "Unsupported test parameter: " + name)
            identity = suite + "/" + name + "(" + (parameter[1] + ":" if parameter else "") + ")"
            require(identity not in expected, "Duplicate selected method: " + identity)
            if identity in ARGUMENTS:
                require("arguments:" in attributes and json.loads(attributes.split("arguments:", 1)[1]) == ARGUMENTS[identity],
                        "Changed cover regression arguments: " + identity)
                expected[identity] = len(ARGUMENTS[identity])
            else:
                require(not parameters and "arguments:" not in attributes, "Unexpected parameterized method: " + identity)
                expected[identity] = 1
        sources.append(relative)
    require(len(expected) == 86 and sum(expected.values()) == 89, "Position selection must remain 86 methods / 89 executions")
    require(sum(NEW_CASES.values()) == 10 and all(expected.get(key) == value for key, value in NEW_CASES.items()),
            "The ten new regression executions must be selected")
    records = []
    for relative in (*sources, *INPUTS):
        data = (repo / relative).read_bytes()
        records.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
    return {"expectedExecutionsByMethod": dict(sorted(expected.items())), "sourceInputs": records}


def verify_tree(tree, expected):
    require(isinstance(tree, dict) and isinstance(tree.get("testNodes"), list), "Missing xcresult testNodes")
    found = {}

    def warnings(children):
        require(isinstance(children, list), "Malformed warning children")
        for child in children:
            require(isinstance(child, dict) and set(child) == {"nodeType", "name"}
                    and child["nodeType"] == "Runtime Warning" and isinstance(child["name"], str) and child["name"].strip(),
                    "Unexpected execution children or malformed runtime warning")

    def visit(node):
        require(isinstance(node, dict), "Malformed test node")
        children = node.get("children", [])
        require(isinstance(children, list), "Malformed test children")
        require(node.get("result", "Passed") == "Passed", "Failed/skipped test container or case")
        if node.get("nodeType") == "Test Case":
            identity = node.get("nodeIdentifier", "")
            require(isinstance(identity, str), "Missing source method identity")
            if identity.startswith("yuedu appTests/"):
                identity = identity[len("yuedu appTests/"):]
            require(identity in expected and identity not in found and node.get("result") == "Passed",
                    "Unrelated, duplicate, failed or skipped method: " + str(identity))
            count = expected[identity]
            if count == 1:
                warnings(children)
            else:
                names = []
                for child in children:
                    require(isinstance(child, dict) and child.get("nodeType") == "Arguments" and child.get("result") == "Passed"
                            and isinstance(child.get("name"), str) and child["name"], "Missing/passing parameter execution required")
                    warnings(child.get("children", []))
                    names.append(child["name"])
                require(len(names) == count and len(set(names)) == count, "Missing/duplicate parameter executions: " + identity)
            found[identity] = count
            return
        require(node.get("nodeType") in ("Test Plan", "Unit test bundle", "Test Suite"), "Unexpected test node type")
        for child in children:
            visit(child)

    for node in tree["testNodes"]:
        visit(node)
    require(found == expected, "Actual method identities differ from the selected source")
    return {"passedExecutionsByMethod": dict(sorted(found.items())), "newRegressionExecutions": sum(found[key] for key in NEW_CASES)}


def sources(work):
    revision = native.source()
    require(not smoke.git("status", "--porcelain", "--untracked-files=no"), "Position checks require a clean tracked checkout")
    selected = inventory()
    for record in selected["sourceInputs"]:
        destination = work / "sources" / record["path"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((REPO / record["path"]).read_bytes())
    native.write(work / "selection.json", {"sourceCommit": revision, **selected})


def verify(work):
    revision = native.source()
    selected = inventory()
    recorded = json.loads((work / "selection.json").read_bytes())
    require(recorded == {"sourceCommit": revision, **selected}, "Selection/source changed after preparation")
    smoke.review_overlays(json.loads((work / "overlays.json").read_bytes()))
    require(os.environ.get("LEGADO_RUNTIME_SOURCE_ONLY") == "1", "Expected the isolated source-only reader test host")
    require((work / "test-exit-status.txt").read_text().strip() == "0", "The XCTest wrapper did not pass")
    native.verify_test_verdict((work / "tests.log").read_text(encoding="utf-8", errors="replace"))
    counts = smoke.verify_summary(json.loads((work / "summary.json").read_bytes()), 86, 89)
    cases = verify_tree(json.loads((work / "tests.json").read_bytes()), selected["expectedExecutionsByMethod"])
    settings = json.loads((work / "build-settings.json").read_bytes())
    hosts = [item["buildSettings"] for item in settings if item.get("target") == native.config.MAIN_TARGET]
    require(len(hosts) == 1, "Expected the actual main-reader test host")
    host = hosts[0]
    require(host.get("CONFIGURATION") == "Debug" and host.get("PLATFORM_NAME") == "iphonesimulator"
            and host.get("PRODUCT_BUNDLE_IDENTIFIER") == native.config.MAIN_BUNDLE, "Unexpected reader test build settings")
    app = Path(host["BUILT_PRODUCTS_DIR"]) / host["FULL_PRODUCT_NAME"]
    info = plistlib.loads((app / "Info.plist").read_bytes())
    smoke.require_local_info(info)
    smoke.require_source_stamp(info, revision)
    native.write(work / "result.json", {"sourceCommit": revision, "passed": True, **counts, **cases,
        "sourceOnly": True, "scope": "Debug Simulator position regression; separate ordinary-JVM Release packaging follows.",
        "artifactSHA256": {name: native.sha(work / name) for name in
            ("selection.json", "overlays.json", "tests.log", "summary.json", "tests.json", "build-settings.json")},
        "hostInfoSHA256": native.sha(app / "Info.plist"), "hostExecutableSHA256": native.sha(app / info["CFBundleExecutable"])})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("sources", "verify"))
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    work = native.config.checked_path(args.work)
    (sources if args.phase == "sources" else verify)(work)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, TypeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
