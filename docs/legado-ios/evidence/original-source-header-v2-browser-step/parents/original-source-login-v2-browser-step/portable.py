from pathlib import Path
import hashlib,importlib.util,json,shutil,subprocess,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;V=S/'validation-root';W=S/'work';V.mkdir(exist_ok=True)
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def cp(rel):
 p=V/rel;p.parent.mkdir(parents=True,exist_ok=True);source=W/rel if(W/rel).exists()else R/rel;shutil.copyfile(source,p)
for folder in ['Packages/LegadoRuntime/vendor/runtime-http','Packages/LegadoRuntime/vendor/scalar-rules','Packages/LegadoRuntime/vendor/probe','Packages/LegadoRuntime/vendor/original-rule','Packages/LegadoRuntime/jvm/src/main/resources']:
 shutil.copytree(R/folder,V/folder,dirs_exist_ok=True)
for rel in ['scripts/reader-experience/runtime-packaging.py','scripts/reader-experience/test-runtime-packaging.py','scripts/legado-ios/verify-native-reuse.py','scripts/legado-ios/verify-runtime-reuse.py','scripts/legado-ios/verify-runtime.py','Packages/LegadoRuntime/vendor/original-rule/manifest.json']:cp(rel)
m=json.loads((W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_text())
for row in m['portedSources']:cp(row['path'])
http=json.loads((R/'Packages/LegadoRuntime/vendor/runtime-http/manifest.json').read_text())
for row in http['encodingSources']:cp('Packages/LegadoRuntime/'+row['portedPath'])
for row in m['portedSources']:assert fact(V/row['path'])=={k:row[k]for k in ('bytes','sha256')}
E=S/'portable-final'
if E.exists():E.rename(S/'portable-incomplete-import-attempt')
E.mkdir()
argv=[sys.executable,'-B',str(V/'scripts/reader-experience/test-runtime-packaging.py'),'-v'];p=subprocess.run(argv,cwd=V,capture_output=True);(E/'packaging.log').write_bytes(p.stdout+p.stderr)
out=dict(argv=argv,exitCode=p.returncode,log='packaging.log',portedRows=len(m['portedSources']))
if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace'));sys.exit(p.returncode)
spec=importlib.util.spec_from_file_location('v2_browser_packaging',V/'scripts/reader-experience/runtime-packaging.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
out['actualOrdinaryJarAudit']=module.inspect_jar(S/'execution-v1/legado-runtime-v2-browser.jar')
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()));rel='Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift';roots={}
methods={}
for kind in ['rawbaseline','work']:
 b=(S/kind/rel).read_bytes();tree=parser.parse(b);errors=[];functions={}
 def visit(n):
  if n.type=='ERROR'or n.is_missing:errors.append(dict(type=n.type,row=n.start_point.row+1,column=n.start_point.column+1))
  if n.type=='function_declaration':
   name=n.child_by_field_name('name')
   if name:
    text=b[name.start_byte:name.end_byte].decode()
    if text.startswith('testNative'):functions[text]=b[n.start_byte:n.end_byte]
  for c in n.children:visit(c)
 visit(tree.root_node);assert not errors,errors;roots[kind]=dict(**fact(S/kind/rel),errors=errors);methods[kind]=functions
assert len(methods['rawbaseline'])==13 and len(methods['work'])==14
assert all(methods['work'][n]==b for n,b in methods['rawbaseline'].items())
out['swiftGrammar']=roots;out['nativeInventory']=dict(oldDefinitions=13,candidateDefinitions=14,oldMethodsASTExact=True,newMethods=sorted(set(methods['work'])-set(methods['rawbaseline'])))
(E/'facts.json').write_text(json.dumps(out,indent=2)+'\n',encoding='utf-8');print(json.dumps(dict(packagingExit=p.returncode,portedRows=len(m['portedSources']),grammarRoots=2,oldNative=13,newNative=14,ordinaryJarInspected=True)))
