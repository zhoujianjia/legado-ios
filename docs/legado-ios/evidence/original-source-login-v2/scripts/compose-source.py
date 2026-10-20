from pathlib import Path
import difflib
import hashlib
import json
import re
import subprocess
import sys

ROOT=Path('F:/yuedu-reader')
V2=ROOT/'.build/original-source-login-v2-protocol-step'
LOGIN=ROOT/'.build/native-210-login-single-process-repair-step'
OUT=ROOT/'.build/ready-v2-native-login-composition-step'
GIT='D:/app/Git/cmd/git.exe'
assert not (OUT/'work').exists() and not (OUT/'preparation-v1.json').exists()
def read(p):return json.loads(p.read_bytes())
def fact(raw):return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def check(p,row):assert fact(p.read_bytes())=={k:row[k] for k in ['bytes','sha256']},str(p)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,indent=2)+'\n').encode())
status=subprocess.check_output([GIT,'status','--porcelain'],cwd=ROOT).decode().splitlines()
assert all(line=='?? debug.log' for line in status),status
assert subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip()=='58da225d8b78a1e191656fb3dbfce8279fdca3e3'
mp=V2/'final-v1.json'; lp=LOGIN/'final-v1.json'
check(mp,{'bytes':20854,'sha256':'a9a5f9ce25a67af1906f97c3fe99cba55e71cef31ff63c62b9e8a8eeeb977bb5'})
check(lp,{'bytes':4255,'sha256':'d632ae4ae1fe8d09468902cf3af48ead2508b89875f16f076b29ec631b216318'})
reviews=[(ROOT/'.build/original-source-login-v2-app-independent-review/review.json',30635,'1277b00142dd496dffc05681a42865b4570ce68af8850ed9ed0a0c9c2b62e37f'),(ROOT/'.build/native-210-login-single-process-independent-review/review.json',5989,'d052515aa329dc7d442f5f17814997c72ef45c7ae7f94bc7984ba6bdfc6b0262')]
for p,size,sha in reviews:check(p,{'bytes':size,'sha256':sha})
v2,login=read(mp),read(lp)
sources={};origins={};overlaps=[]
for stage,manifest,label in [(V2,v2,'reviewed-whole-V2'),(LOGIN,login,'reviewed-Native-process-and-commit-order')]:
    for row in manifest['files']:
        path=row['path'];raw=(stage/'work'/path).read_bytes();check(stage/'work'/path,row['candidate'])
        if row['baseline'] is None:assert not (ROOT/path).exists()
        else:check(ROOT/path,row['baseline'])
        if path in sources:
            assert path=='Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift'
            baseline=(ROOT/path).read_bytes();bp=OUT/'merge-inputs/base.swift';bp.parent.mkdir(parents=True,exist_ok=True);bp.write_bytes(baseline)
            left=OUT/'merge-inputs/native-login.swift';left.write_bytes(raw)
            right=OUT/'merge-inputs/V2.swift';right.write_bytes(sources[path])
            merged=subprocess.run([GIT,'merge-file','-p',str(left),str(bp),str(right)],cwd=ROOT,capture_output=True)
            write(OUT/'merge-inputs/actual-merge-attempt.json',{'exit':merged.returncode,'stdout':fact(merged.stdout),'stderr':fact(merged.stderr),'inputs':{'nativeLogin':fact(raw),'baseline':fact(baseline),'V2':fact(sources[path])}})
            (OUT/'merge-inputs/actual-merge-output.swift').write_bytes(merged.stdout)
            assert merged.returncode==0,merged.stderr.decode(errors='replace')
            result=merged.stdout
            assert not any(marker in result for marker in [b'<<<<<<<',b'=======\n',b'>>>>>>>'])
            overlaps.append({'path':path,'baseline':fact(baseline),'reviewedNative9':fact(raw),'reviewedV2Native10':fact(sources[path]),'merged':fact(result),'merge':'git merge-file -p, disjoint hunks, exit0'})
            sources[path]=result;origins[path].append(label)
        else:sources[path]=raw;origins[path]=[label]
assert len(sources)==21 and len(overlaps)==1
ported=json.loads(sources['Packages/LegadoRuntime/vendor/original-rule/manifest.json'])
assert len(ported['portedSources'])==58
for row in ported['portedSources']:
    raw=sources[row['path']] if row['path'] in sources else (ROOT/row['path']).read_bytes()
    assert fact(raw)=={k:row[k] for k in ['bytes','sha256']},row['path']
sys.path.insert(0,str(ROOT/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
rows=[];grammar=[]
for path,raw in sources.items():
    target=OUT/'work'/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
    baseline=(ROOT/path).read_bytes() if (ROOT/path).exists() else b''
    dp=OUT/'diffs'/(path+'.diff');dp.parent.mkdir(parents=True,exist_ok=True)
    dp.write_bytes(''.join(difflib.unified_diff(baseline.decode().splitlines(True),raw.decode().splitlines(True),fromfile='a/'+path,tofile='b/'+path)).encode())
    rows.append({'path':path,'baseline':fact(baseline) if baseline else None,'candidate':fact(raw),'origins':origins[path],'diff':{'path':dp.relative_to(ROOT).as_posix(),**fact(dp.read_bytes())}})
    if path.endswith('.swift'):
        assert not parser.parse(raw).root_node.has_error,path
        grammar.append({'path':path,**fact(raw),'grammarErrors':0})
native=sources['Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift'].decode()
methods=re.findall(r'func (test\w+)\(',native)
assert len(methods)==len(set(methods))==10
assert 'testNativeOriginalLoginV2UsesProductRhinoAndCheckedLoginBeforeClose' in methods
assert 'LegadoRuntime(configuration:' not in native and 'HeldAcceptedHost' not in native
def test_functions(data):
    result={}
    def walk(node):
        if node.type=='function_declaration':
            text=data[node.start_byte:node.end_byte]
            match=re.match(rb'func\s+(test\w+)\s*\(',text)
            if match:result[match.group(1).decode()]=text
        for child in node.children:walk(child)
    walk(parser.parse(data).root_node)
    return result
merged_methods=test_functions(native.encode())
root_methods=test_functions((LOGIN/'work/Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift').read_bytes())
v2_methods=test_functions((V2/'work/Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift').read_bytes())
assert len(root_methods)==9 and all(merged_methods[k]==v for k,v in root_methods.items())
new_method='testNativeOriginalLoginV2UsesProductRhinoAndCheckedLoginBeforeClose'
assert merged_methods[new_method]==v2_methods[new_method]
write(OUT/'preserved-preparation-attempts.json',{'earlierAttempts':[{'step':'first preparation before any output source','result':'clean-worktree guard rejected four auto-generated JVM crash/replay files, subsequently preserved by hash in ignored Native repair diagnostics'},{'step':'second preparation before any composed production source write','result':'git merge-file returned nonzero with empty stderr; exact stdout was not retained, so conflict cause is not established'},{'step':'read-only same-input merge inspection','exit':0,'output':fact((OUT/'merge-inputs/merge-attempt1.swift').read_bytes())}],'finalMerge':read(OUT/'merge-inputs/actual-merge-attempt.json'),'NativeTestFunctionComposition':'All nine Root-reviewed functions match byte-for-byte; the additional V2 method matches the whole-approved V2 candidate byte-for-byte.','untrackedDebugLog':'Left untouched and excluded from source and commit rosters.'})
record={'schemaVersion':1,'status':'root-composed-ready-V2-and-confirmed-Native-login-repair-awaiting-overlap-review','baselineCommit':'58da225d8b78a1e191656fb3dbfce8279fdca3e3','V2Manifest':{'path':mp.relative_to(ROOT).as_posix(),**fact(mp.read_bytes())},'rootLoginRepairManifest':{'path':lp.relative_to(ROOT).as_posix(),**fact(lp.read_bytes())},'files':rows,'overlaps':overlaps,'candidateGrammarBindings':grammar,'portedSourcesVerified':58,'NativeLoginInfoMethodIdentities':methods,'newAppDefinitions':0,'nextNativeOriginalMethods':21,'nextPackageMethods':24,'futureControlCheckpointRequired':True,'notIncluded':['Native reader metadata/fixture repairs still developing','browser host work'],'actualNewSwiftCompilerSDKOrJNIExecutions':0,'cohortPolicy':'Native210 terminal repairs remain required before one coherent submission. V2 is already independently reviewed and included while those repairs are underway; this avoids a second full SDK rebuild and does not wait for browser work.','canonicalGitCloudChanged':False}
write(OUT/'preparation-v1.json',record)
print(json.dumps({'sources':len(rows),'overlaps':len(overlaps),'grammar':len(grammar),'errors':0,'portedSources':58,'NativeLoginInfoMethods':10,'manifest':fact((OUT/'preparation-v1.json').read_bytes())}))
