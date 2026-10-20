from pathlib import Path
import hashlib,json,subprocess,sys
R=Path('F:/yuedu-reader');S=Path(__file__).parent;C=S/'test-compile-final';C.mkdir(exist_ok=False);E=S/'execution-v1';prior=json.loads((E/'commands.json').read_text());argv=prior[1]['argv'];argv[argv.index('-d')+1]=str(C/'classes');(C/'classes').mkdir();p=subprocess.run(argv,cwd=R,capture_output=True);(C/'compile.log').write_bytes(p.stdout+p.stderr)
root=S/'work/Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginV2BrowserTest.kt';b=root.read_bytes();(C/'facts.json').write_text(json.dumps(dict(argv=argv,exitCode=p.returncode,source=dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest()),execution='No JUnit repeated. Final fixture composition compiles;5 original passing method paths retained, corrected UI method path passed in repair-v2.'),indent=2)+'\n')
print('final-test-compile',p.returncode);sys.exit(p.returncode)
