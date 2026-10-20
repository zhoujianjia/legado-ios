"""Unexecuted root integration candidate: check by default, --apply to write,
--apply --commit to stage/commit exactly this reviewed Cookie/WebKit boundary.
No test/JVM/JAR/SDK/cloud/push/tag execution. Only --apply may grammar-parse the
single final merged Host once, before changing any canonical file.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import copy
import hashlib
import json
import runpy
import subprocess
import sys

ROOT = Path('F:/yuedu-reader')
BASE = ROOT / '.build/original-app-cookie-webkit-delta'
DOC = ROOT / 'docs/legado-ios/core-original-app-cookie-webkit-step.json'
EV = ROOT / 'docs/legado-ios/evidence/core-original-app-cookie-webkit-step'
PLAN = ROOT / 'docs/legado-ios/completion-plan.json'
ATTRS = ROOT / '.gitattributes'
GIT = ['D:/app/Git/cmd/git.exe', '-c', 'core.autocrlf=false']
EXPECTED_HEAD_PREFIX = '09f0a90'
AUDIT_SHA = '06c2d7e9c16069cecb7e61967d8909e39eb2bf8c5a4960e9aa5b002959327980'
HELPER_SHA = '8dacd3aa07485747189fcbb6c999037bb326a251756f68375a17771d38199d83'
HOST = 'Modules/Services/Online/LegadoPersistentStateHost.swift'
MANIFEST = 'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
FALSE_KEYS = ('allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
              'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished')


def sha(raw): return hashlib.sha256(raw).hexdigest()
def encoded(value): return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf8')
def git(*args): return subprocess.check_output(GIT + list(args), cwd=ROOT)


def merged_host_grammar_once(raw):
    """Root executes this only for --apply; no grammar run by this script's author."""
    target = BASE / 'root-integration-merged-host-grammar.json'
    if target.exists():
        result = json.loads(target.read_bytes())
        assert result['sha256'] == sha(raw) and result['bytes'] == len(raw)
        assert result['grammarOnly'] is True and result['SwiftSDKExecuted'] is False
        assert result['filesParsed'] == 1 and result['diagnostics'] == []
        return target, target.read_bytes()
    sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
    from tree_sitter import Language, Parser
    import tree_sitter_swift
    parser = Parser(Language(tree_sitter_swift.language()))
    nodes = [parser.parse(raw).root_node]
    diagnostics = []
    while nodes:
        node = nodes.pop()
        if node.type == 'ERROR' or node.is_missing:
            diagnostics.append({'kind': node.type, 'line': node.start_point[0] + 1,
                                'column': node.start_point[1] + 1,
                                'text': raw[node.start_byte:node.end_byte].decode('utf8')[:180]})
        nodes.extend(reversed(node.children))
    result = {'checkedAtUTC': datetime.now(timezone.utc).isoformat(), 'grammarOnly': True,
              'SwiftSDKExecuted': False, 'filesParsed': 1, 'path': HOST,
              'bytes': len(raw), 'sha256': sha(raw), 'diagnostics': diagnostics}
    out = encoded(result)
    with target.open('xb') as stream: stream.write(out)
    assert not diagnostics, 'Merged Host grammar failed; no canonical files were changed'
    return target, out


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--apply', action='store_true')
    cli.add_argument('--commit', action='store_true')
    args = cli.parse_args()
    assert not args.commit or args.apply
    head = git('rev-parse', 'HEAD').decode('ascii').strip()
    assert head.startswith(EXPECTED_HEAD_PREFIX), 'Root must re-review a changed integration base'
    assert not git('status', '--porcelain')
    assert not DOC.exists() and not EV.exists()
    helper = BASE / 'verify-root-integration-evidence.py'
    assert sha(helper.read_bytes()) == HELPER_SHA
    # Executes only retained evidence reads/hash/XML/JAR inspection, no external tool.
    api = runpy.run_path(str(helper))
    audit, payload = api['verify']()
    saved_audit_path = BASE / 'root-readonly-evidence-audit.json'
    saved_audit_raw = saved_audit_path.read_bytes()
    assert sha(saved_audit_raw) == AUDIT_SHA
    saved_audit = json.loads(saved_audit_raw)
    current = copy.deepcopy(audit); previous = copy.deepcopy(saved_audit)
    current.pop('auditedAtUTC'); previous.pop('auditedAtUTC')
    assert current == previous
    p = json.loads((BASE / 'freeze-v2/preparation.json').read_bytes())
    rows = p['sourceBinding']['changedCodeTestsAndProvenance']
    by_path = {row['path']: row for row in rows}
    assert len(rows) == len(by_path) == 19
    original_manifest_raw = (ROOT / by_path[MANIFEST]['snapshot']).read_bytes()
    original_manifest = json.loads(original_manifest_raw)
    manifest = copy.deepcopy(original_manifest)
    frozen_host = by_path[HOST]
    merged_path = BASE / 'root-preview-webkit-host-merge/LegadoPersistentStateHost.swift'
    merged_host = merged_path.read_bytes()
    merge = json.loads((BASE / 'root-preview-webkit-host-merge/merge.json').read_bytes())
    assert len(merged_host) == 46630 and sha(merged_host) == api['MERGED_SHA']
    # These three existing sections are current adapter-source bindings, already
    # refreshed together by the frozen author. Only their Host leaf changes here.
    mapping = []
    for section in ['appCookieOwnerReadIntegration', 'appCookieOwnerTextIntegration', 'appCookieOwnerWebKitIntegration']:
        matches = [(i, row) for i,row in enumerate(manifest[section]['integrationSources']) if row['path'] == HOST]
        assert len(matches) == 1
        index, row = matches[0]
        assert row['bytes'] == frozen_host['bytes'] and row['sha256'] == frozen_host['sha256']
        mapping.append({'jsonPath': [section, 'integrationSources', index],
                        'frozenDraft': dict(row),
                        'currentIntegration': {'path': HOST, 'bytes': len(merged_host), 'sha256': sha(merged_host)}})
        row.update(bytes=len(merged_host), sha256=sha(merged_host))
    check = copy.deepcopy(manifest)
    for item in mapping:
        section, field, index = item['jsonPath']
        check[section][field][index] = copy.deepcopy(item['frozenDraft'])
    assert check == original_manifest, 'Only three current Host SHA/byte bindings may differ'
    derived_manifest_raw = encoded(manifest)
    assert manifest['sourceProvenance'] == original_manifest['sourceProvenance']
    manifest_map = {'schemaVersion': 1,
        'reason': 'Merge already reviewed preview entity adapter with frozen Cookie/WebKit Host; preserve frozen and old-JAR manifests as historical execution evidence.',
        'frozenV2Manifest': {'path': by_path[MANIFEST]['snapshot'], 'bytes': len(original_manifest_raw), 'sha256': sha(original_manifest_raw)},
        'derivedCurrentManifest': {'path': MANIFEST, 'bytes': len(derived_manifest_raw), 'sha256': sha(derived_manifest_raw)},
        'updatedCurrentHostFields': mapping,
        'ordinaryJarOriginalManifest': p['validation']['ordinaryJar']['updatedOriginalRuleManifestMatchesReviewedFile'],
        'ordinaryJarRebuiltOrReexecuted': False, 'SwiftSDKExecuted': False,
        'historicalExecutionClaimsChanged': False}
    sources = {}
    source_binding = []
    for row in rows:
        raw = merged_host if row['path'] == HOST else derived_manifest_raw if row['path'] == MANIFEST else (ROOT / row['snapshot']).read_bytes()
        sources[ROOT / row['path']] = raw
        source_binding.append({'path': row['path'], 'bytes': len(raw), 'sha256': sha(raw),
                               'frozenDraftBytes': row['bytes'], 'frozenDraftSHA256': row['sha256'],
                               'bindingKind': 'reviewed-preview-cookie-merge' if row['path'] == HOST else 'derived-current-host-source-binding-only' if row['path'] == MANIFEST else 'exact-frozen-v2'})
    assert sum(row['sha256'] != row['frozenDraftSHA256'] for row in source_binding) == 2
    assert len(p['validation']['newSDKDefinitions']['LegadoCookieBrowserHostTests']) == 5
    assert len(p['validation']['newSDKDefinitions']['LegadoHostEffectsTests']) == 2
    assert p['validation']['newNativeAppDefinitions'] == 5 and p['validation']['newPackageDefinitions'] == 2
    assert p['validation']['SwiftSDKExecuted'] is False and p['validation']['newSwiftGateSDKExecuted'] is False

    plan_before = PLAN.read_bytes(); plan = json.loads(plan_before)
    assert len(plan['execution']['deferredQueue']) == 17
    deferred = copy.deepcopy(plan['execution']['deferredQueue'])
    steps = {step['id']: step for step in plan['execution']['stepByStep']['steps']}
    assert steps['C2']['status'] == 'in_progress'
    old_status = {key: step['status'] for key,step in steps.items()}
    accepted = {key: copy.deepcopy(step.get('actualAcceptedEvidence')) for key,step in steps.items()}
    assert all(plan[key] is False for key in FALSE_KEYS)
    relative_doc = DOC.relative_to(ROOT).as_posix()
    steps['C2']['implementationEvidence'].append(relative_doc)
    steps['C2']['implementedSubtasksZh'].append('已准备原 Cookie clear 的字面ASCII竖线SQL子集、同actor进程缓存寿命及既有WK cookie store真实操作接线；同Host保留已合入预览的实体grant/原始键校验。现存29项JVM/5组与普通JAR五组smoke原证据通过，Swift5项与Package2项仅定义、SDK0；v2超时门禁和合并Host未被旧JAR执行。')
    steps['C2']['nextActionZh'] = '集中验证Cookie5项、Package2项、预览15项及受影响旧owner；继续原始字符串、缓存寿命完整合同与普通JAR/JNI/App真实路线，不以JVM或语法记录验收C2。'
    steps['C4'].setdefault('preparatoryImplementationEvidence', []).append(relative_doc)
    steps['C4']['preparatoryScopeZh'] = steps['C4'].get('preparatoryScopeZh', '') + '；Cookie/WebKit公开协议及同预览Host合并为后续接线准备，旧JAR仅绑定其当时输入/manifest，新Swift5和Package2未执行；默认路线仍未切换。'
    plan['execution']['stepByStep']['appCookieWebKitImplementation'] = relative_doc
    plan['existingEvidence']['app-cookie-webkit'] = {'path': relative_doc,
        'scope': 'Actual retained JVM29/5XML and ordinary JAR5 smoke against their original153-input boundaries; current native5/Package2 and merged preview Host remain SDK0. C2 implementation/C4 preparatory only.'}
    assert deferred == plan['execution']['deferredQueue']
    assert old_status == {key: step['status'] for key,step in steps.items()}
    assert accepted == {key: step.get('actualAcceptedEvidence') for key,step in steps.items()}
    assert all(plan[key] is False for key in FALSE_KEYS)
    attrs_before = ATTRS.read_bytes()
    rule = b'docs/legado-ios/evidence/core-original-app-cookie-webkit-step/** -text -whitespace\n'
    assert rule not in attrs_before and (not attrs_before or attrs_before.endswith(b'\n'))
    summary = {'verifiedOnly': not args.apply, 'integrationBaseCommit': head,
        'sourceFiles': 19, 'exactFrozenSources': 17, 'reviewedMergedHost': sha(merged_host),
        'derivedManifest': sha(derived_manifest_raw), 'actualJVMMethods': 29,
        'focusedInputs': 153, 'ordinaryInputs': 153, 'ordinarySmokeMarkers': 5,
        'newNativeDefinitionsOnly': 5, 'newPackageDefinitionsOnly': 2, 'SwiftSDKExecutions': 0,
        'mergedHostGrammarStillToBeRunByRoot': not (BASE / 'root-integration-merged-host-grammar.json').exists()}
    if not args.apply:
        print(json.dumps(summary)); return

    # The one merged Swift source is the sole new grammar input. This executes only
    # after root explicitly chooses --apply; failures remain ignored evidence only.
    grammar_path, grammar_raw = merged_host_grammar_once(merged_host)
    payload['root-integration-merged-host-grammar.json'] = {'sourcePath': grammar_path.relative_to(ROOT).as_posix(), 'raw': grammar_raw}
    payload['root-readonly-evidence-audit.json'] = {'sourcePath': saved_audit_path.relative_to(ROOT).as_posix(), 'raw': saved_audit_raw}
    payload['derived-manifest-current-host-map.json'] = {'sourcePath': 'derived-by-reviewed-root-integration-script', 'raw': encoded(manifest_map)}
    for path in [helper, Path(__file__)]:
        payload['integration-tools/' + path.name] = {'sourcePath': path.relative_to(ROOT).as_posix(), 'raw': path.read_bytes()}
    evidence_rows = [{'path': name, 'sourcePath': item['sourcePath'], 'bytes': len(item['raw']), 'sha256': sha(item['raw'])} for name,item in payload.items()]
    record = {'schemaVersion': 1, 'recordedAtUTC': datetime.now(timezone.utc).isoformat(),
        'status': 'cookie-webkit-original-protocol-implemented-native-sdk-unverified',
        'scopeByStep': {'C2': 'implementation evidence only; in_progress', 'C4': 'preparatory; no default product-route change'},
        'actualProductionChange': p['implemented'], 'timeoutAdmissionFix': p['reviewFix'],
        'sourceBinding': {'integrationBaseCommit': head, 'files': source_binding,
                          'manifestHostDerivation': manifest_map,
                          'canonicalSourceFilesCommittedWithThisRecord': True},
        'actualRetainedVerification': {'JVMUniqueQualifiedMethods': 29, 'JVMQualifiedMethodIDs': audit['actualJVMQualifiedLeaves'],
            'JVMSuites': 5, 'failures': 0, 'errors': 0, 'skipped': 0,
            'focusedInputs': 153, 'ordinaryInputs': 153, 'onlyOrdinaryInputDelta': audit['ordinaryInputOnlyDelta'],
            'ordinaryJar': audit['ordinaryJar'], 'ordinarySmokeMarkers': audit['ordinarySmokeMarkers'],
            'JunitAndProjectTestLeakage': 0, 'projectTestClassesExcluded': 141,
            'oldProvenanceAndNoticeMembersPreserved': 21, 'originalZIPEntriesPreserved': 52,
            'oldOriginalRowsUnchanged': 50, 'JVMOrJarReexecutedByIntegration': 0},
        'preparedSDKVerification': {'nativeAppDefinitions': 5, 'packageDefinitions': 2,
            'methods': p['validation']['newSDKDefinitions'], 'SwiftSDKExecuted': False,
            'JNIExecuted': False, 'nativeExecuted': False, 'mergedHostNewGrammarInputs': 1,
            'mergedHostGrammarDiagnostics': 0,
            'frozenV2SwiftGrammarReusedOnlyByExactSourceHashes': p['validation']['grammarFinal'],
            'oldJarDoesNotExecuteNewSwiftGateOrMergedHostOrDerivedManifest': True},
        'historicalEvidenceHandling': {'v1PreparationPreserved': True,
            'v1StandaloneIndependentReviewRawAvailable': any('independent-review-v1' in name for name in payload),
            'v1GapPreservedByV2ReviewFixAndIndependentReview': True,
            'v2PreparationAndIndependentReviewPreserved': True,
            'frozenAndOldJarManifestRawPreserved': True,
            'oldJARNotRepackedOrAcceptedAsNewSwiftExecution': True},
        'remaining': p['actualRemaining'] + [
            'Preview entity semantics are retained in the separately reviewed merged Host. Actual JNI, WK native owner, timeout gate, and full product-route SDK execution remain unfinished.',
            'Only explicit same-owner/cache/SQL/native-operation contracts are supplied. Full Java String, original global CacheManager LRU, foreign-WK writer CAS and whole C2/C3/C4 compatibility remain unfinished.',
            'Foundation atomic replacement is not explicit file/directory fsync or power-loss durability. No real-device verification is claimed.'],
        'defaultProductRouteEnabled': False, 'newCloudRunRequested': False,
        'physicalDeviceValidationRequested': False,
        'evidence': {'path': EV.relative_to(ROOT).as_posix(), 'manifest': 'manifest.json',
                     'rawFiles': len(evidence_rows), 'JARBinaryExcluded': True,
                     'privateOrRuntimeUserDataIncluded': False},
        **{key: False for key in FALSE_KEYS}}
    writes = dict(sources)
    writes.update({EV / name: item['raw'] for name,item in payload.items()})
    writes[EV / 'manifest.json'] = encoded({'schemaVersion': 1, 'rawBytesPreserved': True,
        'files': evidence_rows, 'binaryJARLocalOnly': audit['ordinaryJar'],
        'currentNineteenSourceFilesBoundToCanonicalGitInsteadOfDuplicated': source_binding})
    writes[DOC] = encoded(record); writes[PLAN] = encoded(plan); writes[ATTRS] = attrs_before + rule
    assert not git('status', '--porcelain') and PLAN.read_bytes() == plan_before and ATTRS.read_bytes() == attrs_before
    paths = sorted(path.relative_to(ROOT).as_posix() for path in writes)
    for path,raw in writes.items():
        path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)
        assert path.read_bytes() == raw
    if args.commit:
        assert not git('diff', '--cached', '--name-only')
        spec = BASE / 'root-stage-paths-v2.nul'
        spec.write_bytes(b'\0'.join(path.encode('utf8') for path in paths) + b'\0')
        subprocess.run(GIT + ['add', '--pathspec-from-file=' + str(spec), '--pathspec-file-nul'], cwd=ROOT, check=True)
        staged = git('diff', '--cached', '--name-only', '-z').rstrip(b'\0').decode('utf8').split('\0')
        assert set(staged) == set(paths)
        for path in paths: assert git('show', ':' + path) == writes[ROOT / path], path
        subprocess.run(GIT + ['diff', '--cached', '--check'], cwd=ROOT, check=True)
        subprocess.run(GIT + ['commit', '-m', 'feat(core): connect original Cookie browser operations to shared native owner'], cwd=ROOT, check=True)
        for row in source_binding: assert sha(git('show', 'HEAD:' + row['path'])) == row['sha256']
    summary.update(applied=True, committed=args.commit, canonicalPaths=len(paths), publicRawEvidenceFiles=len(evidence_rows))
    print(json.dumps(summary))


if __name__ == '__main__': main()
