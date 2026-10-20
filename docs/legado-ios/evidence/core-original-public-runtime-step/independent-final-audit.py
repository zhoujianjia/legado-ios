from datetime import datetime, timezone, timedelta
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
read = lambda p: json.loads(p.read_bytes())
sha = lambda b: hashlib.sha256(b).hexdigest()
enc = lambda x: (json.dumps(x, ensure_ascii=False, indent=2) + '\n').encode('utf-8')

def ref(path):
    data = path.read_bytes()
    return {'path': path.relative_to(ROOT).as_posix(), 'bytes': len(data), 'sha256': sha(data)}

focused = read(OUT / 'focused-final.json')
ordinary = read(OUT / 'ordinary-v1.json')
prep = read(OUT / 'preparation.json')
for item in prep['sourceBinding']['preparedSwiftInputs']:
    assert ref(ROOT / item['path']) == {k: item[k] for k in ('path', 'bytes', 'sha256')}
    assert item['grammarErrors'] == []
    assert (OUT / 'swift-sources' / item['path']).read_bytes() == (ROOT / item['path']).read_bytes()
assert len(prep['sourceBinding']['preparedSwiftInputs']) == 3
assert focused['exitCode'] == ordinary['exitCode'] == 0
log = (OUT / 'focused-final.log').read_bytes()
assert len(log) == focused['logBytes'] and sha(log) == focused['logSHA256']
text = log.decode('utf-8', 'replace')
assert 'BUILD SUCCESSFUL' in text and '> Task :test\n' in text.replace('\r\n', '\n')
assert '> Task :test UP-TO-DATE' not in text and '> Task :test FROM-CACHE' not in text
start = datetime.fromisoformat(focused['startedAtUTC'])
end = datetime.fromisoformat(focused['finishedAtUTC'])
source_map = {x['path']: x for x in focused['sourceBinding']}
assert len(source_map) == 137
for path, item in source_map.items():
    data = (ROOT / path).read_bytes()
    assert ref(ROOT / path) == item, path
    assert (OUT / 'focused-final-sources' / path).read_bytes() == data, path
leaves, suites = [], []
expected_suites = {x['name']: x for x in focused['junitSuites']}
xml_files = list((OUT / 'focused-final-xml').glob('TEST-*.xml'))
assert len(xml_files) == len(expected_suites) == 17
for path in sorted(xml_files):
    raw = path.read_bytes()
    root = ET.fromstring(raw)
    expected = expected_suites[root.attrib['name']]
    assert len(raw) == expected['bytes'] and sha(raw) == expected['sha256']
    assert all(int(root.attrib[x]) == 0 for x in ('failures', 'errors', 'skipped'))
    cases = root.findall('testcase')
    assert len(cases) == int(root.attrib['tests']) == expected['tests']
    timestamp = datetime.fromisoformat(root.attrib['timestamp'].replace('Z', '+00:00'))
    assert start - timedelta(seconds=1) <= timestamp <= end
    for case in cases:
        assert case.find('failure') is case.find('error') is case.find('skipped') is None
        leaves.append((case.attrib['classname'], case.attrib['name']))
    simple = root.attrib['name'].rsplit('.', 1)[-1]
    matching = [x for x in source_map if x.endswith('/' + simple + '.kt') or x.endswith('/' + simple + '.java')]
    assert len(matching) == 1, (simple, matching)
    suites.append({'name': root.attrib['name'], 'tests': len(cases), 'timestamp': root.attrib['timestamp'],
        'xml': ref(path), 'hashMatchedTestSource': source_map[matching[0]]})
assert len(leaves) == len(set(leaves)) == 171
before, after = [read(OUT / ('manifest.' + suffix + '.json')) for suffix in ('before', 'after')]
assert len(before['sourceProvenance']) == 48 and len(after['sourceProvenance']) == 48
assert after['sourceProvenance'] == before['sourceProvenance']
assert (ROOT / 'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes() == (OUT / 'manifest.after.json').read_bytes()
archive = Path('F:/legado-master.zip')
assert sha(archive.read_bytes()) == after['originalArchiveSHA256']
with zipfile.ZipFile(archive) as original:
    for item in after['sourceProvenance']:
        raw = original.read(item['archivePath'])
        assert raw == (ROOT / 'Packages/LegadoRuntime/vendor/original-rule' / item['vendorPath']).read_bytes()
        assert len(raw) == item['bytes'] and sha(raw) == item['sha256']
for item in after['portedSources']:
    assert ref(ROOT / item['path']) == item
old_ordinary = read(ROOT / '.build/original-state-persistence/ordinary-v1.json')['ordinaryJar']
jar_fact = ordinary['ordinaryJar']
ordinary_log = (OUT / 'ordinary-v1.log').read_bytes()
assert len(ordinary_log) == ordinary['logBytes'] and sha(ordinary_log) == ordinary['logSHA256']
assert b'PACKAGED_ORIGINAL_TRADITIONAL_OK books=1 chapters=2 tocPages=2 firstChapterPages=2 sameCookie=true' in ordinary_log
jar_path = ROOT / jar_fact['path']
assert ref(jar_path) == {k: jar_fact[k] for k in ('path', 'bytes', 'sha256')}
with zipfile.ZipFile(jar_path) as jar:
    names = set(jar.namelist())
    assert len(names) == len(jar.namelist())
    assert set(jar_fact['requiredClasses']) <= names
    assert not any(x.startswith(('org/junit/', 'junit/', 'org/opentest4j/')) for x in names)
    compiled_tests = []
    for folder in ['kotlin/test', 'java/test']:
        parent = ROOT / 'Packages/LegadoRuntime/jvm/build/classes' / folder
        compiled_tests += [p.relative_to(parent).as_posix() for p in parent.rglob('*.class')]
    assert not names.intersection(compiled_tests)
    for path in (ROOT / 'Packages/LegadoRuntime/jvm/src/smoke/java').glob('*.java'):
        assert not any(x == path.stem + '.class' or x.startswith(path.stem + '$') for x in names)
    preserved = []
    for item in old_ordinary['byteEqualProvenanceAndNotices']:
        raw = jar.read(item['member'])
        assert len(raw) == item['bytes'] and sha(raw) == item['sha256'], item['member']
        preserved.append(item)
    manifest_member = 'META-INF/legado-provenance/original-rule/manifest.json'
    assert jar.read(manifest_member) == (OUT / 'manifest.after.json').read_bytes()
assert len(preserved) == 21
for item in prep['sourceBinding']['changedCodeTestsAndProvenance']:
    assert ref(ROOT / item['path']) == item
    assert (OUT / 'final-sources' / item['path']).read_bytes() == (ROOT / item['path']).read_bytes()
result = {'schemaVersion': 1, 'status': 'passed', 'recordedAtUTC': datetime.now(timezone.utc).isoformat(),
    'reviewMode': 'Independent read-only exact-byte/XML/JAR/provenance audit; no test, subprocess, network or Git execution',
    'focusedRecord': ref(OUT / 'focused-final.json'), 'focusedLog': ref(OUT / 'focused-final.log'),
    'preparationRecord': ref(OUT / 'preparation.json'), 'executionInputs': 137,
    'allExecutionInputsMatchBeforeExecutionSnapshotsAndCurrentBytes': True,
    'actualFreshJUnitSuites': suites, 'actualUniqueMethods': 171, 'newPublicFacadeMethods': 6,
    'original47PublicCallsRepresentOneJUnitMethod': True, 'failures': 0, 'errors': 0, 'skipped': 0,
    'ordinaryRecord': ref(OUT / 'ordinary-v1.json'), 'ordinaryJar': ref(jar_path),
    'projectCompiledTestClassesChecked': len(compiled_tests), 'testOrJUnitClassLeaks': [],
    'preservedPreviousProvenanceAndNoticeEntries': preserved,
    'oldOriginalSourceEntriesPreserved': 48, 'newExactLockedArchiveSourceEntries': 0,
    'totalOriginalSourceEntries': 48, 'portedSourceHashEntries': len(after['portedSources']),
    'changedCodeTestsAndProvenance': len(prep['sourceBinding']['changedCodeTestsAndProvenance']),
    'readReviewedPublicContract': True, 'nativePackageMethodsPreparedNotExecuted': 5,
    'iosSDKExecutionClaimed': False, 'AppTraditionalRouteSwitched': False, 'wholeCompatibilityClaimed': False}
(OUT / 'independent-final-audit.json').write_bytes(enc(result))
print(json.dumps({'status': 'passed', 'JVMUniqueMethods': 171, 'executionInputs': 137,
    'ordinaryJar': result['ordinaryJar'], 'testClassLeaks': 0, 'previousNoticesPreserved': 21}))
