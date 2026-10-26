#!/usr/bin/env python3
"""Recover the exact retained native ZIP for the clean reader workflow.

The original Actions artifact expired. This fixed orphan Git commit supplies
identical bytes first retained for build30, never a new native build or a claim
that the old artifact lives. Later reader builds reuse that immutable supply.
The ordinary artifact-based restore remains a separate, unchanged admission.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

REPOSITORY = "zhoujianjia/legado-ios"
WORKFLOW = ".github/workflows/legado-reader.yml"
SUPPLY_REF = "refs/heads/native-supply-build30-6d91463d"
SUPPLY_COMMIT = "9309c4ccf70c9af4850e626a103747075979c3f7"
SUPPLY_TREE = "5c2333d513ca45c72ba81e72c850fce5f0cc3423"
ARCHIVE_BLOB = "51d0e0381d4c403fd6e85791c005ba53cf573028"
MANIFEST_BLOB = "917fcd50f859eb24453529d5c1e363bffb9e5289"
MANIFEST_SHA256 = "dac24f42c56d7160f6457388342d176fe1a310e433f4e197eaf89de0441f9a12"
MANIFEST_BYTES = 1169
ARCHIVE_BYTES = 89898489
ARCHIVE_SHA256 = "6d91463d6e28a1bcc6c1d5ba79ad88f5a8d1ba79d0e2e11e78b5fbd5520346ac"
PRODUCER_RUN = 39083752761
PRODUCER_SHA = "ce792982a30942e605fc935b733c5b41bef2736a"
PRODUCER_WORKFLOW = ".github/workflows/legado-ios-prototype.yml"
PRODUCER_WORKFLOW_BLOB = "acc22e4f49b24200f75f85b679564b4e8867d28c"
ORIGINAL_ARTIFACT = 12120530642
ORIGINAL_EXPIRY = "2026-10-25T00:59:12Z"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_context(source, environment=None):
    env = os.environ if environment is None else environment
    require(isinstance(source, str) and re.fullmatch(r"[0-9a-f]{40}", source) is not None,
            "Retained native supply requires a full checkout SHA")
    ref = "refs/tags/reader-legado-" + source[:7]
    expected = {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_SHA": source,
                "GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "tag",
                "GITHUB_REF": ref, "GITHUB_REF_NAME": ref.removeprefix("refs/tags/"),
                "GITHUB_WORKFLOW_REF": REPOSITORY + "/" + WORKFLOW + "@" + ref,
                "GITHUB_WORKFLOW_SHA": source}
    require(all(env.get(key) == value for key, value in expected.items()),
            "Retained native supply requires the actual ordinary-reader tag/workflow")
    require(all(isinstance(env.get(key), str) and re.fullmatch(r"[1-9][0-9]*", env[key])
                for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")),
            "Retained native supply requires the actual run and attempt")
    return expected | {key: env[key] for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")}


def validate_producer(state):
    expected = {"id": PRODUCER_RUN, "head_sha": PRODUCER_SHA,
                "path": PRODUCER_WORKFLOW, "name": "Legado iOS Prototype",
                "status": "completed", "conclusion": "success", "run_attempt": 1}
    require(isinstance(state, dict) and all(state.get(k) == v for k, v in expected.items()),
            "Retained native bytes require the original successful pinned producer")


def validate_manifest(raw):
    require(len(raw) == MANIFEST_BYTES and hashlib.sha256(raw).hexdigest() == MANIFEST_SHA256,
            "Retained native provenance bytes differ from the fixed supply")
    manifest = json.loads(raw)
    require(manifest.get("schemaVersion") == 1
            and manifest.get("purpose") == "exact-retained-native-supply-for-clean-reader-build30"
            and manifest.get("originalArtifactAvailability") == "expired"
            and manifest.get("nativeRuntimeRecompiled") is False
            and manifest.get("nativeZIP") == {"bytes": ARCHIVE_BYTES, "sha256": ARCHIVE_SHA256},
            "Retained native provenance has a different scope or archive")
    producer = manifest.get("nativeProducer", {})
    require(producer.get("runID") == PRODUCER_RUN and producer.get("sourceSHA") == PRODUCER_SHA
            and producer.get("runAttempt") == 1 and producer.get("workflowPath") == PRODUCER_WORKFLOW
            and producer.get("workflowBlob") == PRODUCER_WORKFLOW_BLOB
            and producer.get("artifact") == {"id": ORIGINAL_ARTIFACT,
                "name": "legado-zero-source-build", "size_in_bytes": ARCHIVE_BYTES,
                "digest": "sha256:" + ARCHIVE_SHA256, "expires_at": ORIGINAL_EXPIRY},
            "Retained native provenance does not identify the audited original artifact")
    return manifest


def validate_git_inventory(native):
    git = native.replay.git
    require(git("rev-list", "--parents", "-n", "1", SUPPLY_COMMIT) == SUPPLY_COMMIT,
            "Retained native supply must be the exact orphan commit")
    require(git("rev-parse", SUPPLY_COMMIT + "^{tree}") == SUPPLY_TREE,
            "Retained native supply tree differs")
    require(git("ls-tree", "-r", "--full-tree", SUPPLY_COMMIT).splitlines() == [
        "100644 blob " + MANIFEST_BLOB + "\tnative-provenance.json",
        "100644 blob " + ARCHIVE_BLOB + "\tnative.zip"],
        "Retained native supply contains unexpected paths, modes or blobs")
    require(git("cat-file", "-s", ARCHIVE_BLOB) == str(ARCHIVE_BYTES)
            and git("cat-file", "-s", MANIFEST_BLOB) == str(MANIFEST_BYTES),
            "Retained native supply object sizes differ")


def copy_checked_stream(source, destination, expected_bytes, expected_sha):
    started, count, digest = time.monotonic(), 0, hashlib.sha256()
    while block := source.read(1024 * 1024):
        count += len(block)
        require(count <= expected_bytes and time.monotonic() - started <= 600,
                "Retained native copy exceeded its fixed size or time budget")
        require(destination.write(block) == len(block), "Retained native write was incomplete")
        digest.update(block)
    require(count == expected_bytes and digest.hexdigest() == expected_sha,
            "Retained native ZIP bytes or SHA256 differ from the audited artifact")


def recover(native, api, source, destination):
    context = validate_context(source)
    require(api.repository == REPOSITORY, "Retained native supply repository differs")
    require((native.BASELINE_RUN, native.BASELINE_SHA, native.BASELINE_ARTIFACT,
             native.BASELINE_BYTES, native.BASELINE_DIGEST, native.SOURCE_WORKFLOW,
             native.SOURCE_WORKFLOW_BLOB) ==
            (PRODUCER_RUN, PRODUCER_SHA, ORIGINAL_ARTIFACT, ARCHIVE_BYTES, ARCHIVE_SHA256,
             PRODUCER_WORKFLOW, PRODUCER_WORKFLOW_BLOB),
            "Retained native supply does not match the existing native pin")
    validate_producer(api.run(PRODUCER_RUN))
    # The run's read-only token stays inside the established Git fetch helper.
    # The supply commit has no ancestry and is not part of the reader source.zip.
    native.replay.fetch_source(SUPPLY_COMMIT, api.token)
    validate_git_inventory(native)
    manifest_result = subprocess.run(["git", "cat-file", "blob", MANIFEST_BLOB],
        cwd=native.REPO, capture_output=True, timeout=30)
    require(manifest_result.returncode == 0, "Retained native provenance could not be read")
    manifest = validate_manifest(manifest_result.stdout)
    destination = native.replay.safe_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("xb") as output:
        process = subprocess.Popen(["git", "cat-file", "blob", ARCHIVE_BLOB],
            cwd=native.REPO, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            copy_checked_stream(process.stdout, output, ARCHIVE_BYTES, ARCHIVE_SHA256)
            require(process.wait(timeout=30) == 0, "Retained native blob read failed")
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=30)
    return {"nativeProducer": manifest["nativeProducer"],
            "retainedNativeSupply": {"repository": REPOSITORY, "refAtPublication": SUPPLY_REF,
                "commit": SUPPLY_COMMIT, "tree": SUPPLY_TREE, "archivePath": "native.zip",
                "archiveBlob": ARCHIVE_BLOB, "provenanceBlob": MANIFEST_BLOB,
                "provenanceSHA256": MANIFEST_SHA256, "bytes": ARCHIVE_BYTES,
                "sha256": ARCHIVE_SHA256, "originalArtifactAvailability": "expired",
                "exactOriginalBytesReused": True, "nativeRuntimeRecompiled": False,
                "currentWorkflowContext": context,
                "originalArtifactDownloaded": False,
                "scope": "Exact retained bytes from an isolated temporary Git supply commit; original producer and native input audits remain required."}}


class RetainedSupplyChecks(unittest.TestCase):
    def context(self):
        source = "a" * 40
        ref = "refs/tags/reader-legado-" + source[:7]
        return source, {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_SHA": source,
            "GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "tag", "GITHUB_REF": ref,
            "GITHUB_REF_NAME": ref.removeprefix("refs/tags/"),
            "GITHUB_WORKFLOW_REF": REPOSITORY + "/" + WORKFLOW + "@" + ref,
            "GITHUB_WORKFLOW_SHA": source, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}

    def test_actual_reader_context_is_required(self):
        source, env = self.context()
        self.assertEqual(validate_context(source, env)["GITHUB_SHA"], source)
        for key in env:
            for bad in (None, "", "wrong", "1\n"):
                with self.subTest(key=key, bad=bad), self.assertRaises(ValueError):
                    validate_context(source, env | {key: bad})

    def test_original_producer_success_and_identity_are_required(self):
        good = {"id": PRODUCER_RUN, "head_sha": PRODUCER_SHA, "path": PRODUCER_WORKFLOW,
                "name": "Legado iOS Prototype", "status": "completed", "conclusion": "success", "run_attempt": 1}
        validate_producer(good)
        for key in good:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_producer(good | {key: "wrong"})

    def test_changed_provenance_is_rejected(self):
        for raw in (b"", b"{}", b"x" * MANIFEST_BYTES, b"x" * (MANIFEST_BYTES + 1)):
            with self.subTest(size=len(raw)), self.assertRaises(ValueError):
                validate_manifest(raw)

    def test_exact_stream_is_copied_without_substituting_bytes(self):
        raw = b"owned-native-stream" * 100000
        target = io.BytesIO()
        copy_checked_stream(io.BytesIO(raw), target, len(raw), hashlib.sha256(raw).hexdigest())
        self.assertEqual(target.getvalue(), raw)

    def test_short_long_and_changed_streams_fail(self):
        raw = b"owned native"
        for supplied in (raw[:-1], raw + b"x", b"changed data"):
            with self.subTest(size=len(supplied)), self.assertRaises(ValueError):
                copy_checked_stream(io.BytesIO(supplied), io.BytesIO(), len(raw), hashlib.sha256(raw).hexdigest())

    def test_existing_destination_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "native.zip"
            path.write_bytes(b"existing-owned")
            with self.assertRaises(FileExistsError):
                path.open("xb")
            self.assertEqual(path.read_bytes(), b"existing-owned")


if __name__ == "__main__":
    import sys
    if sys.argv[1:] != ["--self-test"]:
        raise SystemExit("Use runtime-packaging.py restore-retained in the bound reader workflow.")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
