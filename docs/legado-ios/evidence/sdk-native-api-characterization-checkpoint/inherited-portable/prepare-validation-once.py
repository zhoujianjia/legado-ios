from pathlib import Path
import ast
import hashlib
import json
import subprocess

R=Path('F:/yuedu-reader')
S=R/'.build/consolidated-sdk-native-characterization-jvm-fixtures-checkpoint'
V=S/'validation-root'
if V.exists(): raise SystemExit('Validation root already exists; preserve it rather than copying a second tree.')
d=json.loads((S/'draft-v1.json').read_text(encoding='utf-8'))
owned={f['path'] for f in d['files']}
records=[]
for relative in d['sourceROSTERS']['union']:
 source=S/'work'/relative if relative in owned else R/relative
 raw=source.read_bytes()
 target=V/relative
 target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
 records.append(dict(path=relative,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),candidateControl=relative in owned))
for f in d['files']:
 assert (R/f['path']).read_bytes()==(S/'rawbaseline'/f['path']).read_bytes()
 if f['path'].endswith('.py'):ast.parse((S/'work'/f['path']).read_text(encoding='utf-8'))
for relative in ['scripts/legado-ios/verify-native-reuse.py','scripts/legado-ios/verify-runtime-reuse.py']:
 raw=(R/relative).read_bytes();target=V/relative
 if not target.exists():target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
resource=V/'Tests/iOS/LegadoNativeWebRequestCharacterizationTests.swift'
ordered=V/'Tests/iOS/LegadoNativeOriginalReaderTests.swift'
assert 'func testPublicWebRequestCharacterizesOwnedFramesResourcesAndObserverCancellation()' in resource.read_text(encoding='utf-8')
assert 'func testNativeOriginalOrderedWebJSCharacterizesCSPAndOriginalJSONInSamePageWorld()' in ordered.read_text(encoding='utf-8')
commit=subprocess.run(['git','rev-parse','HEAD'],cwd=R,capture_output=True,text=True,check=True).stdout.strip()
out=dict(scope='One validation tree copy for four authorized affected portable guards only. No SDK/JNI/WK/JVM.',observedCanonicalCommit=commit,totalInputs=len(records),nonControls=len(records)-len(owned),files=records,actualGuardsExecuted=0)
(S/'validation-inputs-v1.json').write_text(json.dumps(out,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(validationRoot=V.relative_to(R).as_posix(),observedCanonicalCommit=commit,totalInputs=len(records),treeCopies=1)))
