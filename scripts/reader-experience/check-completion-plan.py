#!/usr/bin/env python3
"""Check the 8-stage/33-package/64-domain ledger, never feature acceptance.

Use --require-execution after all workpackages have execution instructions.
This offline checker only validates structure, dependency graphs, declared
boundaries, and local evidence paths. It does not run App/JVM/iOS behavior.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import re
import sys


REPO = Path(__file__).resolve().parents[2]
PLAN = Path("docs/legado-ios/completion-plan.json")
CATALOG = Path("docs/legado-ios/feature-catalog.json")
READINESS = {"ready", "depends-on-work", "awaiting-cloud", "deferred-device", "externally-blocked"}
ROOT_FALSE = ("allNonDeviceWorkComplete", "automaticSelfRenewalImplemented",
              "fullLegadoCompatibilityEstablished", "legalRedistributionClearanceEstablished")
EXECUTION_FIELDS = {"summaryZh", "currentState", "remainingWork", "nextAction", "readiness",
                    "readyPreparation", "acceptance", "evidence", "deferredHardware", "verificationBoundary"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def strings(value, label, *, nonempty=False):
    require(isinstance(value, list), label + " must be a list")
    require(all(isinstance(item, str) and item.strip() for item in value), label + " requires nonempty strings")
    require(len(value) == len(set(value)), label + " must not contain duplicates")
    require(not nonempty or bool(value), label + " must not be empty")
    return value


def text(value, label, *, chinese=False):
    require(isinstance(value, str) and bool(value.strip()), label + " requires nonempty text")
    require(not chinese or re.search(r"[\u3400-\u9fff]", value) is not None, label + " requires Chinese explanation")


def entries(value, label, count):
    require(isinstance(value, list) and len(value) == count, f"{label} requires exactly {count} entries")
    result = {}
    for item in value:
        require(isinstance(item, dict), label + " entry must be an object")
        identity = item.get("id")
        text(identity, label + ".id")
        require(identity not in result, label + " has duplicate id: " + identity)
        result[identity] = item
    return result


def dag(items, label):
    edges = {}
    for identity, item in items.items():
        dependencies = strings(item.get("dependsOn"), label + "." + identity + ".dependsOn")
        require(set(dependencies) <= set(items), label + " has unknown dependency: " + identity)
        require(identity not in dependencies, label + " has self dependency: " + identity)
        edges[identity] = dependencies
    done, visiting = set(), set()

    def visit(identity):
        require(identity not in visiting, label + " has a dependency cycle at " + identity)
        if identity in done:
            return
        visiting.add(identity)
        for dependency in edges[identity]:
            visit(dependency)
        visiting.remove(identity)
        done.add(identity)

    for identity in edges:
        visit(identity)
    return edges


def evidence_path(root, value, label):
    text(value, label)
    require("\\" not in value and not PurePosixPath(value).is_absolute()
            and not PureWindowsPath(value).drive and ".." not in PurePosixPath(value).parts,
            label + " must be a repository-relative file path")
    candidate = root / value
    require(candidate.resolve().is_relative_to(root), label + " resolves outside repository")
    require(candidate.is_file(), label + " does not exist as a file: " + value)
    return value


def validate(plan, catalog, root=REPO, *, require_execution=False):
    root = root.resolve()
    require(isinstance(plan, dict) and isinstance(catalog, dict), "Plan and catalog must be objects")
    require(type(plan.get("schemaVersion")) is int and plan["schemaVersion"] == 1, "Unsupported plan schema")
    require(plan.get("status") == "in_progress", "Unfinished ledger must retain in_progress status")
    for key in ROOT_FALSE:
        require(plan.get(key) is False, "Unsupported completion claim: " + key)
    policy = plan.get("policy", {})
    require(policy.get("singleProduct") is True and policy.get("builtInBookSources") is False
            and policy.get("privateSourcesMayBeReadOrUploaded") is False
            and policy.get("preserveExistingUserSourcesBooksAndProgress") is True
            and policy.get("askUserToInstallOrTestDuringDeferredPeriod") is False,
            "Plan product/private-source/data-preservation policy changed")
    stages = entries(plan.get("stages"), "stages", 8)
    packages = entries(plan.get("workpackages"), "workpackages", 33)
    features = entries(plan.get("features"), "features", 64)
    original = entries(catalog.get("features"), "catalog.features", 64)
    require(set(features) == set(original), "Feature IDs differ from the 64-domain catalog")
    require(plan.get("baseline", {}).get("featureDomainCount") == 64, "Baseline feature count changed")
    stage_edges = dag(stages, "stages")
    package_edges = dag(packages, "workpackages")
    stage_ancestors = {}

    def ancestors(identity):
        if identity not in stage_ancestors:
            stage_ancestors[identity] = set(stage_edges[identity])
            for parent in stage_edges[identity]:
                stage_ancestors[identity].update(ancestors(parent))
        return stage_ancestors[identity]

    for identity, stage in stages.items():
        require(stage.get("status") in {"planned", "in_progress"}, "Unsupported stage status: " + identity)
        text(stage.get("exitCondition"), "Stage exitCondition: " + identity)
        ancestors(identity)
    registry = plan.get("existingEvidence")
    require(isinstance(registry, dict) and bool(registry), "Evidence registry must be nonempty")
    evidence = set()
    for identity, record in registry.items():
        require(isinstance(record, dict), "Evidence entry must be an object: " + identity)
        evidence.add(evidence_path(root, record.get("path"), "Evidence " + identity))
        text(record.get("scope"), "Evidence scope: " + identity)
    evidence.add(evidence_path(root, plan.get("activeBatchRecord"), "activeBatchRecord"))
    evidence.add(evidence_path(root, plan.get("baseline", {}).get("featureCatalog"), "baseline.featureCatalog"))
    evidence.add(evidence_path(root, plan.get("baseline", {}).get("deliveredCandidateRecord"), "baseline.deliveredCandidateRecord"))

    def references(item, label):
        refs = strings(item.get("existingEvidence"), label + ".existingEvidence", nonempty=True)
        require(set(refs) <= set(registry), label + " references unknown evidence IDs")

    owners, execution_count = Counter(), 0
    for identity, package in packages.items():
        require(package.get("stageId") in stages, "Unknown package stage: " + identity)
        require(package.get("status") in {"planned", "in_progress", "device_dependent_feasibility"},
                "Unsupported package status: " + identity)
        require(package.get("kind") in {"domain-owner", "cross-domain"}, "Unknown package kind: " + identity)
        for key in ("ownedFeatureIds", "relatedFeatureIds"):
            values = strings(package.get(key, []), identity + "." + key)
            require(set(values) <= set(features), "Unknown feature in package " + identity)
        owned = package["ownedFeatureIds"]
        require(bool(owned) == (package["kind"] == "domain-owner"), "Domain/cross-domain ownership mismatch: " + identity)
        for feature in owned:
            owners[feature] += 1
            require(features[feature].get("ownerWorkpackage") == identity, "Owner mapping disagrees: " + feature)
        references(package, identity)
        for key in ("desktopSimulatorAcceptance", "deferredDeviceAcceptance"):
            strings(package.get(key), identity + "." + key, nonempty=key == "desktopSimulatorAcceptance")
        for parent in package_edges[identity]:
            parent_stage = packages[parent]["stageId"]
            require(parent_stage == package["stageId"] or parent_stage in ancestors(package["stageId"]),
                    "Workpackage dependency contradicts stage DAG: " + identity)
        instructions = package.get("execution")
        require(not require_execution or instructions is not None, "Missing execution instructions: " + identity)
        if instructions is None:
            continue
        execution_count += 1
        require(isinstance(instructions, dict) and EXECUTION_FIELDS <= set(instructions), "Incomplete execution fields: " + identity)
        require("dependencies" not in instructions, "Use original dependsOn rather than duplicate execution.dependencies: " + identity)
        for key in ("summaryZh", "currentState", "nextAction", "verificationBoundary"):
            text(instructions[key], identity + ".execution." + key, chinese=key in {"summaryZh", "currentState"})
        require(instructions["readiness"] in READINESS, "Unknown execution readiness: " + identity)
        for key in ("remainingWork", "readyPreparation", "acceptance", "deferredHardware", "evidence"):
            strings(instructions[key], identity + ".execution." + key, nonempty=key in {"remainingWork", "acceptance"})
        for path in instructions["evidence"]:
            evidence.add(evidence_path(root, path, identity + ".execution.evidence"))
    require(set(owners) == set(features) and all(count == 1 for count in owners.values()),
            "All 64 feature domains must be owned exactly once")
    for identity, feature in features.items():
        require(feature.get("status") in {"planned", "partially_implemented_pending_acceptance"},
                "Unsupported feature status: " + identity)
        require(feature.get("fullCompatibilityEstablished") is False, "Unsupported feature acceptance claim: " + identity)
        require(feature.get("ownerWorkpackage") in packages, "Unknown feature owner: " + identity)
        references(feature, identity)
    renewal = packages.get("automatic-renewal-feasibility", {})
    require(renewal.get("feasibilityEstablished") is False and renewal.get("automaticSelfRenewalImplemented") is False
            and renewal.get("implementationAfterTransport") == "gated_not_started"
            and renewal.get("signerIntegrationAuthorizedByPlanOnlyAfterTransportEvidence") is True,
            "Read-only renewal probe must not become signing/install feasibility or implementation acceptance")
    execution = plan.get("execution")
    require(isinstance(execution, dict), "Missing plan execution policy")
    queued = set()
    for name in ("readyQueue", "awaitingEvidenceQueue", "deferredQueue"):
        if name not in execution:
            continue
        values = strings(execution[name], "execution." + name)
        require(set(values) <= set(packages), "Unknown workpackage in " + name)
        require(not queued.intersection(values), "Workpackage occurs in multiple execution queues")
        queued.update(values)
        if name == "readyQueue":
            require(all(packages[value].get("execution", {}).get("readiness") == "ready" for value in values),
                    "readyQueue contains a workpackage whose execution.readiness is not ready")
    validation = plan.get("validation", {})
    require(validation.get("featureCompletionInferredFromTestCounts") is False,
            "Test counts cannot establish feature completion")
    return {"schemaVersion": 1, "status": "passed", "stageCount": 8, "workpackageCount": 33,
            "featureDomainCount": 64, "uniqueFeatureOwnershipChecked": True,
            "stageAndWorkpackageDAGChecked": True, "executionInstructionsChecked": execution_count,
            "executionInstructionsRequired": require_execution, "evidencePathsChecked": sorted(evidence),
            "scope": "Plan structure, ownership, DAG, execution instructions, declared boundaries and file existence only.",
            "appBehaviorExecuted": False, "featureAcceptanceEstablished": False,
            "renewalFeasibilityEstablished": False, "legalRedistributionClearanceEstablished": False}


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, default=REPO / PLAN)
    parser.add_argument("--catalog", type=Path, default=REPO / CATALOG)
    parser.add_argument("--require-execution", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = validate(read_json(args.plan), read_json(args.catalog), require_execution=args.require_execution)
        result["inputSHA256"] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in (args.plan, args.catalog)}
        data = (json.dumps(result, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        if args.output:
            require(args.output.resolve() not in {args.plan.resolve(), args.catalog.resolve()},
                    "Output must not overwrite plan/catalog input")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(data)
        sys.stdout.buffer.write(data)
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
