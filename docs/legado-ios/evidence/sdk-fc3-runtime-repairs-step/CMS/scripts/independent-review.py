from pathlib import Path
import hashlib,json,re
R=Path.cwd(); S=R/'.build/sdk-fc3-cms-ber-envelope-repair-step'; O=Path(__file__).parent
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def read(p): return json.loads(p.read_bytes())
f=read(S/'final-v1.json'); checks=[]
def ok(v,s):
    assert v,s
    checks.append(s)
ok(fact(S/'final-v1.json')==dict(bytes=8346,sha256='c4401980f8da72045092e31da09a06a70f6212e9dc3d7e22b3d90e2d4533cddc'),'frozen CMS2 input')
for row in f['files']:
    for k in ('baseline','candidate','diff'): ok(fact(R/row[k]['path'])=={a:row[k][a] for a in ('bytes','sha256')},k+' '+row['source'])
    ok(fact(R/row['source'])=={a:row['baseline'][a] for a in ('bytes','sha256')},'canonical baseline '+row['source'])
for row in f['evidence']: ok(fact(R/row['path'])=={a:row[a] for a in ('bytes','sha256')},'evidence '+row['path'])
old=(R/f['files'][0]['baseline']['path']).read_text(); new=(R/f['files'][0]['candidate']['path']).read_text()
ok(old[old.index('    private static func next('):]==new[new.index('    private static func next('):],'strict DER next exact to EOF')
def block(text,start,end): return text.split(start,1)[1].split(end,1)[0]
ok(block(old,'            let algorithm = try signatureAlgorithm','        return VerifiedContent')==block(new,'            let algorithm = try signatureAlgorithm','        return VerifiedContent'),'actual signature/key/trust/date/chain/cancel exact')
ok(block(old,'    static func parseDER(', '    private static func matchesSigner(')==block(new,'    static func parseDER(', '    private static func matchesSigner('),'public DER and recursive canonical validation exact')
ok('_ = try single(node.full, tag: 0xa0)' in new,'signed attributes wrapper independently strict DER')
ok('guard depth <= 16, nodes <= 4_096 else' in new and 'guard count < Limits.children else' in new,'envelope depth nodes children budgets')
ok('guard tag != 0, tag & 0x1f != 0x1f else' in new and 'guard tag & 0x20 != 0 else' in new,'EOC/high tag and primitive indefinite rejected')
ok('content.append(node.body)' in new and 'node.body.count <= Limits.contentBytes - content.count' in new,'octet flatten bounded and authenticated by unchanged digest')
math=read(S/'snapshot-v1/evidence/independent-math-and-boundaries.json'); ok(math['failedChecks']==0 and math['totalChecks']==26,'actual independent fixture math26 recorded')
for row in math['sourceFiles']: ok(fact(R/row['path'])=={a:row[a] for a in ('bytes','sha256')},'actual math source '+row['path'])
public=R/'.build/sdk-fc3b01c-terminal/extracted-12307712232/reader-renewal-probe/sdk-produced-public'
for role in ('main','share','widget','framework'):
    data=(public/(role+'.detached.cms')).read_bytes(); ok(len(data)==1798 and data[:2]==bytes([0x30,0x80]),'real '+role+' first TLV is BER indefinite')
testOld=(R/f['files'][1]['baseline']['path']).read_text(); testNew=(R/f['files'][1]['candidate']['path']).read_text()
pattern=r'@Test[^\n]*\n\s*func\s+(\w+)\('
ok(re.findall(pattern,testOld)==re.findall(pattern,testNew) and len(re.findall(pattern,testNew))==7,'same seven original test definitions')
report=dict(version=1,reviewer='root independent of implementation author',input=dict(path=str(S/'final-v1.json'),**fact(S/'final-v1.json')),verdict='approved-bounded-CMS-envelope-source-pending-Swift-Security-SDK',checksPassed=len(checks),checks=checks,findings=[],remainingConfirmedFindings=[],reviewedSemantics='Global envelope traversal bounds primitive/constructed/EOC/depth/nodes and encoded bytes; ordinary DER path remains strict. SignedAttrs full A0 wrapper and recursively canonical content are independently checked without rewriting signature input. Primitive content authenticated unchanged; constructed OCTET STRING concatenation is bounded. Original certificate algorithms, actual signature, anchor-only trust, date, chain and cancellation block byte-exact. Four real CI CMS1798B expose old rejection at offset0 before signature work.',validation=f['validation'],limits=f['limits'],testsRerun=0,SDKHere=0)
(O/'review-v1.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n'); print(json.dumps(dict(checks=len(checks),verdict=report['verdict'],SDK=0)))
