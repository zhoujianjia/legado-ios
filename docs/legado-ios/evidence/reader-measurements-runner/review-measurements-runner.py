"""Independent static review and read-only identity check of frozen runner8."""
from pathlib import Path
from datetime import datetime, timezone
import ast
import hashlib
import json
import re
import subprocess

ROOT = Path("F:/yuedu-reader")
WORK = ROOT / ".build/reader-measurements-runner-worktree"
BUILD = ROOT / ".build/renewal-discovery"
RAW = BUILD / "reader-measurements-runner-independent-validation"
REVIEW = BUILD / "reader-measurements-runner-independent-review.json"
BASE = "9e4656128e202a0324dda3e8ad97a3c028d37499"


def meta(path):
    raw = path.read_bytes()
    return {"path": str(path), "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def pin(path, sha, size=None):
    found = meta(path)
    assert found["sha256"] == sha and (size is None or found["bytes"] == size), found
    return found


def write(path, value):
    with path.open("xb") as stream:
        stream.write((json.dumps(value, indent=2) + "\n").encode("utf-8"))


def main():
    assert not RAW.exists() and not REVIEW.exists()
    RAW.mkdir()
    commands = []

    def run(name, argv):
        started = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(argv, cwd=WORK, capture_output=True)
        out, err = RAW / (name + ".stdout.bin"), RAW / (name + ".stderr.bin")
        out.write_bytes(result.stdout)
        err.write_bytes(result.stderr)
        commands.append({"argv": argv, "cwd": str(WORK), "startedAtUTC": started,
                         "exitCode": result.returncode, "stdout": meta(out), "stderr": meta(err)})
        assert result.returncode == 0
        return result.stdout

    prep_path = WORK / ".build/reader-measurements-runner-preparation.json"
    preparation = pin(prep_path, "48e6d3de388ff7cfa5a760fa885c08d90a0c2a7f02a40b268b094b6909f06bd6", 23684)
    prep = json.loads(prep_path.read_bytes())
    patch = pin(Path(prep["patch"]["path"]), "1da20a58629e888ab6b430c22d68e3500158dbce9379b0c0ab52e2516c3d191f", 65960)
    assert run("head", ["git", "rev-parse", "HEAD"]).decode().strip() == BASE == prep["baselineSourceCommit"]
    assert len(prep["files"]) == len({item["path"] for item in prep["files"]}) == 8
    for item in prep["files"]:
        pin(WORK / item["path"], item["sha256"], item["bytes"])
    tracked = run("tracked-paths", ["git", "diff", "--name-only", "-z"]).decode().rstrip("\0").split("\0")
    untracked = run("untracked-paths", ["git", "ls-files", "--others", "--exclude-standard", "-z"]).decode().rstrip("\0").split("\0")
    assert set(tracked + untracked) == {item["path"] for item in prep["files"]}
    assert set(prep["changedPaths"]) == set(tracked + untracked)
    assert prep["sourceInputsPlanned"] == 38
    author_logs = []
    for command in prep["localChecks"]["commands"]:
        assert command["exitCode"] == command["expectedExitCode"]
        for key in ("stdout", "stderr"):
            item = command[key]
            pin(Path(item["path"]), item["sha256"], item["bytes"])
        author_logs.append(command)
    for name, count in (("portable-collection", 20), ("portable-shared-smoke", 24), ("portable-shared-stage", 20)):
        command = next(item for item in author_logs if item["name"] == name)
        text = Path(command["stderr"]["path"]).read_text(encoding="utf-8")
        assert len(re.findall(r"^test_.* \.\.\. ok$", text, re.M)) == count
        assert re.search(r"^Ran " + str(count) + r" tests in .+\n\nOK$", text.strip(), re.M)
    assembled = b"".join(Path(item["stdout"]["path"]).read_bytes() for item in author_logs
                         if item["name"] == "tracked-patch" or item["name"].startswith("new-file-"))
    assert assembled == Path(patch["path"]).read_bytes()

    collector = WORK / "scripts/reader-experience/collect-reader-measurements.py"
    tree = ast.parse(collector.read_text(encoding="utf-8"))
    names = {"UMD_METHODS", "GROUPS", "PERF_SOURCES", "UMD_FIXTURES", "UMD_IDS", "UMD_SOURCES", "UI_FIXTURES", "SOURCE_FILES"}
    nodes = [node for node in tree.body if (isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id in names for target in node.targets))
        or (isinstance(node, ast.FunctionDef) and node.name in ("require", "verify_tree", "source_inventory"))]
    ns = {"re": re}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(collector), "exec"), ns)
    assert len(ns["SOURCE_FILES"]) == len(set(ns["SOURCE_FILES"])) == 38
    dependency = prep["UMDDependencyPreparation"]
    pin(Path(dependency["path"]), dependency["sha256"], dependency["bytes"])
    umd_prep = json.loads(Path(dependency["path"]).read_bytes())
    umd_root = Path(umd_prep["worktree"])
    assert len(umd_prep["files"]) == len(ns["UMD_SOURCES"]) == 16
    assert set(ns["UMD_SOURCES"]) == {item["path"] for item in umd_prep["files"]}
    for item in umd_prep["files"]:
        pin(umd_root / item["path"], item["sha256"], item["bytes"])
    proposed = []
    def read_source(name):
        source = (umd_root if name in ns["UMD_SOURCES"] else WORK) / name
        return source.read_bytes()
    ns["source_inventory"](read_source)
    for name in ns["SOURCE_FILES"]:
        raw = read_source(name)
        proposed.append({"path": name, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
    unchanged = []
    for name in dict.fromkeys((*prep["localChecks"]["unchangedProtocolFiles"], *ns["PERF_SOURCES"], "scripts/reader-experience/stage-config.py")):
        committed = run("base-" + str(len(unchanged)), ["git", "show", BASE + ":" + name])
        assert committed == (WORK / name).read_bytes()
        unchanged.append({"sourcePath": name, **meta(WORK / name)})
    original_ui = ROOT / prep["historicalUIStructureReference"]["originalRelativeDirectory"]
    ui_reference = []
    for name, expected in ns["UI_FIXTURES"].items():
        old_name = "ui-tests.json" if "ui-tests-" in name else "ui-summary.json"
        original = pin(original_ui / old_name, expected)
        assert (WORK / name).read_bytes() == Path(original["path"]).read_bytes()
        ui_reference.append({"fixture": name, "original": original, "purpose": "Original modern container shape only, not new measurement execution."})

    prior_negative = pin(BUILD / "measurement-runner-preliminary-containment-negative.json",
                         "6144500f71a0344982c9498b2042581b80fff20249318e7235ea634031d6f4ba", 4176)
    prior = json.loads(Path(prior_negative["path"]).read_bytes())
    try:
        ns["verify_tree"](prior["mutatedTree"], "yuedu appTests", "Unit test bundle", ns["GROUPS"]["umd"]["methods"])
    except ValueError as error:
        actual_error = str(error)
    else:
        raise AssertionError("Original external-leaf negative still accepted")
    assert actual_error == "Test method is outside its selected target bundle"
    replay = {"kind": "one-original-owned-synthetic-negative-replay-on-frozen-collector", "source": meta(collector),
              "priorNegative": prior_negative, "function": "verify_tree", "outsideBundleLeaves": 10,
              "actualExceptionType": "ValueError", "actualExceptionMessage": actual_error,
              "rejected": True, "actualXCTestOrSwiftExecuted": False, "portableSuitesRerun": False}
    write(RAW / "containment-replay.json", replay)
    static_checks = {"patch": patch, "preparation": preparation, "sourceFilesVerified": 8,
                     "plannedCombinedSourceBindings": proposed, "sourceInventoryShapeChecked": True,
                     "unchangedBoundaryFiles": unchanged, "authorRawLogCommandsVerified": author_logs,
                     "originalUIBytesCompared": ui_reference, "UMD16DependencyHashVerified": dependency,
                     "originalNegativeReplay": meta(RAW / "containment-replay.json"), "actualReadOnlyCommands": commands}
    write(RAW / "identity-check.json", static_checks)
    review = {
        "schemaVersion": 1, "kind": "independent-static-review-of-source-only-measurement-runner",
        "reviewedAtUTC": datetime.now(timezone.utc).isoformat(), "reviewer": "/root/renewal_discovery_ui",
        "status": "no-unresolved-static-blocking-findings", "unresolvedBlockingFindings": [],
        "baselineSourceCommit": BASE, "worktree": str(WORK), "patch": patch, "preparation": preparation,
        "files": prep["files"], "changedPathCount": 8,
        "resolvedFindings": [{"id": "selected-target-bundle-containment", "originalNegative": prior_negative,
                              "frozenReplay": meta(RAW / "containment-replay.json"),
                              "resolution": "Every case must descend from the selected bundle; nested test plans/bundles are rejected. The original counterexample now throws the precise required ValueError. New portable method preserves both the external-leaf and nested-plan counterexamples."}],
        "reviewedInvariants": {
            "overlayPreparationOrder": "smoke.prepare with explicit measurement tag first requires clean tracked HEAD and creates audited project/Info/source-stamp overlays; only then are actual settings/runtime captured and source preparation validated. Unsafe initial overlay setup exits before any test host.",
            "sourceBinding": "Production requires 38 distinct selected source/helper/fixture files byte-equal to committed HEAD, matching CI tag/GITHUB_SHA and run/attempt. Preparation pins the same audit/environment/source set; collection rechecks before and after. This review only inspected the proposed combined source inventory, using separately frozen UMD16 as an explicit static dependency; no runtime source_provenance success is claimed on this uncommitted isolated checkout.",
            "environmentAndBuiltHost": "Shared capture validates Debug iphonesimulator settings, Xcode/SDK, selected available UDID/runtime, raw input hashes and source. Actual summary/tree must match one device/runtime/configuration. Collection checks the built local/synthetic app source stamp, Info/configuration/executable hashes and actual captured host settings. No built host was created or audited during this preparation.",
            "closedExactExecutionGate": "Single Test Plan, unique correct target bundle, supported nonempty containers, Passed container result when present, unique childless exact method identities, 1/1 memory, 1/1 launch, 11/11 UMD, integer-zero wrapper/export statuses, zero failures/skips/expected failures. Unknown/missing node types, cross-group bundle types, parameterized/duplicate/extra/failed leaves and outside-bundle leaves cannot complete the gate.",
            "rawLogAndArtifactRetention": "Each group uses its own original xcodebuild -l log, xcresult, summary and tests export. Raw marker lines retain original bytes before later validation. The collector additionally requires exact execution artifacts; imported shape validators and owned synthetic positive records do not attest an SDK/XCTest run. Artifact/log/environment/source drift invalidates collection.",
            "failureCollectionAndCombinedGate": "No set -e group abort: recoverable memory, launch or UMD failure still permits both remaining selections and captures individual status/result records. Combined setup/group/status-record gate remains nonzero. Fatal wrapper/step/job deadlines may leave incomplete evidence; neither retries nor synthetic replacement supply success. Workflow upload uses always().",
            "samplesAndClaims": "Source contract selects 13 Swift/XCTest methods in three groups and requires five launch samples, ten memory samples over two fixtures with 300 raw phases. Actual selected methods and samples remain zero. CPU submission plus visible AX under automation is not GPU/device-cold; sampled memory is not exact kernel peak or an improvement.",
            "UMDGoldenBinding": "Runtime source list binds all reviewed UMD16; frozen provenance digest and original reference identities require the ten exact golden bytes. Independent review rehashed dependency16 and compared both original modern UI JSON bytes with their actual prior artifacts. UI originals are structural reference only. No UMD product import/TOC/reopen is enabled.",
            "temporaryRoots": "All independently created temporary roots in the new guard tests resolve before creating checked child paths. Production stage-config.py is byte-identical to base, including symlink/junction rejection. This follows the C failure diagnosis without claiming that an actual macOS alias path was logged or that macOS was rerun.",
            "sharedProtocolScope": "Shared smoke changes add only explicit reader-measurements tag validation, source-stamped overlay preparation and CLI choices, plus assertions inside an existing test. Existing default smoke/renewal behavior remains intact. The old TXT1 selection, stage50 runner/shape protocol, performance nine sources, existing smoke workflow and original shape-only helper are byte-identical to base."
        },
        "evidence": {"identityCheck": meta(RAW / "identity-check.json"), "reviewerScript": meta(Path(__file__)),
                     "authorPortableCollectionMethods": 20, "authorSharedSmokeMethods": 24, "authorSharedStageMethods": 20,
                     "authorRawLogsAllHashVerified": True, "authorPortableSuitesRerunByReviewer": False,
                     "reviewerOriginalNegativeReplays": 1, "bashAndActionlintRawLogsHashVerified": True,
                     "shellcheckExecuted": False, "historicalUIReference": ui_reference,
                     "plannedSourceBindings": 38, "plannedGroupMethods": {"memory": 1, "launch": 1, "umd": 11}},
        "SwiftTypecheckPerformed": False, "AppleSDKCompilationPerformed": False, "iOSTestsExecuted": 0,
        "actualSelectedSwiftXCTestMethodsExecuted": 0, "actualLaunchSamples": 0, "actualMemorySamples": 0,
        "actualRawMemoryPhaseRows": 0, "CIQueriedOrTriggered": False, "sourceOrCanonicalEditsByReviewer": False,
        "UMDProductImportSupported": False, "physicalDeviceMeasured": False, "performanceImprovementEstablished": False,
        "acceptanceBoundary": "Static integration preparation only. The source checkpoint must contain UMD16 and runner8 before actual source-only CI can validate runtime gate compatibility, Apple SDK compilation, exact XCTest methods and original samples."
    }
    write(REVIEW, review)
    print(json.dumps({"review": meta(REVIEW), "status": review["status"], "sourceFiles": 8,
                      "authorPortable": [20, 24, 20], "reviewerReranSuites": False,
                      "originalSyntheticNegativeRejected": True, "actualSwiftExecuted": 0}))


if __name__ == "__main__":
    main()
