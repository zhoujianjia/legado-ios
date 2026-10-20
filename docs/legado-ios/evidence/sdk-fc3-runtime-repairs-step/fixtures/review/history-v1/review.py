from pathlib import Path
import datetime,difflib,hashlib,json,re,subprocess,sys
R=Path('F:/yuedu-reader');S=Path(__file__).parent;P=R/'.build/sdk-fc3b01c-fixture-repairs';m=json.loads((P/'candidate-v1.json').read_bytes());checks=[]
def ck(v,label):
 if not v:raise AssertionError(label)
 checks.append(label)
def fact(p):b=p.read_bytes();return {'path':str(p.relative_to(R)).replace('\\','/'),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
sys.path.insert(0,str(R/'.tools/swift-syntax-python'));from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()));files=[]
for row in m['files']:
 rel=row['path'];src=P/'work'/rel;b=src.read_bytes();a=(R/rel).read_bytes();ck({k:fact(src)[k]for k in ['bytes','sha256']}==row['candidate'],'candidate exact '+rel);ck({k:fact(R/rel)[k]for k in ['bytes','sha256']}==row['baseline'],'baseline exactcurrent '+rel)
 old=subprocess.run(['git','show',m['sourceCommit']+':'+rel],cwd=R,capture_output=True,check=True).stdout
 pat=r'(?m)^\s*@Test(?:\([^\r\n]*\))?\s+(?:@MainActor\s+)?func\s+(\w+)\(([^)]*)\)';defs=re.findall(pat,a.decode('utf-8'))
 ck(defs==re.findall(pat,b.decode('utf-8')),'unchanged test definitions '+rel)
 t=parser.parse(b);pending=[t.root_node];errors=[]
 while pending:
  n=pending.pop()
  if n.is_error or n.is_missing:errors.append([n.type,list(n.start_point)])
  pending+=n.children
 ck(not errors,'candidate grammar only '+rel)
 diff=''.join(difflib.unified_diff(a.decode('utf-8').splitlines(True),b.decode('utf-8').splitlines(True),fromfile='a/'+rel,tofile='b/'+rel));dp=S/'diffs'/(rel+'.diff');dp.parent.mkdir(parents=True,exist_ok=True);dp.write_text(diff,encoding='utf-8',newline='\n')
 if rel.endswith('DeveloperAuthenticationTests.swift'):
  ck(b.decode('utf-8').replace('directory.appendingPathComponent("SelfRenewalApp")','directory.appendingPathComponent("AppSession")')==a.decode('utf-8'),'only appInputs root basename changed')
  ck(old!=a and b'let root = directory.appendingPathComponent("AppSession")'in old,'current S2 baseline preserved; same actualfc3 helper defect')
 elif rel.endswith('AnisetteV3ProviderTests.swift'):
  ck(old==a,'Anisette actualfc3 bytes exact baseline');ck(b'let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString'in b and b'let root = parent.appendingPathComponent("SelfRenewalApp", isDirectory: true)'in b,'owned random parent plus exact root required by production')
  ck(b'removeItem(at: parent)'in b and b'withIntermediateDirectories: false'in b,'cleanup only owned random parent and create without arbitrary intermediates')
 else:
  ck(old==a,'Account actualfc3 bytes exact baseline');ck(b'try #require(failure.underlying is EnrollmentFixtureStop)'in b and b'try #require(!failure.upgradeMayHaveExecuted)'in b and b'try #require(loaded.record.phase == .uploadIntent && loaded.record.remoteHistory == .started)'in b,'Account TLS and ownedintent prerequisites nowthrow before enrollment')
  ck(b'afterRemoteCreation:'in b or b'refreshDeveloperMaterials'in b,'later enrollment path retained rather than deleted')
 files.append({'path':rel,'baseline':fact(R/rel),'candidate':fact(src),'diff':fact(dp),'testDefinitionsUnchanged':len(defs),'wholeBaselineEqualsActualFc3':a==old,'actualFc3Bytes':len(old),'actualFc3SHA256':hashlib.sha256(old).hexdigest()})
production=R/'Modules/Services/SelfRenewal/SelfRenewalAppSession.swift';code=production.read_text(encoding='utf-8');ck('requested.lastPathComponent == "SelfRenewalApp"'in code,'actual production strict root basename guard remains untouched')
log=R/'.build/sdk-fc3b01c-terminal/extracted-12307712232/reader-renewal-probe/currentcore-tests.log';matches=[]
for i,line in enumerate(log.read_text(encoding='utf-8',errors='replace').splitlines(),1):
 if ('recorded an issue'in line and any(v in line for v in ['endpointSelectionIsLocalAndBackwardCompatible','appSessionAuthenticatesThroughSameVaultAndReopensStoredSession','appOwnerCancellationClearsTheSamePendingChallenge']))or('SelfRenewalAccountSessionTests.swift:'in line and 'recorded an issue'in line and any(v in line for v in ['475:','476:','486:','profileExpired','OperationFailure'])):
  matches.append({'line':i,'text':line[:2200]})
ck(len(matches)>=3,'actual historical log includes exact fixture failures')
result={'version':1,'reviewedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'approved-minimal-three-fixture-successor','authorCandidate':fact(P/'candidate-v1.json'),'files':files,'actualFailureSource':'fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a','actualSDKRun':39507170170,'actualSDKJob':118918888695,'rawLog':fact(log),'actualExcerpts':matches,'productionRootContract':{'path':fact(production),'requiredBasename':'SelfRenewalApp','relaxed':False},'findings':[],'baselineBoundary':'DeveloperAuthentication current94894-byte baseline includes already-integrated S2 authenticated-SPD changes; fc3 actual53471-byte file has the same appInputs basename defect. Only that one literal changes, preserving all S2 code. Other two entire baselines exactly match fc3.','guardSemantics':'#expect→#require retains the same predicates but aborts on missing TLS/realUploadIntent before later enrollment effects. No fake TLS receipt, removed assertion, grant bypass, new state owner or production change.','validation':{'checks':len(checks),'candidateGrammarRoots':3,'grammarErrors':0,'newTestDefinitions':0,'SwiftSDKTestsExecutedHere':0,'productionChanged':False,'rootSuiteOrCloudRerun':False},'limits':['No Swift compiler/SDK execution on Windows; actual cases await coherent SDK','Independent of TLS/recovery hang fix and root actualSDK exit124; this does not prove those failures repaired','No physicaldevice/account/Apple capability/renewal acceptance']}
S.mkdir(parents=True,exist_ok=True);(S/'review-v1.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n');print('FROZEN',fact(S/'review-v1.json'),'checks',len(checks))
