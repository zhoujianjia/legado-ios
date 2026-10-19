"""Freeze this isolated five-path preparation and its bounded local evidence."""
import datetime
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT.parents[1]
BASE = "1fd96156392b231580482606f394219df45141db"
OUT = ROOT / ".build/umd-reading-patch-checks"
OUT.mkdir(exist_ok=False)
PATCH = ROOT / ".build/reader-umd-reading.patch"
PREP = ROOT / ".build/reader-umd-reading-preparation.json"
assert not PATCH.exists() and not PREP.exists()
FILES = ["Modules/Core/EPUB/BookParsing.swift",
         "Modules/Core/ReaderCore/CoreText/TXTLazyAttributedStringBuilder.swift",
         "Modules/Core/Replace/ReplaceRule.swift", "Modules/Core/UMD/UMDReadingPreparation.swift",
         "Tests/iOS/yuedu appTests/UMDReadingPreparationTests.swift"]
def sha(raw): return hashlib.sha256(raw).hexdigest()
def info(path):
    raw = path.read_bytes()
    return {"path": str(path), "bytes": len(raw), "sha256": sha(raw)}
def write_json(path, value): path.write_bytes((json.dumps(value, ensure_ascii=True, indent=2) + "\n").encode())
commands = []
def run(label, args, cwd=ROOT, output=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True)
    out = OUT / (label + ".stdout"); err = OUT / (label + ".stderr")
    out.write_bytes(result.stdout); err.write_bytes(result.stderr)
    record = {"argv": args, "cwd": str(cwd), "exitCode": result.returncode,
              "stdout": info(out), "stderr": info(err)}
    write_json(OUT / (label + ".json"), record); commands.append(record)
    assert result.returncode == 0, label
    if output: output.write_bytes(result.stdout)
    return result.stdout
assert run("head", ["git", "-c", "core.longpaths=true", "rev-parse", "HEAD"]).decode().strip() == BASE
changed = run("paths", ["git", "-c", "core.longpaths=true", "diff", "--name-only", "-z"]).decode().split("\0")[:-1]
assert changed == FILES, changed
run("diff-check", ["git", "-c", "core.longpaths=true", "diff", "--check"])
run("patch", ["git", "-c", "core.longpaths=true", "diff", "--binary"], output=PATCH)
run("reverse", ["git", "-c", "core.longpaths=true", "apply", "--check", "--reverse", str(PATCH)])
run("forward-main", ["git", "-c", "core.longpaths=true", "apply", "--check", str(PATCH)], MAIN)
main_head = run("main-head", ["git", "-c", "core.longpaths=true", "rev-parse", "HEAD"], MAIN).decode().strip()
source = json.loads((ROOT / ".build/umd-reading-validation/source-boundaries.json").read_bytes())
grammar = json.loads((ROOT / ".build/umd-reading-validation/grammar.json").read_bytes())
for item in grammar["files"]:
    assert info(ROOT / item["path"])["sha256"] == item["sha256"]
prior_prep = MAIN / ".build/reader-umd-worktree/.build/reader-umd-parser-preparation.json"
prior = json.loads(prior_prep.read_bytes())
for item in prior["files"]:
    assert sha((ROOT / item["path"]).read_bytes()) == item["sha256"]
    assert sha((MAIN / item["path"]).read_bytes()) == item["sha256"]
review = MAIN / ".build/renewal-discovery/umd-parser-independent-review.json"
assert sha(review.read_bytes()) == "b0100254dcee408d9530f4ef23dee56cde2de17638a5628eac6bf2d491686898"
ref_review = MAIN / ".build/renewal-discovery/umd-reference-independent-review.json"
assert sha(ref_review.read_bytes()) == "3052ffd6cea4918047cd5ddcf3c830f791ab8ccac69024ab570e155565467901"
files = [{"path": relative, "bytes": (ROOT / relative).stat().st_size,
          "sha256": sha((ROOT / relative).read_bytes()),
          "change": "added" if relative in FILES[-2:] else "modified"} for relative in FILES]
write_json(OUT / "checks.json", {"commands": commands, "allExitZero": True, "noPatchAppliedToMain": True})
write_json(PREP, {
    "schemaVersion": 1, "createdAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "status": "frozen-isolated-source-preparation-awaiting-independent-review-and-Apple-SDK",
    "base": BASE, "mainHEADAtForwardCheck": main_head, "worktree": str(ROOT),
    "scope": "Unregistered UMD literal in-memory projection into the existing TXT document and renderer; no product format support claim.",
    "patch": info(PATCH), "files": files,
    "implementation": {
        "factory": "UMDReadingPreparation.prepare owns a cancellable detached value worker, validates contiguous raw UTF-16LE byte directory, exact public 2029-to-LF projection and fixed metadata/chapter budgets, then returns the existing UnifiedChapter values.",
        "oneParagraph": "Each chapter is one complete paragraph String with original title, ordinal index and numeric sourceHref. No concatenated global book string, regex TOC reconstruction or composed-character range expansion.",
        "document": "The unmodified TXTBookDocument(book:chapters:) consumes those same values; an empty chapter remains an empty String and its identifier remains distinct from missing content.",
        "builder": "A new explicit literal initializer of the existing TXTLazyAttributedStringBuilder validates array/index/href/one-paragraph identity and budgets. Both old initializers remain byte-identical and default literal storage is nil.",
        "literalMode": "Disables paragraph HTML stripping, whitespace trimming, empty-line cleaning, appended LF and Aozora parsing. It uses the existing Node.text renderer and the same typography/style paths.",
        "transforms": "An injected immutable ReplaceRule value snapshot and the explicit text-conversion setting affect rendering only. Original chapter/document content is retained. Existing legacy mutable settings/rule behavior is not refactored.",
        "positions": "Raw directory offsets are UTF-16LE bytes solely for source validation. Rendered CoreTextReadingPosition.charOffset is relative to the actual spine attributed string, including a visible title prefix and text transformations. No positions are persisted or migrated.",
        "budgets": {"utf16Bytes": 33554432, "chapters": 16384, "metadataUTF16Units": 125, "chapterTitleUTF16Units": 127},
        "instrumentation": "SourcePerfTrace spans include stage, chapter count, validated byte count, configured maximum bytes and main-thread flag; no performance improvement or runtime main-thread result is asserted.",
        "cancellation": "Factory rejects cancelled entry, forwards cancellation to its owned worker, polls during raw validation and rechecks after joining. The literal initializer and rendering entry/between awaited phases observe cancellation. Planned tests deterministically test cancelled entries, not arbitrary in-flight timing.",
        "productIntegration": False, "diskWrites": False, "storeOrLeaseChanges": False,
        "registryOrImporterRegistration": False, "UIChanges": False,
    },
    "plannedSwiftTests": {
        "suite": "UMDReadingPreparationTests", "methods": source["plannedMethods"],
        "methodIdentities": ["UMDReadingPreparationTests/" + name + "()" for name in source["plannedMethods"]],
        "count": 8, "parameterized": False, "expectedExecutions": 8, "actualExecutions": 0,
        "coverage": ["Five original fixture documents/all fifteen chapter titles, body UTF-16, raw offsets and numeric TOC identity",
                     "Literal HTML/Aozora-like text, whitespace, CR/LF and blank lines, with the unchanged legacy initializer as control",
                     "Combining marks, CRLF, ZWJ and regional-indicator chapter seams without global range expansion",
                     "Wrong offsets/projections/metadata/title and input budgets reject rather than repair",
                     "Duplicate or missing chapter identity rejects; empty chapter text differs from missing chapter",
                     "Actual title-prefix rendered marker offsets use the second spine, not raw global byte offsets",
                     "Copied replacement snapshot plus explicit simplified conversion preserve original document",
                     "Cancelled factory/initializer/render entry produces CancellationError"],
    },
    "actualValidation": {
        "portable": {"executed": 12, "passed": 12, "failed": 0,
                     "scope": "Existing independent fixture/reference screen guards; not execution of the new Swift implementation."},
        "getterIntegrity": {"fixtures": 5, "chapters": 15, "passed": True},
        "grammar": {"files": 5, "passed": True, "scope": "tree-sitter only", "record": info(ROOT / ".build/umd-reading-validation/grammar.json")},
        "validation": info(ROOT / ".build/umd-reading-validation/validation-record.json"),
        "staticBoundaries": info(ROOT / ".build/umd-reading-validation/source-boundaries.json"),
        "rawDirectory": str(ROOT / ".build/umd-reading-validation"),
        "collector": info(ROOT / ".build/collect-umd-reading-validation.py"),
        "patchChecks": info(OUT / "checks.json"), "patchRawDirectory": str(OUT),
        "gitDiffCheckPassed": True, "worktreeReverseCheckPassed": True, "mainForwardCheckPassed": True,
        "swiftTypechecks": 0, "swiftSDKBuilds": 0, "swiftTests": 0, "iOSTests": 0,
        "originalJavaRerun": False, "CITriggered": False,
    },
    "frozenParserPreparation": {"manifest": info(prior_prep), "all16FilesRehashedInWorktreeAndMain": True,
                                "independentReview": info(review), "unchangedAndUnregistered": True},
    "originalReference": {"record": info(MAIN / ".build/umd-reference-preparation/run/reference-record.json"),
                          "manifest": info(MAIN / ".build/umd-reference-preparation/bundle-manifest.json"),
                          "independentReview": info(ref_review),
                          "usedAsPriorEvidenceOnly": True, "newJavaExecutions": 0},
    "primaryReference": {"index": info(ROOT / ".build/umd-reading-primary/index.json"),
                         "document": info(ROOT / ".build/umd-reading-primary/rangeOfComposedCharacterSequences.md"),
                         "url": "https://developer.apple.com/documentation/foundation/nsstring/rangeofcomposedcharactersequences(for:)",
                         "usedFor": "The legacy range expansion can include composed sequences overlapping a requested range; separate chapter Strings avoid widening across UMD seams."},
    "sourceSelfReview": [
        "No new importer/renderer/storage/cache/index queue, GCD, sleep, retry, framework or test selector.",
        "Existing document/disk TXT parser/mapped parser/registry/store/project/workflow files are outside this five-path patch.",
        "Only two pure value-model conformance lists gain Sendable; fields and Codable protocol remain unchanged.",
        "Factory input remains immutable; output has one value paragraph per chapter with unique ordinal identity before existing dictionary construction.",
        "Literal builder initializer is synchronous bounded validation and must be called on an owned worker for large product inputs; this preparation introduces no product caller.",
        "Renderer retains existing UIKit/font/style/asset host dependencies. Planned renderer tests run in the app-host MainActor; no new general off-main rendering safety claim.",
        "Golden fixture reads and decoder/document construction in the large-fixture test use owned workers; the synthetic main-actor rendering cases are small. Oversize input construction/validation is detached.",
        "Value arrays/String copy-on-write do not establish a memory footprint limit. The 32 MiB limit is raw UTF-16 chapter data, excluding decoder snapshots, projected document dictionaries, attributed strings and renderer state.",
    ],
    "remainingGates": ["Independent frozen-patch review", "Actual Apple SDK app/test compile and eight real test executions",
                       "Checked shelf/file commit lease and failure-safe import remain design-only outside this patch",
                       "Product UMD routing/registration and real reader/import validation remain unimplemented"],
    "limits": ["Not full UMD/MOBI/image/DRM support or product-visible UMD import.",
               "No persistent reading-position, crash/power-loss transaction, backup/export or binary equivalence claim.",
               "Portable and tree-sitter pass does not prove Swift type checking, actor isolation, UIKit runtime behavior or performance."],
})
print(json.dumps({"patch": info(PATCH), "preparation": info(PREP), "paths": len(files), "plannedSwiftMethods": 8,
                  "actualSwiftExecutions": 0, "checksPassed": True}))
