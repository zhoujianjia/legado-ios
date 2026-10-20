from pathlib import Path
import ast
import difflib
import hashlib
import json

ROOT = Path('F:/yuedu-reader')
STAGE = ROOT / '.build/currentcore-swift-testing-filter-repair'
FILES = ['scripts/reader-experience/renewal-probe-tools.py', 'scripts/reader-experience/test-renewal-probe-tools.py']
assert not (STAGE / 'preparation-v1.json').exists()
originals = {}
for relative in FILES:
    raw = (ROOT / relative).read_bytes()
    originals[relative] = raw
    p = STAGE / 'rawbaseline' / relative
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(raw)

tool = originals[FILES[0]].decode()
anchor = 'def _currentcore_commands(work, native_exit=1):\n'
assert tool.count(anchor) == 1
addition = '''# The 210fb05 xcresult contains all18 selected XCTest methods, but only
# the three parameterized Swift Testing functions. Bare Swift function names
# are not their Xcode identifiers: zero-argument functions require (). Keep
# XCTest method selectors unchanged and retain each real parameter label.
CURRENTCORE_XCTEST_SUITES = frozenset({
    "ReadingPositionStorePersistenceTests", "ReaderViewportSizeObserverHostingTests",
})


def currentcore_test_selector(case):
    if case not in EXPECTED_CASES["currentcore"]:
        raise ValueError("Unselected current-core test identifier")
    parameters = parameter_cases("currentcore")
    if case in parameters:
        return case + "(" + parameters[case] + ":)"
    if case.split("/", 1)[0] in CURRENTCORE_XCTEST_SUITES:
        return case
    return case + "()"


'''
tool = tool.replace(anchor, addition + anchor)
old = '''    only = ["-only-testing:yuedu appTests/" + case + ("(" + parameter_cases("currentcore")[case] + ":)" if case in parameter_cases("currentcore") else "")
            for case in sorted(EXPECTED_CASES["currentcore"])]'''
new = '''    only = ["-only-testing:yuedu appTests/" + currentcore_test_selector(case)
            for case in sorted(EXPECTED_CASES["currentcore"])]'''
assert tool.count(old) == 1
tool = tool.replace(old, new)

tests = originals[FILES[1]].decode()
replacements = [
    ("{case+('('+probe.parameter_cases('currentcore')[case]+':)' if case in probe.parameter_cases('currentcore') else '') for case in expected}",
     "{probe.currentcore_test_selector(case) for case in expected}"),
    ("self.assertTrue(probe.CURRENTCORE_NEW_QUALIFIED_CASES <= set(selected))",
     "self.assertTrue(probe.CURRENTCORE_NEW_QUALIFIED_CASES <= {probe._qualified_method(case) for case in selected})"),
    ('{case + "(" + probe.parameter_cases("currentcore")[case] + ":)" if case in probe.parameter_cases("currentcore") else case\n                for case in probe.EXPECTED_CASES["currentcore"]}',
     '{probe.currentcore_test_selector(case) for case in probe.EXPECTED_CASES["currentcore"]}'),
    ("self.assertIn('-only-testing:yuedu appTests/' + case, command)",
     "self.assertIn('-only-testing:yuedu appTests/' + case + '()', command)"),
    ("self.assertIn('-only-testing:yuedu appTests/' + probe.SDK_REQUIRED_CASE, command)",
     "self.assertIn('-only-testing:yuedu appTests/' + probe.SDK_REQUIRED_CASE + '()', command)"),
]
counts = []
for old, new in replacements:
    count = tests.count(old)
    assert count > 0, old
    counts.append(count)
    tests = tests.replace(old, new)
assert counts == [1, 1, 1, 1, 2], counts

new_tests = '''

class CurrentCoreSwiftTestingSelectorTests(unittest.TestCase):
    def test_currentcore_selectors_match_real_frameworks_and_keep_every_required_function(self):
        # Independent source classification prevents a hard-coded XCTest
        # exception from silently selecting the wrong framework after a change.
        declarations = set()
        for relative in probe.SOURCE_INPUTS:
            if relative.startswith("Tests/iOS/") and relative.endswith(".swift"):
                text = (smoke.REPO / relative).read_text(encoding="utf-8")
                declarations.update(re.findall(r"\\bclass\\s+(\\w+)\\s*:\\s*XCTestCase\\b", text))
        cases = probe.EXPECTED_CASES["currentcore"]
        selected_suites = {case.split("/", 1)[0] for case in cases}
        xctest_suites = selected_suites & declarations
        self.assertEqual(xctest_suites, {"ReadingPositionStorePersistenceTests", "ReaderViewportSizeObserverHostingTests"})
        self.assertEqual(xctest_suites, set(probe.CURRENTCORE_XCTEST_SUITES))
        xctest_cases = {case for case in cases if case.split("/", 1)[0] in xctest_suites}
        self.assertEqual(len(xctest_cases), 18)
        parameters = probe.parameter_cases("currentcore")
        expected = {case + "(" + parameters[case] + ":)" if case in parameters
                    else case if case in xctest_cases else case + "()" for case in cases}
        with patch.dict(os.environ, {"LEGADO_RUNTIME_SOURCE_ONLY": "1", "YUEDU_DEST": "id=synthetic-simulator"}):
            command = probe._currentcore_commands(Path("/owned-selector-fixture"))["native"]
        selectors = [arg.removeprefix("-only-testing:yuedu appTests/") for arg in command if arg.startswith("-only-testing:")]
        self.assertEqual(len(selectors), len(set(selectors)))
        self.assertEqual(set(selectors), expected)
        self.assertEqual({probe._qualified_method(case) for case in selectors}, cases)
        self.assertEqual(len(selectors), 463)
        self.assertEqual(probe.expected_leaf_count("currentcore"), 466)
        self.assertIn(probe.SDK_REQUIRED_CASE + "()", selectors)
        self.assertIn("CoreTextPagedScrollAppearanceTests/authoredCompositionMatchesScroll(nestedBackdrop:)", selectors)
        self.assertIn("ReaderViewportSizeObserverHostingTests/testFullBleedProbeMatchesReaderSurfaceWithSafeAreaInsets", selectors)
        self.assertNotIn(probe.SDK_REQUIRED_CASE, selectors)
        self.assertEqual(command.count("-resultBundlePath"), 1)
        self.assertEqual(command[command.index("-t") + 1], "3600")
        for invalid in ("MissingSuite/missing", probe.SDK_REQUIRED_CASE + "()", "yuedu appTests/" + probe.SDK_REQUIRED_CASE):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                probe.currentcore_test_selector(invalid)

'''
match = __import__('re').search(r"(?m)^if __name__ == [\"']__main__[\"']:", tests)
assert match
tests = tests[:match.start()] + new_tests + tests[match.start():]
rows = []
for relative, text in zip(FILES, [tool, tests]):
    raw = text.encode()
    ast.parse(text)
    p = STAGE / 'work' / relative
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(raw)
    diff = STAGE / 'diffs' / (relative + '.diff')
    diff.parent.mkdir(parents=True, exist_ok=True)
    diff.write_bytes(''.join(difflib.unified_diff(originals[relative].decode().splitlines(True), text.splitlines(True), fromfile='baseline/' + relative, tofile='candidate/' + relative)).replace('\r\n', '\n').encode())
    fact = lambda data: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    rows.append({'path': relative, 'baseline': fact(originals[relative]), 'candidate': fact(raw), 'diff': {'path': diff.relative_to(ROOT).as_posix(), **fact(diff.read_bytes())}})
record = {'schemaVersion': 1, 'status': 'frozen-root-currentcore-selector-fix-awaiting-composed-portable-and-fresh-SDK-execution', 'baselineCommit': '13a13cce0bc62dd6df82247ea5a345e7dfcfa607', 'files': rows, 'actualFailure': '210fb05 SDK native exited0; strict cases rejected21 definitions/24 argument leaves instead of459/462. Bare zero-argument Swift Testing names omitted438 selected functions;18 XCTest and3 correctly labeled Bool methods ran.', 'scope': 'Change only active currentcore argv spelling; prior group identities, historical argv paths, counts/budgets/source/result/fixture gates remain unchanged.', 'newPortableDefinition': 'CurrentCoreSwiftTestingSelectorTests.test_currentcore_selectors_match_real_frameworks_and_keep_every_required_function', 'existingAffectedAssertionsAdjusted': counts, 'actualSDKExecutionsForThisFix': 0, 'actualPortableExecutionsAtFreeze': 0, 'mutations': {'canonical': False, 'Git': False, 'cloud': False}}
(STAGE / 'preparation-v1.json').write_bytes((json.dumps(record, indent=2) + '\n').encode())
print(json.dumps({'candidateFiles': 2, 'newPortableMethods': 1, 'affectedAssertionCounts': counts, 'actualSDKOrPortableExecutions': 0, 'manifest': {'bytes': (STAGE / 'preparation-v1.json').stat().st_size, 'sha256': hashlib.sha256((STAGE / 'preparation-v1.json').read_bytes()).hexdigest()}}))
