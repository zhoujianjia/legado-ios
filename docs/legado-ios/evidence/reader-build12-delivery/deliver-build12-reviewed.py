"""Once-only local handoff. Root is the only canonical/Downloads writer.

No network, signing, installation, test execution or source modification.
Copies are exclusive; historical evidence and the user's report are preserved.
"""
from datetime import datetime, timezone
from pathlib import Path
import copy
import hashlib
import importlib.util
import json
import os
import re

ROOT = Path(__file__).resolve().parents[2]
DOWNLOADS = Path('C:/Users/ZJJ/Downloads')
DEST = ROOT / 'docs/legado-ios/evidence/reader-build12-delivery'
RECORD = ROOT / 'docs/legado-ios/native-reader-experience-build12.json'
A = 'a76d380fdc108db83be68961905ee49edd209571'
C = '1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06'
FLAGS = ('allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished')
PLAN = ROOT / 'docs/legado-ios/completion-plan.json'
BATCH = ROOT / 'docs/legado-ios/self-renewal-dynamic-discovery-batch.json'
RESEARCH = ROOT / 'docs/legado-ios/self-renewal-research.json'
RELEASE = ROOT / 'docs/legado-ios/build12-release-audit-a76d380.json'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
    require(path.is_file() and not path.is_symlink(), 'Missing/nonregular input: ' + str(path))
    return path.read_bytes()


def js(data):
    return json.loads(data.decode('utf-8'))


def encode(value):
    data = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    require(b'\xef\xbf\xbd' not in data, 'Replacement character')
    return data


def exclusive(path, data):
    require(not path.exists() and not path.is_symlink(), 'Refusing overwrite: ' + str(path))
    with path.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    require(read(path) == data, 'Post-write mismatch')


def rel(path):
    return path.relative_to(ROOT).as_posix()


def main():
    require(DOWNLOADS.resolve() == Path('C:/Users/ZJJ/Downloads').resolve()
            and DOWNLOADS.is_dir() and not DOWNLOADS.is_symlink(), 'Unexpected delivery directory')
    require(not DEST.exists() and not RECORD.exists(), 'Handoff already recorded; no rerun')
    audit_path = ROOT / '.build/renewal-discovery/C-renewal-actual-independent-audit.json'
    audit_raw = read(audit_path)
    require(sha(audit_raw) == 'f5e00d24f53689fd9ceb6b45fc4061b7c5c9d3c6c95d258fb2d3bf0d3e5672f9', 'Wrong independent C audit')
    audit = js(audit_raw)
    require(audit['sourceCommit'] == C and audit['unresolvedBlockingFindings'] == []
            and audit['job']['conclusion'] == 'success'
            and audit['AReleaseAndNarrowMapping']['opinionSupportsExplicitRootNarrowDiagnosticHandoffMapping'] is True,
            'Diagnostic prerequisite not satisfied')
    require([(v['actualMethods'], v['actualExecutions'], v['failures'], v['skips'], v['expectedFailures'])
             for v in audit['groups'].values()] == [(8, 8, 0, 0, 0), (13, 13, 0, 0, 0), (1, 1, 0, 0, 0)],
            'Actual diagnostic group changed')
    scope_path = ROOT / 'docs/legado-ios/evidence/reader-build12-a76d380/source-scope/build12-A-C-diagnostic-source-scope-review.json'
    require(sha(read(scope_path)) == '8f1064d97b340b92b1960dab95cedd56b0ca893a1e919cf99cdcf7911ed3bc9a', 'Scope review changed')
    before = {p: read(p) for p in (PLAN, BATCH, RESEARCH, RELEASE)}
    plan, batch, research, release = (js(before[p]) for p in (PLAN, BATCH, RESEARCH, RELEASE))
    require(all(plan[k] is False for k in FLAGS), 'Global completion flag changed')
    require(release['sourceCommit'] == A and release['staticIPAAndSourceAuditsPassed'] is True, 'Wrong Release audit')
    for item in audit['AReleaseAndNarrowMapping']['existingActualThreeAuditsRehashed']:
        require(sha(read(Path(item['path']))) == item['sha256'] and item['passed'] is True, 'A audit changed')
    entries = []
    raw_inputs = []
    names = ('LocalBookshelf-build12-a76d380-unsigned.ipa',
             'LocalBookshelf-build12-a76d380-manifest.json', 'LocalBookshelf-source-a76d380.zip')
    for item, name in zip(release['candidateEntryPoints'], names, strict=True):
        data = read(ROOT / item['path'])
        require((len(data), sha(data)) == (item['bytes'], item['sha256']), 'Release input mismatch')
        target = DOWNLOADS / name
        require(not target.exists(), 'Existing delivery file: ' + name)
        raw_inputs.append((target, data))
        entries.append({**item, 'localPath': str(target), 'copyVerified': True})
    manifest = js(raw_inputs[1][1])
    require((manifest['sourceCommit'], manifest['build'], manifest['version'], manifest['configuration'])
            == (A, '12', '3.0.0', 'Release'), 'Wrong manifest identity')
    readme = read(ROOT / '.build/renewal-discovery/build12-delivery-preparation/LocalBookshelf-build12-a76d380-README.txt')
    require(sha(readme) == '48d59ead5ca0f5701c4928dcb2aa38154b13813bc322ddb83cbf5a453fad48bd', 'Unreviewed README')
    require('\ufffd' not in readme.decode('utf-8') and '?' not in readme.decode('utf-8'), 'Damaged README prose')
    target = DOWNLOADS / 'LocalBookshelf-build12-a76d380-README.txt'
    require(not target.exists(), 'Existing README')
    raw_inputs.append((target, readme))
    entries.append({'path': rel(ROOT / '.build/renewal-discovery/build12-delivery-preparation/LocalBookshelf-build12-a76d380-README.txt'),
                    'localPath': str(target), 'bytes': len(readme), 'sha256': sha(readme), 'copyVerified': True})
    recorded = datetime.now(timezone.utc).isoformat()
    mapping = {
        'acceptedBy': '/root', 'acceptedAtUTC': recorded,
        'decision': 'Accept narrowly scoped diagnostic device handoff only',
        'ReleaseSourceCommit': A, 'actualDiagnosticTestSourceCommit': C,
        'sameSourceAcceptance': False, 'wholeAppOrReleaseBinaryRuntimeAcceptance': False,
        'sourceScopeReview': {'path': rel(scope_path), 'sha256': sha(read(scope_path))},
        'independentActualCAudit': {'path': rel(DEST / audit_path.name), 'sha256': sha(audit_raw)},
        'basis': 'Actual C8/13/UI1 and successful preflight apply only to the unchanged narrow diagnostic projection: 28/29 whole inputs equal; the helper differs outside ten raw/AST-identical reachable functions. A IPA, source archive and JVM static/raw-XML audits separately passed. All C results stay C-bound; delivered bytes stay A-bound.',
        'excluded': ['font and position runtime', 'Firestore schema observations', 'launch/memory samples',
                     'UMD parser or product import', 'physical device behavior', 'authenticated service identity',
                     'signing', 'installation', 'automatic renewal'],
        'builtCInfoReReadOffline': False,
        'originalAggregateRunConflict': audit['aggregateRun'],
        'successfulJobAndUploadAcceptanceDoesNotRewriteAggregateAPI': True,
    }
    record = {
        'schemaVersion': 1, 'recordKind': 'audited-build12-read-only-diagnostic-device-handoff',
        'recordedAtUTC': recorded, 'status': 'delivered-unsigned-awaiting-user-dynamic-discovery-report',
        'version': '3.0.0', 'build': '12', 'sourceCommit': A, 'minimumIOS': '18.0',
        'bundleIdentifier': manifest['bundleIdentifier'], 'signed': False, 'installed': False,
        'delivered': True, **{k: False for k in FLAGS}, 'automaticSelfRenewalVerified': False,
        'delivery': entries, 'releaseAudit': rel(RELEASE), 'explicitDiagnosticMapping': mapping,
        'actualDiagnosticTests': {'sourceCommit': C, 'runID': audit['runID'], 'job': audit['job'],
                                  'groups': {'legacy': '8/8', 'discovery': '13/13', 'UI': '1/1'},
                                  'failures': 0, 'skips': 0, 'expectedFailures': 0,
                                  'platform': 'Debug iOS Simulator', 'ReleaseIPAExecuted': False},
        'instructionsZh': '沿用原签名方式与同一账号／团队、主 App 及扩展 Bundle ID 映射覆盖安装，保留书籍、书源及进度，不要卸载。电脑关机、拔 USB，手机 Wi-Fi 开、VPN 关；设置 → 高级 → 自续签验证 → 开始连接验证 → 导出验证报告。无需安装 SideStore。',
        'requestMeaning': 'Only a bounded RemotePairing discovery and same-device TCP diagnostic; no authentication, signing or replacement installation implementation.',
        'oldReportPreserved': 'docs/legado-ios/self-renewal-device-transport-build10.json',
        'newDeviceReportReceived': False, 'builtInSources': False, 'privateSourcesReadOrUploaded': False,
        'temporaryPublicDiagnosticPolicy': {'existingAuthorizationOnly': True, 'retentionDays': 1,
                                          'formalRedistributionClearanceEstablished': False},
        'historicalDocumentSnapshots': [rel(DEST / (p.name + '.before')) for p in before],
    }
    package = next(p for p in plan['workpackages'] if p['id'] == 'automatic-renewal-feasibility')
    package['execution']['currentState'] = '动态发现探针已在固定 C 源码的真实 Xcode 26.2 Debug Simulator 通过旧通道 8／发现 13／界面 1，零失败、跳过和预期失败。A build12 的 IPA、资源、JVM 与对应源码审计通过；已按独立源码范围证明明确接受仅诊断范围的 A／C 映射，并交付未签名包。电脑离线条件的动态发现真机报告尚未收到，认证安装与完整自动续签均未实现。'
    package['execution']['nextAction'] = '用户按 build12 说明验证电脑关机且 USB 断开时的动态发现，导出 JSON；先核对发现与 TCP 证据，再决定有界认证传输工作。其他 ready 开发继续，不重复本次已通过且未改变的探针测试。'
    package['execution']['readiness'] = 'deferred-device'
    package['execution']['deferredHardware'] = ['已按用户要求交付 build12 通道诊断包，待电脑关机、USB 断开的动态发现报告；认证 transport、签名、替换安装、冷启数据与无人值守分别待验。']
    package['execution']['evidence'].append(rel(RECORD))
    package['existingEvidence'].append('build12-diagnostic-handoff')
    plan['existingEvidence']['build12-diagnostic-handoff'] = {'path': rel(RECORD), 'scope': 'A Release static audits plus explicitly mapped unchanged C8/13/UI1 diagnostic; unsigned handoff only, no service/auth/install/renewal acceptance.'}
    plan['execution']['currentDeviceCandidate'] = {'userRequestedOn': '2026-10-19', 'scopeZh': '已交付动态发现与同设备 TCP 只读诊断包，待用户导出报告；完整自动续签仍未实现。', 'record': rel(RECORD), 'build': '12', 'fullAutomaticRenewalImplemented': False}
    plan['execution']['awaitingEvidenceQueue'].remove('automatic-renewal-feasibility')
    plan['execution']['deferredQueue'].append('automatic-renewal-feasibility')
    policy = plan['execution']['cloudTriggerPolicy']
    policy['alreadyRunningTasks'] = 'Saved actual C renewal job118155310210/source1a87f6d completed success, all11steps and source-bound 8/13/UI1 passed; original aggregate API in_progress is preserved without inferring run completion. A Release39272843081/sourcea76d380 audited and build12 delivered via explicit narrow diagnostic mapping. C smoke39281083749 failed in portable collector setUp with zero Swift/iOS; test-owned canonical temp-root repair is included for the next consolidated source-only checkpoint. Prior failures remain immutable.'
    policy['nextPlannedCheckpoint'] = 'Submit one coherent source-only smoke and independent measurements checkpoint with reviewed UMD parser16, launch/memory9, runner8 and actual C test-owned temporary-root repair. Keep existing smoke groups, memory1/UI1/UMD11 and schema observations separate. No new Release or unchanged renewal run; A build12 is already delivered as a narrowly scoped diagnostic candidate.'
    batch['status'] = 'actual-C-diagnostics-passed-A-build12-narrow-handoff-delivered'
    batch['verification'].update({'newDiscoverySwiftTestsExecuted': True, 'actualSimulatorCasesPassed': {'legacyUnit': 8, 'discovery': 13, 'UI': 1}, 'AppleSDKCompilationPassed': True, 'AppleSDKLinkPassed': True, 'AppleSDKAcceptanceScope': 'Actual fixed C Debug arm64 Simulator app/test build and selected 8/13/UI1. A Release has separate static audits and explicit narrow diagnostic mapping; no whole-App or physical-device runtime acceptance.'})
    batch['plannedDeviceCandidate'].update({'status': record['status'], 'delivered': True, 'record': rel(RECORD)})
    batch['actualReleaseArtifactAudit'].update({'SimulatorDiagnosticsAccepted': True, 'ACRelevantSourceScopeReuseAccepted': True, 'delivered': True, 'handoffRecord': rel(RECORD), 'diagnosticSourceIsCNotA': True})
    batch['actualPassedDiagnosticCheckpoint'] = record['actualDiagnosticTests']
    research['status'] = 'dynamic-discovery-Simulator-verified-build12-delivered-device-report-pending'
    research['verification'].update(batch['verification'])
    research['previousDeviceCandidates'].append(copy.deepcopy(research['nextDeviceCandidate']))
    research['nextDeviceCandidate'] = {'build': '12', 'status': record['status'], 'sourceCommit': A, 'record': RECORD.name, 'builtInSources': False, 'IPAIndependentlyAudited': True, 'localIPAPath': entries[0]['localPath'], 'ipaSHA256': entries[0]['sha256'], 'signedOrInstalled': False, 'automaticSelfRenewalImplemented': False}
    research['nextDevelopmentCandidate'] = copy.deepcopy(research['nextDeviceCandidate'])
    research['currentUserRequest']['record'] = RECORD.name
    research['previousDiscoveryCloudCheckpoint'] = research['currentDiscoveryCloudCheckpoint']
    research['currentDiscoveryCloudCheckpoint'] = {**record['actualDiagnosticTests'], 'record': rel(RECORD), 'aggregateRunConflictPreserved': True}
    research['completedGates'].append('Fixed C actual 8 legacy/13 discovery/UI1 passed and independently audited; A build12 separately audited and handed off only through explicit narrow unchanged-diagnostic source mapping.')
    research['nextGates'] = research['nextGates'][2:]
    release['subsequentHandoff'] = {'record': rel(RECORD), 'recordedAtUTC': recorded, 'delivered': True, 'originalFieldsAboveAreInitialStaticAuditSnapshot': True, 'explicitNarrowDiagnosticMappingAccepted': True, 'ReleaseBinaryExecuted': False}
    changes = {PLAN: encode(plan), BATCH: encode(batch), RESEARCH: encode(research), RELEASE: encode(release)}
    require(all(plan[k] is False for k in FLAGS), 'Completion boundary changed')
    require(all(read(p) == before[p] for p in before), 'Concurrent document mutation')
    # All prerequisite checks precede exclusive user delivery.
    DEST.mkdir(exist_ok=False)
    for path, data in before.items():
        exclusive(DEST / (path.name + '.before'), data)
    exclusive(DEST / audit_path.name, audit_raw)
    exclusive(DEST / 'LocalBookshelf-build12-a76d380-README.txt', readme)
    exclusive(DEST / Path(__file__).name, read(Path(__file__).resolve()))
    for target, data in raw_inputs:
        exclusive(target, data)
    exclusive(RECORD, encode(record))
    for path, data in changes.items():
        require(read(path) == before[path], 'Concurrent mutation before replace')
        temp = DEST / (path.name + '.after')
        exclusive(temp, data)
        staging = path.with_name('.' + path.name + '.build12-handoff.tmp')
        exclusive(staging, data)
        os.replace(staging, path)
    checker_path = ROOT / 'scripts/reader-experience/check-completion-plan.py'
    spec = importlib.util.spec_from_file_location('plan_checker_build12', checker_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    checked = module.validate(plan, js(read(ROOT / 'docs/legado-ios/feature-catalog.json')), ROOT, require_execution=True)
    require(checked['status'] == 'passed', 'Plan structure failed')
    exclusive(DEST / 'plan-check.json', encode(checked))
    for target, data in raw_inputs:
        require(sha(read(target)) == sha(data), 'Final delivery mismatch')
    print(json.dumps({'status': record['status'], 'record': rel(RECORD), 'recordSHA256': sha(read(RECORD)),
                      'deliveredFiles': len(entries), 'planCheck': checked['status'], 'automaticSelfRenewalImplemented': False}))


if __name__ == '__main__':
    main()
