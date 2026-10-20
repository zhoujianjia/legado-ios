from pathlib import Path
import hashlib,importlib.util,json,shutil,sys,zipfile
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;V=S/'validation-root';W=S/'work';V.mkdir(exist_ok=False)
prior=R/'.build/original-source-login-v2-browser-step/validation-root';shutil.copytree(prior,V,dirs_exist_ok=True)
for p in W.rglob('*'):
 if p.is_file():d=V/p.relative_to(W);d.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,d)
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
manifest='Packages/LegadoRuntime/vendor/original-rule/manifest.json';m=json.loads((W/manifest).read_text(encoding='utf-8'));base=json.loads((S/'rawbaseline'/manifest).read_text(encoding='utf-8'));changed=[]
for a,b in zip(base['portedSources'],m['portedSources']):
 assert a['path']==b['path'];assert fact(V/b['path'])=={k:b[k]for k in ('bytes','sha256')}
 if a!=b:changed.append(b['path'])
assert len(changed)==3 and len(m['portedSources'])==58;base['portedSources']=m['portedSources'];assert base==m
spec=importlib.util.spec_from_file_location('coherent_runtime_packaging',V/'scripts/reader-experience/runtime-packaging.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
jar=S/'execution-v1/legado-runtime-header-v2-browser.jar';inspection=module.inspect_jar(jar)
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()));grammar=[]
for rel in ['Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift','Modules/Services/Online/LegadoPersistentStateHost.swift','Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift']:
 for kind in ['rawbaseline','work']:
  b=(S/kind/rel).read_bytes();tree=parser.parse(b);errors=[]
  def visit(n):
   if n.type=='ERROR'or n.is_missing:errors.append(dict(type=n.type,row=n.start_point.row+1,column=n.start_point.column+1))
   for c in n.children:visit(c)
  visit(tree.root_node);assert not errors,(rel,errors);grammar.append(dict(path=rel,kind=kind,**fact(S/kind/rel),errors=errors))
prod=json.loads((S/'execution-v1/production-binding.json').read_text(encoding='utf-8'));priorbinding=json.loads((R/'.build/original-source-login-browser-post-step/ordinary-jar-production-class-binding.json').read_text(encoding='utf-8'));names={r['path']for r in priorbinding['classes']};fresh={r['path']for r in prod['recompiledClasses']};assert len(names)==349 and fresh.issubset(names)
with zipfile.ZipFile(jar)as z:
 classes=[dict(path=n,bytes=len(z.read(n)),sha256=hashlib.sha256(z.read(n)).hexdigest())for n in sorted(names)];assert z.testzip()is None
 binding=dict(jar=fact(jar),classes=classes,productionClassCount=len(names),recompiledClassCount=len(fresh),retainedCount=len(names-fresh),extraUnchangedJavaClasses=52,CRCValid=True,inspection=inspection,kind='Exact coherent3 main source K2 overlay on POST91d; not fresh Gradle')
(S/'ordinary-jar-production-class-binding.json').write_text(json.dumps(binding,indent=2)+'\n',encoding='utf-8')
out=dict(portedRows=58,changedRows=changed,other55RowsUnchanged=True,allOtherManifestMetadataUnchanged=True,actualOrdinaryJarInspection=inspection,grammar=grammar,SDKExecuted=False,portableReuse=dict(testRuntimePackaging='Inherited unchanged six-test implementation/evidence from Header and V2 slices; not repeated',files=[dict(path=str(prior/rel),**fact(prior/rel))for rel in ['scripts/reader-experience/runtime-packaging.py','scripts/reader-experience/test-runtime-packaging.py','scripts/legado-ios/verify-native-reuse.py','scripts/legado-ios/verify-runtime-reuse.py','scripts/legado-ios/verify-runtime.py']]))
(S/'binding-facts.json').write_text(json.dumps(out,indent=2)+'\n',encoding='utf-8');print(json.dumps(dict(ported=58,manifestChanges=3,grammarRoots=6,errors=0,jar=fact(jar),fresh=len(fresh),retained=len(names-fresh),classes=len(names))))
