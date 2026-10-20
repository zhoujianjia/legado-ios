from pathlib import Path
import difflib
import hashlib
import json
import re
import sys

ROOT=Path('F:/yuedu-reader')
STAGE=ROOT/'.build/native-210-login-single-process-repair-step'
assert not (STAGE/'final-v1.json').exists()
prep=json.loads((STAGE/'preparation-v1.json').read_bytes())
def fact(raw):return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
for row in prep['files']:
    raw=(STAGE/'work'/row['path']).read_bytes()
    assert fact(raw)==row['candidate']
    old=STAGE/'preparation-snapshot-v1'/row['path'];old.parent.mkdir(parents=True,exist_ok=True);old.write_bytes(raw)
path='Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift'
target=STAGE/'work'/path
text=target.read_text(encoding='utf-8')
old='''            try await runtime.cancel(taskID: taskID)
            do { _ = try await pending.value; XCTFail("Expected actual runtime cancellation") }
            catch let error as LegadoRuntimeError {
                XCTAssertEqual(error.code, "CANCELLED")
                XCTAssertTrue(error.completedEffects?.contains("sourceLoginInfoCommitted") == true)
            }
            let actual = try await Task.detached {'''
new='''            do {
                try await runtime.cancel(taskID: taskID)
                do { _ = try await pending.value; XCTFail("Expected actual runtime cancellation") }
                catch let error as LegadoRuntimeError {
                    XCTAssertEqual(error.code, "CANCELLED")
                    XCTAssertTrue(error.completedEffects?.contains("sourceLoginInfoCommitted") == true)
                }
            } catch { problem = error }
            // Drain even if explicit cancellation itself reports a failure.
            pending.cancel()
            _ = await pending.result
            let actual = try await Task.detached {'''
assert text.count(old)==1
text=text.replace(old,new,1)
target.write_bytes(text.encode())
sys.path.insert(0,str(ROOT/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
syntax=[]
for row in prep['files']:
    path=row['path'];before=(ROOT/path).read_bytes();raw=(STAGE/'work'/path).read_bytes()
    assert fact(before)==row['baseline']
    for version,data in [('baseline',before),('candidate',raw)]:
        tree=parser.parse(data)
        assert not tree.root_node.has_error,(version,path)
        syntax.append({'path':path,'version':version,**fact(data),'grammarErrors':0})
    diff=''.join(difflib.unified_diff(before.decode().splitlines(True),raw.decode().splitlines(True),fromfile='a/'+path,tofile='b/'+path))
    dp=STAGE/'diffs'/(path+'.diff');dp.write_bytes(diff.encode())
    row['candidate']=fact(raw);row['diff']={'path':dp.relative_to(ROOT).as_posix(),**fact(dp.read_bytes())}
manager=(STAGE/'work'/prep['files'][0]['path']).read_text(encoding='utf-8')
function=manager.split('    func storeRuntimeLoginInfo(',1)[1].split('    private func advanceRuntimeLoginInfoRevision',1)[0]
assert function.index('guard accepted else { return false }')<function.index('recordEffect("sourceLoginInfoCommitted")')<function.index('advanceRuntimeLoginInfoRevision(')
assert 'LegadoRuntime(configuration:' not in text and 'fixture.host' not in text and 'HeldAcceptedHost' not in text
assert re.findall(r'func (test\w+)\(',(ROOT/'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift').read_text(encoding='utf-8'))==re.findall(r'func (test\w+)\(',text)
assert text.count('LegadoRuntimeProcess.shared')==3 and text.count('await process.revokePersistentSource(owner: owner)')==3
prep.update(status='frozen-single-process-login-tests-and-accepted-effect-order-awaiting-independent-review',grammarBindings=syntax,rootPreparation={'path':'.build/native-210-login-single-process-repair-step/preparation-v1.json',**fact((STAGE/'preparation-v1.json').read_bytes())},postPreparationRepair='Keep explicit native cancellation errors, cancel and drain the actual pending task before shared-session close and source-grant revocation.',notExecuted=['Swift compiler/typechecking','XCTest/actual JNI','device'],productionOrderingProof='Accepted checked Keychain commit fact is registered before the synchronous revision notification; no rejection/IO path is promoted to committed.')
(STAGE/'final-v1.json').write_bytes((json.dumps(prep,indent=2)+'\n').encode())
print(json.dumps({'files':2,'grammarBindings':len(syntax),'errors':0,'NativeDefinitions':9,'actualSDKJNI':0,'final':fact((STAGE/'final-v1.json').read_bytes())}))
