from pathlib import Path
import hashlib
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '.build/renewal-discovery/perf-main-verification'
OUT.mkdir(exist_ok=True)
prepared = json.loads((ROOT / '.build/reader-launch-memory-worktree/.build/reader-launch-memory-preparation.json').read_text(encoding='utf-8'))
for item in prepared['files']:
    raw = (ROOT / item['path']).read_bytes()
    assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256'], item['path']
name = sys.argv[1]
commands = {'measurement': ('test-reader-launch-memory.py', 15), 'stage': ('test-reader-stage-baseline.py', 20)}
script, count = commands[name]
command = [sys.executable, '-B', 'scripts/reader-experience/' + script]
result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
record = {'sourceFilesMatched': prepared['files'], 'command': command, 'exitCode': result.returncode,
          'portableMethodsPassed': count, 'actualSwiftCompilationOrIOSTestsExecuted': False, 'logs': {}}
for channel in ('stdout', 'stderr'):
    raw = getattr(result, channel)
    path = OUT / (name + '.' + channel)
    path.open('xb').write(raw)
    record['logs'][channel] = {'path': path.relative_to(ROOT).as_posix(), 'bytes': len(raw),
                               'sha256': hashlib.sha256(raw).hexdigest()}
(OUT / (name + '.json')).open('xb').write((json.dumps(record, indent=2) + '\n').encode('utf-8'))
assert result.returncode == 0, record
assert ('Ran ' + str(count) + ' tests in').encode() in result.stderr and result.stderr.rstrip().endswith(b'OK')
print(json.dumps({'group': name, 'sourceFilesMatched': len(prepared['files']), 'portableMethodsPassed': count}))
