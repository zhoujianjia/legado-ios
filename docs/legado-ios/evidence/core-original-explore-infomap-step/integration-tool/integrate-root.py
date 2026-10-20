"""Default performs read-only source/XML/JAR/hash checks. --apply writes the exact
nineteen-source C3 boundary, minimal retained evidence, record and completion plan.
--apply --commit additionally stages exactly those paths and commits. No build,
grammar, tests, JAR repacking, SDK, cloud, push or tag is performed in any mode.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import copy
import hashlib
import json
import subprocess
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path('F:/yuedu-reader')
BASE = ROOT / '.build/original-explore-infomap-delta'
BASE_COMMIT = 'a3a639798632e221ce3154c5f779400b72610313'
PREP_SHA = 'c316a215f55c5944a466f6fec5741448eeb43d2778baf8efba680bf3efc56f99'
MANIFEST_PATH = 'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
DOC = ROOT / 'docs/legado-ios/core-original-explore-infomap-step.json'
EV = ROOT / 'docs/legado-ios/evidence/core-original-explore-infomap-step'
PLAN = ROOT / 'docs/legado-ios/completion-plan.json'
ATTRS = ROOT / '.gitattributes'
GIT = ['D:/app/Git/cmd/git.exe', '-c', 'core.autocrlf=false']
FALSE_KEYS = ('allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
              'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished')


def sha(raw): return hashlib.sha256(raw).hexdigest()
def encoded(value): return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf8')
def git(*args): return subprocess.check_output(GIT + list(args), cwd=ROOT)


def checked(path, digest=None, size=None):
    raw = path.read_bytes()
    assert digest is None or sha(raw) == digest, 'SHA mismatch: ' + str(path)
    assert size is None or len(raw) == size, 'Size mismatch: ' + str(path)
    return raw


def fact(path, raw=None):
    raw = path.read_bytes() if raw is None else raw
    return {'path': path.relative_to(ROOT).as_posix(), 'bytes': len(raw), 'sha256': sha(raw)}


def bound(row): return checked(ROOT / row['path'], row['sha256'], row['bytes'])


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--apply', action='store_true')
    cli.add_argument('--commit', action='store_true')
    args = cli.parse_args()
    assert not args.commit or args.apply
    head = git('rev-parse', 'HEAD').decode('ascii').strip()
    # The producer's separate scripts may be committed first. Their non-overlapping
    # descendants are allowed only while every actual source/dependency below matches.
    ancestor = subprocess.run(GIT + ['merge-base', '--is-ancestor', BASE_COMMIT, head], cwd=ROOT,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert ancestor.returncode == 0, 'Integration base must descend from canonical a3a6397'
    assert not git('status', '--porcelain')
    assert not DOC.exists() and not EV.exists()
    prep_path = BASE / 'preparation.json'
    raw_p = checked(prep_path, PREP_SHA, 38894)
    p = json.loads(raw_p)
    assert p['canonicalBaseCommit'] == BASE_COMMIT
    rows = p['sourceBinding']['changedCodeTestsAndProvenance']
    assert len(rows) == len({r['path'] for r in rows}) == 19
    by_path = {r['path']: r for r in rows}
    writes = {}
    evidence = {}
    def retain(path, name, raw=None):
        assert name not in evidence
        data = path.read_bytes() if raw is None else raw
        evidence[name] = {'sourcePath': path.relative_to(ROOT).as_posix(), 'raw': data}
    retain(prep_path, 'preparation.json', raw_p)
    for row in rows:
        raw = checked(ROOT / row['snapshot'], row['sha256'], row['bytes'])
        assert b'\r' not in raw and row['crlf'] == 0
        current = ROOT / row['path']; before = row['canonicalAtBase']
        if before['exists']:
            checked(current, before['sha256'], before['bytes'])
        else:
            assert not current.exists(), row['path']
        writes[current] = raw
        retain(ROOT / row['snapshot'], 'changed-sources/' + row['path'], raw)
    assert by_path['Modules/Services/Online/LegadoPersistentStateHost.swift']['canonicalAtBase']['sha256'] == '1bac6f3c5eddaeb4b31e1f414ecde6986495cdb586476304af038fcc59173a2f'
    diff_row = p['sourceBinding']['finalDiff']
    retain(ROOT / diff_row['path'], 'final-changes.diff', bound(diff_row))

    for row in p['reviews']:
        raw = bound(row); review = json.loads(raw)
        if 'additionalConfirmedBlockers' in review: assert review['additionalConfirmedBlockers'] == []
        if 'findings' in review: assert review['findings'] == []
        retain(ROOT / row['path'], 'reviews/' + Path(row['path']).name, raw)
    # V1's actual retention findings remain rejected historical evidence, not passes.
    first_review = json.loads(bound(p['reviews'][0]))
    assert first_review['confirmedBlockers']
    root_review_path = BASE / 'root-production-review.json'
    root_review_raw = checked(root_review_path)
    root_review = json.loads(root_review_raw)
    assert root_review['preparationSHA256'] == PREP_SHA and root_review['confirmedBlockers'] == []
    assert root_review['testsExecuted'] == root_review['SwiftSDKExecuted'] == root_review['JNIExecuted'] == 0
    retain(root_review_path, 'reviews/root-production-review.json', root_review_raw)
    for name in ['independent-review-inputs-v1.json', 'independent-review-inputs-v2.json',
                 'independent-review-inputs-v2-final.json', 'host-integration-base.json']:
        retain(BASE / name, 'review-inputs/' + name)

    grammar_row = p['validation']['grammarReuse']['record']
    grammar_raw = bound(grammar_row); grammar = json.loads(grammar_raw)
    assert len(grammar['files']) == 5
    for row in grammar['files']:
        assert row['path'] in by_path and row['sha256'] == by_path[row['path']]['sha256']
        assert row['bytes'] == by_path[row['path']]['bytes'] and row['diagnostics'] == []
    assert p['validation']['grammarReuse']['SDKExecutions'] == 0
    retain(ROOT / grammar_row['path'], 'grammar-reused-five-swift.json', grammar_raw)

    v = p['validation']; source = p['sourceBinding']['acceptedExecutionInputs']
    ordinary_raw = bound(v['ordinary']); ordinary = json.loads(ordinary_raw)
    final_raw = bound(source['sameAsSuccessfulFocusedRecord']); final_run = json.loads(final_raw)
    assert final_run['exitCode'] == ordinary['exitCode'] == 0
    assert final_run['executionSourcesUnchanged'] and ordinary['executionSourcesUnchanged']
    continuity_raw = bound(source['continuity']); continuity = json.loads(continuity_raw)
    assert continuity['canonicalBaseCommit'] == BASE_COMMIT
    assert continuity['sourceCount'] == source['count'] == len(continuity['inputs']) == 157
    assert continuity['changedInputs'] == 11 and continuity['allComparedByteEqual'] is True
    current_inputs = {row['path']: row for row in ordinary['sourceBinding']}
    final_inputs = {row['path']: row for row in final_run['sourceBinding']}
    assert len(current_inputs) == len(final_inputs) == 157
    assert {k: x['sha256'] for k,x in current_inputs.items()} == {k: x['sha256'] for k,x in final_inputs.items()}
    canonical_input_count = 0
    for row in continuity['inputs']:
        assert row['sha256'] == current_inputs[row['path']]['sha256']
        if row['origin'] == 'final-sources':
            assert row['path'] in by_path and by_path[row['path']]['sha256'] == row['sha256']
            actual = writes[ROOT / row['path']]
        else:
            assert row['origin'] == 'canonical Git ' + BASE_COMMIT
            actual = checked(ROOT / row['path']); canonical_input_count += 1
        assert sha(actual) == row['sha256']
        input_row = current_inputs[row['path']]
        assert len(actual) == input_row['bytes']
        if input_row.get('snapshot'): checked(ROOT / input_row['snapshot'], row['sha256'], input_row['bytes'])
    assert canonical_input_count == 146
    retain(ROOT / source['continuity']['path'], 'final-input-continuity.json', continuity_raw)

    reuse_raw = bound(v['reuseMapping']); reuse = json.loads(reuse_raw)
    retain(ROOT / v['reuseMapping']['path'], 'related-result-reuse.json', reuse_raw)
    assert reuse['acceptedUniqueMethods'] == v['acceptedUniqueMethods'] == 54
    assert reuse['newMethods'] == v['newMethods'] == 5
    assert reuse['oldMethods'] == v['oldMethods'] == 49
    assert reuse['newlyExecutedFinalMethods'] == v['actualFinalRunMethods'] == 16
    assert reuse['unchangedV1MethodsReused'] == v['unchangedOldMethodsReused'] == 38
    assert reuse['acceptedXML'] == v['acceptedXML'] and len(v['acceptedXML']) == 5
    leaves = []; accepted_by_execution = {'v1': 0, 'v7': 0}
    for row in v['acceptedXML']:
        raw = bound(row); xml = ET.fromstring(raw)
        assert xml.tag == 'testsuite' and xml.attrib['name'] == row['suite']
        assert all(int(xml.attrib[name]) == 0 for name in ['failures', 'errors', 'skipped'])
        cases = xml.findall('testcase')
        assert len(cases) == row['methods'] == int(xml.attrib['tests'])
        for case in cases:
            assert not any(case.find(name) is not None for name in ['failure', 'error', 'skipped'])
            assert case.attrib['classname'] == row['suite']
            leaves.append(case.attrib['classname'] + '.' + case.attrib['name'])
        accepted_by_execution[row['execution']] += len(cases)
        retain(ROOT / row['path'], 'accepted-xml/' + row['execution'] + '/' + Path(row['path']).name, raw)
    assert len(leaves) == len(set(leaves)) == 54 and set(leaves) == set(reuse['uniqueLeafIDs'])
    assert accepted_by_execution == {'v1': 38, 'v7': 16}

    # Preserve each real attempt, including rejected fixtures; only the explicit
    # five-suite mapping above contributes to accepted unique method counts.
    assert len(v['attempts']) == 7
    for attempt in v['attempts']:
        record_row = attempt['record']; raw = bound(record_row); record = json.loads(raw)
        version = Path(record_row['path']).stem.removeprefix('focused-')
        retain(ROOT / record_row['path'], 'attempts/' + version + '/record.json', raw)
        log_path = BASE / ('focused-' + version + '.log')
        retain(log_path, 'attempts/' + version + '/raw.log', checked(log_path, record['logSHA256'], record['logBytes']))
        for xml_row in record.get('junitSuites', []):
            if any(int(xml_row[key]) for key in ['failures', 'errors', 'skipped']):
                xml_path = BASE / ('focused-' + version + '-xml') / ('TEST-' + xml_row['name'] + '.xml')
                retain(xml_path, 'attempts/' + version + '/' + xml_path.name,
                       checked(xml_path, xml_row['sha256'], xml_row['bytes']))
    # V4's one-method filter did not collect suite metadata in its result JSON.
    # Its retained raw failing XML is still indexed explicitly, never counted passed.
    for xml_path in sorted((BASE / 'focused-v4-xml').glob('*.xml')):
        name = 'attempts/v4/' + xml_path.name
        if name not in evidence: retain(xml_path, name)
    before = json.loads((BASE / 'focused-v1.json').read_bytes())
    old_inputs = {row['path']: row for row in before['sourceBinding']}
    actual_delta = [{'path': path, 'fromV1SHA256': old_inputs[path]['sha256'] if path in old_inputs else None,
                     'finalSHA256': row['sha256']} for path,row in final_inputs.items()
                    if path not in old_inputs or old_inputs[path]['sha256'] != row['sha256']]
    assert actual_delta == reuse['changesFromV1Execution']
    retain(ROOT / v['ordinary']['path'], 'ordinary-v2.json', ordinary_raw)
    log_path = BASE / 'ordinary-v2.log'
    ordinary_log = checked(log_path, ordinary['logSHA256'], ordinary['logBytes'])
    retain(log_path, 'ordinary-v2.log', ordinary_log)
    markers = ['PACKAGED_PAYLOAD_OK', 'PACKAGED_ORIGINAL_TRADITIONAL_OK', 'PACKAGED_APP_COOKIE_OWNER_READ_OK',
               'PACKAGED_APP_COOKIE_OWNER_TEXT_OK', 'PACKAGED_APP_COOKIE_OWNER_BROWSER_PROTOCOL_OK',
               'PACKAGED_ORIGINAL_EXPLORE_INFOMAP_OK']
    assert all(marker.encode('ascii') in ordinary_log for marker in markers)
    jar_row = v['ordinaryJar']; jar_path = ROOT / jar_row['path']
    checked(jar_path, jar_row['sha256'], jar_row['bytes'])
    assert jar_row['bytes'] == 10705582 and jar_row['sha256'] == '3662ae84bfcb6cc34effdc34edaaebbd940f2c2c170ccb78c81de0f907cdfcd5'
    manifest_raw = writes[ROOT / MANIFEST_PATH]; manifest = json.loads(manifest_raw)
    assert len(manifest_raw) == 106561 and sha(manifest_raw) == 'a1340a0037678dacef1f520637cefb6b46d007583562c3ffe897bb466ee67701'
    compiled_tests = set()
    for relative in ['build/classes/kotlin/test', 'build/classes/java/test']:
        folder = BASE / 'jvm-work' / relative
        compiled_tests.update(path.relative_to(folder).as_posix() for path in folder.rglob('*.class'))
    assert len(compiled_tests) == jar_row['projectCompiledTestClassesChecked'] == 150
    assert jar_row['junitOrProjectTestClasses'] == [] and jar_row['engineTestsFlag'] is False
    with zipfile.ZipFile(jar_path) as jar:
        names = jar.namelist(); assert len(names) == len(set(names))
        assert set(jar_row['requiredClasses']).issubset(names)
        assert not (compiled_tests & set(names))
        assert not any(name.startswith(('org/junit/', 'junit/')) for name in names)
        assert not any(name.endswith(('FileRulePersistenceAdapter.class', 'StatePersistenceProcessProbe.class', 'LegadoPayloadSmoke.class')) for name in names)
        assert 'fixtures/android-traditional-stateful-golden.json' not in names
        for row in jar_row['byteEqualProvenanceAndNotices']:
            raw = jar.read(row['member'])
            assert len(raw) == row['bytes'] and sha(raw) == row['sha256']
        assert len(jar_row['byteEqualProvenanceAndNotices']) == 21
        embedded = jar_row['updatedOriginalRuleManifestMatchesReviewedFile']
        assert jar.read(embedded['member']) == manifest_raw
        assert embedded['sha256'] == sha(manifest_raw) and embedded['bytes'] == len(manifest_raw)

    failed = v['ordinaryInitialFailure']; failed_raw = bound(failed['record']); failed_record = json.loads(failed_raw)
    assert failed_record['exitCode'] != 0
    checked(ROOT / failed['jar']['path'], failed['jar']['sha256'], failed['jar']['bytes'])
    retain(ROOT / failed['record']['path'], 'ordinary-failure-v1/record.json', failed_raw)
    fail_log = BASE / 'ordinary-v1.log'
    retain(fail_log, 'ordinary-failure-v1/raw.log', checked(fail_log, failed_record['logSHA256'], failed_record['logBytes']))
    retain(ROOT / failed['embeddedManifest']['path'], 'ordinary-failure-v1/embedded-manifest.json', bound(failed['embeddedManifest']))
    retain(BASE / 'ordinary-v1-built-jar.json', 'ordinary-failure-v1/built-jar-metadata.json')
    # The old52 original entries already have canonical evidence. Check continuity,
    # add just the two actual new original bytes (already among the nineteen sources).
    before_manifest = json.loads((ROOT / MANIFEST_PATH).read_bytes())
    assert len(before_manifest['sourceProvenance']) == 52
    assert len(manifest['sourceProvenance']) == 54 and manifest['sourceProvenance'][:52] == before_manifest['sourceProvenance']
    assert manifest['originalArchiveSHA256'] == before_manifest['originalArchiveSHA256'] == p['provenance']['archiveSHA256']
    assert p['provenance']['newRawReferences'] == manifest['sourceProvenance'][52:]
    for row in p['provenance']['newRawReferences']:
        relative = 'Packages/LegadoRuntime/vendor/original-rule/' + row['vendorPath']
        raw = writes[ROOT / relative]
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256']
    retain(ROOT / p['provenance']['record']['path'], 'provenance-update.json', bound(p['provenance']['record']))
    assert p['implemented'] == manifest['exploreInfoMapIntegration']
    assert len(p['nativePreparedMethods']) == len(p['packagePreparedMethods']) == 2
    assert all(v[key] == 0 for key in ['AndroidExecutions', 'JNIExecutions', 'SwiftSDKExecutions', 'deviceExecutions'])
    assert not p['defaultAppRouteChanged'] and not p['fullSourceCompatibilityEstablished'] and not p['fullC2C3C4Complete']

    plan_before = PLAN.read_bytes(); plan = json.loads(plan_before)
    steps = {step['id']: step for step in plan['execution']['stepByStep']['steps']}
    statuses = {key: step['status'] for key,step in steps.items()}
    accepted = {key: copy.deepcopy(step.get('actualAcceptedEvidence')) for key,step in steps.items()}
    deferred = copy.deepcopy(plan['execution']['deferredQueue'])
    assert len(deferred) == 17 and all(plan[key] is False for key in FALSE_KEYS)
    relative_doc = DOC.relative_to(ROOT).as_posix()
    steps['C3'].setdefault('preparatoryImplementationEvidence', []).append(relative_doc)
    steps['C3']['preparatoryScopeZh'] = steps['C3'].get('preparatoryScopeZh', '') + '；新增原exploreBookAwait与InfoMap进程LRU99、显式context生命周期及同Host/source/revision缓存接线。当前唯一54项为旧38复用＋本次16（新5＋既有Runtime11），普通JAR六组smoke通过；Native2与Package2仅定义、SDK/JNI0。UI导航、渲染、按钮、全源onPause与默认App路线仍未完成。'
    steps['C3']['nextActionZh'] = '集中验证原explore/context typed Swift与既有owner，再接实际导航/pause/resume、渲染/按钮、全源onPause保存及批量/缓存/媒体缺口；不得以本段JVM/JAR替完整产品链验收。'
    steps['C2']['implementationEvidence'].append(relative_doc)
    steps['C2']['implementedSubtasksZh'].append('已补同Host既有backing/source/revision稳定explore scope，独立于每次opaque grant，原InfoMap仅留受检String map、LRU99及显式当前源savePending；不留task/environment，不以scope字符串授予持久权限。Native2/Package2未执行，完整C2仍未验收。')
    steps['C4'].setdefault('preparatoryImplementationEvidence', []).append(relative_doc)
    steps['C4']['preparatoryScopeZh'] = steps['C4'].get('preparatoryScopeZh', '') + '；普通JAR公开explore/context协议本段六组smoke通过，typed Package/Native各2项只准备，真实JNI/原生产品链与默认路线未通过。'
    plan['execution']['stepByStep']['originalExploreInfoMapImplementation'] = relative_doc
    plan['existingEvidence']['original-explore-infomap'] = {'path': relative_doc,
        'scope': 'Original explicit explore/context/InfoMap host integration: current unique54=old38 reused+final16(new5+Runtime11), ordinary JAR6smoke; native2/Package2 definitions only, SDK/JNI0. No default-route/full C2/C3/C4 acceptance.'}
    assert statuses == {key: step['status'] for key,step in steps.items()}
    assert accepted == {key: step.get('actualAcceptedEvidence') for key,step in steps.items()}
    assert deferred == plan['execution']['deferredQueue'] and all(plan[key] is False for key in FALSE_KEYS)
    attrs_before = ATTRS.read_bytes()
    rule = b'docs/legado-ios/evidence/core-original-explore-infomap-step/** -text -whitespace\n'
    assert rule not in attrs_before and (not attrs_before or attrs_before.endswith(b'\n'))
    summary = {'verifiedOnly': not args.apply, 'actualIntegrationHead': head,
        'requiredAncestor': BASE_COMMIT, 'sourceRowsVerified': 19, 'inputContinuity': {'total': 157, 'canonicalUnchanged': 146, 'changed': 11},
        'acceptedUniqueMethods': 54, 'reusedV1Methods': 38, 'finalV7Methods': 16,
        'newMethods': 5, 'oldRuntimeMethodsRerun': 11, 'acceptedXML': 5,
        'ordinaryJarSHA256': jar_row['sha256'], 'ordinarySmokeMarkers': 6,
        'oldNoticesVerified': 21, 'testClassesExcluded': 150, 'oldSourceProvenanceRowsUnchanged': 52,
        'newOriginalReferences': 2, 'reusedSwiftGrammarHashes': 5,
        'nativeDefinitionsOnly': 2, 'packageDefinitionsOnly': 2, 'SwiftSDKExecutions': 0,
        'testsOrJARReexecuted': 0, 'compactRawEvidenceFiles': len(evidence)}
    if not args.apply:
        print(json.dumps(summary)); return

    retain(Path(__file__), 'integration-tool/integrate-root.py')
    evidence_rows = [{'path': name, 'sourcePath': item['sourcePath'], 'bytes': len(item['raw']), 'sha256': sha(item['raw'])} for name,item in evidence.items()]
    summary['compactRawEvidenceFiles'] = len(evidence_rows)
    source_rows = [{'path': row['path'], 'bytes': row['bytes'], 'sha256': row['sha256']} for row in rows]
    record = {'schemaVersion': 1, 'recordedAtUTC': datetime.now(timezone.utc).isoformat(),
        'status': 'original-explore-infomap-implemented-JVM-JAR-verified-native-unverified',
        'scopeByStep': {'C3': 'preparatory implementation, whole step unfinished', 'C2': 'implementation evidence, in_progress', 'C4': 'preparatory; ordinary JAR public protocol only'},
        'actualProductionChange': p['implemented'],
        'sourceBinding': {'actualIntegrationBaseCommit': head, 'requiredCanonicalAncestor': BASE_COMMIT,
                          'files': source_rows, 'sourceInputs': source['continuity'],
                          'sourceFilesAndCompactSnapshotsCommittedWithThisRecord': True},
        'retainedVerification': {'acceptedUniqueMethods': 54, 'acceptedMethodIDs': sorted(leaves),
            'acceptedXML': v['acceptedXML'], 'newMethods': 5, 'oldMethods': 49,
            'finalV7Execution': {'methods': 16, 'new': 5, 'oldRuntime': 11}, 'unchangedV1MethodsReused': 38,
            'failures': 0, 'errors': 0, 'skipped': 0,
            'inputContinuity': {'total': 157, 'canonicalUnchanged': 146, 'changed': 11},
            'ordinaryJar': jar_row, 'ordinarySmokeMarkers': markers,
            'JunitOrProjectTestLeakage': 0, 'projectTestClassesExcluded': 150,
            'priorNoticeMembersPreserved': 21, 'old52SourceProvenanceRowsUnchanged': True,
            'newRawOriginalReferences': p['provenance']['newRawReferences'],
            'totalOriginalSourceEntries': 54, 'grammarReusedOnlyByExactFiveSourceHashes': v['grammarReuse'],
            'newNativeDefinitions': p['nativePreparedMethods'], 'newPackageDefinitions': p['packagePreparedMethods'],
            'SwiftSDKExecutions': 0, 'JNIExecutions': 0, 'deviceExecutions': 0,
            'newGrammarTestOrJARExecutionsByIntegration': 0},
        'historicalFailuresPreserved': {'attemptNotes': v['attempts'], 'ordinaryInitialFailure': failed,
            'reviewV1RetentionFindingsPreserved': True, 'reviewV2AndExploreOnlyAddendumPreserved': True,
            'actualFailuresAndCorrections': p['actualFailuresAndCorrections'],
            'repeatedOrFailedAttemptsAddedToAcceptedCounts': False},
        'historicalManifestScope': 'Frozen urlExpansionIntegration/webBookIntegration/publicTraditionalRuntimeIntegration descriptions retain their original stage wording and older explore TODOs. The current exploreInfoMapIntegration section narrows those TODOs with the actual explicit explore/context implementation. Historical text is not rewritten and does not mean current explore is wholly absent; UI navigation/render/buttons, all-source onPause and the default App route are still missing.',
        'remaining': p['remaining'] + ['Public content still uses needSave=false; unsupported media/non-text behavior and unfinished batch/cache/render/product gates remain explicit. Arbitrary erased non-String map values are typed rejected rather than retained, so full original object-map compatibility is not established.'],
        'defaultAppRouteChanged': False, 'newCloudRunRequested': False,
        'physicalDeviceValidationRequested': False,
        'evidence': {'path': EV.relative_to(ROOT).as_posix(), 'manifest': 'manifest.json', 'rawFiles': len(evidence_rows),
                     'all157InputsOrOld52OriginalEntriesDuplicated': False, 'JARBinariesExcluded': True},
        **{key: False for key in FALSE_KEYS}}
    writes.update({EV / name: item['raw'] for name,item in evidence.items()})
    writes[EV / 'manifest.json'] = encoded({'schemaVersion': 1, 'rawBytesPreserved': True, 'files': evidence_rows,
        'retainedLocalJarOnly': v['ordinaryJar'], 'old52OriginalEntriesBoundToCanonicalAncestor': BASE_COMMIT,
        'inputContinuityArchivedInsteadOfFull157SnapshotDuplication': True})
    writes[DOC] = encoded(record); writes[PLAN] = encoded(plan); writes[ATTRS] = attrs_before + rule
    assert PLAN.read_bytes() == plan_before and ATTRS.read_bytes() == attrs_before
    assert not git('status', '--porcelain') and git('rev-parse', 'HEAD').decode('ascii').strip() == head
    paths = sorted(path.relative_to(ROOT).as_posix() for path in writes)
    for path,raw in writes.items():
        path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)
        assert path.read_bytes() == raw
    if args.commit:
        assert not git('diff', '--cached', '--name-only')
        spec = BASE / 'root-stage-paths.nul'; spec.write_bytes(b'\0'.join(path.encode('utf8') for path in paths) + b'\0')
        subprocess.run(GIT + ['add', '--pathspec-from-file=' + str(spec), '--pathspec-file-nul'], cwd=ROOT, check=True)
        staged = git('diff', '--cached', '--name-only', '-z').rstrip(b'\0').decode('utf8').split('\0')
        assert set(staged) == set(paths)
        for path in paths: assert git('show', ':' + path) == writes[ROOT / path], path
        subprocess.run(GIT + ['diff', '--cached', '--check'], cwd=ROOT, check=True)
        subprocess.run(GIT + ['commit', '-m', 'feat(core): connect original exploration and InfoMap lifecycle'], cwd=ROOT, check=True)
        for row in rows: assert sha(git('show', 'HEAD:' + row['path'])) == row['sha256']
    summary.update(applied=True, committed=args.commit, canonicalPaths=len(paths))
    print(json.dumps(summary))


if __name__ == '__main__': main()
