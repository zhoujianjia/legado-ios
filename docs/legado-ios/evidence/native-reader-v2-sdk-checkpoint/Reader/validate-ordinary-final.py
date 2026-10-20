from pathlib import Path
import json,subprocess,sys,importlib.util,unittest
R=Path('F:/yuedu-reader');S=R/'.build/native-210-reader-repair-step';C=S/'incremental';V=S/'validation-root';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';jar=C/'legado-runtime-incremental.jar'
out=C/'ordinary-final';out.mkdir(exist_ok=True);classes=out/'classes';classes.mkdir(exist_ok=True)
commands=[]
for args,name in [([str(J/'javac.exe'),'-J-Xmx64m','-J-XX:+UseSerialGC','-cp',str(jar),'-d',str(classes),str(S/'OrdinaryReaderRepairSmoke.java')],'compile.log'),([str(J/'java.exe'),'-Xms16m','-Xmx128m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC','-cp',str(jar)+';'+str(classes),'OrdinaryReaderRepairSmoke'],'execute.log')]:
 commands.append({'argv':args,'log':name});(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8');p=subprocess.run(args,cwd=R,capture_output=True);(out/name).write_bytes(p.stdout+p.stderr);print(name,p.returncode,flush=True);assert p.returncode==0
spec=importlib.util.spec_from_file_location('reader_repair_packaging',R/'scripts/reader-experience/runtime-packaging.py');pack=importlib.util.module_from_spec(spec);sys.modules[spec.name]=pack;spec.loader.exec_module(pack);pack.REPO=V
details=pack.inspect_jar(jar);(S/'ordinary-incremental-jar-inspected.json').write_text(json.dumps(details,indent=2)+'\n',encoding='utf-8')
spec=importlib.util.spec_from_file_location('reader_repair_packaging_tests',R/'scripts/reader-experience/test-runtime-packaging.py');tests=importlib.util.module_from_spec(spec);sys.modules[spec.name]=tests;spec.loader.exec_module(tests);tests.packaging.REPO=V
with (S/'packaging-tests.log').open('w',encoding='utf-8')as log: result=unittest.TextTestRunner(stream=log,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(tests))
assert result.testsRun==6 and result.wasSuccessful();print('ordinary incremental packaging6 pass',flush=True)
