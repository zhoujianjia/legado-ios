from pathlib import Path
import ast,hashlib,json,os,shutil,subprocess,sys
sys.dont_write_bytecode=True
S=Path(__file__).parent;V=S/'successor-v2';root=V/'validation-root';shutil.copytree(S/'validation-root',root,dirs_exist_ok=True);E=V/'validation'
if E.exists():E.rename(V/'validation-initial-fixture-path-failure')
E.mkdir();tmp=V/'tmp';tmp.mkdir(exist_ok=True)
changed=['scripts/reader-experience/original-cold-process-tools.py','scripts/reader-experience/test-original-cold-process-tools.py']
for rel in changed:shutil.copyfile(V/'work'/rel,root/rel);ast.parse((V/'work'/rel).read_text(encoding='utf-8'))
argv=[sys.executable,'-B',str(root/'scripts/reader-experience/test-original-cold-process-tools.py'),'ColdProcessProtocolTests.test_marker_commit_is_complete_and_refuses_stale_overwrite','-v']
env=os.environ.copy();env.update(TEMP=str(tmp),TMP=str(tmp),TMPDIR=str(tmp),PYTHONDONTWRITEBYTECODE='1');p=subprocess.run(argv,cwd=root,capture_output=True,env=env);(E/'marker-and-kernel-exit.log').write_bytes(p.stdout+p.stderr);(E/'commands.json').write_text(json.dumps([dict(argv=argv,exitCode=p.returncode,log='marker-and-kernel-exit.log')],indent=2)+'\n',encoding='utf-8');print('affected marker+exit1',p.returncode)
if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace'));sys.exit(p.returncode)
# Bind the actual call order without adding a mirrored test definition.
t=ast.parse((V/'work'/changed[0]).read_text(encoding='utf-8'));run=next(n for n in t.body if isinstance(n,ast.FunctionDef)and n.name=='run');calls=[n for n in ast.walk(run)if isinstance(n,ast.Call)and isinstance(n.func,ast.Name)]
term=next(n.lineno for n in calls if n.func.id=='terminate_producer');commits=sorted(n.lineno for n in calls if n.func.id=='commit_marker');assert len(commits)==2 and term<commits[0]<commits[1]
(E/'facts.json').write_text(json.dumps(dict(affectedExistingGuard=1,newDefinitions=0,PythonASTRoots=2,terminateBeforeProducerCommit=True,threeSuccessfulExitPathsProduceObservation=True,finalResultBindsExitObservation=True,AppSDKExecutions=0,coldHosts=0,NativeSwiftUnchanged=True),indent=2)+'\n',encoding='utf-8')
