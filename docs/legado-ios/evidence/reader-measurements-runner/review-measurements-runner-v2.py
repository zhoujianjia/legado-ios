"""Fresh v2 review; keep the unused v1 checker and all frozen evidence intact."""
from pathlib import Path
import ast
import hashlib
import json

ROOT = Path("F:/yuedu-reader")
BUILD = ROOT / ".build/renewal-discovery"
WORK = ROOT / ".build/reader-measurements-runner-worktree"
base_script = BUILD / "review-measurements-runner.py"
assert hashlib.sha256(base_script.read_bytes()).hexdigest() == "71f5e0c084c5fabf55966f7e45b434bddba6c0bdbd3814bc8900686ad8686cfc"
source = base_script.read_text(encoding="utf-8")
replacements = {
    'reader-measurements-runner-preparation.json': 'reader-measurements-runner-preparation-v2.json',
    '48e6d3de388ff7cfa5a760fa885c08d90a0c2a7f02a40b268b094b6909f06bd6': '99a2fada7ec2f1bdd6dd4811655cd38e0a920c0716780208f5cc591784dcc4f6',
    '23684)': '26207)',
    '1da20a58629e888ab6b430c22d68e3500158dbce9379b0c0ab52e2516c3d191f': '11e578fc44104e10b168320b0c8ebd766ab4d46294e7f40203a381df1798197f',
    '65960)': '72760)',
    '("portable-collection", 20)': '("portable-collection", 22)',
    '"authorPortableCollectionMethods": 20': '"authorPortableCollectionMethods": 22',
    '"authorPortable": [20, 24, 20]': '"authorPortable": [22, 24, 20]',
}
for old, new in replacements.items():
    assert source.count(old) == 1, old
    source = source.replace(old, new, 1)
ast.parse(source, filename=str(base_script))
ns = {"__file__": str(Path(__file__).resolve()), "__name__": "pinned_independent_review_v2"}
exec(compile(source, str(base_script), "exec"), ns)
write_original = ns["write"]
meta, pin = ns["meta"], ns["pin"]


def write_review(path, value):
    if path == ns["REVIEW"]:
        prep = json.loads(Path(value["preparation"]["path"]).read_bytes())
        assert prep["preparationRevision"] == 2
        legacy = prep["supersedesFrozenV1"]
        for item in (legacy["preparation"], legacy["patch"]):
            pin(Path(item["path"]), item["sha256"], item["bytes"])
        old = json.loads(Path(legacy["preparation"]["path"]).read_bytes())
        for command in old["localChecks"]["commands"]:
            for key in ("stdout", "stderr"):
                item = command[key]
                pin(Path(item["path"]), item["sha256"], item["bytes"])
        historic = prep["debugPayloadHistoricalReference"]
        pin(Path(historic["path"]), historic["sha256"], historic["bytes"])
        historical = json.loads(Path(historic["path"]).read_bytes())
        actual_a = historical["mainAppA"]
        pin(ROOT / actual_a["log"], actual_a["sha256"], actual_a["bytes"])
        lines = (ROOT / actual_a["log"]).read_text(encoding="utf-8").splitlines()
        for excerpt in actual_a["excerpts"]:
            assert lines[excerpt["line"] - 1] == excerpt["text"]
        ui = historical["oldUIBuildSettings"]
        pin(ROOT / ui["path"], ui["sha256"], ui["bytes"])
        entries = json.loads((ROOT / ui["path"]).read_bytes())
        actual = [entry["buildSettings"] for entry in entries if entry.get("target") == "yuedu app"]
        assert len(actual) == 1
        for key, expected in ui["selectedActualFields"].items():
            assert actual[0].get(key) == expected
        assert actual[0]["ENABLE_DEBUG_DYLIB"] == "YES"
        assert "EXECUTABLE_DEBUG_DYLIB_PATH" not in actual[0]
        workflow = (WORK / ".github/workflows/reader-measurements.yml").read_text(encoding="utf-8")
        assert workflow.count("include-hidden-files: true") == 1 and workflow.count("retention-days: 7") == 1
        collector = (WORK / "scripts/reader-experience/collect-reader-measurements.py").read_text(encoding="utf-8")
        tests = (WORK / "scripts/reader-experience/test-collect-reader-measurements.py").read_text(encoding="utf-8")
        assert 'declared_path is None or declared_path ==' in collector
        assert 'require(tested_host(environment) == report["testedHost"]' in collector
        assert tests.count('def test_debug_dylib_mode_requires_real_nonempty_payload_and_preserves_no_mode(') == 1
        assert tests.count('def test_debug_payload_mutated_during_collection_cannot_leave_a_passing_record(') == 1
        value["reviewedPreparationRevision"] = 2
        value["supersededV1PreservedAndRehashed"] = legacy
        value["evidence"]["reviewerBaseScript"] = meta(base_script)
        value["evidence"]["debugPayloadHistoricalReferenceRehashed"] = historic
        value["resolvedFindings"].extend([
            {"id": "hidden-owned-evidence-upload", "reportedBy": "/root",
             "resolution": "Pinned upload action receives include-hidden-files:true for both owned .build paths and retention7. Existing workflow scope/action pin unchanged. This is explicit artifact configuration, not a claim of observed upload loss in prior runs."},
            {"id": "actual-main-debug-code-payload", "reportedBy": "/root",
             "resolution": "Actual ENABLE_DEBUG_DYLIB must be explicit YES/NO. YES requires a real nonempty executable-basename.debug.dylib plus hash, validating an optional declared path while preserving original absence as null. NO records no main debug payload. Complete host identity is re-read after collection; changed payload with unchanged stub cannot leave validated flags.",
             "actualPortableCoverageReadAndLogsVerified": ["test_debug_dylib_mode_requires_real_nonempty_payload_and_preserves_no_mode", "test_debug_payload_mutated_during_collection_cannot_leave_a_passing_record"],
             "scope": "Synthetic owned file identity/negative tests, not a new SDK build or proof the hashed instructions executed."}
        ])
        value["reviewedInvariants"]["environmentAndBuiltHost"] += " The explicit actual Debug-dylib flag also binds the nonempty main .debug.dylib when enabled; optional build-derived path absence stays null, and the full tested-host identity is rechecked at collection end."
        value["reviewedInvariants"]["artifactUpload"] = "Always upload both owned .build directories with include-hidden-files:true, if-no-files-found:error, seven-day retention and the unchanged pinned upload action. No actual new upload was performed during this review."
        value["reviewedInvariants"]["debugPayloadNegatives"] = "Read the two additional methods and pinned successful 22-method raw log: missing/empty payload fails, changing only payload changes its identity while stub stays equal, optional derived path absence is retained, wrong declared path fails, NO produces null payload and missing flag fails. The collection-level mutation changes only debug bytes during its second binding call and requires exit1 with both validated flags false. No suite was rerun by reviewer."
    write_original(path, value)


ns["write"] = write_review
ns["main"]()
