from pathlib import Path
import ast
import difflib
import hashlib
import json

ROOT = Path('F:/yuedu-reader')
BASE = ROOT / '.build/currentcore-swift-testing-filter-repair'
STAGE = BASE / 'v2'
FILES = ['scripts/reader-experience/renewal-probe-tools.py', 'scripts/reader-experience/test-renewal-probe-tools.py']
assert not (STAGE / 'preparation-v2.json').exists()
originals = {p: (BASE / 'work' / p).read_bytes() for p in FILES}
tool = originals[FILES[0]].decode()
anchor = 'def _currentcore_commands(work, native_exit=1):\n'
assert tool.count(anchor) == 1
helper = '''def verify_group_summary(summary, group):
    if group == "currentcore":
        # Actual210 xcresult reports unique definitions at the top level and
        # parameter executions on the sole device/configuration. Require both;
        # neither count substitutes for the qualified-case/raw-argument gates.
        return smoke.verify_summary(summary, len(EXPECTED_CASES[group]), expected_leaf_count(group))
    return smoke.verify_summary(summary, expected_leaf_count(group))


'''
tool = tool.replace(anchor, helper + anchor)
for before, after in [
    ('smoke.verify_summary(smoke.read_json(work / (selection_mode() + "-summary.json")), expected_leaf_count(selection_mode()))', 'verify_group_summary(smoke.read_json(work / (selection_mode() + "-summary.json")), selection_mode())'),
    ('smoke.verify_summary(smoke.read_json(work / (group + "-summary.json")), expected_leaf_count(group))', 'verify_group_summary(smoke.read_json(work / (group + "-summary.json")), group)'),
    ('smoke.verify_summary(smoke.read_json(args.summary), expected_leaf_count(args.group))', 'verify_group_summary(smoke.read_json(args.summary), args.group)'),
]:
    assert tool.count(before) == 1, before
    tool = tool.replace(before, after)

tests = originals[FILES[1]].decode()
anchor = '    def built_fixture(self):\n'
assert tests.count(anchor) == 1
fixture = '''    def summary_fixture(self, group):
        count = probe.expected_leaf_count(group)
        if group != "currentcore":
            return {"totalTestCount": count, "passedTests": count, "failedTests": 0, "skippedTests": 0}
        definitions = len(probe.EXPECTED_CASES[group])
        return {"totalTestCount": definitions, "passedTests": definitions,
                "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                "devicesAndConfigurations": [{"passedTests": count, "failedTests": 0,
                                              "skippedTests": 0, "expectedFailures": 0}]}

'''
tests = tests.replace(anchor, fixture + anchor)
old = '''            count = probe.expected_leaf_count(group)
            self.write_json(group + "-summary.json", {"totalTestCount": count, "passedTests": count,
                                                      "failedTests": 0, "skippedTests": 0})'''
assert tests.count(old) == 1
tests = tests.replace(old, '''            self.write_json(group + "-summary.json", self.summary_fixture(group))''')
old = '''                raw = json.dumps({'totalTestCount': count, 'passedTests': count, 'failedTests': 0, 'skippedTests': 0}).encode()'''
assert tests.count(old) == 1
tests = tests.replace(old, '''                raw = json.dumps(self.summary_fixture('currentcore')).encode()''')
new_test = '''    def test_currentcore_summary_keeps_definition_and_single_device_execution_counts_distinct(self):
        summary = {"totalTestCount": 463, "passedTests": 463, "failedTests": 0, "skippedTests": 0,
                   "expectedFailures": 0, "devicesAndConfigurations": [{"passedTests": 466,
                       "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        accepted = probe.verify_group_summary(summary, "currentcore")
        self.assertEqual(accepted["totalTestCount"], 463)
        self.assertEqual(accepted["expectedExecutions"], 466)
        self.assertEqual(accepted["deviceExecutionCounts"]["passedTests"], 466)
        faults = []
        changed = copy.deepcopy(summary); changed.update(totalTestCount=466, passedTests=466); faults.append(changed)
        changed = copy.deepcopy(summary); changed["devicesAndConfigurations"][0]["passedTests"] = 463; faults.append(changed)
        changed = copy.deepcopy(summary); changed.pop("devicesAndConfigurations"); faults.append(changed)
        changed = copy.deepcopy(summary); changed["devicesAndConfigurations"] *= 2; faults.append(changed)
        changed = copy.deepcopy(summary); changed["devicesAndConfigurations"][0]["skippedTests"] = 1; faults.append(changed)
        changed = copy.deepcopy(summary); changed["devicesAndConfigurations"][0]["failedTests"] = 1; faults.append(changed)
        changed = copy.deepcopy(summary); changed["devicesAndConfigurations"][0]["expectedFailures"] = 1; faults.append(changed)
        changed = copy.deepcopy(summary); changed["expectedFailures"] = True; faults.append(changed)
        changed = copy.deepcopy(summary); changed["totalTestCount"] = True; faults.append(changed)
        # The real incomplete210 shape stays rejected; this repair must never
        # downgrade the required definitions or accept its short execution.
        changed = copy.deepcopy(summary); changed.update(totalTestCount=21, passedTests=21)
        changed["devicesAndConfigurations"][0]["passedTests"] = 24; faults.append(changed)
        for index, changed in enumerate(faults):
            with self.subTest(fault=index), self.assertRaises(ValueError):
                probe.verify_group_summary(changed, "currentcore")
        # Existing non-currentcore summary paths keep their exact old contract.
        historical = {"totalTestCount": 8, "passedTests": 8, "failedTests": 0, "skippedTests": 0}
        self.assertEqual(probe.verify_group_summary(historical, "unit"), smoke.verify_summary(historical, 8))

'''
anchor = 'class CurrentCoreSwiftTestingSelectorTests(unittest.TestCase):\n'
assert tests.count(anchor) == 1
tests = tests.replace(anchor, anchor + new_test)

rows = []
for relative, text in zip(FILES, [tool, tests]):
    raw = text.encode()
    ast.parse(text)
    candidate = STAGE / 'work' / relative
    baseline = STAGE / 'rawbaseline' / relative
    diff = STAGE / 'diffs' / (relative + '.diff')
    for path in [candidate, baseline, diff]:
        path.parent.mkdir(parents=True, exist_ok=True)
    candidate.write_bytes(raw)
    baseline.write_bytes(originals[relative])
    diff.write_bytes(''.join(difflib.unified_diff(originals[relative].decode().splitlines(True), text.splitlines(True), fromfile='selector-v1/' + relative, tofile='selector-summary-v2/' + relative)).replace('\r\n', '\n').encode())
    fact = lambda data: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    rows.append({'path': relative, 'baselineSelectorV1': fact(originals[relative]), 'candidate': fact(raw), 'incrementalDiff': {'path': diff.relative_to(ROOT).as_posix(), **fact(diff.read_bytes())}})
record = {'schemaVersion': 1, 'status': 'root-frozen-selector-and-actual-summary-count-repair-awaiting-final-composed-portable-and-SDK', 'previousVersion': {'path': (BASE / 'preparation-v1.json').relative_to(ROOT).as_posix(), **fact((BASE / 'preparation-v1.json').read_bytes())}, 'files': rows, 'newActualFinding': '210 top total/passed21 counts method definitions; sole device passed24 counts argument executions. Three active currentcore callers incorrectly supplied execution count as the top definition count. Correct all three through one helper into the existing strict smoke.verify_summary(definitions, executions).', 'changedActiveCallSites': ['after-tests SDK fixture verification', 'full result(group) summary', 'CLI verify-tests'], 'keptStrict': ['463 definitions/466 exact leaves', 'one device, zero failed/skipped/expectedFailures with real integer counts', 'qualified case identities, all raw Bool details and required App SDK signer', 'all intended legacy mode sets, old summary paths,3600 single invocation/ten phase ordering'], 'newPortableDefinitionsAcrossBothVersions': ['CurrentCoreSwiftTestingSelectorTests.test_currentcore_selectors_match_real_frameworks_and_keep_every_required_function', 'CurrentCoreSwiftTestingSelectorTests.test_currentcore_summary_keeps_definition_and_single_device_execution_counts_distinct'], 'actualSDKExecutions': 0, 'actualPortableExecutionsAtRootFreeze': 0, 'mutations': {'canonical': False, 'Git': False, 'cloud': False}}
(STAGE / 'preparation-v2.json').write_bytes((json.dumps(record, indent=2) + '\n').encode())
print(json.dumps({'candidateFiles': 2, 'changedProductionSummaryCallers': 3, 'newPortableMethodsTotal': 2, 'manifest': {'bytes': (STAGE / 'preparation-v2.json').stat().st_size, 'sha256': hashlib.sha256((STAGE / 'preparation-v2.json').read_bytes()).hexdigest()}}))
