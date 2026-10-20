"""Archive existing public preparation evidence once; no tests/Git/network calls.
Never copy user report/context/inspection inputs from renewal-delivery.
"""
import hashlib
import json
from pathlib import Path
import stat

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "docs/legado-ios/evidence/renewal-candidate-selection"
SWIFT = ROOT / ".build/renewal-discovery/bounded-endpoint-selection-20261020"
INSPECTOR = ROOT / ".build/renewal-candidate-inspector-validation"
UI = ROOT / ".build/renewal-candidate-ui-validation"


def read(path):
    assert path.is_absolute() and path.is_relative_to(ROOT)
    for item in (path, *path.parents):
        info = item.lstat()
        assert not stat.S_ISLNK(info.st_mode) and not (getattr(info, "st_file_attributes", 0) & 0x400)
        if item == ROOT:
            break
    assert path.is_file() and path.resolve().is_relative_to(ROOT)
    return path.read_bytes()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    assert not DEST.exists() and not DEST.is_symlink()
    read(ROOT / "docs/legado-ios/completion-plan.json")  # Existing safe parent validation only; never written.
    items = {}

    def add(source, name, digest=None, size=None):
        assert name not in items and not name.startswith("/") and ".." not in Path(name).parts
        data = read(source)
        assert digest is None or sha(data) == digest, str(source)
        assert size is None or len(data) == size, str(source)
        assert not source.is_relative_to(ROOT / ".build/renewal-delivery"), "User input directory is excluded"
        items[name] = (source, data)
        return data

    swift_names = ("verification.json", "change.patch", "verification-final.json", "change-final.patch",
                   "verification-v2.json", "change-v2.patch", "notes.json", "check.py", "check-v2.py",
                   "check-v2.command.json", "check-v2.stdout", "check-v2.stderr")
    for name in swift_names:
        add(SWIFT / name, "swift/" + name)
    v1 = json.loads(items["swift/verification-final.json"][1])
    v2 = json.loads(items["swift/verification-v2.json"][1])
    assert sha(items["swift/verification-v2.json"][1]) == "649cab6e9f5541d2db2dda086eccc5b78f17ebe2b821a874b5daa675830075b2"
    assert v2["plannedMethods"] == v2["plannedExecutions"] == 16 and v2["methodIdentities"] == v1["methodIdentities"]
    assert v2["actualSwiftOrIOSTestExecutions"] == 0
    assert sha(items["swift/change-v2.patch"][1]) == v2["patchSHA256"]
    command = json.loads(items["swift/check-v2.command.json"][1])
    assert command["exitCode"] == 0
    for name, entry in command["logs"].items():
        assert sha(items["swift/check-v2." + name][1]) == entry["sha256"]

    for version in ("v2", "v3"):
        for path in sorted((INSPECTOR / version).iterdir()):
            assert path.is_file()
            add(path, "inspector/" + version + "/" + path.name)
    final = json.loads(items["inspector/v3/validation.json"][1])
    assert sha(items["inspector/v3/validation.json"][1]) == "da41138f3a6093ed22fabfc0a8998407f9d8852691027ae5d937915922cb78da"
    assert sha(items["inspector/v2/validation.json"][1]) == final["reusedInspectorEvidence"]["sha256"]
    assert final["actualSwiftTypechecks"] == final["actualSDKBuilds"] == final["actualIOSTests"] == 0
    for version in ("v2", "v3"):
        validation = json.loads(items["inspector/" + version + "/validation.json"][1])
        for command in validation["commands"]:
            assert command["exitCode"] == 0
            for log in command["logs"]:
                data = read(ROOT / log["path"])
                assert (len(data), sha(data)) == (log["bytes"], log["sha256"])
    for entry in final["files"]:
        add(ROOT / entry["path"], "sources/" + entry["path"], entry["sha256"], entry["bytes"])
    inventory = json.loads(items["inspector/v3/source-inputs-at-validation.json"][1])
    assert sha(items["inspector/v3/source-inputs-at-validation.json"][1]) == "5cfc596be8dcb1db18bf86ce2bb6d5a9fcb5c8372ff3b9d30b988145c53d35ff"
    assert inventory["sourceInputCount"] == len(inventory["files"]) == 32 and inventory["CIHeadBindingPrepared"] is False
    for entry in inventory["files"]:
        assert (len(read(ROOT / entry["path"])), sha(read(ROOT / entry["path"]))) == (entry["bytes"], entry["sha256"])

    ui_first = json.loads(add(UI / "result.json", "ui/result.json", "17c8f8b8ce32eebb45692ec3ee7c7af0fa25d2939ad410538ec85cd89f88e1ea"))
    ui_final = json.loads(add(UI / "result-export-interpretation.json", "ui/result-export-interpretation.json",
                              "84fb0d176a78ff9cc37f4b33c92cdd8b8446c963855c43aeacda4a0a99052ae6"))
    add(ROOT / ".build/renewal-discovery/check-renewal-candidate-ui.py", "ui/check-renewal-candidate-ui.py",
        "245f1472984d72c8bc4de7fa7bf6d39070dd3373b8cd7a917d82a3b7d779355d")
    assert ui_first["languages"] == 5 and ui_first["keysPerLanguage"] == 3731
    assert ui_final["SDKOrSwiftTestsExecuted"] == 0
    assert sha(read(ROOT / ui_final["path"])) == ui_final["sha256"]
    for entry in ui_first["files"]:
        if entry["path"].endswith(".strings"):
            assert (len(read(ROOT / entry["path"])), sha(read(ROOT / entry["path"]))) == (entry["bytes"], entry["sha256"])
    for entry in v2["files"]:
        assert (len(read(ROOT / entry["path"])), sha(read(ROOT / entry["path"]))) == (entry["bytes"], entry["sha256"])
    add(Path(__file__).resolve(), "archive-renewal-candidate-selection.py")
    entries = [{"path": name, "source": source.relative_to(ROOT).as_posix(), "bytes": len(data), "sha256": sha(data)}
               for name, (source, data) in sorted(items.items())]
    catalog = {"schemaVersion": 1, "files": entries, "excludesItself": True,
               "onlyExistingPublicPreparationEvidenceCopied": True, "userRawReportOrContextCopied": False,
               "testsRerun": False, "networkOrCIOrGitUsed": False}
    encoded = (json.dumps(catalog, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    items["catalog.json"] = (None, encoded)
    DEST.mkdir(exist_ok=False)
    for name, (_, data) in sorted(items.items()):
        path = DEST / name
        path.parent.mkdir(exist_ok=True, parents=True)
        with path.open("xb") as stream:
            stream.write(data)
        assert read(path) == data
    actual = [path for path in DEST.rglob("*") if path.is_file()]
    assert {path.relative_to(DEST).as_posix() for path in actual} == set(items)
    print(json.dumps({"files": len(actual), "bytes": sum(path.stat().st_size for path in actual),
                      "catalogSHA256": sha(encoded), "directory": DEST.relative_to(ROOT).as_posix(),
                      "userOriginalReportOrContextCopied": False, "newTestRuns": 0}))


if __name__ == "__main__":
    main()
