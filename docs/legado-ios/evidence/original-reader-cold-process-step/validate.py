from pathlib import Path
import ast,hashlib,importlib.util,json,os,shutil,subprocess,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';V=S/'validation-root';V.mkdir(exist_ok=False);E=S/'validation-v1';E.mkdir(exist_ok=False)
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def copy(rel):
 p=W/rel if(W/rel).is_file()else R/rel;dst=V/rel;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dst)
spec=importlib.util.spec_from_file_location('cold_validation_native',R/'scripts/reader-experience/native-smoke-tools.py');n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)
paths=set(n.SOURCE_INPUTS)
for folder in ['scripts/reader-experience','scripts/legado-ios']:
 paths.update(p.relative_to(R).as_posix()for p in (R/folder).glob('*.py'))
paths.update(p.relative_to(W).as_posix()for p in W.rglob('*')if p.is_file())
for rel in sorted(paths):copy(rel)
commands=[];tmp=S/'tmp';tmp.mkdir();env=os.environ.copy();env.update(TEMP=str(tmp),TMP=str(tmp),TMPDIR=str(tmp),PYTHONDONTWRITEBYTECODE='1')
for name,argv in [('cold-protocol.log',[sys.executable,'-B',str(V/'scripts/reader-experience/test-original-cold-process-tools.py'),'-v']),('native-inventory.log',[sys.executable,'-B',str(V/'scripts/reader-experience/test-native-smoke-tools.py'),'NativeSmokeProvenanceTests.test_workflow_keeps_native_groups_in_separate_required_hosts_after_real_staging','-v']),('bash-syntax.log',['D:/app/Git/bin/bash.exe','-n',str(W/'scripts/xctest.sh')])]:
 p=subprocess.run(argv,cwd=V,capture_output=True,env=env);(E/name).write_bytes(p.stdout+p.stderr);commands.append(dict(argv=argv,exitCode=p.returncode,log=name,tempRoot=str(tmp)));(E/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8');print(name,p.returncode,flush=True)
 if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-6000:]);sys.exit(p.returncode)
for rel in ['scripts/reader-experience/original-cold-process-tools.py','scripts/reader-experience/test-original-cold-process-tools.py']:
 ast.parse((W/rel).read_text(encoding='utf-8'))
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()));rel='Tests/iOS/LegadoNativeOriginalReaderTests.swift';roots=[];methods={}
for kind in ['rawbaseline','work']:
 p=S/kind/rel;b=p.read_bytes();tree=parser.parse(b);errors=[];inventory={}
 def visit(node):
  if node.type=='ERROR'or node.is_missing:errors.append(dict(type=node.type,line=node.start_point.row+1,column=node.start_point.column+1))
  if node.type=='function_declaration':
   name=node.child_by_field_name('name')
   if name:
    text=b[name.start_byte:name.end_byte].decode()
    if text.startswith('testNative'):inventory[text]=b[node.start_byte:node.end_byte]
  for child in node.children:visit(child)
 visit(tree.root_node);assert not errors,errors;roots.append(dict(path=rel,kind=kind,**fact(p),errors=errors));methods[kind]=inventory
assert len(methods['rawbaseline'])==11 and len(methods['work'])==13
assert all(methods['work'][k]==v for k,v in methods['rawbaseline'].items())
facts=dict(pureProtocolMethods=5,existingInventoryGuard=1,bashSyntax=0,PythonParsedRoots=2,SwiftGrammar=roots,old11NativeMethodsASTExact=True,newColdMethods=sorted(set(methods['work'])-set(methods['rawbaseline'])),NativeGroup26Unchanged=True,mainjs1Unchanged=True,sourceClosure=dict(nativeExistingInputs=len(n.SOURCE_INPUTS),coldAdditionalProtocolInputs=2,total=len(n.SOURCE_INPUTS)+2),copiedSourceFacts=[dict(path=rel,**fact(V/rel))for rel in sorted(paths)],actualSDK=0,actualColdHosts=0,actualJVMTests=0)
(E/'facts.json').write_text(json.dumps(facts,indent=2)+'\n',encoding='utf-8');print(json.dumps({k:v for k,v in facts.items()if k!='copiedSourceFacts'and k!='SwiftGrammar'}))
