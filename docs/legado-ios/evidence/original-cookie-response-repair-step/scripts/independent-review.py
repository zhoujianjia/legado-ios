from pathlib import Path
import hashlib,json,re
R=Path.cwd(); S=R/'.build/sdk-fc3-cookie-response-repair-step'; O=Path(__file__).parent
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
f=json.loads((S/'final-v1.json').read_bytes()); checks=[]
def ok(v,s):
    assert v,s
    checks.append(s)
ok(fact(S/'final-v1.json')==dict(bytes=6830,sha256='06c9fbb7129d9ca55f9e82f3d173693c27b50e4b9c8ae7b8c261b758d11def7c'),'frozen two-source candidate')
for row in f['files']:
    for branch,key in [('rawbaseline','baseline'),('work','candidate')]: ok(fact(S/'snapshot-v1'/branch/row['path'])==row[key],key+' '+row['path'])
    ok(fact(R/row['path'])==row['baseline'],'canonical baseline '+row['path'])
    ok(fact(R/row['diff']['path'])=={k:row['diff'][k] for k in ('bytes','sha256')},'diff '+row['path'])
for row in f['evidence']: ok(fact(R/row['path'])=={k:row[k] for k in ('bytes','sha256')},'evidence '+row['path'])
old=(S/'snapshot-v1/rawbaseline'/f['files'][0]['path']).read_text(); new=(S/'snapshot-v1/work'/f['files'][0]['path']).read_text()
start='    private func originalResponseCookies('; end='    private func cookieBoolean('
ok(old.split(start)[0]==new.split(start)[0] and old.split(end)[1]==new.split(end)[1],'entire Host outside one response method byte-exact')
for term in ['HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url)','properties.removeValue(forKey: .maximumAge)','properties[.discard] = persistent ? "FALSE" : "TRUE"','if persistent { properties[.expires] = nativeExpiry }','else { properties.removeValue(forKey: .expires) }','if native.isHTTPOnly != httpOnly','if native.isSecure != secure','if native.isSessionOnly != !persistent','if native.expiresDate != (persistent ? nativeExpiry : nil)','guard mismatches.isEmpty else']:
    ok(term in new,'retained or added exact policy '+term)
ok('properties[HTTPCookiePropertyKey("HttpOnly")]' not in new,'no guessed HttpOnly initializer representation')
oldTest=(S/'snapshot-v1/rawbaseline'/f['files'][1]['path']).read_text(); test=(S/'snapshot-v1/work'/f['files'][1]['path']).read_text(); pattern=r'@Test[^\n]*\n\s*func\s+(\w+)\('
ok(re.findall(pattern,oldTest)==re.findall(pattern,test) and len(re.findall(pattern,test))==5,'five original test identities retained')
report=dict(version=1,reviewer='root independent of implementation author',input=dict(path=str(S/'final-v1.json'),**fact(S/'final-v1.json')),verdict='approved-same-owner-cookie-construction-pending-Darwin-SDK',checksPassed=len(checks),checks=checks,findings=[],remainingConfirmedFindings=[],manualReview='Actual response parser produces platform-native attribute representation; exact producer provenance/name/value/domain/path/security/session/absolute expiry checks still precede Record construction or any owner write. Relative MaxAge removed before absolute milliseconds reapplied; no second expiry clock. No values/domain/headers enter fixed-field mismatch diagnostics. Existing actual parser/properties/Record restart path already passed in fc3, but failing field remains unmeasured and this new source is SDK-unexecuted.',limits=f.get('limits',[]),testsRerun=0,actualSDK=0)
(O/'review-v1.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n'); print(json.dumps(dict(checks=len(checks),verdict=report['verdict'],SDK=0)))
