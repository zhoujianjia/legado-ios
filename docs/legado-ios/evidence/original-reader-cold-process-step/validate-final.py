from pathlib import Path
import ast,hashlib,json,os,shutil,subprocess,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';V=S/'validation-root';E=S/'validation-final';E.mkdir(exist_ok=False)
for rel in ['scripts/reader-experience/original-cold-process-tools.py','scripts/reader-experience/test-original-cold-process-tools.py','Tests/iOS/LegadoNativeOriginalReaderTests.swift']:
 shutil.copyfile(W/rel,V/rel)
env=os.environ.copy();env.update(TEMP=str(S/'tmp'),TMP=str(S/'tmp'),TMPDIR=str(S/'tmp'),PYTHONDONTWRITEBYTECODE='1')
argv=[sys.executable,'-B',str(V/'scripts/reader-experience/test-original-cold-process-tools.py'),
 'ColdProcessProtocolTests.test_receipts_require_current_nonce_accepted_host_and_different_pid',
 'ColdProcessProtocolTests.test_offline_marker_requires_two_real_bodies_all_artifacts_and_stopped_peer',
 'ColdProcessProtocolTests.test_two_qualified_invocations_use_frozen_binary_and_keep_host_budget','-v']
p=subprocess.run(argv,cwd=V,capture_output=True,env=env);(E/'cold-affected.log').write_bytes(p.stdout+p.stderr);(E/'commands.json').write_text(json.dumps([dict(argv=argv,exitCode=p.returncode,log='cold-affected.log')],indent=2)+'\n',encoding='utf-8');print('affected3',p.returncode,flush=True)
if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace'));sys.exit(p.returncode)
for rel in ['scripts/reader-experience/original-cold-process-tools.py','scripts/reader-experience/test-original-cold-process-tools.py']:ast.parse((W/rel).read_text(encoding='utf-8'))
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()));rel='Tests/iOS/LegadoNativeOriginalReaderTests.swift';b=(W/rel).read_bytes();tree=parser.parse(b);errors=[];inventory={}
def visit(node):
 if node.type=='ERROR'or node.is_missing:errors.append(dict(type=node.type,line=node.start_point.row+1,column=node.start_point.column+1))
 if node.type=='function_declaration':
  name=node.child_by_field_name('name')
  if name and b[name.start_byte:name.end_byte].decode().startswith('testNative'):inventory[b[name.start_byte:name.end_byte].decode()]=b[node.start_byte:node.end_byte]
 for child in node.children:visit(child)
visit(tree.root_node);assert not errors,errors;assert len(inventory)==13
facts=dict(pureProtocolAffectedMethods=3,SwiftCandidateGrammarErrors=errors,sourceSHA256=hashlib.sha256(b).hexdigest(),sourceBytes=len(b),PythonASTRoots=2,reason='Only strict typed count guards and future native140->142 source dedupe changed after initial5+inventory1; rerun affected3 only. Consumer cleanup authorization/explicitUDID already in initial tests, final same helpers continue guarded.',actualSDK=0,actualColdHosts=0,notFutureS4Union=True)
(E/'facts.json').write_text(json.dumps(facts,indent=2)+'\n',encoding='utf-8');print(json.dumps(facts))
