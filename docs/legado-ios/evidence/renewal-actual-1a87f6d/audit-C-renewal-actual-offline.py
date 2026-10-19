"""Audit original C renewal artifacts offline; never execute HEAD result()."""
from pathlib import Path, PurePosixPath
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor
import ast
import hashlib
import json
import plistlib
import re
import subprocess
import zipfile

ROOT = Path("F:/yuedu-reader")
BASE = ROOT / ".build/renewal-discovery"
RAW = BASE / "C-renewal-actual-independent-audit-raw"
DEST = BASE / "C-renewal-actual-independent-audit.json"
ARTIFACT = ROOT / ".build/b12-2e93221697"
WORK = ARTIFACT / "reader-renewal-probe"
C = "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06"
A = "a76d380fdc108db83be68961905ee49edd209571"
RELEASE = ROOT / "docs/legado-ios/evidence/reader-build12-a76d380"


def strict(raw):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            assert key not in value, "Duplicate JSON key: " + key
            value[key] = item
        return value
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def meta(path):
    raw = path.read_bytes()
    return {"path": str(path), "bytes": len(raw), "sha256": sha(raw)}


def pin(path, expected, size=None):
    found = meta(path)
    assert found["sha256"] == expected and (size is None or found["bytes"] == size), found
    return found


def write(path, value):
    with path.open("xb") as stream:
        stream.write((json.dumps(value, indent=2) + "\n").encode("utf-8"))


def main():
    assert not RAW.exists() and not DEST.exists()
    RAW.mkdir()
    commands = []
    def git_blob(spec):
        label, index, source, path = spec
        argv = ["git", "show", source + ":" + path]
        started = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(argv, cwd=ROOT, capture_output=True)
        out, err = RAW / (label + "-" + str(index).zfill(2) + ".stdout.bin"), RAW / (label + "-" + str(index).zfill(2) + ".stderr.bin")
        out.write_bytes(result.stdout)
        err.write_bytes(result.stderr)
        commands.append({"name": label + "-" + str(index).zfill(2), "argv": argv, "cwd": str(ROOT),
                         "startedAtUTC": started, "exitCode": result.returncode,
                         "stdout": meta(out), "stderr": meta(err)})
        assert result.returncode == 0 and result.stderr == b""
        return (label, path), result.stdout

    retrieval_path = BASE / "C-completed-job-evidence-20261019T1640/retrieval-record.json"
    retrieval_meta = pin(retrieval_path, "83c9de8551b3a13a5619350fb89a2ac5d717289632e64edfa604f254d380c9f0")
    retrieval = strict(retrieval_path.read_bytes())
    assert retrieval["sourceCommit"] == C and retrieval["runID"] == 39281084369
    assert retrieval["actualJobID"] == 118155310210 and retrieval["actualJobStatus"] == "completed" and retrieval["actualJobConclusion"] == "success"
    assert retrieval["savedAggregateRunStatus"] == "in_progress" and retrieval["aggregateRunCompletionInferred"] is False
    assert retrieval["newRunJobsGETs"] == 0 and retrieval["errors"] == []
    prior = retrieval["priorRunAndJobEvidence"]
    for item in prior:
        pin(Path(item["path"]), item["sha256"], item["bytes"])
    run = strict(Path(next(x["path"] for x in prior if x["path"].endswith("run.raw.json"))).read_bytes())
    jobs = strict(Path(next(x["path"] for x in prior if x["path"].endswith("jobs.raw.json"))).read_bytes())
    assert run["head_sha"] == C and run["head_branch"] == "reader-renewal-1a87f6d"
    assert run["status"] == "in_progress" and run["conclusion"] is None
    assert run["path"] == ".github/workflows/reader-renewal-probe.yml" and run["event"] == "push"
    assert len(jobs["jobs"]) == jobs["total_count"] == 1
    job = jobs["jobs"][0]
    assert job["id"] == 118155310210 and job["run_id"] == run["id"] == 39281084369 and job["head_sha"] == C
    assert job["status"] == "completed" and job["conclusion"] == "success"
    assert len(job["steps"]) == 11 and all(s["status"] == "completed" and s["conclusion"] == "success" for s in job["steps"])
    artifact_info = retrieval["artifacts"][0]
    assert len(retrieval["artifacts"]) == 1 and artifact_info["githubArtifactDigestMatched"] is True
    archive = pin(Path(artifact_info["archivePath"]), "bfa6496f86183fced6a95125bfe6ac0faa278971fe09b95593933919983eebcc", 2260954)
    listing_info = retrieval["artifactListHTTP"]["rawBody"]
    pin(Path(listing_info["path"]), listing_info["sha256"], listing_info["bytes"])
    listing = strict(Path(listing_info["path"]).read_bytes())["artifacts"]
    assert len(listing) == 1 and listing[0]["id"] == 12203686066
    assert listing[0]["size_in_bytes"] == archive["bytes"] and listing[0]["digest"] == "sha256:" + archive["sha256"]
    members = []
    with zipfile.ZipFile(archive["path"]) as zipped:
        entries = zipped.infolist()
        assert len(entries) < 30000 and sum(e.file_size for e in entries) < 3 * 1024**3
        seen = set()
        for entry in entries:
            path = PurePosixPath(entry.filename)
            assert not path.is_absolute() and ".." not in path.parts
            assert not any(char in entry.filename for char in (":", "\\", "\x00"))
            assert not entry.flag_bits & 1 and (entry.external_attr >> 16) & 0o170000 != 0o120000
            assert entry.file_size <= 512 * 1024**2 and entry.filename.rstrip("/").casefold() not in seen
            seen.add(entry.filename.rstrip("/").casefold())
            if not entry.is_dir():
                target = ARTIFACT.joinpath(*path.parts)
                assert target.resolve().is_relative_to(ARTIFACT.resolve())
                raw = zipped.read(entry)
                assert target.read_bytes() == raw
                members.append({"path": entry.filename, "bytes": len(raw), "sha256": sha(raw)})
    write(RAW / "archive-members.json", {"allExtractedBytesMatchOriginalZIP": True, "files": members})

    result = strict((WORK / "result.json").read_bytes())
    inputs = strict((WORK / "source-inputs.json").read_bytes())
    audit = strict((WORK / "overlays.json").read_bytes())
    assert (WORK / "result.log").read_bytes() == (WORK / "result.json").read_bytes()
    assert (WORK / "prepare.log").read_bytes() == (WORK / "source-inputs.json").read_bytes()
    assert result["sourceCommit"] == inputs["sourceCommit"] == audit["sourceCommit"] == C
    assert result["sourceTag"] == inputs["sourceTag"] == "reader-renewal-1a87f6d"
    assert result["schemaVersion"] == 2 and result["status"] == "passed"
    assert result["sourceInputs"] == inputs["sourceInputs"] and result["sourceOverlays"] == audit
    assert len(inputs["sourceInputs"]) == len({x["path"] for x in inputs["sourceInputs"]}) == 29
    for name, expected in result["evidenceSHA256"].items():
        pin(WORK / name, expected)
    assert len(result["evidenceSHA256"]) == 11
    specs = [(label, index, source, item["path"]) for label, source in (("C", C), ("A", A))
             for index, item in enumerate(inputs["sourceInputs"])]
    with ThreadPoolExecutor(max_workers=4) as executor:
        blobs = dict(executor.map(git_blob, specs))
    source_comparison = []
    for item in inputs["sourceInputs"]:
        c_raw, a_raw = blobs[("C", item["path"])], blobs[("A", item["path"])]
        assert len(c_raw) == item["bytes"] and sha(c_raw) == item["sha256"]
        source_comparison.append({**item, "actualCBlobHashMatched": True, "sameABytes": a_raw == c_raw,
                                  "ASHA256": sha(a_raw)})
    different = [x["path"] for x in source_comparison if not x["sameABytes"]]
    assert different == ["scripts/reader-experience/smoke-tools.py"]

    helper_path = "scripts/reader-experience/renewal-probe-tools.py"
    smoke_path = "scripts/reader-experience/smoke-tools.py"
    helper_tree = ast.parse(blobs[("C", helper_path)].decode("utf-8"))
    smoke_tree = ast.parse(blobs[("C", smoke_path)].decode("utf-8"))
    selected_names = {"TAG_PREFIX", "UNIT_SUITE", "DISCOVERY_SUITE", "UI_SUITE", "LANGUAGES", "BONJOUR_SERVICES", "USAGE_KEY", "EXPECTED_CASES", "SOURCE_INPUTS"}
    selected = [node for node in helper_tree.body if (isinstance(node, ast.Assign) and any(
        isinstance(t, ast.Name) and t.id in selected_names for t in node.targets)) or
        (isinstance(node, ast.FunctionDef) and node.name == "verify_cases")]
    selected.extend(node for node in smoke_tree.body if isinstance(node, ast.FunctionDef) and node.name == "verify_summary")
    ns = {"json": json}
    exec(compile(ast.Module(body=selected, type_ignores=[]), "fixed-C-pure-verifiers", "exec"), ns)
    assert list(ns["SOURCE_INPUTS"]) == [x["path"] for x in inputs["sourceInputs"]]
    assert inputs["intendedTests"] == {key: sorted(value) for key, value in ns["EXPECTED_CASES"].items()}
    group_results = {}
    common_device = None
    for group, count in (("unit", 8), ("discovery", 13), ("ui", 1)):
        summary = strict((WORK / (group + "-summary.json")).read_bytes())
        tree = strict((WORK / (group + "-tests.json")).read_bytes())
        ns["verify_summary"](summary, count, count)
        replay = {**ns["verify_summary"](summary, count), **ns["verify_cases"](tree, group)}
        assert replay == result["targetedTests"][group]
        assert summary["result"] == "Passed" and summary["testFailures"] == []
        assert len(tree["testNodes"]) == 1 and tree["testNodes"][0]["nodeType"] == "Test Plan"
        target = "yuedu appUITests" if group == "ui" else "yuedu appTests"
        bundle = "UI test bundle" if group == "ui" else "Unit test bundle"
        leaves, bundles, node_counts = [], [], {}
        def visit(node, inside=False, root=False):
            assert isinstance(node, dict)
            kind = node.get("nodeType")
            assert kind in ("Test Plan", bundle, "Test Suite", "Test Case")
            node_counts[kind] = node_counts.get(kind, 0) + 1
            children = node.get("children", [])
            assert type(children) is list and node.get("result") == "Passed"
            if kind == "Test Case":
                assert inside and not children
                name = node["nodeIdentifier"].removesuffix("()")
                name = name.removeprefix(target + "/")
                assert name in ns["EXPECTED_CASES"][group] and name not in leaves
                assert "/" + target.replace(" ", "%20") + "/" in node["nodeIdentifierURL"]
                leaves.append(name)
            else:
                assert children
                if kind == "Test Plan": assert root
                if kind == bundle:
                    assert not inside and node["name"] == target
                    bundles.append(node)
                for child in children: visit(child, inside or kind == bundle)
        visit(tree["testNodes"][0], root=True)
        assert len(bundles) == 1 and len(leaves) == count and set(leaves) == ns["EXPECTED_CASES"][group]
        device = summary["devicesAndConfigurations"][0]["device"]
        assert tree["devices"] == [device]
        assert tree["testPlanConfigurations"] == [summary["devicesAndConfigurations"][0]["testPlanConfiguration"]]
        assert device["platform"] == "iOS Simulator" and device["architecture"] == "arm64"
        assert result["simulatorDestination"] == "id=" + device["deviceId"]
        common_device = device if common_device is None else common_device
        assert common_device == device and device["osVersion"] == "26.2" and device["osBuildNumber"] == "23C54"
        raw_log = (WORK / (group + "-tests.log")).read_text(encoding="utf-8")
        assert raw_log.count("** TEST SUCCEEDED **") == 1
        assert "** TEST FAILED **" not in raw_log and "** BUILD FAILED **" not in raw_log
        assert not re.search(r"^/Users/.*\berror:", raw_log, re.M)
        if group != "ui":
            assert re.search(r"Test run with " + str(count) + r" tests in 1 suite passed", raw_log)
        else:
            assert raw_log.count("Test Case '-[yuedu_appUITests.SelfRenewalProbeUITests testReadOnlyConnectionProbeCanExportWithoutClaimingRenewal]' passed") == 1
        bundle_path = WORK / (group + ".xcresult")
        info = plistlib.loads((bundle_path / "Info.plist").read_bytes())
        assert info and any(p.is_file() for p in (bundle_path / "Data").rglob("*"))
        group_results[group] = {"actualMethods": count, "actualExecutions": count, "failures": 0, "skips": 0,
                                "expectedFailures": 0, "passedExactIdentities": sorted(leaves), "closedNodeCounts": node_counts,
                                "sourceCVerifyCasesAndSummaryReplayed": True, "additionalClosedBundleLeafGatePassed": True,
                                "summary": meta(WORK / (group + "-summary.json")), "tree": meta(WORK / (group + "-tests.json")),
                                "rawLog": meta(WORK / (group + "-tests.log")), "finalXcodebuildVerdict": "TEST SUCCEEDED",
                                "xcresultInfo": meta(bundle_path / "Info.plist"), "xcresultFiles": sum(p.is_file() for p in bundle_path.rglob("*"))}
    outer = (ARTIFACT / "ci-logs/reader-renewal.log").read_text(encoding="utf-8")
    assert outer.count("xcodebuild status: 0; wrapper verdict stop: false") == 3
    portable = []
    for name, count in (("reader-renewal-existing-guards.log", 24), ("reader-renewal-guards.log", 16)):
        path = ARTIFACT / "ci-logs" / name
        text = path.read_text(encoding="utf-8")
        assert len(re.findall(r"^test_.* \.\.\. ok$", text, re.M)) == count
        assert re.search(r"^Ran " + str(count) + r" tests in .+\n\nOK$", text.strip(), re.M)
        portable.append({"methods": count, "rawLog": meta(path), "rerunByReviewer": False})

    config_tree = ast.parse(blobs[("C", "scripts/reader-experience/stage-config.py")].decode("utf-8"))
    constants = [n for n in config_tree.body if isinstance(n, ast.Assign) and any(
        isinstance(t, ast.Name) and t.id in ("LOCAL_FLAGS", "GOOGLE_CLIENT", "GOOGLE_REVERSED") for t in n.targets)]
    cns = {}
    exec(compile(ast.Module(body=constants, type_ignores=[]), "fixed-C-local-constants", "exec"), cns)
    original_info = blobs[("C", "Info.plist")]
    info = plistlib.loads(original_info)
    info.update(cns["LOCAL_FLAGS"])
    info.update(GatewayBaseURL="", GIDClientID=cns["GOOGLE_CLIENT"], YueduExperienceSourceCommit=C, GitCommitSHA=C[:7])
    for entry in info.get("CFBundleURLTypes", []):
        entry["CFBundleURLSchemes"] = [cns["GOOGLE_REVERSED"] if name.startswith("com.googleusercontent.apps.") else name for name in entry.get("CFBundleURLSchemes", [])]
    overlay_bytes = plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False)
    assert sha(original_info) == audit["infoOverlay"]["originalSHA256"]
    assert sha(overlay_bytes) == audit["infoOverlay"]["overlaySHA256"] and audit["infoOverlay"]["sourceCommitStamped"] == C
    assert audit["projectOverlay"]["replacementCount"] == 0 and audit["projectOverlay"]["expectedTrackedOverlay"] is False
    assert audit["projectOverlay"]["originalSHA256"] == audit["projectOverlay"]["overlaySHA256"] == sha(blobs[("C", "Yuedu-Reader.xcodeproj/project.pbxproj")])
    assert audit["expectedTrackedChanges"] == ["Info.plist"]
    assert strict((WORK / "info-overlay.json").read_bytes()) == audit["infoOverlay"]
    assert strict((WORK / "project-overlay.json").read_bytes()) == audit["projectOverlay"]
    settings = strict((WORK / "build-settings.json").read_bytes())
    actual = [e["buildSettings"] for e in settings if e.get("target") == "yuedu app"]
    assert len(actual) == 1
    for name, expected in {"CONFIGURATION": "Debug", "SWIFT_VERSION": "5.0", "PLATFORM_NAME": "iphonesimulator", "PRODUCT_BUNDLE_IDENTIFIER": "local.zhoujianjia.legado-reader", "SDK_VERSION": "26.2"}.items():
        assert actual[0][name] == expected
    assert result["developerDirectory"] == "/Applications/Xcode_26.2.0.app/Contents/Developer"
    assert (WORK / "xcode-version.log").read_text().strip() == "Xcode 26.2\nBuild version 17C52"
    metadata = result["builtDiscoveryMetadata"]
    assert metadata["bonjourServices"] == list(ns["BONJOUR_SERVICES"]) and metadata["fallbackMatchesBothSourceConfigurations"] is True
    assert info["NSBonjourServices"] == list(ns["BONJOUR_SERVICES"])
    localizations = metadata["localizedUsageDescriptions"]
    assert [x["language"] for x in localizations] == list(ns["LANGUAGES"])
    for entry in localizations:
        assert entry["sourceSHA256"] == sha(blobs[("C", "Resources/" + entry["language"] + ".lproj/InfoPlist.strings")])
        assert entry["usageDescriptionMatchesSource"] is True and re.fullmatch("[0-9a-f]{64}", entry["builtSHA256"])
    assert not any(PurePosixPath(x["path"]).suffix in (".ipa", ".dylib") or ".app/" in x["path"] for x in members)
    for key in ("ipaGenerated", "ipaUploaded", "appleAccountUsed", "pairingRecordUsed", "iphoneTransportVerified", "physicalDeviceValidationPassed", "serviceIdentityVerified", "selfRenewalVerified", "unattendedRenewalVerified"):
        assert result[key] is False
    assert result["runtimeSourceOnly"] is True and result["computerPoweredOff"] == result["companionAppsAbsent"] == "notMeasured"

    scope_path = RELEASE / "source-scope/build12-A-C-diagnostic-source-scope-review.json"
    scope_meta = pin(scope_path, "8f1064d97b340b92b1960dab95cedd56b0ca893a1e919cf99cdcf7911ed3bc9a")
    scope = strict(scope_path.read_bytes())
    scope_archive = strict((RELEASE / "source-scope/archive-record.json").read_bytes())
    raw_scope_archive = pin(RELEASE / "source-scope/original-static-review-raw-evidence.zip", scope_archive["rawArchiveSHA256"])
    with zipfile.ZipFile(raw_scope_archive["path"]) as archive_reader:
        assert {x.filename for x in archive_reader.infolist() if not x.is_dir()} == {x["path"] for x in scope_archive["rawMembers"]}
        for item in scope_archive["rawMembers"]:
            data = archive_reader.read(item["path"])
            assert len(data) == item["bytes"] and sha(data) == item["sha256"]
    assert scope["AReleaseSource"] == A and scope["CDiagnosticSource"] == C
    assert scope["sourceInputDeclarations"]["exactByteMatches"] == 28
    projection = scope["smokeImportedProjection"]
    assert projection["allReachableRawFunctionsAndASTEqual"] and projection["allExistingImportTimeNodesRawAndASTPreserved"]
    a_smoke = blobs[("A", smoke_path)].decode("utf-8")
    c_smoke = blobs[("C", smoke_path)].decode("utf-8")
    a_functions = {n.name: n for n in ast.parse(a_smoke).body if isinstance(n, ast.FunctionDef)}
    c_functions = {n.name: n for n in ast.parse(c_smoke).body if isinstance(n, ast.FunctionDef)}
    for name in projection["transitiveFunctionClosure"]:
        assert ast.get_source_segment(a_smoke, a_functions[name]) == ast.get_source_segment(c_smoke, c_functions[name])
        assert ast.dump(a_functions[name]) == ast.dump(c_functions[name])
    release_audits = []
    for original in scope["existingReleaseAudits"]:
        path = RELEASE / Path(original["path"]).name
        identity = pin(path, original["sha256"], original["bytes"])
        record = strict(path.read_bytes())
        assert record["sourceCommit"] == A and record.get("issues") == []
        assert record.get("passed", record.get("staticAuditPassed")) is True
        release_audits.append({"kind": original["kind"], **identity, "passed": True, "scope": original["scope"], "packageReauditPerformed": False})
    manifest = strict((RELEASE / "build-manifest.json").read_bytes())
    assert manifest["sourceCommit"] == A
    core = strict((RELEASE / "build12-actual-core-a76d380.json").read_bytes())
    assert core["ipaSHA256"] == manifest["ipaSHA256"] and core["ipaBytes"] == manifest["ipaBytes"]
    assert core["buildManifestSHA256"] == meta(RELEASE / "build-manifest.json")["sha256"]
    commands.sort(key=lambda x: x["name"])
    write(RAW / "actual-read-only-commands.json", commands)
    write(RAW / "source-input-comparison.json", {"CSourceInputsMatched": 29, "AWholeFileMatches": 28,
          "wholeFileDifferences": different, "comparison": source_comparison,
          "tenReachableSmokeFunctionsRawAndASTEqual": True})
    report = {
        "schemaVersion": 1, "kind": "independent-offline-audit-of-actual-C-renewal-probe-evidence",
        "auditedAtUTC": datetime.now(timezone.utc).isoformat(), "auditor": "/root/renewal_discovery_ui",
        "status": "passed-for-actual-C-read-only-diagnostic-test-scope", "unresolvedBlockingFindings": [],
        "sourceCommit": C, "sourceTag": "reader-renewal-1a87f6d", "runID": 39281084369,
        "job": {"id": 118155310210, "URL": job["html_url"], "status": "completed", "conclusion": "success", "all11StepsCompletedSuccess": True},
        "aggregateRun": {"savedStatus": "in_progress", "savedConclusion": None, "successfulCompletionInferred": False,
                         "conflictPreserved": True, "originalAPIUnmodified": True},
        "retrieval": retrieval_meta, "originalArtifact": archive, "archiveMemberCount": len(members),
        "allOriginalZIPMembersSafelyComparedToExtractedBytes": True,
        "result": meta(WORK / "result.json"), "resultLogByteIdentical": True, "sourceInputs": meta(WORK / "source-inputs.json"),
        "groups": group_results, "actualSwiftOrXCTestMethods": 22, "actualExecutions": 22,
        "device": common_device, "Xcode": {"version": "26.2", "build": "17C52", "SDKVersion": "26.2", "configuration": "Debug"},
        "actualPortablePreflight": portable,
        "localizationAndShellCheck": "The fixed-C guard step executes localization and shell syntax checks after portable suites and is actually completed/success. Separate localization stdout was not retained in this artifact; no new localization check was rerun.",
        "sourceBinding": {"all29InputBytesAndHashesMatchFixedCGitBlobs": True, "sourceStampConsistentAcrossInputResultOverlay": True,
                          "workingTreeHEADUsedAsC": False, "fixedCPureVerifySummaryAndVerifyCasesOnlyReplayed": True,
                          "currentGitHEADResultFunctionExecuted": False},
        "overlays": {"InfoOriginalGitBytesAndReconstructedAfterHashMatch": True,
                     "sourceInfoOverlaySHA256": sha(overlay_bytes), "projectReplacementCount": 0,
                     "projectOriginalAndAfterBytesMatchFixedC": True, "onlyDeclaredTrackedChange": "Info.plist",
                     "standaloneOverlayRecordsEqualResultAndAudit": True},
        "builtHostBoundary": {"builtAppIncluded": False, "builtInfoOrLocalizedFilesReReadOffline": False,
                              "builtInfoSHA256RecordedByRunner": result["testedInfoSHA256"],
                              "builtMetadataReportedByRunner": metadata,
                              "actualResultHelperRanOnCI": True,
                              "basis": "Fixed-C result() source performs built local-info/source-stamp/Bonjour/privacy/five-localization/synthetic-config/no-JVM checks before writing result.json. Actual source-bound job and execution step succeeded and original result/log are byte-identical. The app bytes are deliberately absent, so offline hash/Info re-execution is impossible and is not claimed."},
        "AReleaseAndNarrowMapping": {"releaseSource": A, "releaseIPAHash": manifest["ipaSHA256"], "releaseIPABytes": manifest["ipaBytes"],
                                     "existingActualThreeAuditsRehashed": release_audits, "packageAuditsRerun": False,
                                     "narrowScopeReview": scope_meta, "itsRawArchive": raw_scope_archive,
                                     "sameWholeSourceInputFiles": 28, "wholeInputFileCount": 29,
                                     "differentWholeHelper": "scripts/reader-experience/smoke-tools.py",
                                     "relevantTenImportedHelperRawAndASTEqualRechecked": True,
                                     "completeAppSourceOrBinaryEquivalent": False,
                                     "opinionSupportsExplicitRootNarrowDiagnosticHandoffMapping": True,
                                     "opinion": "The actual C 8/13/UI1 gates and successful preflight close the runtime prerequisites previously left open for the unchanged narrow diagnostic projection. Together with the three actual A package audits, they are sufficient evidence for root to explicitly map only this read-only diagnostic test coverage to the A build12 package for a user device diagnostic handoff. This is a scoped source-mapping exception, not same-source, whole-app or Release-binary runtime acceptance. Keep all C result fingerprints C-bound and all delivered IPA/manifest/source hashes A-bound; state this exception in the handoff."},
        "exclusions": {"AReleaseIPAExecuted": False, "physicalDeviceVerified": False, "serviceIdentityVerified": False,
                       "signingInstallationOrRenewalVerified": False, "automaticSelfRenewalImplementedOrVerified": False,
                       "fullAppFontPositionFirestoreAccepted": False, "fullLegadoCompatibilityAccepted": False,
                       "computerPoweredOff": "notMeasured", "companionAppsAbsent": "notMeasured"},
        "performed": {"offlineReadOnlyAudit": True, "newSDKBuilds": 0, "newSwiftOrIOSTestRuns": 0,
                      "portableSuitesRerun": 0, "networkQueries": 0, "CIQueriesOrTriggers": 0,
                      "trackedSourceOrCanonicalEdits": 0, "privateInputsRead": False},
        "rawEvidence": {"directory": str(RAW), "commands": meta(RAW / "actual-read-only-commands.json"),
                        "archiveMembers": meta(RAW / "archive-members.json"), "sourceComparison": meta(RAW / "source-input-comparison.json"),
                        "auditorScript": meta(Path(__file__))}
    }
    write(DEST, report)
    print(json.dumps({"audit": meta(DEST), "status": report["status"], "groups": {k: v["actualExecutions"] for k, v in group_results.items()},
                      "C29Matched": True, "AWholeFiles28of29": True, "narrowMappingSupported": True,
                      "builtInfoReplayedOffline": False, "aggregateRunSuccessInferred": False}))


if __name__ == "__main__":
    main()
