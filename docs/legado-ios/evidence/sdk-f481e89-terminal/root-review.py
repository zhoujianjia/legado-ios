from pathlib import Path
import hashlib,json,re,subprocess,zipfile,xml.etree.ElementTree as ET

root=Path('F:/yuedu-reader'); raw=root/'.build/sdk-f481e89-terminal'
stage=root/'.build/sdk-f481e89-archive-candidate'; final=json.loads((stage/'final-v1.json').read_bytes())
work=root/final['candidateRoot']; checks=[]
def digest(b): return hashlib.sha256(b).hexdigest()
def fact(b): return {'bytes':len(b),'sha256':digest(b)}
def require(name,condition):
    checks.append({'check':name,'passed':bool(condition)})
    assert condition,name
def norm(b):
    s=b.decode('utf-8-sig')
    return ('\n'.join(x.rstrip(' \t') for x in s.splitlines()).rstrip('\n')+'\n').encode() if s else b''
require('frozen roster facts',len(final['files'])==107 and sum(x['bytes'] for x in final['files'])==2143301)
for row in final['files']:
    p=work/row['path']; b=p.read_bytes()
    require('candidate '+row['path'],p.resolve().is_relative_to(work.resolve()) and fact(b)=={k:row[k] for k in ('bytes','sha256')} and b'\0' not in b and norm(b)==b)
    require('bounded public text '+row['path'],len(b)<350000 and 'private-download' not in row['path'] and not re.search(rb'(?im)^-----BEGIN (?:RSA |EC |ENCRYPTED |OPENSSH )?PRIVATE KEY-----',b) and not re.search(rb'(?i)[?&](?:X-Amz-Signature|X-Goog-Signature|sig|signature|token)=',b))
record=json.loads((work/final['record']).read_bytes())
for row in record['preservedEvidence']:
    original=row['original']
    if 'archive' in original:
        with zipfile.ZipFile(root/original['archive']['path']) as z:
            b=z.read(original['member']['path'])
        require('normalized original '+row['path'],fact(b)=={k:original['member'][k] for k in ('bytes','sha256')} and norm(b)==(work/row['path']).read_bytes())
    elif 'path' in original and 'sourceCommit' not in original:
        b=(root/original['path']).read_bytes()
        require('local metadata '+row['path'],fact(b)=={k:original[k] for k in ('bytes','sha256')} and norm(b)==(work/row['path']).read_bytes())
z=zipfile.ZipFile(raw/'evidence.zip'); pz=zipfile.ZipFile(raw/'package.zip')
for name,archive,count in [('evidence.zip',z,122),('package.zip',pz,10)]:
    require('archive CRC '+name,archive.testzip() is None and len(archive.infolist())==count and fact((raw/name).read_bytes())=={k:final['originalArchives'][name]['originalZIP'][k] for k in ('bytes','sha256')})
def er(n): return z.read('reader-renewal-probe/'+n)
def ej(n): return json.loads(er(n))
def pr(n): return pz.read('reader-renewal-original-api/'+n)
def pj(n): return json.loads(pr(n))
source=final['sourceCommit']; run=json.loads((raw/'run.json').read_bytes()); job=json.loads((raw/'jobs.json').read_bytes())['jobs'][0]
require('exact terminal identities',run['id']==39533277187 and job['id']==119003957104 and run['head_sha']==source and all(x['status']=='completed' and x['conclusion']=='failure' for x in (run,job)))
core=ej('source-inputs.json'); package=pj('source-inputs.json'); producer=ej('sdk-produced-public/sdk-produced-fixture-manifest.json')
rows=core['sourceInputs']; require('declared source counts',len(rows)==364 and len(package['sourceInputs'])==23 and len(producer['sourceInputs'])==7)
by_path={r['path']:r for r in rows}
require('package exact subset',all(r==by_path[r['path']] for r in package['sourceInputs']))
for r in producer['sourceInputs']:
    matches=[v for k,v in by_path.items() if k.endswith('/'+r['path'])]
    require('producer subset '+r['path'],len(matches)==1 and all(matches[0][k]==r[k] for k in ('bytes','sha256')))
paths=sorted(by_path)
batch=subprocess.run(['D:/app/Git/cmd/git.exe','cat-file','--batch'],cwd=root,input=''.join(source+':'+p+'\n' for p in paths).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
offset=0
for path in paths:
    e=batch.index(b'\n',offset); _,kind,size=batch[offset:e].split(); size=int(size); b=batch[e+1:e+1+size]
    require('historical source '+path,kind==b'blob' and fact(b)=={k:by_path[path][k] for k in ('bytes','sha256')})
    offset=e+size+2
require('batch consumed',offset==len(batch))
fingerprint=digest(json.dumps(rows,sort_keys=True,separators=(',',':')).encode())
phases=[ej('currentcore-phase-'+n+'.json') for n in ['producer','stage','before-build','boot','native','export','cases','test-settings','after-tests','build-settings','result']]
for ph in phases:
    require('phase snapshots '+ph['phase'],ph['sourceBefore']==ph['sourceAfter'] and ph['sourceBefore']['sourceCommit']==source and ph['sourceBefore']['sourceInputCount']==364 and ph['sourceBefore']['sourceInputsSHA256']==fingerprint)
native=next(x for x in phases if x['phase']=='native'); argv=native['command']['argv']; selectors=[s for s in argv if s.startswith('-only-testing:')]
require('App selected actual zero',len(selectors)==len(set(selectors))==471 and core['intendedArgumentLeafCount']==474 and ej('currentcore-tests.json')['testNodes']==[] and all(ej('currentcore-summary.json')[k]==0 for k in ['totalTestCount','passedTests','failedTests','skippedTests']))
require('actual native failure',native['command']['exitCode']==1 and not native['command']['timedOut'] and native['reportedXcodebuildStatuses']==[{'exitCode':65,'wrapperVerdictStop':False}])
errors=[]
for line in er('currentcore-tests.log').decode().splitlines():
    if ': error:' not in line: continue
    match=re.search(r'^(.+\.swift):(\d+):(\d+): error: (.+)$',line)
    if match: errors.append(match.groups())
require('single actual compiler error',len(errors)==1 and errors[0][0].endswith('Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift') and errors[0][1:] == ('390','100',"value of type 'SelfRenewalCMSVerifier.SignedAttribute.Value' has no member 'full'"))
cases=list(ET.fromstring(pr('xunit.xml')).iter('testcase')); ids=sorted(c.get('classname')+'/'+c.get('name') for c in cases); result=pj('result.json')
verbose=sorted(c+'/'+n for c,n in re.findall(r"^Test Case '-\[([^ ]+) ([^\]]+)\]' passed",pr('tests.log').decode(),re.M))
require('Package24 actual identity and pass',len(ids)==len(set(ids))==24 and not any(list(c) for c in cases) and ids==verbose==sorted(result['passedCaseIdentifiers'])==sorted(package['qualifiedXCTestMethods']) and result['status']=='passed' and result['failedTests']==result['skippedTests']==0 and pj('execution.json')['exitCode']==0)
require('producer commands actual success',len(producer['commands'])==48 and all(c['exitCode']==0 and c['timedOut'] is False and c['processCleanup']['drained'] and c['processCleanup']['childReaped'] and c['processCleanup']['pipesClosed'] and not c['processCleanup']['issues'] for c in producer['commands']))
binding=ej('sdk-fixture-binding.json')
require('producer public outputs',len(binding['publicOutputs'])==43 and all(fact(er('sdk-produced-public/'+p))==f for p,f in binding['publicOutputs'].items()) and len(producer['actualSDKProducedMachOs'])==4)
require('raw xcresult retained with no accepted result',any('.xcresult/' in n for n in z.namelist()) and ej('currentcore-completion.json')['resultProduced'] is False)
require('claims remain false',all(record[k] is False for k in ['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']) and record['AppSDK']['actualDefinitions']==record['AppSDK']['actualLeaves']==0)
out=root/'.build/sdk-f481e89-archive-root-review/review-v1.json'; out.parent.mkdir(parents=True,exist_ok=True)
review={'schemaVersion':1,'status':'approved','failedChecks':0,'candidateFinal':{'path':(stage/'final-v1.json').relative_to(root).as_posix(),**fact((stage/'final-v1.json').read_bytes())},'sourceCommit':source,'candidateFiles':107,'actualAppMethods':0,'actualAppLeaves':0,'independentPackagePassed':24,'producerCommandsPassed':48,'historicalSourceInputs':364,'phaseRecords':11,'beforeAfterSnapshots':22,'checks':checks,'clarification':'resultProduced=false is the original controller accepted-result field; raw xcresult is present, with exported App test tree empty. No rerun or new xcresulttool decode.','operations':{'cloudQueries':0,'downloads':0,'SDKRuns':0,'testsRerun':0,'GitReadOnlyBatch':1,'canonicalWrites':0},'remainingConfirmedSourceBlockers':[]}
out.write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'review':{'path':out.relative_to(root).as_posix(),**fact(out.read_bytes())},'checks':len(checks),'failedChecks':0,'App':0,'Package':24}))
