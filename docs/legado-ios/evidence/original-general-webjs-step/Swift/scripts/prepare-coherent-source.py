from pathlib import Path
import datetime,hashlib,json,sys
R=Path.cwd(); S=Path(__file__).parent; P=R/'.build/original-general-webjs-swift-implementation-step'; N=R/'.build/original-general-webjs-swift-native-successor'
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Parser,Language
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def read(p): return json.loads(p.read_bytes())
f=read(P/'final-v1.json'); n=read(N/'candidate-v1.json'); review=R/'.build/original-general-webjs-swift-independent-review/review-v1.json'
assert fact(P/'final-v1.json')==dict(bytes=15553,sha256='656c4edb243ed86bf8091c0e41835bb7e023eeada257cb05a0ef9dc398faf2bc')
assert fact(review)==dict(bytes=41730,sha256='57114e009ae59810f863ba44131c47cf12280b0f223b0c13c1eeca324bab96e5')
host='Modules/Services/Online/LegadoPersistentStateHost.swift'; native='Tests/iOS/LegadoNativeOriginalReaderTests.swift'; rows=[]; grammar=[]
for row in f['files']:
    path=row['path']; parent=R/f['candidateRoot']/path; assert fact(parent)==row['candidate']
    baseline=(R/path).read_bytes(); data=parent.read_bytes()
    if path==host:
        cookie=read(R/'.build/sdk-fc3-cookie-response-repair-step/final-v1.json')['files'][0]
        assert fact(R/path)==cookie['candidate']
        start=b'    private func originalResponseCookies('; end=b'    private func cookieBoolean('
        old=(R/f['baselineRoot']/path).read_bytes(); original=old[old.index(start):old.index(end)]
        assert data.count(original)==1
        replacement=baseline[baseline.index(start):baseline.index(end)]
        data=data.replace(original,replacement)
        assert data.count(replacement)==1 and data.replace(replacement,original)==parent.read_bytes()
    elif path==native:
        p=N/'work'/path; assert fact(p)==n['candidate']; data=p.read_bytes()
        assert fact(R/path)==row['baseline']
    else: assert fact(R/path)==row['baseline']
    target=S/'work'/path; target.parent.mkdir(parents=True,exist_ok=True); assert not target.exists(); target.write_bytes(data)
    rows.append(dict(path=path,baseline=dict(bytes=len(baseline),sha256=hashlib.sha256(baseline).hexdigest()),candidate=dict(path=target.relative_to(R).as_posix(),**fact(target)),parentCandidate=row['candidate']))
    if path in (host,native):
        tree=parser.parse(data); pending=[tree.root_node]; errors=[]
        while pending:
            node=pending.pop()
            if node.is_error or node.is_missing: errors.append(dict(type=node.type,row=node.start_point.row+1))
            pending.extend(node.children)
        assert not errors,(path,errors)
        grammar.append(dict(path=path,**fact(target),syntaxErrors=0))
unchanged=[]
for row in f['unchangedBindings']:
    assert fact(R/row['path'])=={k:row[k] for k in ('bytes','sha256')}
    unchanged.append(row)
gaps={k:v for k,v in f.items() if isinstance(v,list) and v and isinstance(v[0],dict) and 'area' in v[0]}; assert len(gaps)==1
report=dict(version=1,frozenUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),scope='Reviewed General Swift6 + single Native String-prior-result repair + already-reviewed current Cookie response method; no new implementation branch.',sourceRoot='work',files=rows,unchangedBindings=unchanged,parent=dict(path=str(P/'final-v1.json'),**fact(P/'final-v1.json')),parentIndependentReview=dict(path=str(review),**fact(review)),NativeSuccessor=dict(path=str(N/'candidate-v1.json'),**fact(N/'candidate-v1.json')),CookieSource=dict(path=host,**fact(R/host)),newGrammar=grammar,otherGrammarAndNodeEvidenceReused='All other complete source bytes and exact JS functions remain the frozen656c/57114 reviewed inputs. No runtime suites rerun.',remainingCompatibility=gaps,actualSwiftSDK=0,actualWK=0,actualJNI=0,newNativeMethods=1,oldReaderMethodsRetained=13,newAppDefinitions=0)
(S/'final-v1.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n'); print(json.dumps(dict(files=len(rows),newGrammar=len(grammar),actualSDK=0,final=fact(S/'final-v1.json'))))
