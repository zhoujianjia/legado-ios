"""Local grammar/inventory/diff capture only. This does not execute Swift tests."""
import base64
import difflib
import hashlib
import json
from pathlib import Path
import re
import sys

OUT = Path(__file__).resolve().parent
SUFFIX = "-final"
ROOT = OUT.parents[2]
sys.path.insert(0, str(ROOT / ".tools/swift-syntax-python"))
from tree_sitter import Language, Parser
import tree_sitter_swift

before = json.loads((OUT / "before.json").read_text(encoding="ascii"))
parser = Parser(Language(tree_sitter_swift.language()))


def failures(node):
    result = [node] if node.type == "ERROR" or node.is_missing else []
    for child in node.children:
        result.extend(failures(child))
    return result


files = []
patch = []
for path, encoded in before.items():
    original = base64.b64decode(encoded)
    data = (ROOT / path).read_bytes()
    errors = failures(parser.parse(data).root_node)
    assert not any(line.rstrip(b" \t") != line for line in data.splitlines()), path
    assert chr(0xFFFD) not in data.decode("utf-8"), path
    files.append({"path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                  "beforeSHA256": hashlib.sha256(original).hexdigest(),
                  "grammarErrors": [{"line": node.start_point.row + 1, "column": node.start_point.column + 1,
                                     "kind": node.type} for node in errors]})
    patch.extend(difflib.unified_diff(original.decode("utf-8").splitlines(keepends=True),
                                    data.decode("utf-8").splitlines(keepends=True),
                                    fromfile="a/" + path, tofile="b/" + path))
test_path = next(path for path in before if path.startswith("Tests/"))
original = base64.b64decode(before[test_path]).decode("utf-8")
current = (ROOT / test_path).read_text(encoding="utf-8")
old_methods = re.findall(r"@Test func (\w+)\(", original)
methods = re.findall(r"@Test func (\w+)\(", current)
assert len(old_methods) == len(set(old_methods)) == 13
assert len(methods) == len(set(methods)) == 16 and set(old_methods) <= set(methods)
assert "@Test(" not in current
patch_data = "".join(patch).encode("utf-8")
with (OUT / ("change" + SUFFIX + ".patch")).open("xb") as stream:
    stream.write(patch_data)
result = {"status": "grammar-screen-passed" if all(not item["grammarErrors"] for item in files) else "grammar-screen-failed",
          "files": files, "patchBytes": len(patch_data), "patchSHA256": hashlib.sha256(patch_data).hexdigest(),
          "old13MethodIdentitiesPreserved": True, "plannedMethods": 16, "plannedExecutions": 16,
          "methodIdentities": ["SelfRenewalDiscoveryProbeTests/" + name for name in methods],
          "newMethods": sorted(set(methods) - set(old_methods)),
          "method": "tree-sitter grammar screen and source inventory only",
          "SwiftTypecheckPerformed": False, "AppleSDKCompilationPerformed": False,
          "actualSwiftOrIOSTestExecutions": 0, "actualDeviceNetworkValidation": False,
          "CIQueriesOrTriggers": 0, "GitOperations": 0, "privateInputsRead": False}
with (OUT / ("verification" + SUFFIX + ".json")).open("x", encoding="utf-8", newline="\n") as stream:
    json.dump(result, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
print(json.dumps({"status": result["status"], "files": len(files), "plannedMethods": len(methods),
                  "actualSwiftOrIOSTestExecutions": 0, "patchSHA256": result["patchSHA256"]}))
sys.exit(any(item["grammarErrors"] for item in files))
