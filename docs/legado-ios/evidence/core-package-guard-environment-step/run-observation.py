import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('phase', choices=('before', 'after'))
args = parser.parse_args()
out = HERE / args.phase
out.mkdir(exist_ok=False)
spec = importlib.util.spec_from_file_location('environment_observation_api', ROOT / 'scripts/reader-experience/original-api-package-tools.py')
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)
def facts():
    return [{'path': path, 'bytes': len(raw := (ROOT / path).read_bytes()),
             'sha256': hashlib.sha256(raw).hexdigest()} for path in api.SOURCE_INPUTS]
before = facts()
test = ROOT / 'scripts/reader-experience/test-original-api-package-tools.py'
(out / 'test-source.py').write_bytes(test.read_bytes())
command = [sys.executable, str(test)]
if args.phase == 'before':
    command.append('OriginalAPIPackageEvidenceTests.test_valid_xml_and_each_verbose_xctest_leaf_are_both_required')
command.append('-v')
env = dict(os.environ)
env['YUEDU_RENEWAL_SELECTION'] = 'currentcore'
started = datetime.now(timezone.utc).isoformat()
result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=120)
(out / 'stdout.log').write_bytes(result.stdout)
(out / 'stderr.log').write_bytes(result.stderr)
after = facts()
if before != after:
    raise RuntimeError('observation source changed during execution')
receipt = {'schemaVersion': 1, 'startedAtUTC': started, 'completedAtUTC': datetime.now(timezone.utc).isoformat(),
    'phase': args.phase, 'arguments': command, 'ambientSelection': 'currentcore', 'exitCode': result.returncode,
    'sourceInputsBefore': before, 'sourceInputsAfter': after, 'inputsUnchangedDuringExecution': True,
    'logs': [{'path': name, 'bytes': len(raw := (out / name).read_bytes()), 'sha256': hashlib.sha256(raw).hexdigest()}
             for name in ('stdout.log', 'stderr.log', 'test-source.py')],
    'swiftOrAppleSDKExecuted': False, 'physicalDeviceExecuted': False,
    'macFailureSoleCauseEstablished': False}
(out / 'observation.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf8')
print(json.dumps({'phase': args.phase, 'exitCode': result.returncode, 'sourceCount': len(before),
    'stderr': result.stderr.decode('utf8', errors='replace')[-5500:]}))
