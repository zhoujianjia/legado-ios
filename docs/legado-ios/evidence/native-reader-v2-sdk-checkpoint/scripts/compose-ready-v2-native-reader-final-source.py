from pathlib import Path
import difflib
import hashlib
import json
import subprocess

ROOT = Path('F:/yuedu-reader')
STAGE = ROOT / '.build/native-210-reader-repair-step'
OUT = ROOT / '.build/ready-v2-native-reader-final-source'
GIT = 'D:/app/Git/cmd/git.exe'

def facts(raw):
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}

def check(path, row):
    assert facts(path.read_bytes()) == {k: row[k] for k in ('bytes', 'sha256')}, str(path)

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode())

assert not OUT.exists()
assert subprocess.check_output([GIT, 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip() == '8cebe2023d0f3b9b3d8143d964b0c9bb2a6e7978'
status = subprocess.check_output([GIT, 'status', '--porcelain'], cwd=ROOT).decode().splitlines()
assert all(line == '?? debug.log' for line in status), status
manifest_path = STAGE / 'final-v1.json'
check(manifest_path, {'bytes':17750,'sha256':'350f664aefc1fad829c9a5a239caa9483a52a6e851fe9304329d32ce7a2f533f'})
record = json.loads(manifest_path.read_bytes())
source_path = 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleWebBookState.kt'
ported_path = 'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
sources = {}
for row in record['files']:
    path = row['path']
    check(STAGE / 'work' / path, row['candidate'])
    if path != ported_path:
        check(ROOT / path, row['baseline'])
        sources[path] = (STAGE / 'work' / path).read_bytes()
assert len(sources) == 3
baseline_raw = (ROOT / ported_path).read_bytes()
baseline = json.loads(baseline_raw)
assert len(baseline['portedSources']) == 58
candidate = json.loads(baseline_raw)
rows = [r for r in candidate['portedSources'] if r['path'] == source_path]
assert len(rows) == 1
old_row = dict(rows[0])
assert {k: old_row[k] for k in ('bytes','sha256')} == facts((ROOT / source_path).read_bytes())
rows[0].update(facts(sources[source_path]))
candidate_raw = (json.dumps(candidate, ensure_ascii=False, indent=2) + '\n').encode()
assert baseline_raw == (json.dumps(baseline, ensure_ascii=False, indent=2) + '\n').encode(), 'Preserve manifest serialization'
sources[ported_path] = candidate_raw
changed_rows = [i for i, (a, b) in enumerate(zip(baseline['portedSources'], candidate['portedSources'])) if a != b]
assert len(changed_rows) == 1
for key in baseline:
    if key != 'portedSources':
        assert baseline[key] == candidate[key]
for row in candidate['portedSources']:
    raw = sources.get(row['path'], (ROOT / row['path']).read_bytes())
    assert facts(raw) == {k: row[k] for k in ('bytes','sha256')}, row['path']
bound = []
for path, raw in sources.items():
    dst = OUT / 'work' / path
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(raw)
    original = (ROOT / path).read_bytes()
    dp = OUT / 'diffs' / (path + '.diff')
    dp.parent.mkdir(parents=True, exist_ok=True)
    dp.write_bytes(''.join(difflib.unified_diff(original.decode().splitlines(True), raw.decode().splitlines(True), fromfile='a/'+path, tofile='b/'+path)).encode())
    bound.append({'path': path, 'baseline': facts(original), 'candidate': facts(raw), 'diff': {'path': dp.relative_to(ROOT).as_posix(), **facts(dp.read_bytes())}})
write(OUT / 'preparation-v1.json', {
    'status':'Reader-three-exact-reviewed-candidates-plus-current58-ported-row-merge-awaiting-independent-review',
    'canonicalBaseline':'8cebe2023d0f3b9b3d8143d964b0c9bb2a6e7978',
    'ReaderPreparation': {'path': manifest_path.relative_to(ROOT).as_posix(), **facts(manifest_path.read_bytes())},
    'files': bound,
    'portedSources':58,
    'portedMerge':{'changedRows':1,'before':old_row,'after':rows[0],'retainedAllOtherRowsAndMetadata':True},
    'actualNewJVMorSDK':0,
    'validationReuse':'Original one-source incremental production validation predates V2. Its exact three distinct JVM methods and outside-consumer evidence apply only to that explicit source closure, not a fresh combined V2 production JAR or SDK/JNI acceptance.',
    'operations':{'canonical':False,'Git':False,'cloud':False}
})
print(json.dumps({'sources':len(sources),'portedRows':58,'changedPortedRows':1,'manifest':facts((OUT/'preparation-v1.json').read_bytes())}))
