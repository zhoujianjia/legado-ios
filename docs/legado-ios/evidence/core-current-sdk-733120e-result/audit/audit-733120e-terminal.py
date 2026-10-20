import hashlib
import json
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

ROOT = pathlib.Path('F:/yuedu-reader')
STAGE = ROOT / '.build/renewal-discovery/core-sdk-account-selection-step/actual-733120e'
BASE = ROOT / '.build/sdk-evidence/733120e'
NATIVE = BASE / 'native/reader-renewal-probe'
PACKAGE = BASE / 'package/reader-renewal-original-api'
COMMIT = '733120e01f9250ea7509640080148249274a2d74'
GIT = 'D:/app/Git/cmd/git.exe'

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def item(path):
    raw = path.read_bytes()
    return {'path': path.relative_to(ROOT).as_posix(), 'bytes': len(raw), 'sha256': sha(raw)}

def equal_row(path, row):
    raw = path.read_bytes()
    assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], str(path)

job = read(STAGE / 'jobs.followup3.connector.json')['structuredContent']['jobs']
assert len(job) == 1 and job[0]['id'] == 118603717942
assert job[0]['status'] == 'completed' and job[0]['conclusion'] == 'failure'
native = read(NATIVE / 'source-inputs.json')
package = read(PACKAGE / 'result.json')
pkg_inputs = read(PACKAGE / 'source-inputs.json')
assert native['sourceCommit'] == package['sourceCommit'] == COMMIT
assert len(native['sourceInputs']) == 232
assert len(package['sourceInputs']) == 22 and package['packageSourceInputCount'] == 15
assert package['sourceInputs'] == pkg_inputs['sourceInputs']
all_rows = native['sourceInputs'] + package['sourceInputs']
rows = {}
for row in all_rows:
    assert row['path'] not in rows or rows[row['path']] == row
    rows[row['path']] = row
names = list(rows)
proc = subprocess.run([GIT, 'cat-file', '--batch'],
    input=''.join(COMMIT + ':' + p + '\n' for p in names).encode(),
    cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
cursor = 0
for name in names:
    end = proc.stdout.index(b'\n', cursor)
    header = proc.stdout[cursor:end].split()
    assert len(header) == 3 and header[1] == b'blob', name
    size = int(header[2]); start = end + 1
    raw = proc.stdout[start:start + size]
    assert len(raw) == rows[name]['bytes'] and sha(raw) == rows[name]['sha256'], name
    assert proc.stdout[start + size:start + size + 1] == b'\n'
    cursor = start + size + 1
assert cursor == len(proc.stdout)

artifacts = []
for kind, artifact_id, count in [('package', 12261344082, 9), ('native', 12261284623, 67)]:
    summary = read(STAGE / ('download-' + kind + '-summary.json'))
    assert summary['artifactID'] == artifact_id and summary['runID'] == 39415600445
    equal_row(STAGE / (kind + '-evidence.zip'), summary)
    assert summary['verifiedAgainstGitHubArtifactDigest'] and len(summary['members']) == count
    for row in summary['members']:
        equal_row(ROOT / row['path'], row)
    artifacts.append({'artifactID': artifact_id, 'bytes': summary['bytes'],
        'sha256': summary['sha256'], 'memberCount': count})

expected = package['qualifiedXCTestMethods']
assert len(expected) == len(set(expected)) == 17
xml = ET.parse(PACKAGE / 'xunit.xml').getroot()
xml_cases = xml.findall('.//testcase')
assert len(xml_cases) == 17
assert not xml.findall('.//failure') and not xml.findall('.//error') and not xml.findall('.//skipped')
xml_ids = sorted(c.attrib['classname'] + '/' + c.attrib['name'] for c in xml_cases)
log = (PACKAGE / 'tests.log').read_text(encoding='utf-8')
verbose_ids = sorted(a + '/' + b for a, b in re.findall(
    r"Test Case '-\[([^ ]+) ([^\]]+)\]' passed", log))
assert sorted(expected) == xml_ids == verbose_ids == package['passedCaseIdentifiers'] == package['verbosePassedCaseIdentifiers']
assert package['totalTestCount'] == 17 and package['failedTests'] == package['skippedTests'] == 0
assert package['status'] == 'passed' and package['runtimeSourceOnly'] and not package['jvmExecuted']
execution = read(PACKAGE / 'execution.json')
assert execution['completed'] and not execution['timedOut'] and execution['exitCode'] == 0
assert execution['arguments'][execution['arguments'].index('--filter') + 1] == package['filter']
assert '--disable-swift-testing' in execution['arguments']
for name, digest in package['evidenceSHA256'].items():
    assert sha((PACKAGE / name).read_bytes()) == digest, name
package_rows = [r for r in package['sourceInputs'] if r['path'].startswith('Packages/')]
assert len(package_rows) == 15
for row in package_rows:
    if row['path'].endswith(('.swift', '.m')):
        assert '/' + row['path'] in log, row['path']
assert '-DSWIFT_PACKAGE=1' in log and '-DLGR_WITH_OPENJDK' not in log

pipeline = read(NATIVE / 'currentcore-pipeline.json')
assert not pipeline['allPhasesSucceeded'] and pipeline['qualifiedMethodDefinitions'] == 353
assert pipeline['argumentLeaves'] == 355
phases = []
for row in pipeline['phaseRecords']:
    equal_row(NATIVE / row['path'], row)
    phase = read(NATIVE / row['path'])
    assert phase['sourceBefore'] == phase['sourceAfter']
    assert phase['sourceBefore']['sourceCommit'] == COMMIT
    assert phase['sourceBefore']['sourceInputCount'] == 232
    cmd = phase.get('command')
    if cmd:
        equal_row(NATIVE / cmd['output'], cmd)
        if 'stderr' in cmd:
            equal_row(NATIVE / cmd['stderr'], {'bytes': cmd['stderrBytes'], 'sha256': cmd['stderrSHA256']})
    phases.append({'phase': phase['phase'], 'state': phase['state'],
        'exitCode': cmd['exitCode'] if cmd else None,
        'timedOut': cmd['timedOut'] if cmd else None,
        'elapsedSeconds': phase['elapsedSeconds']})
native_phase = read(NATIVE / 'currentcore-phase-native.json')
equal_row(NATIVE / native_phase['nativeLog']['path'], native_phase['nativeLog'])
assert native_phase['reportedXcodebuildStatuses'] == [{'exitCode': 65, 'wrapperVerdictStop': False}]
assert native_phase['state'] == 'failed' and not native_phase['wrapperReportedBudgetTimeout']
native_log = (NATIVE / 'currentcore-tests.log').read_text(encoding='utf-8')
diagnostics = [line for line in native_log.splitlines() if ': error:' in line]
assert len(diagnostics) == 1 and 'BookSourceHealthChecker.swift:58:1:' in diagnostics[0]
assert "does not conform to protocol 'BookSourceHealthCheckFetching'" in diagnostics[0]
summary = read(NATIVE / 'currentcore-summary.json')
assert summary['totalTestCount'] == summary['passedTests'] == summary['failedTests'] == 0
producer_lines = (NATIVE / 'currentcore-producer.log').read_text(encoding='utf-8').splitlines()
timeout = [json.loads(x.split(' ', 1)[1]) for x in producer_lines if x.startswith('OWNED_TOOL_TIMEOUT ')]
assert len(timeout) == 1 and timeout[0]['timeoutSeconds'] == 20 and timeout[0]['timedOut']
assert timeout[0]['processReturnCode'] == -9 and timeout[0]['processCleanup']['issues'] == []
assert 'ToolTimeout: private tool failed: 124' in (NATIVE / 'currentcore-producer.log.stderr.log').read_text(encoding='utf-8')
trust = [json.loads(x.split(' ', 1)[1]) for x in producer_lines if x.startswith('OWNED_USER_TRUST_STATUS ')]
assert len(trust) == 2 and trust[0]['authorizationPreflightPassed'] and trust[1]['cleanupVerified']
assert trust[1]['priorSettingsAbsent'] and trust[1]['settingsEntryCount'] == 0
assert not any(x.startswith('OWNED_USER_TRUST_STATUS ') and 'installOwnedUserTrust' in x for x in producer_lines)
assert any(x.startswith('OWNED_KEYCHAIN_CLEANUP ') and json.loads(x.split(' ', 1)[1])['exitCode'] == 0 for x in producer_lines)

job_raw = read(STAGE / 'job.logs.terminal.connector.json')['structuredContent']['content']
assert 'Ran 24 tests' in job_raw and 'Ran 59 tests' in job_raw and 'FAILED (failures=2)' in job_raw
failures = re.findall(r'FAIL: (test_[^ ]+)', job_raw)
assert failures == ['test_controlledsigning_source_methods_wrapper_and_workflow_keep_sdk_groups_independent',
    'test_integrated_leaf_union_matches_source_and_excludes_storage_benchmark']
guard_path = STAGE / 'portable-job-terminal.log'
guard_path.write_bytes(job_raw.encode())

sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
import tree_sitter
import tree_sitter_swift
health = ROOT / 'Modules/Core/BookSource/BookSourceHealthChecker.swift'
parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
tree = parser.parse(health.read_bytes())
assert not tree.root_node.has_error
grammar = {'checker': 'tree-sitter-swift-only', 'input': item(health), 'parseCount': 1,
    'errorCount': 0, 'SwiftCompilerExecuted': False, 'SDKExecuted': False,
    'limitation': 'Grammar only. The real four-argument witness correction requires another App SDK compile.'}
grammar_path = STAGE / 'health-witness-grammar.json'
grammar_path.write_text(json.dumps(grammar, indent=2) + '\n', encoding='utf-8', newline='\n')
audit = {'schemaVersion': 1, 'recordedAtUTC': datetime.now(timezone.utc).isoformat(),
    'sourceCommit': COMMIT, 'runID': 39415600445, 'jobID': 118603717942,
    'status': 'completed-failure', 'queryTerminalAgain': False,
    'nativeSourceInputCount': 232, 'packageSourceInputCount': 15,
    'packageControlInputCount': 7, 'distinctGitBlobsVerified': len(rows),
    'artifactInputs': artifacts, 'phases': phases,
    'package': {'status': 'passed', 'qualifiedMethods': expected, 'passed': 17,
        'XMLAndVerboseOutcomesAgree': True, 'evidenceHashesVerified': True,
        'runtimeSourceOnly': True, 'JVMExecuted': False, 'AppExecuted': False},
    'portable': {'smoke': {'executed': 24, 'passed': 24},
        'renewal': {'executed': 59, 'passed': 57, 'failed': failures},
        'remainingGuardCommandsAccepted': False, 'rawJobLog': item(guard_path)},
    'native': {'methodsExecuted': 0, 'diagnostics': diagnostics,
        'XcodebuildExitCode': 65, 'wrapperExitCode': native_phase['command']['exitCode']},
    'producer': {'status': 'failed', 'userAuthorizationPreflightPassed': True,
        'installAcknowledged': False, 'timeout': timeout[0], 'ownedTrustAbsenceVerified': True,
        'ownedKeychainCleanupExitCode': 0, 'targetCodesignExecuted': False},
    'healthWitnessCorrection': {'grammar': item(grammar_path),
        'input': item(health), 'SDKAcceptedAfterFix': False,
        'reason': 'Existing generation-aware five-argument overload with a default does not implement the original four-argument protocol requirement. Two exact witnesses forward nil generation to the same existing fetch/package path; the concrete package witness preserves package metadata.'},
    'sourceScope': '733120e does not include the later render delta, certificate reconciliation or this HealthChecker correction. Package success covers only its actual22 inputs and17 methods.'}
out = STAGE / 'root-terminal-audit.json'
out.write_text(json.dumps(audit, indent=2) + '\n', encoding='utf-8', newline='\n')
print(json.dumps({'audit': item(out), 'GitInputs': len(rows), 'packagePassed': 17,
    'nativeExecuted': 0, 'healthGrammarErrors': 0}))
