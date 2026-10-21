"""Preserve the initial ignored build-directory archive attempt and resume staging."""
from pathlib import Path
import hashlib, json, shutil, subprocess

R = Path('F:/yuedu-reader')
S = Path(__file__).resolve().parent
B = R / 'docs/legado-ios/evidence/native-88c61ee-terminal'
RP = R / 'docs/legado-ios/core-native-88c61ee-terminal-result.json'
G = 'D:/app/Git/cmd/git.exe'
def fact(p):
    b = p.read_bytes()
    return dict(bytes=len(b), sha256=hashlib.sha256(b).hexdigest())
def save(p, v): p.write_bytes((json.dumps(v, ensure_ascii=False, indent=2) + '\n').encode())
old = json.loads((S / 'canonical-roster.json').read_bytes())
record = json.loads(RP.read_bytes())
for row in old: assert fact(R / row['path']) == {k: row[k] for k in ('bytes', 'sha256')}
mapping = {}
for row in old:
    src = R / row['path']
    if '/jvm/build/test-results/test/' not in row['path']: continue
    dst = B / 'raw-artifact/jvm-test-results' / src.name
    assert src.resolve().is_relative_to(B.resolve()) and dst.resolve().is_relative_to(B.resolve())
    assert src.suffix == '.xml' and not dst.exists()
    mapping[row['path']] = dst.relative_to(R).as_posix()
assert len(mapping) == 53
save(S / 'archive-layout-resume-history.json', dict(
    reason='Initial exact git add rejected53 new archive XML paths under global build ignore rule.',
    earlierRoster='canonical-roster.json', movedFiles=53, fileBytesChanged=False,
    sourceOrCloudOrTestMutations=0, newPaths=list(mapping.values())))
for before, after in mapping.items():
    src, dst = R / before, R / after
    dst.parent.mkdir(parents=True, exist_ok=True)
    src.rename(dst)
for row in record['preservedEvidence']:
    row['path'] = mapping.get(row['path'], row['path'])
script = B / 'scripts/archive-layout-resume.py'
assert not script.exists()
shutil.copyfile(Path(__file__), script)
record['preservedEvidence'].append(dict(path=script.relative_to(R).as_posix(), **fact(script),
    original=dict(path=Path(__file__).relative_to(R).as_posix(), **fact(Path(__file__))), normalization='Exact UTF8 source'))
record['archivePreparationHistory'] += ' Initial Git staging also refused53 XML paths under the repository build-directory ignore; resume moved only those new exact XML bytes to jvm-test-results and updated archive references. No force add, code change, test or cloud replay.'
save(RP, record)
rows = []
for row in old:
    name = mapping.get(row['path'], row['path'])
    rows.append(dict(path=name, **fact(R / name)))
rows.append(dict(path=script.relative_to(R).as_posix(), **fact(script)))
save(S / 'canonical-roster-layout-resume.json', rows)
checks = subprocess.run([G, 'check-ignore', '--stdin'], cwd=R,
    input=''.join(x['path']+'\n' for x in rows).encode(), capture_output=True)
assert checks.returncode == 1 and not checks.stdout, checks.stdout.decode()
print(json.dumps(dict(reviewedPaths=len(rows), exactXMLRelocated=53, ignoredPaths=0, testsRerun=0, cloudMutations=0)))
