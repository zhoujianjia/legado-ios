"""V2: only the affected test file receives a new grammar screen."""
import base64
import difflib
import hashlib
import json
from pathlib import Path
import re
import sys

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
sys.path.insert(0, str(ROOT / ".tools/swift-syntax-python"))
from tree_sitter import Language, Parser
import tree_sitter_swift

prior = json.loads((OUT / "verification-final.json").read_text(encoding="utf-8"))
before = json.loads((OUT / "before.json").read_text(encoding="ascii"))
files = []
patch = []
errors = []
for item in prior["files"]:
    path = item["path"]
    data = (ROOT / path).read_bytes()
    if path.startswith("Tests/"):
        tree = Parser(Language(tree_sitter_swift.language())).parse(data)
        pending = [tree.root_node]
        while pending:
            node = pending.pop()
            if node.type == "ERROR" or node.is_missing:
                errors.append({"line": node.start_point.row + 1, "column": node.start_point.column + 1, "kind": node.type})
            pending.extend(node.children)
        methods = ["SelfRenewalDiscoveryProbeTests/" + name for name in re.findall(r"@Test func (\w+)\(", data.decode("utf-8"))]
        assert methods == prior["methodIdentities"] and len(methods) == 16
    else:
        assert hashlib.sha256(data).hexdigest() == item["sha256"], "Production file changed in mock-only repair"
    files.append({"path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    patch.extend(difflib.unified_diff(base64.b64decode(before[path]).decode("utf-8").splitlines(keepends=True),
                                    data.decode("utf-8").splitlines(keepends=True), fromfile="a/" + path, tofile="b/" + path))
patch_data = "".join(patch).encode("utf-8")
with (OUT / "change-v2.patch").open("xb") as stream:
    stream.write(patch_data)
record = {"status": "grammar-screen-passed" if not errors else "grammar-screen-failed", "revision": 2,
          "files": files, "grammarFilesChecked": [path for path in before if path.startswith("Tests/")],
          "grammarErrors": errors, "productionFilesByteHashesUnchanged": True,
          "fix": "Only mock transportFailed attempts now carry normalized posix ECONNREFUSED. The reported-address-shape test asserts error domain/code for every returned attempt.",
          "priorFixtureContractViolationPreservedInV1Records": True,
          "plannedMethods": 16, "plannedExecutions": 16, "methodIdentities": methods,
          "patchBytes": len(patch_data), "patchSHA256": hashlib.sha256(patch_data).hexdigest(),
          "SwiftTypecheckPerformed": False, "AppleSDKCompilationPerformed": False,
          "actualSwiftOrIOSTestExecutions": 0, "otherPortableSuitesRerun": 0,
          "CIQueriesOrTriggers": 0, "GitOperations": 0}
with (OUT / "verification-v2.json").open("x", encoding="utf-8", newline="\n") as stream:
    json.dump(record, stream, indent=2)
    stream.write("\n")
print(json.dumps({"status": record["status"], "grammarFiles": 1, "plannedMethods": 16,
                  "actualSwiftOrIOSTestExecutions": 0, "patchSHA256": record["patchSHA256"]}))
sys.exit(bool(errors))
