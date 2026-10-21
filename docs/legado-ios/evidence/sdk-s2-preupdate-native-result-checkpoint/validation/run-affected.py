from pathlib import Path
import hashlib,json,os,subprocess,time
root=Path('F:/yuedu-reader');st=root/'.build/consolidated-sdk-s2-preupdate-native-result-checkpoint';vr=st/'validation-root'
jobs=[('core','test-renewal-probe-tools.py',[
 'RenewalProbeEvidenceTests.test_currentcore_exact_ast_union_source_boundaries_arguments_and_one_new_budget',
 'DeltaReuseCheckpointSelectionTests.test_delta_inputs_keep_app_inventory_all_three_pairs_required_fixture_and_new_package_mode']),
 ('native','test-native-smoke-tools.py',[
 'NativeSmokeProvenanceTests.test_result_requires_exact_built_app_source_stamp',
 'NativeSmokeProvenanceTests.test_workflow_keeps_native_groups_in_separate_required_hosts_after_real_staging'])]
env=dict(os.environ,PYTHONIOENCODING='utf-8',PYTHONDONTWRITEBYTECODE='1');results=[]
for group,script,methods in jobs:
 argv=['C:/Python312/python.exe','-B',str(vr/'scripts/reader-experience'/script),*methods,'-v']
 started=time.time();p=subprocess.run(argv,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log=st/('affected-'+group+'-v1.log');log.write_bytes(p.stdout)
 results.append({'group':group,'argv':argv,'methods':methods,'exitCode':p.returncode,'elapsedSeconds':round(time.time()-started,3),'log':{'path':log.relative_to(root).as_posix(),'bytes':len(p.stdout),'sha256':hashlib.sha256(p.stdout).hexdigest()}})
 print(group,p.returncode,p.stdout.decode('utf-8')[-400:])
out=st/'affected-validation-v1.json';out.write_bytes((json.dumps({'executions':results,'distinctMethods':4,'methodExecutions':4,'actualSwiftSDK':0,'actualJVM':0,'canonicalGitWrites':False,'cloudQueries':0},indent=2)+'\n').encode())
raise SystemExit(1 if any(r['exitCode']for r in results)else 0)
