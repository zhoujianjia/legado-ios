from pathlib import Path
import concurrent.futures
import datetime
import hashlib
import json
import os
import subprocess
import sys

S = Path(__file__).resolve().parent
R = S.parents[1]
V = S / 'validation-root'
assert (S / 'preparation/final-source-bindings-ready.json').is_file(), 'Wait for frozen production inputs'
assert not (S / 'affected-validation-v1.json').exists(), 'Do not repeat passing executions'
METHODS = {
    'core': [
        'RenewalProbeEvidenceTests.test_currentcore_exact_ast_union_source_boundaries_arguments_and_one_new_budget',
        'LiveCoreSelectionTests.test_later_core_union_matches_real_suite_owners_without_widening_old_modes',
        'DeltaReuseCheckpointSelectionTests.test_delta_inputs_keep_app_inventory_all_three_pairs_required_fixture_and_new_package_mode',
    ],
    'native': [
        'NativeSmokeProvenanceTests.test_workflow_keeps_native_groups_in_separate_required_hosts_after_real_staging',
    ],
}


def fact(path):
    raw = path.read_bytes()
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def run(group):
    script = V / 'scripts/reader-experience' / ('test-renewal-probe-tools.py' if group == 'core' else 'test-native-smoke-tools.py')
    argv = [sys.executable, '-B', str(script), *METHODS[group], '-v']
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result = subprocess.run(argv, cwd=V, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env=dict(os.environ, PYTHONIOENCODING='utf-8'), timeout=120)
    end = datetime.datetime.now(datetime.timezone.utc).isoformat()
    output = S / ('affected-' + group + '-v1.log')
    output.write_bytes(result.stdout)
    row = {'argv': argv, 'cwd': str(V), 'startUTC': start, 'endUTC': end,
           'exitCode': result.returncode, 'timedOut': False, 'methods': METHODS[group],
           'source': {'path': script.relative_to(R).as_posix(), **fact(script)},
           'log': {'path': output.relative_to(R).as_posix(), **fact(output)}}
    (S / ('affected-' + group + '-v1.json')).write_bytes((json.dumps(row, indent=2) + '\n').encode())
    return row


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    rows = list(pool.map(run, METHODS))
summary = {'kind': 'four affected Python portable methods only', 'commands': rows,
           'distinctMethods': sum(map(len, METHODS.values())), 'methodExecutions': sum(map(len, METHODS.values())),
           'allCommandExitsZero': all(row['exitCode'] == 0 for row in rows),
           'SwiftSDK': 0, 'XCTest': 0, 'JVMCompilationOrJUnit': 0, 'cloud': 0}
(S / 'affected-validation-v1.json').write_bytes((json.dumps(summary, indent=2) + '\n').encode())
print(json.dumps(summary, indent=2))
raise SystemExit(0 if summary['allCommandExitsZero'] else 1)
