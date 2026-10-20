import hashlib
import json
import pathlib
import re
import sys
from datetime import datetime, timezone
from urllib.request import Request, urlopen

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / ".tools/swift-syntax-python"))
from tree_sitter import Language, Parser
import tree_sitter_swift

FILES = [
    "Modules/Services/SelfRenewal/SelfRenewalMachOSignatureReader.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalMachOSignatureReaderTests.swift",
]
SOURCES = {
    "loader.h": "https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/EXTERNAL_HEADERS/mach-o/loader.h",
    "fat.h": "https://raw.githubusercontent.com/apple-oss-distributions/cctools/main/include/mach-o/fat.h",
    "cs_blobs.h": "https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/osfmk/kern/cs_blobs.h",
}
parser = Parser(Language(tree_sitter_swift.language()))
records = []
for name in FILES:
    raw = (ROOT / name).read_bytes()
    tree = parser.parse(raw)
    errors = []
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append({"type": node.type, "start": list(node.start_point), "end": list(node.end_point)})
        stack.extend(node.children)
    assert not errors, (name, errors)
    (HERE / pathlib.Path(name).name).write_bytes(raw)
    records.append({"path": name, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                    "grammarErrors": errors})
primary = []
for filename, url in SOURCES.items():
    destination = HERE / "primary" / filename
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raw = destination.read_bytes()
    else:
        with urlopen(Request(url, headers={"User-Agent": "Yuedu-owned-materials-structure-review"}), timeout=30) as response:
            raw = response.read(262_145)
            assert len(raw) <= 262_144
        destination.write_bytes(raw)
    primary.append({"path": str(destination.relative_to(ROOT)).replace("\\", "/"), "url": url,
                    "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
test_source = (ROOT / FILES[1]).read_text(encoding="utf-8")
methods = re.findall(r"    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(", test_source)
assert len(methods) == 9 and len(set(methods)) == 9
result = {
    "createdAtUTC": datetime.now(timezone.utc).isoformat(),
    "status": "prepared_not_sdk_executed",
    "sourceInputs": records,
    "grammarParsedFiles": 2,
    "preparedSwiftTestMethods": methods,
    "preparedSwiftTestCount": 9,
    "actualSwiftSDKBuilds": 0,
    "actualSwiftTestExecutions": 0,
    "productionConnection": "Calls existing SelfRenewalMaterialInventory.read, then parses only inventory codeFile ranges",
    "newSeparateHardLimits": {"architectures": 16, "loadCommands": 4096, "commandBytesPerSlice": 1048576,
                               "signatureBytesPerSlice": 16777216, "blobSlots": 32,
                               "stringBytes": 255, "totalAdditionalReadBytes": 67108864},
    "readOnly": True,
    "callerOwnedQuiescentUnpackedApplicationRequired": True,
    "wholeExecutableReadRequired": False,
    "originalInventoryBudgetChanged": False,
    "realCredentialsProfilesIPAsOrDeviceMaterialsRead": False,
    "cryptographicVerificationPerformed": False,
    "replacementPolicyTrustedAdapterConstructed": False,
    "signingInstallationOrAutomaticRenewalImplemented": False,
    "deferredFormats": ["raw standalone CodeDirectory", "scatter vectors", "pre-encrypted hash arrays",
                        "linkage signatures", "unknown required dyld commands", "unknown signature slots",
                        "future CodeDirectory versions", "CMS ASN.1 and trust", "page and special-slot digest verification"],
    "primaryReferences": primary,
}
(HERE / "preparation.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
print(json.dumps({"status": result["status"], "grammarParsedFiles": 2,
                  "preparedSwiftTestCount": 9, "actualSwiftTestExecutions": 0,
                  "sourceInputs": records}, ensure_ascii=False))
