from pathlib import Path
import datetime
import hashlib
import json
import subprocess
import sys
import time

R=Path('F:/yuedu-reader')
S=R/'.build/consolidated-sdk-native-characterization-jvm-fixtures-checkpoint'
group=sys.argv[1]
assert group in ['core','native']
version=sys.argv[2] if len(sys.argv)>2 else 'v1'
assert version in ['v1','v2']
record=S/('affected-'+group+'-'+version+'.json')
if record.exists():raise SystemExit('This group already has execution evidence; do not rerun unchanged guards.')
targets=['DeltaReuseCheckpointSelectionTests'] if group=='core' else [
 'NativeSmokeProvenanceTests.test_workflow_keeps_native_groups_in_separate_required_hosts_after_real_staging',
 'NativeSmokeProvenanceTests.test_result_requires_exact_built_app_source_stamp']
test='test-renewal-probe-tools.py' if group=='core' else 'test-native-smoke-tools.py'
argv=[sys.executable,'-B','scripts/reader-experience/'+test,*targets,'-v']
started=datetime.datetime.now(datetime.timezone.utc).isoformat();clock=time.monotonic()
done=subprocess.run(argv,cwd=S/'validation-root',stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
log=S/('affected-'+group+'-'+version+'.log');log.write_bytes(done.stdout)
fact=dict(path=log.relative_to(R).as_posix(),bytes=len(done.stdout),sha256=hashlib.sha256(done.stdout).hexdigest())
d=dict(scope='Authorized affected portable provenance guards only, not Apple execution.',startedUTC=started,argv=argv,cwd=(S/'validation-root').relative_to(R).as_posix(),expectedMethods=2,exitCode=done.returncode,seconds=round(time.monotonic()-clock,3),log=fact,SwiftSDK=0,JNI=0,WK=0,JVM=0)
record.write_text(json.dumps(d,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(d))
raise SystemExit(done.returncode)
