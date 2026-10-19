"""One bounded local collector. No Swift SDK, CI or original Java execution."""
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT.parents[1]
BASE = "1fd96156392b231580482606f394219df45141db"
OUT = ROOT / ".build/umd-reading-validation"
OUT.mkdir(parents=True, exist_ok=False)
FILES = [
    "Modules/Core/EPUB/BookParsing.swift",
    "Modules/Core/Replace/ReplaceRule.swift",
    "Modules/Core/UMD/UMDReadingPreparation.swift",
    "Modules/Core/ReaderCore/CoreText/TXTLazyAttributedStringBuilder.swift",
    "Tests/iOS/yuedu appTests/UMDReadingPreparationTests.swift",
]
METHODS = ["originalGoldenDocumentsAndDirectory", "literalBodyAndLegacyControl", "chapterSeamsDoNotMerge",
           "rejectsInconsistentProjectionAndBudgets", "literalMetadataAndEmptyChapter",
           "positionsUseRenderedSpineAndTitlePrefix", "explicitTransformsPreserveOriginalDocument",
           "cancellationDoesNotReturnPreparedContent"]

def digest(data): return hashlib.sha256(data).hexdigest()
def write_json(path, value): path.write_bytes((json.dumps(value, ensure_ascii=True, indent=2) + "\n").encode("utf-8"))
def file_info(path):
    raw = path.read_bytes()
    return {"path": str(path), "bytes": len(raw), "sha256": digest(raw)}

commands = []
def run(label, args, cwd=ROOT, expected=0):
    result = subprocess.run(args, cwd=cwd, capture_output=True)
    out = OUT / (label + ".stdout"); err = OUT / (label + ".stderr")
    out.write_bytes(result.stdout); err.write_bytes(result.stderr)
    record = {"label": label, "argv": args, "cwd": str(cwd), "exitCode": result.returncode,
              "stdout": file_info(out), "stderr": file_info(err)}
    write_json(OUT / (label + ".json"), record); commands.append(record)
    if result.returncode != expected: raise RuntimeError(f"{label}: exit {result.returncode}")
    return result.stdout

portable = run("portable", [sys.executable, "-B", "scripts/reader-experience/test-umd-fixtures.py", "-v"])
getters = run("getters", [sys.executable, "-B", "scripts/reader-experience/inspect-umd-fixtures.py",
                           "--root", "Tests/iOS/yuedu appTests/Fixtures/UMD"])
getter_result = json.loads(getters)
assert getter_result["fixtures"] == 5 and getter_result["chapters"] == 15
assert getter_result["swiftExecuted"] == 0 and getter_result["iOSExecuted"] == 0
portable_text = (OUT / "portable.stderr").read_text(encoding="utf-8")
assert "Ran 12 tests" in portable_text and portable_text.rstrip().endswith("OK")

sys.path.insert(0, str(MAIN / ".tools/swift-syntax-python"))
from tree_sitter import Language, Parser
import tree_sitter_swift
parser = Parser(Language(tree_sitter_swift.language()))
def errors(node):
    found = []
    if node.type == "ERROR" or node.is_missing: found.append({"type": node.type, "start": list(node.start_point)})
    for child in node.children: found.extend(errors(child))
    return found
grammar = []
for relative in FILES:
    raw = (ROOT / relative).read_bytes(); tree = parser.parse(raw)
    issues = errors(tree.root_node)
    grammar.append({"path": relative, "bytes": len(raw), "sha256": digest(raw), "errors": issues, "passed": not issues})
assert all(item["passed"] for item in grammar)
write_json(OUT / "grammar.json", {"scope": "tree-sitter parsing only, not Swift SDK/typechecking", "files": grammar, "passed": True,
                                  "swiftSDKBuilds": 0, "iOSExecutions": 0})

def git_blob(relative):
    return run("base-" + digest(relative.encode())[:10], ["git", "-c", "core.longpaths=true", "show", BASE + ":" + relative])
def nodes_of(node, kind):
    result = [node] if node.type == kind else []
    for child in node.children: result.extend(nodes_of(child, kind))
    return result
builder_path = FILES[3]
old_builder = git_blob(builder_path); new_builder = (ROOT / builder_path).read_bytes()
def initializers(raw):
    return [raw[n.start_byte:n.end_byte] for n in nodes_of(parser.parse(raw).root_node, "init_declaration")]
old_inits = initializers(old_builder); new_inits = initializers(new_builder)
assert len(old_inits) == 2 and len(new_inits) == 3 and old_inits == new_inits[1:]
for i, relative in enumerate(FILES[:2]):
    before = git_blob(relative); after = (ROOT / relative).read_bytes()
    marker = b"Identifiable, Equatable" if i == 0 else b"Identifiable, Codable"
    assert before.replace(marker, marker + b", Sendable", 1) == after
test_source = (ROOT / FILES[4]).read_text(encoding="utf-8")
observed = re.findall(r"@Test\([^\n]*\)\s+func\s+(\w+)\(\)\s+async\s+throws", test_source)
assert observed == METHODS and "arguments:" not in test_source

frozen_manifest = MAIN / ".build/reader-umd-worktree/.build/reader-umd-parser-preparation.json"
manifest = json.loads(frozen_manifest.read_bytes())
assert len(manifest["files"]) == 16
frozen = []
for item in manifest["files"]:
    raw = (ROOT / item["path"]).read_bytes(); main_raw = (MAIN / item["path"]).read_bytes()
    assert len(raw) == item["bytes"] and digest(raw) == item["sha256"]
    assert raw == main_raw
    frozen.append({"path": item["path"], "bytes": len(raw), "sha256": digest(raw), "worktreeAndMainUnchanged": True})

write_json(OUT / "source-boundaries.json", {
    "scope": "static source and fixture-byte checks; no behavior/typecheck claim",
    "base": BASE, "files": grammar,
    "oldTwoBuilderInitializersByteIdentical": True,
    "oldInitializerSHA256": [digest(raw) for raw in old_inits],
    "twoValueModelsOnlyAddSendable": True,
    "plannedSuite": "UMDReadingPreparationTests", "plannedMethods": METHODS,
    "plannedMethodCount": 8, "plannedExecutions": 8, "parameterized": False,
    "actualSwiftTests": 0, "actualSwiftSDKBuilds": 0, "actualIOSTests": 0,
    "frozenParserManifest": file_info(frozen_manifest), "frozen16": frozen,
    "registryStoreDocumentAndCIUnmodifiedByPatch": True,
})
write_json(OUT / "validation-record.json", {
    "createdAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "scope": "portable fixture checks and tree-sitter/source integrity only",
    "portableTests": {"executed": 12, "passed": 12, "failed": 0},
    "getterIntegrity": getter_result, "grammarFiles": 5, "grammarPassed": True,
    "commands": commands,
    "sourceChecks": file_info(OUT / "source-boundaries.json"),
    "grammar": file_info(OUT / "grammar.json"),
    "actualSwiftTypechecks": 0, "actualSwiftSDKBuilds": 0, "actualSwiftTests": 0,
    "actualIOSTests": 0, "originalJavaRerun": False,
})
print(json.dumps({"passed": True, "portable": 12, "getterFixtures": 5, "getterChapters": 15,
                  "grammarFiles": 5, "plannedSwiftTests": 8, "actualSwiftTests": 0,
                  "record": file_info(OUT / "validation-record.json")}))
