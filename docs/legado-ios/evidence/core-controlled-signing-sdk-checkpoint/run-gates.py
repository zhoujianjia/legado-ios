"""One local affected-gates run; no Swift, Git, network or JVM execution."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
WORK = Path(__file__).resolve().parent
OWNED = (
    "scripts/reader-experience/renewal-probe-tools.py",
    "scripts/reader-experience/test-renewal-probe-tools.py",
    "scripts/reader-experience/renewal-probe-tests.sh",
    ".github/workflows/reader-renewal-probe.yml",
    "scripts/reader-experience/original-api-package-tools.py",
    "scripts/reader-experience/test-original-api-package-tools.py",
    "scripts/reader-experience/original-api-package-tests.sh",
)

def module(path, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

def record(relative):
    raw = (ROOT / relative).read_bytes()
    return {"path": relative, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}

def write_json(name, value):
    with (WORK / name).open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

native = module("scripts/reader-experience/renewal-probe-tools.py", "native_prepared_gates")
package = module("scripts/reader-experience/original-api-package-tools.py", "package_prepared_gates")
native_inputs = [record(path) for path in native.SOURCE_INPUTS]
package_inputs = [record(path) for path in package.SOURCE_INPUTS]
assert len(native_inputs) == len(set(native.SOURCE_INPUTS)) == 80
assert len(package_inputs) == len(set(package.SOURCE_INPUTS)) == 19
assert len(package.PACKAGE_INPUTS) == 12 and len(package.EXPECTED) == 10
counts = {mode: sum(len(native.EXPECTED_CASES[group]) for group in groups)
          for mode, groups in native.SELECTION_GROUPS.items()}
assert counts == {"all": 30, "replacement": 5, "implementation": 11,
                  "signature": 9, "cryptography": 25, "sealedmaterials": 48,
                  "boundmaterials": 78, "controlledsigning": 23}
write_json("preparation.json", {"recordedAtUTC": datetime.now(timezone.utc).isoformat(),
    "allSourceInputs": native_inputs, "allPackageSourceInputs": package_inputs,
    "ownedControlInputs": [record(path) for path in OWNED], "modeMethodCounts": counts})

commands = [
    ("renewal-evidence-guards", [sys.executable, "-B", "scripts/reader-experience/test-renewal-probe-tools.py", "-v"], 35),
    ("package-evidence-guards", [sys.executable, "-B", "scripts/reader-experience/test-original-api-package-tools.py", "-v"], 12),
    ("renewal-shell-syntax", ["D:/app/Git/bin/bash.exe", "-n", "scripts/reader-experience/renewal-probe-tests.sh"], None),
    ("package-shell-syntax", ["D:/app/Git/bin/bash.exe", "-n", "scripts/reader-experience/original-api-package-tests.sh"], None),
    ("renewal-workflow-lint", [str(ROOT / ".tools/actionlint/actionlint.exe"), "-shellcheck=", ".github/workflows/reader-renewal-probe.yml"], None),
]

def execute(item):
    name, command, methods = item
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    log = WORK / (name + ".log")
    log.write_bytes(result.stdout)
    value = {"name": name, "command": command, "exitCode": result.returncode,
        "elapsedSeconds": round(time.monotonic() - started, 3),
        "log": record(log.relative_to(ROOT).as_posix())}
    if methods is not None:
        match = re.search(rb"(?m)^Ran (\d+) tests? in .+$", result.stdout)
        actual = int(match.group(1)) if match else None
        ok = re.search(rb"(?m)^OK\s*$", result.stdout) is not None
        value.update(actualPortableTestMethods=actual, unittestOK=ok,
                     exactExpectedCount=actual == methods)
    return value

with ThreadPoolExecutor(max_workers=5) as workers:
    outcomes = list(workers.map(execute, commands))
stable = native_inputs == [record(path) for path in native.SOURCE_INPUTS] and package_inputs == [record(path) for path in package.SOURCE_INPUTS]
passed = stable and all(item["exitCode"] == 0 and item.get("unittestOK", True) and item.get("exactExpectedCount", True) for item in outcomes)
for path in OWNED:
    target = WORK / "sources" / path
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / path, target)
prior = ".build/renewal-discovery/bound-material-selection-gates/result.json"
primary = ".build/renewal-discovery/original-api-package-selection-gates/primary/sources.json"
write_json("result.json", {
    "schemaVersion": 1, "recordedAtUTC": datetime.now(timezone.utc).isoformat(),
    "status": "passed" if passed else "failed", "commands": outcomes,
    "actualPortableTestMethods": sum(item.get("actualPortableTestMethods") or 0 for item in outcomes),
    "sourceSnapshotUnchangedDuringChecks": stable,
    "selectionMode": "controlledsigning", "nativeSourceInputCount": 80,
    "allSourceInputs": native_inputs, "modeMethodCounts": counts,
    "controlledSigningExactMethods": sorted(native.EXPECTED_CASES["controlledsigning"]),
    "controlledSigningColdTimeoutSeconds": 2700,
    "packageMode": package.MODE, "packageSourceInputCount": 12,
    "packageControlInputCount": 7, "allPackageSourceInputs": package_inputs,
    "packageExactMethods": sorted(package.EXPECTED), "packageExactFilter": package.FILTER,
    "packageFlags": list(package.REQUIRED_FLAGS), "packageWorkers": 1,
    "packageTimeoutSeconds": package.TEST_TIMEOUT,
    "ownedControlInputs": [record(path) for path in OWNED],
    "priorUnaffectedPortableEvidence": {**record(prior),
        "scope": "Earlier smoke24/report32 results retained as historical evidence; neither was rerun or counted here."},
    "primaryContractEvidence": {**record(primary), "source": json.loads((ROOT / primary).read_text(encoding="utf-8"))},
    "nativeSDKMethodsExecutedLocally": 0, "packageXCTestMethodsExecutedLocally": 0,
    "swiftExecuted": False, "jvmExecuted": False, "gitInvoked": False,
    "cloudTriggeredOrQueried": False, "physicalDeviceValidationPassed": False,
    "selfRenewalVerified": False, "unattendedRenewalVerified": False,
    "limitations": [
        "This result accepts Python portable evidence guards and shell/workflow syntax only.",
        "The prepared native23 and separate package10 methods still require actual macOS SDK execution.",
        "Existing seven native selection sets and budgets are preserved; no older native SDK method is counted here.",
        "SPM source-only mode compiles a stub CLegadoJNI closure; no original Kotlin/JVM flow runs.",
        "Generic anchors, owned Keychain fixtures and controlled signer substrate do not establish Apple authority, full package signing, installation or automatic renewal.",
    ],
})
print(json.dumps({"status": "passed" if passed else "failed", "sourceStable": stable,
    "commands": [{key: value for key, value in item.items() if key not in ("command", "log")} for item in outcomes],
    "result": record((WORK / "result.json").relative_to(ROOT).as_posix())}, indent=2))
raise SystemExit(0 if passed else 1)
