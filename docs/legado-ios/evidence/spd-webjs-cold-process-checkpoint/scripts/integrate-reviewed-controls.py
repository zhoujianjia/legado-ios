"""Root-only integration after the separate, reviewed15-source WebJS commit.

Usage: python .build/integrate-reviewed-spd-webjs-controls.py REVIEW BYTES SHA256
This script does not commit, tag, dispatch, poll, or run any test/compiler.
"""
from pathlib import Path, PurePosixPath
import argparse
import copy
import datetime
import hashlib
import json
import re
import subprocess
import zipfile

R = Path('F:/yuedu-reader')
S = R / '.build/consolidated-sdk-spd-webjs-cold-process-checkpoint'
MP = S / 'preparation/final-v1.json'
GIT = 'D:/app/Git/cmd/git.exe'
FLAGS = ('allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished')
BINARY_SUFFIXES = {'.class', '.kotlin_module', '.jar', '.zip', '.ipa', '.xcresult'}


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def raw_fact(raw):
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def fact(path):
    return raw_fact(path.read_bytes())


def check(path, expected):
    assert path.is_file() and not path.is_symlink(), str(path)
    assert fact(path) == {k: expected[k] for k in ('bytes', 'sha256')}, str(path)


def project_path(raw):
    p = Path(raw)
    p = p if p.is_absolute() else R / p
    assert p.resolve().is_relative_to(R.resolve()), str(p)
    return p


def stage_path(base, raw):
    p = Path(raw)
    p = p if p.is_absolute() else R / p if raw.startswith('.build/') else base / p
    assert p.resolve().is_relative_to((R / '.build').resolve()), str(p)
    return p


def document_fact(path):
    return {'path': path.relative_to(R).as_posix(), **fact(path)}


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def check_review(value, bindings):
    assert type(value.get('failedChecks')) is int and value['failedChecks'] == 0
    assert value.get('remainingConfirmedFindings') == []
    assert value.get('mismatches', []) == []
    text = json.dumps(value, ensure_ascii=False)
    for binding in bindings:
        assert binding['sha256'] in text, 'Review does not bind the exact preparation'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('review')
    parser.add_argument('review_bytes', type=int)
    parser.add_argument('review_sha256')
    args = parser.parse_args(argv)
    rp = Path(args.review).resolve()
    assert rp.is_relative_to((R / '.build').resolve())
    assert args.review_bytes > 0 and re.fullmatch('[0-9a-f]{64}', args.review_sha256)
    check(MP, {'bytes': 30638, 'sha256': '1acee769085f81dda4ff82eb57c158ffa70af15e0f780c4ef53897d9824a5b97'})
    check(rp, {'bytes': args.review_bytes, 'sha256': args.review_sha256})
    m, review = read(MP), read(rp)
    check_review(review, [fact(MP)])
    assert {k: review['final'][k] for k in ('bytes', 'sha256')} == fact(MP)
    assert len(m['files']) == 5
    reviewed_files = {row['path']: row for row in review['files']}
    assert set(reviewed_files) == {row['path'] for row in m['files']}
    for row in m['files']:
        assert reviewed_files[row['path']]['candidate'] == row['candidate']
        assert reviewed_files[row['path']]['baseline'] == row['baseline']

    # The15 WebJS sources have already been committed separately. No fixed HEAD
    # prefix is assumed, and no arbitrary modified/untracked path is admitted.
    status = subprocess.check_output([GIT, 'status', '--porcelain=v1', '-z', '--untracked-files=all'], cwd=R)
    assert all(row == b'?? debug.log' for row in status.split(b'\0') if row), status.decode(errors='replace')
    assert subprocess.check_output([GIT, 'diff', '--cached', '--name-only', '-z'], cwd=R) == b''
    head = subprocess.check_output([GIT, 'rev-parse', 'HEAD'], cwd=R).decode().strip()
    assert re.fullmatch('[0-9a-f]{40}', head)

    counts = m['counts']
    required_counts = dict(coreInputs=343, nativeInputs=148, uniqueInputUnion=359,
        unchangedCanonicalNoncandidateInputs=339, NativeOriginalDefinitions=27,
        NativeLoginInfoDefinitions=16, NativeMainJSDefinitions=1, NativeIndependentColdHosts=2,
        AppDefinitions=463, AppLeaves=466, BoolParameterPairs=3, PackageMethods=24,
        PackageCompilationInputs=16, PackageControls=7, PackageAllInputs=23)
    assert all(counts[k] == v for k, v in required_counts.items())
    assert all(value is True for value in m['invariants'].values() if isinstance(value, bool))
    candidate_root = S / m['candidateRoot']
    assert candidate_root.resolve().is_relative_to(S.resolve())
    control_bytes = {}
    for row in m['files']:
        rel = row['path']
        check(R / rel, row['baseline'])
        check(candidate_root / rel, row['candidate'])
        check(project_path(row['diff']['path']), row['diff'])
        control_bytes[rel] = (candidate_root / rel).read_bytes()

    composition = m['sourceComposition']
    bp, sp = project_path(composition['JVMBackend']['path']), project_path(composition['SwiftPageOwner']['path'])
    check(bp, composition['JVMBackend']); check(sp, composition['SwiftPageOwner'])
    backend, swift = read(bp), read(sp)
    check(bp, {'bytes': 34731, 'sha256': '3ce8c092ce65acf3e38e136cf6b81070a7e1df96ebc8184a4d1266fd4e816854'})
    check(sp, {'bytes': 11850, 'sha256': 'e2fbf3c0091ff1f74869120f32f33d4a0e8c5c22bc700e39bbb1eb2667092fd0'})
    sources = {}
    for parent, author in [(bp.parent, backend), (sp.parent, swift)]:
        root = stage_path(parent, author['candidateRoot'])
        for row in author['files']:
            rel = row['path']; assert rel not in sources
            check(root / rel, row['candidate']); check(R / rel, row['candidate'])
            sources[rel] = row['candidate']
    assert len(sources) == 15 and not set(sources) & set(control_bytes)
    for row in m['productionSources']:
        assert row['path'] in sources and row['candidate'] == sources[row['path']]
        check(project_path(row['snapshot']['path']), row['snapshot'])

    source_record_path = R / 'docs/legado-ios/core-original-local-html-webjs-step.json'
    source_record = read(source_record_path)
    assert {row['path']: row['candidate'] for row in source_record['sourceFiles']} == sources
    assert all(source_record[k] is False for k in FLAGS)
    sr = project_path(source_record['independentReview']['path'])
    check(sr, source_record['independentReview'])
    check_review(read(sr), [fact(bp), fact(sp)])

    #339 noncandidate inputs remain exact, while all15 canonical WebJS inputs
    # already equal the frozen source and only5 old controls remain to replace.
    rosters, union = {}, {}
    for name, expected in [('core', 343), ('Native', 148), ('Package', 23)]:
        roster = m['sourceRosters'][name]; path = project_path(roster['path']); check(path, roster)
        rows = read(path); assert len(rows) == len({r['path'] for r in rows}) == expected
        rosters[name] = rows
        for row in rows:
            rel = row['path']; raw = control_bytes[rel] if rel in control_bytes else (R / rel).read_bytes()
            assert raw_fact(raw) == {k: row[k] for k in ('bytes', 'sha256')}, rel
            if rel in union: assert union[rel] == raw_fact(raw)
            union[rel] = raw_fact(raw)
    assert len(union) == 359 and set(sources) | set(control_bytes) <= set(union)
    noncandidate = set(union) - set(sources) - set(control_bytes)
    assert len(noncandidate) == 339
    for rel in noncandidate: check(R / rel, union[rel])
    for row in rosters['Package']: check(R / row['path'], row)
    for group in composition['canonicalS4C5S2']:
        check(project_path(group['manifest']['path']), group['manifest'])
        for row in group['sourceFiles']: check(R / row['path'], row)

    # Actual ignored ordinary-JAR production classes and all128 main/control
    # source facts must remain bound. These reads never execute Java/Swift.
    def backend_evidence(suffix):
        found = [r for r in backend['evidence'] if r['path'].startswith('snapshot-v2/') and r['path'].endswith(suffix)]
        assert len(found) == 1, suffix
        p = stage_path(bp.parent, found[0]['path']); check(p, found[0]); return p
    inputs_path = backend_evidence('/actual-jvm-compilation-inputs.json')
    inspection_path = backend_evidence('/ordinary-jar-inspected-v3.json')
    class_binding_path = backend_evidence('/ordinary-v4/production-binding.json')
    inputs, inspected, binding = read(inputs_path), read(inspection_path), read(class_binding_path)
    assert len(inputs['inputs']) == 128 and sum('/src/main/' in row['path'] for row in inputs['inputs']) == 125
    for row in inputs['inputs']: check(R / row['path'], row)
    jar = stage_path(bp.parent, backend['ordinaryJar']['path']); check(jar, backend['ordinaryJar'])
    assert inspected['productionClassCount'] == 408 and inspected['recompiledClassCount'] == 59 and inspected['retainedClassCount'] == 349
    assert inspected['portedSources'] == 59 and inspected['inspection']['testClassesIncluded'] is False
    expected_classes = {row['path']: row for row in inspected['classes']}; assert len(expected_classes) == 408
    with zipfile.ZipFile(jar) as payload:
        assert payload.testzip() is None and len(payload.namelist()) == len(set(payload.namelist()))
        project_classes = {p for p in payload.namelist() if p.startswith(('io/yuedu/legado/', 'io/legado/app/', 'com/script/')) and p.endswith('.class')}
        assert project_classes == set(expected_classes)
        for name, row in expected_classes.items(): assert raw_fact(payload.read(name)) == {k: row[k] for k in ('bytes', 'sha256')}
        for row in binding['unchangedResources']: assert raw_fact(payload.read(row['path'])) == {k: row[k] for k in ('bytes', 'sha256')}
        manifest = 'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
        assert payload.read('META-INF/legado-provenance/original-rule/manifest.json') == (R / manifest).read_bytes()
    provenance = read(R / manifest); assert len(provenance['portedSources']) == 59
    for row in provenance['portedSources']: check(R / row['path'], row)

    guards = m['actualPortableGuards']
    assert guards['distinctMethods'] == guards['executions'] == guards['passed'] == 4 and guards['failed'] == 0
    for command in guards['commands']:
        assert command['exitCode'] == 0; check(project_path(command['log']['path']), command['log'])

    pp = R / 'docs/legado-ios/completion-plan.json'; plan = read(pp)
    assert all(plan[k] is False for k in FLAGS)
    cloud = plan['execution']['cloudTriggerPolicy']; original_handles = copy.deepcopy(cloud['onlyLiveSDKHandles'])
    assert {h['runID'] for h in original_handles} <= {39507170170, 39507170384}
    for handle in original_handles: assert handle['sourceCommit'] == 'fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a'

    record_path = R / 'docs/legado-ios/core-spd-webjs-cold-process-checkpoint.json'
    archive = R / 'docs/legado-ios/evidence/spd-webjs-cold-process-checkpoint'
    assert not record_path.exists() and not archive.exists()
    items, excluded = {}, []
    def add(path, name, expected=None):
        assert not PurePosixPath(name).is_absolute() and '..' not in PurePosixPath(name).parts
        if expected: check(path, expected)
        assert path.is_file() and not path.is_symlink()
        if path.suffix in BINARY_SUFFIXES:
            excluded.append({'path': path.relative_to(R).as_posix(), **fact(path), 'reason': 'Binary remains ignored; textual source/class facts archived.'}); return
        assert name not in items or items[name] == path; items[name] = path
    add(MP, 'checkpoint-preparation.json'); add(rp, 'reviews/controls-review.json')
    add(sr, 'reviews/webjs-source-review.json'); add(source_record_path, 'already-integrated-webjs-source-record.json')
    add(bp, 'parents/backend-preparation-v2.json'); add(sp, 'parents/swift-preparation-v1.json')
    for row in m['evidence']:
        p = project_path(row['path']); add(p, 'checkpoint/' + p.relative_to(S).as_posix(), row)
    for row in m['files']: add(project_path(row['diff']['path']), 'diffs/' + row['path'] + '.diff', row['diff'])
    for name, row in m['sourceRosters'].items(): add(project_path(row['path']), 'rosters/' + name + '-source-inputs.json', row)
    add(inputs_path, 'closure/JVM-compilation-inputs.json'); add(inspection_path, 'closure/JVM-class-inspection.json')
    add(class_binding_path, 'closure/JVM-production-binding.json'); add(jar, 'excluded/ordinary-runtime.jar', backend['ordinaryJar'])
    add(Path(__file__).resolve(), 'scripts/integrate-reviewed-controls.py')
    if isinstance(review.get('checkLedger'), dict):
        row = review['checkLedger']; add(project_path(row['path']), 'reviews/controls-check-ledger.json', row)
    normalized = {}
    for name, path in items.items():
        raw = path.read_bytes()
        assert b'\0' not in raw and not re.search(rb'(?:[?&])X-Amz-Signature=[0-9a-fA-F]{16,}', raw), name
        assert not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----', raw), name
        text = '\n'.join(line.rstrip(' \t') for line in raw.decode('utf-8-sig').splitlines()).rstrip('\n')
        normalized[name] = (text + '\n' if text else '').encode('utf-8')
    preserved = [dict(path=(archive / name).relative_to(R).as_posix(), **raw_fact(normalized[name]),
        originalEvidence=document_fact(path), normalization='Strict UTF8/LF; trailing horizontal and empty EOF whitespace removed; exact original facts retained.') for name, path in items.items()]
    record = dict(schemaVersion=1, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        status='reviewed-SPD-WebJS-cold-process-controls-integrated-actual-SDK-Native-pending',
        reviewedCanonicalParent=head, sourceFiles=m['files'], changedControls=5,
        alreadyIntegratedWebJSSources=[dict(path=rel, candidate=value) for rel, value in sources.items()],
        sourceComposition=m['sourceComposition'], countsForNextCheckpoint=counts,
        sourceIndependentReview=document_fact(sr), controlsIndependentReview=document_fact(rp),
        controlsValidation=guards, invariants=m['invariants'], newNativeSelector=m['newNativeSelector'],
        independentColdHostMethods=m['coldMethods'], classClosure=dict(ordinaryJar=backend['ordinaryJar'], productionClasses=408,
            sourceInputs=128, mainSourceInputs=125, portedSources=59, freshFullGradle=False),
        preservedEvidence=preserved, excludedBinaryEvidence=excluded,
        limits=m['proofLimits'] + ['Control guards and earlier bounded JVM/ordinary-Java evidence never establish new SDK/JNI/UIKit/device or automatic-renewal acceptance.'],
        currentCloudHandlesUnchanged=True, newCloudTagCreated=False, **{key: False for key in FLAGS})
    steps = plan['execution']['stepByStep']; record_rel = record_path.relative_to(R).as_posix()
    steps['queuedSPDWebJSColdNextCheckpoint'] = dict(record=record_rel, **counts,
        actualAcceptancePending=True, currentPairMustBeArchivedBeforeTrigger=True,
        noAdditionalTagCreated=True, separateColdProcessMethods=m['coldMethods'])
    if 'queuedColdProcessLookupNextCheckpoint' in steps:
        queued = steps['queuedColdProcessLookupNextCheckpoint']
        queued.update(futureAppDefinitions=463, futureAppLeaves=466, futureOriginalGroup=27,
            futureLoginInfoGroup=16, futureSeparateMainJSGroup=1, futureSeparateColdHosts=2,
            finalCoreNativeUnionCounts={'core': 343, 'native': 148, 'union': 359},
            coherentControlRecord=record_rel, actualAcceptancePending=True)
    plan.setdefault('activeDevelopmentBatchRecords', []).append(record_rel)
    cloud['nextPlannedCheckpoint'] = 'Reviewed next coherent controls:343core/148Native/359union, original27(LoginInfo16)+MainJS1 and2 independent cold hosts, App463/466 with3 Bool matrices, unchanged Package24/23inputs. Preserve current fc3 handles and archive actual outcomes/repair confirmed failures before one later pair; no duplicate/per-item/IPA tag. Portable or old JVM evidence is not SDK acceptance.'
    assert cloud['onlyLiveSDKHandles'] == original_handles and all(plan[key] is False for key in FLAGS)

    # All authority/byte/normalization checks finish before the first write.
    for name, raw in normalized.items():
        target = archive / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(raw)
    for rel, raw in control_bytes.items(): (R / rel).write_bytes(raw)
    record_path.write_bytes(encoded(record)); pp.write_bytes(encoded(plan))
    paths = [R / rel for rel in control_bytes] + [archive / name for name in items] + [record_path, pp]
    assert len(paths) == len(set(paths))
    for rel, expected in sources.items(): check(R / rel, expected)
    roster = [document_fact(path) for path in paths]
    (S / 'canonical-roster.json').write_bytes(encoded(roster))
    subprocess.run([GIT, 'diff', '--check'], cwd=R, check=True)
    print(json.dumps(dict(canonicalRoster=str(S / 'canonical-roster.json'), reviewedPaths=len(paths),
        changedControls=5, currentCloudHandlesUnchanged=True, actualSDK=0, actualNative=0, newTags=0)))


if __name__ == '__main__':
    main()
