#!/usr/bin/env python3
"""Portable negative checks for the single reviewed reader-test evidence reuse."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("reader_test_reuse", Path(__file__).with_name("reader-test-reuse.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class ReaderTestReuseGuards(unittest.TestCase):
    def run_record(self):
        return {"id": check.RUN_ID, "head_sha": check.BASE_SHA, "run_attempt": check.ATTEMPT,
                "path": ".github/workflows/legado-reader.yml", "status": "completed", "conclusion": "failure",
                "repository": {"full_name": check.REPOSITORY},
                "head_repository": {"full_name": check.REPOSITORY}}

    def artifacts(self):
        return [{"id": record["id"], "name": record["name"], "size_in_bytes": record["bytes"],
                 "digest": record["digest"], "expired": False,
                 "workflow_run": {"id": check.RUN_ID, "head_sha": check.BASE_SHA}}
                for record in check.ARTIFACTS.values()]

    def jobs(self):
        def step(name, conclusion="success"):
            return {"name": name, "status": "completed", "conclusion": conclusion}
        return [
            {"id": 127249813487, "run_id": check.RUN_ID, "name": "position-regression", "status": "completed", "conclusion": "success",
             "steps": [step("Verify the fixed reader-position selection and result guards"),
                       step("Require the source-only reader position regressions before packaging"),
                       step("Preserve selected source, raw results and failure logs")]},
            {"id": 127268089982, "run_id": check.RUN_ID, "name": "reader", "status": "completed", "conclusion": "failure",
             "steps": [step("Verify the exact source tag and build the fresh ordinary JVM"),
                       step("Execute the three source-only Swift module-image diagnostics"),
                       step("Restore the exact retained pinned native VM after original artifact expiry"),
                       step("Resolve the installed Apple toolchain"),
                       step("Require the jimage-backed JNI product routes in three fresh Simulator hosts"),
                       step("Replace Simulator resources with the exact physical-device jimage runtime"),
                       step("Compile and package the actual main application with the local JVM", "failure"),
                       step("Preserve compilation, source and ordinary-payload evidence")]},
        ]

    def test_only_the_exact_reviewed_commit_message_marker_enables_reuse(self):
        self.assertFalse(check.detect_reuse("Repair Build 33 package audit"))
        self.assertTrue(check.detect_reuse("Repair package audit [reuse-reader-tests:42028850565]"))
        for message in ("[reuse-reader-tests:1]", "[reuse-reader-tests:42028850564]",
                        "[reuse-reader-tests:]", "[reuse-reader-tests:42028850565]\n[reuse-reader-tests:2]"):
            with self.subTest(message=message), self.assertRaises(ValueError):
                check.detect_reuse(message)

    def test_complete_git_diff_is_restricted_to_the_reviewed_five_files(self):
        allowed = {
            "scripts/reader-experience/clean-package-audit.py",
            "scripts/reader-experience/test-clean-package-audit.py",
            ".github/workflows/legado-reader.yml",
            "scripts/reader-experience/reader-test-reuse.py",
            "scripts/reader-experience/test-reader-test-reuse.py",
        }
        self.assertEqual(set(check.ALLOWED_CHANGES), allowed)
        check.validate_changes(sorted(allowed))
        for path in ("Modules/Features/Reader/CoreTextPagedView.swift",
                     "Tests/iOS/yuedu appTests/ReaderCoverPositionTests.swift",
                     "Packages/LegadoRuntime/jvm/build.gradle.kts", "Resources/Info.plist",
                     "Yuedu-Reader.xcodeproj/project.pbxproj", "scripts/reader-experience/build.sh",
                     "scripts/reader-experience/position-regression.py", "scripts/sim.sh",
                     "scripts/reader-experience/../reader-experience/clean-package-audit.py"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                check.validate_changes(sorted(allowed) + [path])

    def test_only_the_original_completed_failed_packaging_run_is_accepted(self):
        check.validate_run(self.run_record())
        for field, value in (("id", check.RUN_ID + 1), ("head_sha", "f" * 40),
                             ("run_attempt", check.ATTEMPT + 1), ("path", ".github/workflows/other.yml"),
                             ("status", "in_progress"), ("conclusion", "success"), ("conclusion", "cancelled"),
                             ("repository", {"full_name": "someone/else"})):
            record = self.run_record()
            record[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                check.validate_run(record)

    def test_the_exact_test_jobs_can_pass_before_the_packaging_failure(self):
        check.validate_jobs(self.jobs())
        for index in (0, 1):
            for field, value in (("id", 1), ("status", "in_progress"), ("steps", [])):
                jobs = self.jobs()
                jobs[index][field] = value
                with self.subTest(index=index, field=field), self.assertRaises(ValueError):
                    check.validate_jobs(jobs)
        for jobs in (self.jobs()[:1], self.jobs() + [copy.deepcopy(self.jobs()[0])]):
            with self.subTest(count=len(jobs)), self.assertRaises(ValueError):
                check.validate_jobs(jobs)

    def test_a_failed_skipped_or_cancelled_test_step_never_becomes_reusable(self):
        for index, step_index in ((0, 1), (1, 4)):
            for conclusion in ("failure", "skipped", "cancelled", None):
                jobs = self.jobs()
                jobs[index]["steps"][step_index]["conclusion"] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(ValueError):
                    check.validate_jobs(jobs)
        jobs = self.jobs()
        jobs[0]["conclusion"] = "failure"
        with self.assertRaises(ValueError):
            check.validate_jobs(jobs)

    def test_fixed_artifact_ids_digests_sizes_and_source_identity_are_required(self):
        check.validate_artifacts(self.artifacts())
        for index in (0, 1):
            for field, value in (("id", 1), ("name", "unrelated"), ("size_in_bytes", 1),
                                 ("digest", "sha256:" + "0" * 64), ("expired", True),
                                 ("workflow_run", {"id": check.RUN_ID + 1, "head_sha": check.BASE_SHA}),
                                 ("workflow_run", {"id": check.RUN_ID, "head_sha": "f" * 40})):
                artifacts = self.artifacts()
                artifacts[index][field] = value
                with self.subTest(index=index, field=field, value=value), self.assertRaises(ValueError):
                    check.validate_artifacts(artifacts)

    def test_missing_or_duplicate_artifacts_are_rejected(self):
        for artifacts in ([], self.artifacts()[:1], self.artifacts() + [copy.deepcopy(self.artifacts()[0])]):
            with self.subTest(count=len(artifacts)), self.assertRaises(ValueError):
                check.validate_artifacts(artifacts)

    def test_hashes_bind_the_downloaded_raw_evidence_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = b'{"testNodes":[]}\n'
            (root / "tests.json").write_bytes(raw)
            hashes = {"tests.json": hashlib.sha256(raw).hexdigest()}
            check.check_hashes(root, hashes)
            (root / "tests.json").write_bytes(raw + b"changed")
            with self.assertRaises(ValueError):
                check.check_hashes(root, hashes)
            with self.assertRaises((ValueError, OSError)):
                check.check_hashes(root, {"missing.json": hashes["tests.json"]})

    def write_json(self, path, value):
        path.write_text(json.dumps(value), encoding="utf-8")

    def sha(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def native_evidence(self, root):
        for name in ("build-settings.json", "native-exports.json"):
            self.write_json(root / name, {})
        host = {"sourceCommit": check.BASE_SHA, "nativeRequired": True, "localMode": True,
                "configuration": "Debug", "settingsSHA256": self.sha(root / "build-settings.json"),
                "nativeExportsSHA256": self.sha(root / "native-exports.json"), "ordinaryJarSHA256": "a" * 64}
        self.write_json(root / "host.json", host)
        self.write_json(root / "source-restored.json", {"sourceCommit": check.BASE_SHA, "trackedSourceRestored": True})
        host_hash = self.sha(root / "host.json")
        cases = []
        for name, method in check.native.CASES.items():
            summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
                       "expectedFailures": 0, "devicesAndConfigurations": [
                           {"passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
            tree = {"testNodes": [{"nodeType": "Test Suite", "result": "Passed", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": method, "result": "Passed"}]}]}
            self.write_json(root / (name + "-summary.json"), summary)
            self.write_json(root / (name + "-tests.json"), tree)
            (root / (name + ".log")).write_text("** TEST SUCCEEDED **\n", encoding="utf-8")
            (root / (name + "-lifecycle.log")).write_text("shutdown then boot\n", encoding="utf-8")
            record = {"sourceCommit": check.BASE_SHA, **check.native.verify_case(summary, tree, method),
                      "summarySHA256": self.sha(root / (name + "-summary.json")),
                      "testsSHA256": self.sha(root / (name + "-tests.json")),
                      "logSHA256": self.sha(root / (name + ".log")),
                      "lifecycleLogSHA256": self.sha(root / (name + "-lifecycle.log")), "hostSHA256": host_hash}
            self.write_json(root / (name + "-result.json"), record)
            cases.append(record)
        aggregate = {"sourceCommit": check.BASE_SHA, "passed": True, "passedTests": 3,
                     "failedTests": 0, "skippedTests": 0, "passedMethods": list(check.native.CASES.values()),
                     "hostSHA256": host_hash, "cases": cases}
        self.write_json(root / "result.json", aggregate)

    def rehash_native_case(self, root, name, key, filename):
        record = json.loads((root / (name + "-result.json")).read_bytes())
        record[key] = self.sha(root / filename)
        self.write_json(root / (name + "-result.json"), record)
        aggregate = json.loads((root / "result.json").read_bytes())
        aggregate["cases"] = [record if item["passedMethod"] == record["passedMethod"] else item
                              for item in aggregate["cases"]]
        self.write_json(root / "result.json", aggregate)

    def test_native_reuse_revalidates_the_three_raw_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.native_evidence(root)
            result = check.verify_native(root)
            self.assertEqual(result["executions"], 3)
            self.assertEqual(result["methods"], list(check.native.CASES.values()))

    def test_native_skip_failure_or_wrong_identity_is_rejected_even_with_matching_hashes(self):
        for mutation in ("skipped", "failed", "wrong-identity", "duplicate-case", "failed-verdict"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.native_evidence(root)
                name = next(iter(check.native.CASES))
                if mutation in ("skipped", "failed"):
                    filename = name + "-summary.json"
                    summary = json.loads((root / filename).read_bytes())
                    summary["skippedTests" if mutation == "skipped" else "failedTests"] = 1
                    self.write_json(root / filename, summary)
                    self.rehash_native_case(root, name, "summarySHA256", filename)
                elif mutation in ("wrong-identity", "duplicate-case"):
                    filename = name + "-tests.json"
                    tree = json.loads((root / filename).read_bytes())
                    cases = tree["testNodes"][0]["children"]
                    if mutation == "wrong-identity":
                        cases[0]["nodeIdentifier"] = "Unrelated/test()"
                    else:
                        cases.append(copy.deepcopy(cases[0]))
                    self.write_json(root / filename, tree)
                    self.rehash_native_case(root, name, "testsSHA256", filename)
                else:
                    filename = name + ".log"
                    (root / filename).write_text("** TEST SUCCEEDED **\n** TEST FAILED **\n", encoding="utf-8")
                    self.rehash_native_case(root, name, "logSHA256", filename)
                with self.assertRaises(ValueError):
                    check.verify_native(root)

    def test_native_aggregate_cannot_replace_source_or_host_acceptance(self):
        for filename, field, value in (("result.json", "sourceCommit", "f" * 40),
                                       ("result.json", "passed", False),
                                       ("result.json", "skippedTests", 1),
                                       ("host.json", "nativeRequired", False),
                                       ("source-restored.json", "sourceCommit", "f" * 40),
                                       ("source-restored.json", "trackedSourceRestored", False)):
            with self.subTest(filename=filename, field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.native_evidence(root)
                record = json.loads((root / filename).read_bytes())
                record[field] = value
                self.write_json(root / filename, record)
                with self.assertRaises(ValueError):
                    check.verify_native(root)

    def position_evidence(self, root):
        selected = check.position.inventory()
        blobs = {record["path"]: (check.REPO / record["path"]).read_bytes() for record in selected["sourceInputs"]}
        for path, raw in blobs.items():
            destination = root / "sources" / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)
        overlay_records = {}
        for key, path in (("projectOverlay", "Yuedu-Reader.xcodeproj/project.pbxproj"), ("infoOverlay", "Info.plist")):
            blobs[path] = (check.REPO / path).read_bytes()
            overlay_records[key] = {"path": path, "originalSHA256": hashlib.sha256(blobs[path]).hexdigest()}
        overlay_records["infoOverlay"]["sourceCommitStamped"] = check.BASE_SHA
        overlays = {"sourceCommit": check.BASE_SHA, **overlay_records,
                    "syntheticConfiguration": {"syntheticConfiguration": True, "upstreamCredentialsUsed": False}}
        self.write_json(root / "selection.json", {"sourceCommit": check.BASE_SHA, **selected})
        self.write_json(root / "overlays.json", overlays)
        summary = {"totalTestCount": 86, "passedTests": 86, "failedTests": 0, "skippedTests": 0,
                   "expectedFailures": 0, "devicesAndConfigurations": [
                       {"passedTests": 89, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        cases = []
        for method, executions in selected["expectedExecutionsByMethod"].items():
            node = {"nodeType": "Test Case", "nodeIdentifier": method, "result": "Passed"}
            if executions > 1:
                node["children"] = [{"nodeType": "Arguments", "name": str(value), "result": "Passed"}
                                    for value in check.position.ARGUMENTS[method]]
            cases.append(node)
        tree = {"testNodes": [{"nodeType": "Test Suite", "result": "Passed", "children": cases}]}
        self.write_json(root / "summary.json", summary)
        self.write_json(root / "tests.json", tree)
        self.write_json(root / "build-settings.json", [])
        (root / "tests.log").write_text("** TEST SUCCEEDED **\n", encoding="utf-8")
        (root / "test-exit-status.txt").write_text("0\n", encoding="utf-8")
        counts = check.native.smoke.verify_summary(summary, 86, 89)
        verified = check.position.verify_tree(tree, selected["expectedExecutionsByMethod"])
        self.write_json(root / "result.json", {"sourceCommit": check.BASE_SHA, "passed": True, "sourceOnly": True,
                        **counts, **verified, "artifactSHA256": {name: self.sha(root / name) for name in
                        ("selection.json", "overlays.json", "tests.log", "summary.json", "tests.json", "build-settings.json")}})
        return blobs

    def rehash_position(self, root, filename):
        record = json.loads((root / "result.json").read_bytes())
        record["artifactSHA256"][filename] = self.sha(root / filename)
        self.write_json(root / "result.json", record)

    def test_position_reuse_checks_all_raw_methods_executions_and_original_blobs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            blobs = self.position_evidence(root)
            result = check.verify_position(root, blobs.__getitem__)
            self.assertEqual(result, {"methods": 86, "executions": 89, "newRegressionExecutions": 10})

    def test_position_execution_changes_fail_even_when_raw_file_hashes_are_updated(self):
        for mutation in ("skip-summary", "failed-tree", "duplicate-method", "failed-log"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                blobs = self.position_evidence(root)
                if mutation == "skip-summary":
                    filename = "summary.json"
                    value = json.loads((root / filename).read_bytes())
                    value["devicesAndConfigurations"][0]["skippedTests"] = 1
                    self.write_json(root / filename, value)
                elif mutation in ("failed-tree", "duplicate-method"):
                    filename = "tests.json"
                    value = json.loads((root / filename).read_bytes())
                    cases = value["testNodes"][0]["children"]
                    if mutation == "failed-tree":
                        cases[0]["result"] = "Failed"
                    else:
                        cases.append(copy.deepcopy(cases[0]))
                    self.write_json(root / filename, value)
                else:
                    filename = "tests.log"
                    (root / filename).write_text("** TEST SUCCEEDED **\n** BUILD FAILED **\n", encoding="utf-8")
                self.rehash_position(root, filename)
                with self.assertRaises(ValueError):
                    check.verify_position(root, blobs.__getitem__)

    def test_position_source_copies_and_original_overlay_blobs_cannot_drift(self):
        for path in ("Modules/Features/Reader/CoreTextPagedView.swift", "Info.plist"):
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                blobs = self.position_evidence(root)
                blobs[path] += b"changed"
                with self.assertRaises(ValueError):
                    check.verify_position(root, blobs.__getitem__)


if __name__ == "__main__":
    unittest.main()
