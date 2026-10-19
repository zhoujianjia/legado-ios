"""Read-only frozen-source checks and independent static review evidence."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import re
import subprocess

ROOT = Path("F:/yuedu-reader")
WORK = ROOT / ".build/reader-umd-reading-worktree"
BUILD = ROOT / ".build/renewal-discovery"
RAW = BUILD / "umd-reading-independent-validation-final"
DEST = BUILD / "umd-reading-independent-review.json"
BASE = "1fd96156392b231580482606f394219df45141db"


def meta(path):
    b = path.read_bytes()
    return {"path": str(path), "bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()}


def pin(path, sha, size=None):
    item = meta(path)
    assert item["sha256"] == sha and (size is None or item["bytes"] == size), item
    return item


def write(path, value):
    with path.open("xb") as f:
        f.write((json.dumps(value, indent=2) + "\n").encode("utf-8"))


def main():
    assert not RAW.exists() and not DEST.exists()
    RAW.mkdir()
    commands = []
    def run(name, argv):
        started = datetime.now(timezone.utc).isoformat()
        completed = subprocess.run(argv, cwd=WORK, capture_output=True)
        out, err = RAW / (name + ".stdout.bin"), RAW / (name + ".stderr.bin")
        out.write_bytes(completed.stdout); err.write_bytes(completed.stderr)
        commands.append({"argv": argv, "cwd": str(WORK), "startedAtUTC": started, "exitCode": completed.returncode,
                         "stdout": meta(out), "stderr": meta(err)})
        assert completed.returncode == 0 and completed.stderr == b""
        return completed.stdout
    prep_path = WORK / ".build/reader-umd-reading-preparation.json"
    preparation = pin(prep_path, "ccabf53a827271014eacdb10a1d813056bdfa5ec2167a37fcc58720507e3cd88", 12719)
    prep = json.loads(prep_path.read_bytes())
    patch = pin(Path(prep["patch"]["path"]), "3441c1517244bd4e6e7eac5f6e0cdd04726796a6fbe90e8f6c8c42075939fcef", 32714)
    assert run("head", ["git", "rev-parse", "HEAD"]).decode().strip() == prep["base"] == BASE
    assert len(prep["files"]) == len({x["path"] for x in prep["files"]}) == 5
    for item in prep["files"]: pin(WORK / item["path"], item["sha256"], item["bytes"])
    assert set(run("paths", ["git", "diff", "--name-only", "-z"]).decode().rstrip("\0").split("\0")) == {x["path"] for x in prep["files"]}
    assert run("patch", ["git", "diff", "--binary"]) == Path(patch["path"]).read_bytes()
    evidence = prep["actualValidation"]
    bound_records = {}
    for key in ("validation", "staticBoundaries", "patchChecks"):
        item = evidence[key]
        pin(Path(item["path"]), item["sha256"], item["bytes"])
        bound_records[key] = json.loads(Path(item["path"]).read_bytes())
    grammar = evidence["grammar"]["record"]
    pin(Path(grammar["path"]), grammar["sha256"], grammar["bytes"])
    for record in (bound_records["validation"], bound_records["patchChecks"]):
        for command in record["commands"]:
            assert command["exitCode"] == 0
            for key in ("stdout", "stderr"):
                item = command[key]; pin(Path(item["path"]), item["sha256"], item["bytes"])
    portable = Path(next(x for x in bound_records["validation"]["commands"] if x["label"] == "portable")["stderr"]["path"]).read_text(encoding="utf-8")
    assert len(re.findall(r"^test_.* \.\.\. ok$", portable, re.M)) == 12 and re.search(r"^Ran 12 tests in .+\n\nOK$", portable.strip(), re.M)
    assert bound_records["validation"]["getterIntegrity"]["fixtures"] == 5 and bound_records["validation"]["getterIntegrity"]["chapters"] == 15
    assert bound_records["validation"]["grammarFiles"] == 5 and bound_records["validation"]["grammarPassed"] is True
    assert all(bound_records["validation"][key] == 0 for key in ("actualSwiftTypechecks", "actualSwiftSDKBuilds", "actualSwiftTests", "actualIOSTests"))
    parser_manifest = prep["frozenParserPreparation"]["manifest"]
    pin(Path(parser_manifest["path"]), parser_manifest["sha256"], parser_manifest["bytes"])
    parser = json.loads(Path(parser_manifest["path"]).read_bytes())
    assert len(parser["files"]) == 16
    for item in parser["files"]:
        pin(WORK / item["path"], item["sha256"], item["bytes"])
        pin(ROOT / item["path"], item["sha256"], item["bytes"])
    for group in (prep["originalReference"], {"review": prep["frozenParserPreparation"]["independentReview"]}, prep["primaryReference"]):
        for item in group.values():
            if isinstance(item, dict) and all(key in item for key in ("path", "sha256", "bytes")):
                pin(Path(item["path"]), item["sha256"], item["bytes"])
    model_changes = []
    for name, before, after in (("Modules/Core/EPUB/BookParsing.swift", b"struct UnifiedChapter: Identifiable, Equatable {", b"struct UnifiedChapter: Identifiable, Equatable, Sendable {"),
                               ("Modules/Core/Replace/ReplaceRule.swift", b"struct ReplaceRule: Identifiable, Codable {", b"struct ReplaceRule: Identifiable, Codable, Sendable {")):
        old = run("model-" + str(len(model_changes)), ["git", "show", BASE + ":" + name])
        assert old.count(before) == 1 and (WORK / name).read_bytes() == old.replace(before, after, 1)
        model_changes.append({"path": name, "onlySendableConformanceAdded": True})
    name = "Modules/Core/ReaderCore/CoreText/TXTLazyAttributedStringBuilder.swift"
    old_builder = run("builder-base", ["git", "show", BASE + ":" + name]).decode("utf-8")
    builder = (WORK / name).read_text(encoding="utf-8")
    old_initializers = []
    for signature in ("    init(text:", "    init(mappedTextFile:"):
        def block(text):
            start = text.index(signature); brace = text.index("{", start); depth = 1; end = brace + 1
            while depth:
                depth += (text[end] == "{") - (text[end] == "}"); end += 1
            return text[start:end].encode("utf-8")
        old, new = block(old_builder), block(builder)
        assert old == new
        old_initializers.append({"signature": signature.strip(), "rawByteIdentical": True, "bytes": len(old), "sha256": hashlib.sha256(old).hexdigest()})
    unchanged = []
    for name in ("Modules/Services/LibraryStore/UniversalBookInterfaces.swift", "Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift",
                 "Modules/Core/ReaderCore/CoreText/AttributedStringBuilding.swift", "Modules/Services/LibraryStore/LocalBookImportService.swift",
                 "scripts/reader-experience/smoke.sh"):
        old = run("unchanged-" + str(len(unchanged)), ["git", "show", BASE + ":" + name])
        assert old == (WORK / name).read_bytes()
        unchanged.append(meta(WORK / name))
    tests = (WORK / "Tests/iOS/yuedu appTests/UMDReadingPreparationTests.swift").read_text(encoding="utf-8")
    names = re.findall(r"^    func (\w+)\(\) async throws \{", tests, re.M)
    assert names == prep["plannedSwiftTests"]["methods"] and len(names) == len(re.findall(r"^    @Test", tests, re.M)) == 8
    assert '@Suite("Unregistered UMD literal reading preparation", .serialized)' in tests and "@MainActor\nstruct UMDReadingPreparationTests" in tests
    write(RAW / "identity-check.json", {"preparation": preparation, "patch": patch, "files": prep["files"],
          "authorEvidenceAllRehashed": True, "oldInitializers": old_initializers, "valueModelChanges": model_changes,
          "unchangedDependencyFiles": unchanged, "unchangedParserFiles": 16, "plannedMethods": names, "actualReadOnlyCommands": commands})
    report = {
        "schemaVersion": 1, "kind": "independent-static-review-of-unregistered-umd-literal-reading-preparation",
        "reviewedAtUTC": datetime.now(timezone.utc).isoformat(), "reviewer": "/root/renewal_discovery_ui",
        "status": "no-unresolved-static-blocking-findings", "unresolvedBlockingFindings": [],
        "base": BASE, "worktree": str(WORK), "patch": patch, "preparation": preparation, "files": prep["files"],
        "nonBlockingFindings": [{"id": "trace-byte-field-is-entry-zero", "alsoIdentifiedByRoot": True,
             "sourcePaths": ["Modules/Core/UMD/UMDReadingPreparation.swift", "Modules/Core/ReaderCore/CoreText/TXTLazyAttributedStringBuilder.swift"],
             "finding": "validatedBytes is interpolated into the span detail before the closure executes, so the logged bytes field is the entry value zero, not the completed validated byte count. Chapter count and maxBytes are real input/budget metadata. The preparation instrumentation prose must not be interpreted as completed-byte telemetry; no runtime/performance result is established.",
             "blocking": False}],
        "reviewedInvariants": {
            "throwingDelegatingInitializer": "The pre-delegation throwing span references only initializer parameters, local validatedBytes/remainingUnits/iteration values and the nested error type. It does not read a stored property or capture self. All successful paths then call the existing text initializer before assigning literalContent; throwing paths do not return an uninitialized instance. No definite self-before-init defect was found statically. Actual Swift initializer diagnostics remain SDK-pending.",
            "Sendable": "Only UnifiedChapter and ReplaceRule conformance lists change. Their stored values are Int/String/[String]/String? and String/Bool/Int respectively. The detached factory captures the existing Sendable UMDTextDocument and Sendable Limits and returns [UnifiedChapter]. No unchecked Sendable, lock, queue, actor/global setting rewrite or claim that the entire UIKit renderer is Sendable is introduced.",
            "factoryValidation": "An owned detached worker validates positive budgets, at most 16384 chapters by default, ordinal contiguous raw byte offsets, even raw byte lengths, bounded metadata/title code units and exact UTF16LE code-unit projection (only U+2029 to LF). Subtractions/additions remain within checked cumulative budgets. It returns one complete paragraph String per chapter and sequential numeric href/ID, avoiding duplicate dictionary keys and global composed-character range expansion.",
            "literalNodePath": "Literal mode uses a single existing RenderableNode.text body with parsesAozoraMarkup false. Existing NodeAttributedStringRenderer text branch creates NSAttributedString(string:str), and renderInlineContent's paragraph walk changes attributes without reparsing HTML/entities/Aozora or rebuilding the text. Separate complete chapter Strings prevent combining-mark/CRLF/ZWJ/regional-indicator composition from widening across chapter boundaries. Exact rendered UIKit/typography behavior is covered only by the eight unexecuted tests, not proven here.",
            "emptyAndMissing": "A legitimate empty chapter is retained as a present empty String; an out-of-range chapter is nil/throws through existing interfaces. An entirely empty document remains rejected. Existing TXTBookDocument's chapter dictionary lookup distinguishes empty from missing.",
            "transformsAndOffsets": "Explicit copied ReplaceRule values plus the selected conversion affect builder output, while TXTBookDocument retains the original chapter bodies. Rendered position offsets belong to each spine's actual attributed string including any visible title prefix and transforms; raw global UTF16LE offsets only validate the source directory. No position persistence, migration or byte-offset-to-rendered-index mapping is implemented.",
            "legacyBoundary": "The two existing builder initializer blocks are raw-byte identical. Default literalContent is nil, preserving the old TXT paragraph trimming, Aozora parsing and global-rule branch. BookParsing.swift and ReplaceRule.swift otherwise match base exactly. Existing document/renderer/import service and smoke selection are byte-identical to base, and all original UMD16 files rehash unchanged in both worktree and main. The separate new measurement runner is not in this isolated base and is not part of the five-path patch.",
            "concurrencyAndCancellation": "Factory cancellation is forwarded to and joined with its worker; checks exist at entry, chapter/raw iteration and after joining. Literal initializer is synchronous bounded validation and must be called on an owned worker for a large future input. New tests only prove planned pre-cancelled entries, not in-flight race timing. Rendering retains its existing UIKit/font/style/global dependencies and carries no general off-main safety guarantee.",
            "actualTestScope": "Eight nonparameterized serialized MainActor test methods are source-prepared: five original fixtures/fifteen chapter bodies, literal markup and whitespace plus legacy control, Unicode chapter seams, malformed projections/budgets/IDs/empty body, rendered title/spine positions, copied rules/conversion and deterministic entry cancellation. The separate reviewed measurement runner selects UMDTextDecoderTests11 only and does not execute this new suite; it is absent from this isolated base. No Apple SDK/XCTest run occurred.",
            "productBoundary": "No UMD parser registration, importer/reader route, file/shelf transaction, store/lease, persistence, UI or workflow change is added. This is an in-memory preparation and literal builder seam; it does not establish product-visible import, TOC/reopen, MOBI/image/cover/DRM support or whole-reader acceptance."
        },
        "evidence": {"identityCheck": meta(RAW / "identity-check.json"), "reviewerScript": meta(Path(__file__)),
                     "authorPortableTests": 12, "authorPortableScope": "Existing fixture/reference integrity only; no new Swift execution",
                     "authorGetterFixtures": 5, "authorGetterChapters": 15, "authorGrammarFiles": 5,
                     "grammarIsNotTypecheck": True, "authorRawAndRecordHashesVerified": True,
                     "portableOrGrammarRerunByReviewer": False, "oldInitializers": old_initializers,
                     "plannedMethods": names, "plannedExecutions": 8, "actualSwiftExecutions": 0,
                     "originalParserManifest": parser_manifest,
                     "priorVerificationAttempt": "The first reviewer check assumed reader-measurements.sh existed at the isolated base; git show rejected that absent path before any review record was produced. Original attempt1 helper/raw are retained. The final check instead binds the existing smoke.sh and preserves the explicit absence of the separate new runner; no reviewed source was changed."},
        "SwiftTypecheckPerformed": False, "AppleSDKCompilationPerformed": False, "iOSTestsExecuted": 0,
        "CIQueriedOrTriggered": False, "networkQueries": 0, "sourceOrMainOrCanonicalEditsByReviewer": False,
        "integrationRecorderExecuted": False, "originalJavaRerun": False,
        "remainingAcceptance": "Actual SDK compilation and all eight real test executions remain required, including delegation/type inference, Swift Testing macros, Foundation UTF16/Node-render behavior and app-host font/style dependencies. A future checked import and product route remain separate work."
    }
    write(DEST, report)
    print(json.dumps({"review": meta(DEST), "status": report["status"], "blockingFindings": 0,
                      "nonBlockingFindings": 1, "files": 5, "plannedSwiftMethods": 8, "actualSwiftMethods": 0}))


if __name__ == "__main__": main()
