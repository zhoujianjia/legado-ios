from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET

ROOT=Path('F:/yuedu-reader'); BASE=ROOT/'.build/original-app-cookie-write-delta'
OUT=BASE/'root-final-integration-audit.json'
assert not OUT.exists()
def sha(raw): return hashlib.sha256(raw).hexdigest()
def checked(row, path=None):
    raw=(path or ROOT/row['path']).read_bytes()
    assert len(raw)==row['bytes'] and sha(raw)==row['sha256'], row.get('path')
    return raw
prep_path=BASE/'preparation.json'; raw=prep_path.read_bytes()
assert sha(raw)=='0ecc2da1732da1643c8264843a3b0bf6d8ccc929d9901d30214c565a4b2927bf'
assert raw==(BASE/'freeze-v1/preparation.json').read_bytes()
p=json.loads(raw); changes=p['sourceBinding']['changedCodeTestsAndProvenance']; assert len(changes)==19
changed={r['path']:r for r in changes}
for row in changes:
    final=checked(row,ROOT/row['snapshot']); assert final==Path(row['sourcePath']).read_bytes() and b'\r' not in final
    before=row['canonicalBefore']
    if before: checked(before)
    else: assert not (ROOT/row['path']).exists()
v3=json.loads(checked(p['jvmValidation']['record'])); assert v3['exitCode']==0 and v3['executionSourcesUnchanged']
checked(p['jvmValidation']['log'])
assert len(p['sourceBinding']['acceptedExecutionInputs'])==151
for row in p['sourceBinding']['acceptedExecutionInputs']: checked(row,ROOT/row['snapshot'])
methods=[]
for row in p['jvmValidation']['xml']:
    suite=ET.fromstring(checked(row))
    assert all(int(suite.attrib[k])==0 for k in ('failures','errors','skipped'))
    cases=suite.findall('testcase'); assert len(cases)==int(suite.attrib['tests'])==row['uniqueMethods']
    assert {t.attrib['name'] for t in cases}==set(row['methods'])
    for case in cases:
        assert case.find('failure') is None and case.find('error') is None and case.find('skipped') is None
        methods.append(suite.attrib['name']+'.'+case.attrib['name'])
assert len(methods)==len(set(methods))==63
ordinary=json.loads(checked(p['ordinaryValidation']['record'])); assert ordinary['exitCode']==0 and ordinary['executionSourcesUnchanged']
log=checked(p['ordinaryValidation']['log'])
assert all(marker.encode() in log for marker in p['ordinaryValidation']['markers'])
final_inputs=p['sourceBinding']['ordinaryBuildExecutionInputs']; assert len(final_inputs)==152
for row in final_inputs:
    raw=checked(row,ROOT/row['snapshot'])
    current=ROOT/changed[row['path']]['snapshot'] if row['path'] in changed else ROOT/row['path']
    assert current.read_bytes()==raw, row['path']
old={r['path']:r['sha256'] for r in p['sourceBinding']['acceptedExecutionInputs']}
new={r['path']:r['sha256'] for r in final_inputs}
delta=json.loads(checked(p['sourceBinding']['integrationDelta']))
assert {key for key in old if old[key]!=new[key]}=={r['path'] for r in delta['changesFromFocusedV3']}
assert set(new)-set(old)==set(delta['addedInputs'])
comment=json.loads((BASE/'comment-only-equivalence.json').read_bytes())
before=next(r for r in p['sourceBinding']['acceptedExecutionInputs'] if r['path']==comment['path'])
a=checked(before,ROOT/before['snapshot']); b=(ROOT/comment['path']).read_bytes()
assert len([line for line in a.splitlines() if line not in b.splitlines()])==2
assert all(line.lstrip().startswith(b'//') for line in a.splitlines() if line not in b.splitlines())
assert b'\n'.join(line for line in a.splitlines() if line in b.splitlines())==b.rstrip(b'\n')
jar_path=ROOT/p['ordinaryJar']['path']; checked(p['ordinaryJar'])
manifest_path='Packages/LegadoRuntime/vendor/original-rule/manifest.json'
manifest_raw=checked(changed[manifest_path],ROOT/changed[manifest_path]['snapshot']); manifest=json.loads(manifest_raw)
original=json.loads((ROOT/manifest_path).read_bytes())
assert manifest['sourceProvenance'][:49]==original['sourceProvenance'] and len(manifest['sourceProvenance'])==50
assert manifest['textSubContentIntegration']==original['textSubContentIntegration']
archive=Path('F:/legado-master.zip'); assert sha(archive.read_bytes())==manifest['originalArchiveSHA256']
with zipfile.ZipFile(archive) as z:
    for ref in manifest['sourceProvenance']:
        raw=z.read(ref['archivePath']); assert len(raw)==ref['bytes'] and sha(raw)==ref['sha256']
        source='Packages/LegadoRuntime/vendor/original-rule/'+ref['vendorPath']
        actual=ROOT/changed[source]['snapshot'] if source in changed else ROOT/source
        assert actual.read_bytes()==raw
with zipfile.ZipFile(jar_path) as jar:
    names=set(jar.namelist()); assert set(p['ordinaryJar']['requiredClasses'])<=names
    tests=set()
    for language in ('kotlin','java'):
        folder=BASE/'jvm-work/build/classes'/language/'test'
        tests.update(path.relative_to(folder).as_posix() for path in folder.rglob('*.class'))
    assert len(tests)==135 and not names.intersection(tests)
    assert not any(n.startswith(('junit/','org/junit/','io/yuedu/legado/tls-fixture-v1/')) for n in names)
    assert jar.read('META-INF/legado-provenance/original-rule/manifest.json')==manifest_raw
    notices=p['ordinaryJar']['byteEqualProvenanceAndNotices']; assert len(notices)==21
    for notice in notices:
        raw=jar.read(notice['member']); assert len(raw)==notice['bytes'] and sha(raw)==notice['sha256']
        assert raw==(ROOT/'Packages/LegadoRuntime/vendor'/notice['source']).read_bytes()
grammar=json.loads(checked(p['swiftPrepared']['grammar'])); assert len(grammar['files'])==7 and all(not r['diagnostics'] for r in grammar['files'])
assert not grammar['SwiftSDKExecuted']
for row in p['swiftPrepared']['sourceOnlyPackageCompileAndTestInputClosure']:
    raw=checked(row,ROOT/row['snapshot'])
    target=ROOT/changed[row['path']]['snapshot'] if row['path'] in changed else ROOT/row['path']
    assert target.read_bytes()==raw
assert p['swiftPrepared']['sourceOnlyPackageCompileAndTestInputCount']==13
result={'schemaVersion':1,'reviewedAtUTC':datetime.now(timezone.utc).isoformat(),
    'kind':'root-independent-source-XML-JAR-provenance-integration-review', 'confirmedBlockingFindings':[],
    'frozenPreparation':{'path':prep_path.relative_to(ROOT).as_posix(),'bytes':prep_path.stat().st_size,'sha256':sha(prep_path.read_bytes())},
    'sourceFilesVerified':19,'acceptedActualJVMMethods':63,'qualifiedMethods':methods,'actualJUnitSuites':7,
    'acceptedExecutionSourceInputs':151,'finalOrdinarySourceInputs':152,
    'integrationDeltaExplicit':True,'commentOnlyTwoLineRestoreIndependentlyVerified':True,
    'ordinaryJar':{'path':jar_path.relative_to(ROOT).as_posix(),'bytes':jar_path.stat().st_size,'sha256':sha(jar_path.read_bytes()),'ordinarySmokes':p['ordinaryValidation']['markers'],'projectTestClassesChecked':135,'JUnitOrProjectTestLeaks':0,'embeddedCurrentManifestByteEqual':True,'oldNoticesByteEqual':21,'originalZIPEntriesByteEqual':50},
    'reviewFindings':['Only explicitly granted app-owner-text sessions use the same task Host and existing native Cookie owner. No source JSON can choose an owner/path; default/read-only contracts remain separate.', 'Locked CookieStore/Manager pure bodies preserve raw empty-old merge, case, original map ordering, nullable set, getKey URL-vs-domain behavior and UTF16 pruning. Native Unicode keys/values compare byte identities in the same file.', 'Actual existing OkHttp network interceptor merges each actual redirect request header with current owner text and synchronously checks response callback before redirect/final return. Parsed properties/URL/header provenance go to one native actor commit.', 'Native persistent DB raw text and same-actor bounded process session text retain distinct original lifetimes. Native RFC expiry/path projection remains separate and unknown WK metadata is never invented.', 'Real sequential login Cookie-before-header put and header-before-Cookie removal are preserved; later ordinary owner failures carry completedEffect metadata. Cancellation never promises rollback of an already accepted preceding effect.', 'Reviewed owner commit admission/revoke cancellation tickets and response parsing/type bounds, error mapping and old Codable errors. No confirmed source blocker; actual Foundation/Swift behavior still requires the SDK batch.'],
    'newNativeDefinitions':5,'newPackageDefinitions':2,'SwiftGrammarOnlyFiles':7,'SwiftSDKExecutions':0,'JNIExecutions':0,
    'additionalLimits':['Foundation Data.write(.atomic) is the checked replacement boundary here; no explicit file/directory fsync, OS kill or power-loss durability is established.', 'JVM tests use the actual public runtime and real OkHttp with a controlled native-protocol fixture; they do not execute the Swift owner, WebKit or JNI.', 'The reviewed ordinary JAR source is newer than immutable SDK tag reader-renewal-9105b46. No live or historical SDK pass can certify these new19 files.', 'Original setWebCookie/clear subset, actual WK removal/apply and all native-ingress session-text visibility remain unfinished; strict write acknowledgements differ from original Android logged failures.'],
    'newTestsRunByRoot':0,'previousFailuresRetained':True,'defaultAppRouteEnabled':False}
OUT.write_bytes((json.dumps(result,indent=2,ensure_ascii=False)+'\n').encode('utf-8'))
print(json.dumps({k:result[k] for k in ('sourceFilesVerified','acceptedActualJVMMethods','finalOrdinarySourceInputs','SwiftSDKExecutions','confirmedBlockingFindings')}))
