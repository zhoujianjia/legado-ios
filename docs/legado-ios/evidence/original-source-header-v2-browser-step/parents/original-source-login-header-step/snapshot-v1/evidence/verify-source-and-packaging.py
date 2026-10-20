from pathlib import Path
import hashlib,importlib.util,json,re,shutil,sys,unittest,zipfile,xml.etree.ElementTree as ET
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';V=S/'validation-root';A=R/'.build/original-source-login-browser-post-step'
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
swift=['Modules/Services/Online/LegadoPersistentStateHost.swift','Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift','Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift'];grammar=[]
for kind,root in [('baseline',S/'rawbaseline'),('candidate',W)]:
 for rel in swift:
  p=root/rel;b=p.read_bytes();errors=[]
  def visit(n):
   if n.type=='ERROR'or n.is_missing:errors.append(dict(type=n.type,line=n.start_point.row+1))
   for c in n.children:visit(c)
  visit(parser.parse(b).root_node);grammar.append(dict(set=kind,path=rel,**fact(p),errors=errors))
assert all(not r['errors']for r in grammar),grammar
write(S/'swift-grammar.json',dict(scope='tree-sitter syntax only; no Swift compiler, SDK, JNI, UIKit/WebKit or Native test execution',roots=grammar))
native=swift[-1];old=re.findall(r'func (test\w+)\(', (S/'rawbaseline'/native).read_text(encoding='utf-8'));new=re.findall(r'func (test\w+)\(', (W/native).read_text(encoding='utf-8'))
assert len(old)==13 and len(new)==14 and set(old)<set(new)
write(S/'native-definition.json',dict(path=native,**fact(W/native),oldDefinitions=old,newDefinitions=sorted(set(new)-set(old)),actualExecution=0,flow='One shared LegadoRuntimeProcess executor, same existing App LoginManager/defaults and CookieStore. Actual Host rejects read-only/wrong task/source metadata. Actual Rhino emits Cookie/header writes; raw composed/decomposed UTF8 checks and revision increments/noop are asserted. Successful remove reaches real existing WebKit expiration; cancellation after accepted Cookie then header keeps both facts and prevents late Keychain write. No second VM/store/HTTP owner. SDK not executed.'))
changed='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt'
manifest='Packages/LegadoRuntime/vendor/original-rule/manifest.json'
for rel in [changed,manifest]:shutil.copyfile(W/rel,V/rel)
prior=json.loads((A/'actual-jvm-compilation-inputs.json').read_text(encoding='utf-8'));inputs=[]
for row in prior['inputs']:
 p=(W/row['path'])if row['path']==changed else(V/row['path']);f=fact(p)
 if row['path']!=changed:assert f=={k:row[k]for k in ('bytes','sha256')},row['path']
 inputs.append(dict(path=row['path'],**f))
tr='Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/'
tests=[dict(path=tr+n,**fact((V if n in ['FileRulePersistenceAdapter.kt','OriginalCookieTextOracle.kt']else W)/(tr+n)))for n in ['FileRulePersistenceAdapter.kt','OriginalCookieTextOracle.kt','AppCookieOwnerTextTest.kt','OriginalSourceLoginHeaderTest.kt']]
write(S/'actual-jvm-compilation-inputs.json',dict(kind='124 main roots: one ProductionRulePlatform freshly compiled,123 other main source bytes exact immutable POST. Three unchanged Gradle/control files retained only as input closure facts; no full Gradle invocation.',inputs=inputs,recompiledRoots=[changed],testInputs=tests))
m=json.loads((W/manifest).read_text(encoding='utf-8'));assert len(m['portedSources'])==58
for row in m['portedSources']:assert fact(V/row['path'])=={k:row[k]for k in ('bytes','sha256')},row['path']
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod
tool=load('post_packaging',R/'scripts/reader-experience/runtime-packaging.py');tool.REPO=V
jar=S/'execution-v1/legado-runtime-header-incremental.jar';inspection=tool.inspect_jar(jar)
with zipfile.ZipFile(jar)as z:
 assert z.testzip()is None
 assert not any('/OriginalSourceLoginHeaderTest' in n or n.startswith(('org/junit/','org/hamcrest/'))for n in z.namelist())
 production=[]
 basebinding=json.loads((S/'execution-v1/production-binding.json').read_text(encoding='utf-8'))
 for row in basebinding['retainedClasses']:
  b=z.read(row['path']);assert len(b)==row['bytes']and hashlib.sha256(b).hexdigest()==row['sha256'];production.append(row)
 for row in basebinding['recompiledClasses']:production.append({k:row[k]for k in ('path','bytes','sha256')})
write(S/'ordinary-jar-production-class-binding.json',dict(kind='Exact one-source incremental K2 payload, NOT fresh full Gradle',jar=fact(jar),classes=sorted(production,key=lambda r:r['path']),productionClassCount=len(production),recompiledClassCount=len(basebinding['recompiledClasses']),retainedCount=len(basebinding['retainedClasses']),CRCValid=True,inspection=inspection,portedSources=58))
testmodule=load('post_packaging_tests',R/'scripts/reader-experience/test-runtime-packaging.py');testmodule.packaging.REPO=V
with (S/'packaging-tests.log').open('w',encoding='utf-8')as out:
 result=unittest.TextTestRunner(stream=out,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(testmodule.OrdinaryJarGuardTests))
assert result.wasSuccessful()and result.testsRun==6
xml=ET.parse(S/'execution-v1/actual-tests.xml').getroot();assert xml.attrib['tests']=='5'and xml.attrib['failures']=='0'and xml.attrib['errors']=='0'and xml.attrib['skipped']=='0'
write(S/'actual-jvm-tests.json',dict(xml=dict(path='execution-v1/actual-tests.xml',**fact(S/'execution-v1/actual-tests.xml')),initialExecuted=5,failed=0,newHeader=4,affectedPriorOrder=1,methods=[r.attrib for r in xml.findall('testcase')],JVMUIKitExecution=False,finalShutterSuccessor=dict(path='execution-shutter-v2/actual-tests.xml',**fact(S/'execution-shutter-v2/actual-tests.xml')),finalDistinctMethods=5,totalActualExecutions=6,scope='Initial5 plus only strengthened security method1 rerun. Other4 final method bodies exactly unchanged; no production recompile.'))
print(json.dumps(dict(grammarRoots=len(grammar),grammarErrors=0,NativeDefinitions=len(new),newNative=sorted(set(new)-set(old)),inputs=len(inputs),mainInputs=124,productionClasses=len(production),recompiled=len(basebinding['recompiledClasses']),retained=len(basebinding['retainedClasses']),portedSources=58,packagingTests=result.testsRun,JVMFinalDistinctMethods=5,SwiftSDKExecuted=0)))
