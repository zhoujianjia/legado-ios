from pathlib import Path
import ast,datetime,difflib,hashlib,importlib.util,json,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;P=S/'preparation';old=P/'work';W=P/'work-v3';assert not W.exists();W.mkdir()
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
draft=json.loads((P/'controls-draft-v2.json').read_text());rows=[]
wrong='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalWebJsPageRuntime.kt'
correct='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalWebJsPageRuntime.kt'
for row in draft['files']:
 rel=row['path'];assert fact(old/rel)==row['draft']and fact(R/rel)==row['baseline'];text=(old/rel).read_text(encoding='utf-8').replace(wrong,correct)
 p=W/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text,encoding='utf-8',newline='\n')
 if rel.endswith('.py'):ast.parse(text,filename=rel)
 rows.append(dict(path=rel,baseline=row['baseline'],draft=fact(p)))
inventory=json.loads((P/'inventory-draft-v1.json').read_text());known=[correct if p==wrong else p for p in inventory['knownInputs']];assert len(known)==len(set(known))
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,R/path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
core=load('webjs_cohort_core_baseline','scripts/reader-experience/renewal-probe-tools.py');native=load('webjs_cohort_native_baseline','scripts/reader-experience/native-smoke-tools.py')
groups={name:dict(baselinePaths=list(before),cohortPaths=list(dict.fromkeys((*before,*known))),added=[p for p in known if p not in before])for name,before in [('core',core.SOURCE_INPUTS),('native',native.SOURCE_INPUTS)]}
result=dict(status='successor-control-draft-corrects-inventory-path-no-Swift-draft-byte-acceptance-no-tests',recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),baseline='canonical59ad5db controls current bytes independently checked; no Git queried',parentDraft=dict(path='preparation/controls-draft-v2.json',**fact(P/'controls-draft-v2.json')),files=rows,knownSourcePaths=known,groups=groups,counts=dict(core=len(groups['core']['cohortPaths']),native=len(groups['native']['cohortPaths']),union=len(set(groups['core']['cohortPaths'])|set(groups['native']['cohortPaths']))),history=[dict(kind='Pre-test inventory correction',wrong=wrong,actual=correct,testExecutions=0,canonicalMutations=0)],SwiftSourceFinalPending=True,actualTests=0)
write(P/'controls-draft-v3.json',result);print(json.dumps(dict(path=str(P/'controls-draft-v3.json'),**fact(P/'controls-draft-v3.json'),counts=result['counts'])))
