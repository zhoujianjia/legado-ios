"""Read-only identity/evidence check for the frozen, unregistered UMD batch."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
from datetime import datetime, timezone
import zipfile


ROOT = Path("F:/yuedu-reader")
WORK = ROOT / ".build/reader-umd-worktree"
REFERENCE = ROOT / ".build/umd-reference-preparation"
BASE = "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06"
PATCH_SHA = "50f5d84136eca006fdeea2cf0c151d39920673c1bc2e3e46759796fa02de1b21"
PREP_SHA = "f5ffb5197a5ae2e346f15bb123c53278b7bd5da4a17cc8ebd78706b8996a6040"


def identity(path):
    data = path.read_bytes()
    return {"path": str(path), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def pinned(path, sha, size=None):
    found = identity(path)
    assert found["sha256"] == sha, found
    assert size is None or found["bytes"] == size, found
    return found


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    out = args.out_dir.resolve()
    assert out.parent == (ROOT / ".build/renewal-discovery").resolve()
    out.mkdir(exist_ok=False)
    commands = []

    def run(name, argv):
        started = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(argv, cwd=WORK, capture_output=True, check=False)
        stdout = out / (name + ".stdout.bin")
        stderr = out / (name + ".stderr.bin")
        stdout.write_bytes(result.stdout)
        stderr.write_bytes(result.stderr)
        commands.append({"name": name, "argv": argv, "cwd": str(WORK),
                         "startedAtUTC": started, "exitCode": result.returncode,
                         "stdout": identity(stdout), "stderr": identity(stderr)})
        assert result.returncode == 0, commands[-1]
        return result.stdout

    patch = pinned(WORK / ".build/reader-umd-parser.patch", PATCH_SHA, 335793)
    preparation = pinned(WORK / ".build/reader-umd-parser-preparation.json", PREP_SHA, 20445)
    prep = read_json(Path(preparation["path"]))
    assert run("head", ["git", "rev-parse", "HEAD"]).decode().strip() == BASE == prep["base"]
    assert len(prep["files"]) == 16
    files = []
    for item in prep["files"]:
        assert item["change"] == "added"
        found = pinned(WORK / item["path"], item["sha256"], item["bytes"])
        files.append({"path": item["path"], "bytes": found["bytes"], "sha256": found["sha256"]})
    names = run("diff-paths", ["git", "diff", "--name-only", "-z"])
    assert set(names.decode().rstrip("\0").split("\0")) == {x["path"] for x in files}
    actual_patch = run("diff-binary", ["git", "diff", "--binary", "--no-ext-diff"])
    assert actual_patch == Path(patch["path"]).read_bytes()
    run("diff-check", ["git", "diff", "--check"])
    run("reverse-check", ["git", "apply", "--check", "--reverse", patch["path"]])

    bindings = prep["originalReference"]
    reference_record = pinned(Path(bindings["referenceRecord"]), bindings["sha256"])
    reference_manifest = pinned(Path(bindings["bundleManifest"]), bindings["bundleManifestSHA256"])
    original_review = pinned(Path(bindings["independentReview"]["path"]), bindings["independentReview"]["sha256"])
    manifest = read_json(Path(reference_manifest["path"]))
    assert len(manifest["files"]) == 132
    assert len({x["path"] for x in manifest["files"]}) == 132
    for item in manifest["files"]:
        pinned(REFERENCE / item["path"], item["sha256"], item["bytes"])
    archived = pinned(REFERENCE / bindings["sourceZIP"]["archived"], bindings["sourceZIP"]["sha256"], bindings["sourceZIP"]["bytes"])
    with zipfile.ZipFile(archived["path"]) as archive:
        assert len(bindings["unchangedJavaEntriesRehashed"]) == 9
        for item in bindings["unchangedJavaEntriesRehashed"]:
            found = pinned(REFERENCE / item["path"], item["sha256"], item["bytes"])
            assert archive.read(item["entry"]) == Path(found["path"]).read_bytes()

    fixture_root = WORK / "Tests/iOS/yuedu appTests/Fixtures/UMD"
    provenance = read_json(fixture_root / "provenance.json")
    assert provenance["referenceRecordSHA256"] == reference_record["sha256"]
    assert provenance["bundleManifestSHA256"] == reference_manifest["sha256"]
    assert len(provenance["files"]) == len({x["path"] for x in provenance["files"]}) == 10
    fixture_ids = set()
    chapters = 0
    for item in provenance["files"]:
        local = pinned(fixture_root / item["path"], item["sha256"], item["bytes"])
        assert Path(local["path"]).read_bytes() == (REFERENCE / "run/fixtures" / item["path"]).read_bytes()
        fixture_ids.add(Path(item["path"]).parts[0])
        if Path(item["path"]).name == "reader-output.json":
            golden = read_json(Path(local["path"]))
            assert golden["id"] == Path(item["path"]).parts[0]
            assert golden["umdType"] == {"type": "java.lang.Byte", "value": 1}
            assert golden["chapterCount"]["value"] == len(golden["chapters"])
            raw_length = 0
            for index, chapter in enumerate(golden["chapters"]):
                assert chapter["index"] == index
                assert chapter["offset"]["value"] == raw_length
                raw = base64.b64decode(chapter["rawContent"]["valueBase64"], validate=True)
                assert raw == (REFERENCE / "run/fixtures" / golden["id"] / chapter["rawContent"]["file"]).read_bytes()
                assert raw.decode("utf-16le").replace("\u2029", "\n") == chapter["getContentString"]["value"]
                raw_length += len(raw)
                chapters += 1
            assert raw_length == golden["totalContentLength"]["value"]
    assert len(fixture_ids) == 5 and chapters == 15

    evidence = prep["actualValidation"]
    validation = pinned(WORK / evidence["rawRecord"], evidence["rawRecordSHA256"])
    stored = read_json(Path(validation["path"]))
    assert stored["commands"] == evidence["commands"]
    author_logs = []
    for command in evidence["commands"]:
        assert command["exitCode"] == 0
        author_logs.append({"name": command["name"], "stdout": identity(WORK / command["stdout"]),
                            "stderr": identity(WORK / command["stderr"]), "reviewerReran": False})
    assert (WORK / ".build/umd-validation/patch-final.stdout.txt").read_bytes() == Path(patch["path"]).read_bytes()
    portable = (WORK / ".build/umd-validation/portable-12.stderr.txt").read_text(encoding="utf-8")
    assert len(re.findall(r"^test_.* \.\.\. ok$", portable, re.M)) == 12
    assert re.search(r"^Ran 12 tests in .+\n\nOK$", portable.strip(), re.M)
    getters = read_json(WORK / ".build/umd-validation/fixture-getters.stdout.txt")
    assert getters["fixtureIntegrityValidated"] is True and getters["fixtures"] == 5 and getters["chapters"] == 15
    assert getters["swiftExecuted"] == getters["iOSExecuted"] == 0
    grammar = pinned(WORK / evidence["grammar"]["path"], evidence["grammar"]["sha256"])
    parsed_grammar = read_json(Path(grammar["path"]))
    assert parsed_grammar["passed"] is True and len(parsed_grammar["files"]) == 3
    for item in parsed_grammar["files"]:
        pinned(WORK / item["path"], item["sha256"])
        assert item["passed"] is True and item["errors"] == []
    assert all(evidence[k] == 0 for k in ("swiftTypecheck", "swiftSDKBuild", "iOSExecution", "deviceExecution", "CITriggered"))
    primary_index = pinned(WORK / prep["primaryAPI"]["path"], prep["primaryAPI"]["sha256"])
    primary = read_json(Path(primary_index["path"]))
    primary_manual = pinned(WORK / ".build/umd-primary/zlib-manual.html", primary["sha256"], primary["bytes"])

    unchanged_boundaries = []
    for boundary in ("Modules/Core/EPUB/BookParsing.swift", "Modules/Services/LibraryStore/LocalBookImportService.swift"):
        original = run("base-" + Path(boundary).stem, ["git", "show", BASE + ":" + boundary])
        assert original == (WORK / boundary).read_bytes()
        unchanged_boundaries.append(identity(WORK / boundary))
    swift = (WORK / "Tests/iOS/yuedu appTests/UMDTextDecoderTests.swift").read_text(encoding="utf-8")
    assert len(re.findall(r"^    @Test", swift, re.M)) == 11
    result = {"schemaVersion": 1, "kind": "umd-parser-independent-read-only-identity-check",
              "observedAtUTC": datetime.now(timezone.utc).isoformat(), "status": "passed",
              "base": BASE, "patch": patch, "preparation": preparation, "files": files,
              "reference": {"manifest": reference_manifest, "record": reference_record, "priorIndependentReview": original_review,
                            "manifestMembersRehashed": 132, "originalJavaEntriesComparedToZIP": 9,
                            "originalArchive": archived, "copiedGoldenFilesCompared": 10, "fixtures": 5, "chapters": 15},
              "authorEvidence": {"validation": validation, "rawLogs": author_logs, "portableChecks": 12,
                                 "portableRerunByReviewer": False, "grammar": grammar, "grammarFiles": 3,
                                 "grammarRerunByReviewer": False, "primaryIndex": primary_index, "primaryManual": primary_manual},
              "unchangedProductBoundaries": unchanged_boundaries, "plannedSwiftMethods": 11,
              "actualReviewerCommands": commands, "SwiftExecution": 0, "AppleSDKCompilation": 0,
              "JavaExecution": 0, "networkQueries": 0, "sourceEdits": 0}
    (out / "identity-check.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "passed", "files": 16, "copiedGoldenFiles": 10, "referenceMembers": 132,
                      "chapters": 15, "plannedSwiftMethods": 11, "authorPortableChecks": 12,
                      "reviewerReranPortable": False, "SwiftExecuted": 0}))


if __name__ == "__main__":
    main()
