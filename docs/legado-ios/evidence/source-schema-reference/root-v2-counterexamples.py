import hashlib
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
helper = root / '.build/source-schema-reference-worktree/scripts/reader-experience/collect-rule-defaults-reference.py'
spec = importlib.util.spec_from_file_location('root_v2_collector_negative', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
summary = {'totalTestCount': 3, 'passedTests': 3, 'failedTests': 0, 'skippedTests': 0,
           'expectedFailures': 0, 'devicesAndConfigurations': [
               {'passedTests': 3, 'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}]}
cases = [{'nodeType': 'Test Case', 'nodeIdentifier': name, 'result': 'Passed'} for name in module.METHODS]
mutations = [
    {'nodeType': 'Unrecognized Container', 'result': 'Passed', 'children': cases},
    {'nodeType': 'Test Plan', 'result': 'Interrupted', 'children': cases},
    {'nodeType': 'Test Plan', 'result': 'Passed', 'children': cases + [{'nodeType': 'Unrecognized Leaf', 'result': 'Passed'}]},
]
observations = []
for node in mutations:
    try:
        value = module.verify_execution(summary, {'testNodes': [node]}, 0)
        observations.append({'syntheticNode': node, 'rejected': False, 'returned': value})
    except ValueError as error:
        observations.append({'syntheticNode': node, 'rejected': True, 'error': str(error)})
record = {'scope': 'Synthetic strictness counterexamples only; no XCTest, SDK or device execution.',
          'helperSHA256': hashlib.sha256(helper.read_bytes()).hexdigest(), 'observations': observations}
output = root / '.build/renewal-discovery/source-collector-v2-negative.json'
output.open('xb').write((json.dumps(record, indent=2) + '\n').encode('utf-8'))
print(json.dumps({'rejected': [item['rejected'] for item in observations], 'record': str(output)}))
