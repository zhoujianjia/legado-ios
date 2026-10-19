"""Preserve the frozen review and explicitly correct its trace-call assumption."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess

ROOT = Path("F:/yuedu-reader")
BUILD = ROOT / ".build/renewal-discovery"
WORK = ROOT / ".build/reader-umd-reading-worktree"
RAW = BUILD / "umd-reading-trace-correction-raw"
OUTPUT = BUILD / "umd-reading-independent-review-correction.json"
OLD = BUILD / "umd-reading-independent-review.json"
BASE = "1fd96156392b231580482606f394219df45141db"
CALLEE = "Modules/Core/BookSource/SourcePerfTrace.swift"


def identity(path):
    data = path.read_bytes()
    return {"path": str(path), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def write(path, value):
    with path.open("xb") as stream:
        stream.write((json.dumps(value, indent=2) + "\n").encode("utf-8"))


def main():
    assert not RAW.exists() and not OUTPUT.exists()
    original = identity(OLD)
    assert original["sha256"] == "9fdd297081f4b74ba56d04273f9356e1ec661f8e9f0f426fc7021c7c587ae0d8"
    previous = json.loads(OLD.read_bytes())
    assert len(previous["nonBlockingFindings"]) == 1
    assert previous["nonBlockingFindings"][0]["id"] == "trace-byte-field-is-entry-zero"
    for item in previous["files"]:
        found = identity(WORK / item["path"])
        assert (found["sha256"], found["bytes"]) == (item["sha256"], item["bytes"])
    for item in (previous["patch"], previous["preparation"]):
        assert identity(Path(item["path"])) == item
    RAW.mkdir()
    commands = []
    def run(name, argv):
        started = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(argv, cwd=ROOT, capture_output=True)
        out, err = RAW / (name + ".stdout.bin"), RAW / (name + ".stderr.bin")
        out.write_bytes(result.stdout); err.write_bytes(result.stderr)
        commands.append({"argv": argv, "cwd": str(ROOT), "startedAtUTC": started,
                         "exitCode": result.returncode, "stdout": identity(out), "stderr": identity(err)})
        assert result.returncode == 0 and result.stderr == b""
        return result.stdout
    base = run("callee-at-base", ["git", "show", BASE + ":" + CALLEE])
    head = run("current-head", ["git", "rev-parse", "HEAD"]).decode().strip()
    assert base == (WORK / CALLEE).read_bytes() == (ROOT / CALLEE).read_bytes()
    text = base.decode("utf-8")
    assert "_ detail: @autoclosure () -> String" in text
    assert "record(stage, detail(), since: t0, thresholdMs: thresholdMs)" in text
    assert text.index("defer {") < text.index("return try body()")
    assert "thresholdMs: Double = 1" in text and "guard ms >= thresholdMs else { return }" in text
    record = {
        "schemaVersion": 1, "kind": "correction-supplement-to-frozen-umd-reading-independent-review",
        "correctedAtUTC": datetime.now(timezone.utc).isoformat(), "reviewer": "/root/renewal_discovery_ui",
        "status": "no-unresolved-static-blocking-findings",
        "originalReviewPreservedUnchanged": original,
        "base": BASE, "patch": previous["patch"], "preparation": previous["preparation"], "files": previous["files"],
        "withdrawnFinding": {
            "id": "trace-byte-field-is-entry-zero", "withdrawn": True, "findingWasIncorrect": True,
            "correction": "The original reviewer treated the detail expression as an eagerly constructed String. Actual SourcePerfTrace.span accepts a nonescaping @autoclosure and calls detail() from defer after try body() returns or throws. Therefore validatedBytes is read at completion, or as the partial validated count on failure; it is not necessarily the entry value zero. No source change is required for this finding.",
            "actualCalleeInspected": True, "reportedByRootAndIndependentlyConfirmed": True
        },
        "effectiveReview": {
            "status": "no-unresolved-static-blocking-findings", "unresolvedBlockingFindings": [],
            "nonBlockingFindings": [], "allOtherOriginalReviewScopeAndEvidenceRetained": True,
            "traceSemantics": "The body and detail autoclosure capture local/parameter values; lazy detail evaluation after the synchronous validation observes final or partial validatedBytes. Default reporting threshold is 1 ms, so shorter spans may produce no log. This source inspection establishes semantics, not a measured trace output, timing or performance result.",
            "throwsInitializerAndSendableAssessmentUnchanged": "No definite self-before-init access or stored-field Sendable defect was identified by static review. This correction adds no Swift compile or runtime claim.",
            "plannedSwiftMethods": 8, "actualSwiftMethodsExecuted": 0,
            "SwiftTypecheckPerformed": False, "AppleSDKCompilationPerformed": False,
            "iOSTestsExecuted": 0, "productUMDImportOrTOCReopenAccepted": False
        },
        "calleeBinding": {
            "sourcePath": CALLEE, "baseGitBytes": identity(RAW / "callee-at-base.stdout.bin"),
            "frozenWorktreeFile": identity(WORK / CALLEE), "currentMainFile": identity(ROOT / CALLEE),
            "currentMainHEADObservedOnly": head, "allThreeByteIdentical": True,
            "relevantSourceLines": {"spanSignatureAndDefer": [35, 50], "recordThreshold": [67, 77]}
        },
        "actualReadOnlyCommands": commands,
        "performed": {"newPortableOrSwiftSuites": 0, "newSDKBuilds": 0, "networkOrCIQueries": 0,
                      "sourceOrFrozenEvidenceEdits": 0, "integrationRecordersExecuted": 0},
        "supplementRequiredForFinalUse": "Use this supplement with the original frozen review. The original trace-byte finding is withdrawn and must not be archived or presented as a current valid finding.",
        "correctionScript": identity(Path(__file__))
    }
    write(OUTPUT, record)
    assert identity(OLD) == original
    write(RAW / "manifest.json", {"schemaVersion": 1,
          "files": [identity(path) for path in sorted(RAW.iterdir()) if path.is_file()],
          "excludesItself": True, "correction": identity(OUTPUT), "originalReview": original,
          "oldReviewAndFrozenFiveUnchanged": True, "noTestOrSDKExecution": True})
    print(json.dumps({"correction": identity(OUTPUT), "rawManifest": identity(RAW / "manifest.json"),
                      "effectiveBlockingFindings": 0, "effectiveNonBlockingFindings": 0,
                      "originalReviewUnchanged": True, "actualSwiftTests": 0}))


if __name__ == "__main__": main()
