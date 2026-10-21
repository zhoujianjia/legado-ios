from pathlib import Path
import hashlib,json,os,subprocess,time
root=Path('F:/yuedu-reader');st=root/'.build/consolidated-sdk-s2-preupdate-native-result-checkpoint';vr=st/'validation-root'
methods=[
 'MaterialPublicationAndLoginActionSelectionTests.test_combined_checkpoint_keeps_four_real_material_methods_and_exact_login_inputs',
 'LoginUIExploreCheckpointSelectionTests.test_reviewed_app_methods_and_ui_fixture_keep_exact_scope_and_parameter_identities',
 'DeltaReuseCheckpointSelectionTests.test_delta_inputs_keep_app_inventory_all_three_pairs_required_fixture_and_new_package_mode']
argv=['C:/Python312/python.exe','-B',str(vr/'scripts/reader-experience/test-renewal-probe-tools.py'),*methods,'-v']
started=time.time();p=subprocess.run(argv,cwd=root,env=dict(os.environ,PYTHONIOENCODING='utf-8',PYTHONDONTWRITEBYTECODE='1'),stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
log=st/'affected-workflow-label-v2.log';log.write_bytes(p.stdout)
result={'argv':argv,'methods':methods,'exitCode':p.returncode,'elapsedSeconds':round(time.time()-started,3),'log':{'path':log.relative_to(root).as_posix(),'bytes':len(p.stdout),'sha256':hashlib.sha256(p.stdout).hexdigest()},'scope':'Three exact existing workflow-label methods only. No already-passed method repeated.'}
(st/'affected-workflow-label-v2.json').write_bytes((json.dumps(result,indent=2)+'\n').encode())
print(p.stdout.decode('utf-8'));raise SystemExit(p.returncode)
