from datetime import datetime, timezone
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import sys

ROOT=Path(__file__).resolve().parents[3];OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
files=['Modules/Services/SelfRenewal/SelfRenewalResourceSealVerifier.swift',
       'Modules/Services/SelfRenewal/SelfRenewalNestedCodeRequirementsVerifier.swift',
       'Tests/iOS/yuedu appTests/SelfRenewalResourceSealVerifierTests.swift',
       'Tests/iOS/yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests.swift',
       'Tests/iOS/yuedu appTests/SelfRenewalNestedResourceFixture.swift']
sources=[]
for name in files:
 raw=(ROOT/name).read_bytes();stack=[parser.parse(raw).root_node];errors=[]
 while stack:
  n=stack.pop()
  if n.type=='ERROR' or n.is_missing:errors.append([n.type,list(n.start_point),list(n.end_point)])
  stack.extend(n.children)
 assert not errors,(name,errors)
 target=OUT/'sources'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
 sources.append({'path':name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'grammarErrors':errors})
methods=re.findall(r'    @Test\([^\n]+\)\n    func (\w+)\(', (ROOT/files[3]).read_text(encoding='utf-8'))
assert len(methods)==len(set(methods))==8,methods
old_methods=re.findall(r'    @Test\([^\n]+\)\n    func (\w+)\(', (ROOT/files[2]).read_text(encoding='utf-8'))
assert len(old_methods)==10
record=json.loads((OUT/'independent-owned-vectors.json').read_text(encoding='utf-8'))
swift=(ROOT/files[4]).read_text(encoding='utf-8')
blobs={sha:base64.b64decode(encoded) for sha,encoded in re.findall(r'"([0-9a-f]{64})": "([A-Za-z0-9+/=]+)"',swift)}
def digest(kind,raw):
 if kind==1:return hashlib.sha1(raw).digest()
 if kind==2:return hashlib.sha256(raw).digest()
 if kind==3:return hashlib.sha256(raw).digest()[:20]
 if kind==4:return hashlib.sha384(raw).digest()
 raise AssertionError(kind)
def u32(raw,at):return struct.unpack_from('>I',raw,at)[0]
def node(raw,start=0):
 tag=raw[start];at=start+1;n=raw[at];at+=1
 if n&128:
  w=n&127;n=int.from_bytes(raw[at:at+w],'big');at+=w
 return tag,raw[at:at+n],at+n
def children(raw):
 out=[];at=0
 while at<len(raw):
  tag,body,end=node(raw,at);out.append((tag,body));at=end
 return out
def der_values(raw):
 tag,body,end=node(raw);assert end==len(raw)
 if tag==0x70:
  fields=children(body);assert fields[0]==(2,b'\x01') and fields[1][0]==0xb0
  result={}
  for _,pair in children(fields[1][1]):
   values=children(pair);key=values[0][1].decode()
   kind,value=values[1]
   if kind==1:result[key]=value==b'\xff'
   elif kind==12:result[key]=value.decode()
   elif kind==0x30:result[key]=[v.decode() for t,v in children(value)]
   else:raise AssertionError(kind)
  return result
 raise AssertionError(tag)
audit=[]
for variant,case in record['cases'].items():
 content={path:blobs[sha] for path,sha in case['filesSHA256'].items()}
 for path,sha in case['filesSHA256'].items():
  assert hashlib.sha256(content[path]).hexdigest()==sha
  assert (OUT/'owned'/variant/'Owned.app'/path).read_bytes()==content[path]
 selected={};page_count=special_count=cms_count=0
 for info_path,information in list(content.items()):
  if not info_path.endswith('Info.plist'):continue
  prefix=info_path[:-len('Info.plist')];metadata=plistlib.loads(information)
  executable=metadata['CFBundleExecutable'];raw=content[prefix+executable]
  offsets=[0] if raw[:4]!=bytes.fromhex('cafebabe') else [u32(raw,8+i*20+8) for i in range(u32(raw,4))]
  contexts=[]
  for slice_index,offset in enumerate(offsets):
   code=raw[offset:];limit,size=struct.unpack_from('<II',code,40)
   signature=code[limit:limit+size];assert u32(signature,4)==len(signature)
   members={}
   for i in range(u32(signature,8)):
    slot,at=struct.unpack_from('>II',signature,12+i*8);members[slot]=signature[at:at+u32(signature,at+4)]
   material={1:information,3:content[prefix+'_CodeSignature/CodeResources'],**{k:v for k,v in members.items() if k in (2,5,7)}}
   directories=[]
   for slot,cd in members.items():
    if slot!=0 and not 0x1000<=slot<0x1005:continue
    hashes,identifier,specials,pages,signed_limit=struct.unpack_from('>IIIII',cd,16)
    width,kind,platform,page=cd[36:40];assert pages==3 and signed_limit==limit==173 and page==6
    ident=cd[identifier:cd.index(0,identifier)].decode()
    for i in range(pages):
     assert cd[hashes+i*width:hashes+(i+1)*width]==digest(kind,code[i*64:min(173,(i+1)*64)])
     page_count+=1
    for i in range(1,specials+1):
     assert cd[hashes-i*width:hashes-(i-1)*width]==(digest(kind,material[i]) if i in material else bytes(width))
     if i in material:special_count+=1
    directories.append((kind,slot,ident,digest(kind,cd)[:20]))
   chosen=next(d for kind in [4,2,3,1] for d in directories if d[0]==kind)
   ents=der_values(members[7][8:]);assert ents['com.owned.feature'] is True and ents['com.owned.disabled'] is False
   assert ents['com.owned.values']==['alpha','beta']
   name=variant+'-'+executable+('-x86' if slice_index else '')
   assert members[0]==(OUT/'owned'/f'{name}.verified.cd').read_bytes()
   assert members[0x10000][8:]==(OUT/'owned'/f'{name}.cms').read_bytes()
   cms_count+=1
   contexts.append({'identifier':chosen[2],'selectedHashType':chosen[0],'selectedCDHash':chosen[3].hex(),'loadedDirectoryCount':len(directories),'DEREntitlementsDecoded':True})
  selected[prefix.rstrip('/') or '.']=contexts
 # Validate every ordinary resource seal independently; nested requirements are
 # recorded below, not evaluated by production Swift in this portable audit.
 ordinary_seals=0
 for path,raw in content.items():
  if not path.endswith('_CodeSignature/CodeResources'):continue
  prefix=path[:-len('_CodeSignature/CodeResources')];envelope=plistlib.loads(raw)
  for relative,seal in envelope['files2'].items():
   if 'requirement' in seal:continue
   for kind in [1,2,3,4]:assert seal['hash' if kind==1 else 'hash'+str(kind)]==digest(kind,content[prefix+relative])
   ordinary_seals+=1
 root=plistlib.loads(content['_CodeSignature/CodeResources'])['files2']['Frameworks/Child.framework']
 child=selected['Frameworks/Child.framework']
 if variant=='falseRequirement':assert 'wrong.child' in root['requirement'] and root['cdhash'].hex()==child[0]['selectedCDHash']
 if variant=='wrongHint':assert root['cdhash']==bytes(20) and all(c['identifier']=='owned.child' for c in child)
 if variant=='wrongIdentity':assert all(c['identifier']=='owned.evil' for c in child)
 if variant=='fatMismatch':assert [c['identifier'] for c in child]==['owned.child','owned.evil']
 if variant=='systemPolicy':assert root['requirement'].endswith('anchor apple generic')
 audit.append({'case':variant,'files':len(content),'bundles':len(selected),'slices':cms_count,'actualPagesChecked':page_count,'actualNonzeroSpecialDigestsChecked':special_count,'ordinaryResourceSealsChecked':ordinary_seals,'selectedCodeDirectoryContexts':selected})
assert sum(x['slices'] for x in audit)==len(record['actualOpenSSLDetachedCMSVerifications'])==40
(OUT/'independent-fixture-audit.json').write_text(json.dumps({'status':'passed','scope':'Independent wire/page/resource/CD/DER fixture reconstruction only; no Swift execution','cases':audit},indent=2)+'\n',encoding='utf-8',newline='\n')
primary=[]
for path in sorted((OUT/'primary').glob('*')):
 if path.is_file():primary.append({'path':str(path.relative_to(ROOT)).replace('\\','/'),'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
result={'recordedAtUTC':datetime.now(timezone.utc).isoformat(),'status':'prepared_not_sdk_executed',
        'sourceInputs':sources,'grammarParsedFiles':len(sources),'newSwiftSuite':'SelfRenewalNestedCodeRequirementsVerifierTests',
        'preparedNewSwiftMethods':methods,'preparedNewSwiftTests':8,'existingResourceMethodsRequiringSDKRevalidation':old_methods,
        'actualSwiftSDKBuilds':0,'actualSwiftTestExecutions':0,'independentOwnedCases':8,'bundlesPerCase':4,'actualOpenSSLDetachedSignaturesVerified':40,
        'independentFixtureAudit':'independent-fixture-audit.json','primarySecurityCommit':'db15acbe6a7f257a859ad9a3bb86097bfe0679d9','primarySnapshots':primary,
        'productionConnection':'single prior Inventory + genuine hash/CMS material -> same checked executable FD re-read selected raw CD matching Hash/Signed SHA256 -> actual Info slot1 and DER slot7 digest check -> certificate chain from actual validated CMS signer -> deepest-first recursive resource validity and every slice requirement expression',
        'exportedCompositionFacts':['EnvelopeVerification.verifiedFileDigests only includes actually streamed and matched seals','Materials.codeAttributes reuses actual selected-CD-bound Info/DER/certificate contexts','missing DER stays nil; XML slot5 is not substituted for pinned StaticCode entitlement context'],
        'requirementScope':'bounded single-expression syntax per requirements.grammar; arbitrary compound expression/negation, identifier/platform/cdhash, certificate slots/SHA1/subject/extensions/policies/timestamp, Info/entitlement match suffixes; paths parse but never read arbitrary external files',
        'cdHashSealIsOnlyHint':True,'requiresEveryFatSlice':True,'legacyAlternateAuthenticationNeverUpgraded':True,
        'unresolvedSystemContext':['anchor apple / apple generic (Apple root/trustcache policy)','trusted certificates (system trust settings)','named anchor/code fragments','notarization / legacy Developer ID','external certificate path compilation context'],
        'remainingUnverified':['Swift SDK compile/runtime tests','system-policy requirement predicates and external compiler contexts','strict Apple resource policy and Apple signing/provisioning/install authority','profile composition handled by root','scatter/pre-encrypted/linkage formats','automatic renewal/install/replacement'],
        'appleAuthorityEstablished':False,'replacementAuthorized':False,'atomicSealClaimed':False,'realUserAccountsOrIPAsRead':False,
        'ciDocsGitTouched':False}
(OUT/'preparation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps({'status':result['status'],'grammarParsedFiles':len(sources),'newMethods':8,'actualOpenSSLVerified':40,'ownedCases':8,'actualSwiftOrSDKExecution':0,'sourceInputs':sources}))
