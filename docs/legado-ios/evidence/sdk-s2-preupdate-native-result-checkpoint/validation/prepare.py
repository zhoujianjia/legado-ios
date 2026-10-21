"""Ignored candidate only: no canonical/Git/cloud writes or test execution."""
from pathlib import Path
import difflib,hashlib,importlib.util,json,re,shutil,subprocess

ROOT=Path('F:/yuedu-reader');ST=ROOT/'.build/consolidated-sdk-s2-preupdate-native-result-checkpoint'
CONTROLS=(
 'scripts/reader-experience/renewal-probe-tools.py',
 'scripts/reader-experience/test-renewal-probe-tools.py',
 'scripts/reader-experience/native-smoke-tools.py',
 'scripts/reader-experience/test-native-smoke-tools.py',
 '.github/workflows/reader-renewal-probe.yml',
 '.github/workflows/legado-native-reader-test.yml',
 'scripts/reader-experience/renewal-probe-tests.sh')
def fact(p):
 raw=p.read_bytes();return {'path':p.relative_to(ROOT).as_posix(),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def load(path):return json.loads((ROOT/path).read_bytes())
parents={
 'proxyRemote':'.build/original-proxy-remote-union-step/final-v1.json',
 'certificateReuse':'.build/s2-certificate-reuse-step/final-v1.json',
 'preUpdateBackend':'.build/original-preupdate-refresh-step/backend-final-v1.json',
 'preUpdateApp':'.build/original-preupdate-app-step/app-native-tests-final-v1.json',
 'readerComposition':'.build/original-preupdate-native-result-union/composition-v1.json'}
documents={k:load(p)for k,p in parents.items()}
ownerpaths=sorted({row['path']for key in ['proxyRemote','certificateReuse','preUpdateBackend','preUpdateApp']for row in documents[key]['files']}|{row['path']for row in documents['preUpdateApp']['productionFiles']})
assert len(ownerpaths)==35
newcases={
 'SelfRenewalDeveloperAccountClientTests':documents['certificateReuse']['authoredRegressions']['newNoArgumentDefinitions'],
 'LegadoPreviewStateOwnerTests':documents['preUpdateApp']['AppRegressions']['newNoArgumentDefinitions']}
assert [len(v)for v in newcases.values()]==[4,4]
newproduct='LegadoNativeOriginalReaderTests/'+documents['preUpdateApp']['NativeRegression']['newMethod']
newplatform='LegadoNativeOriginalReaderTests/testNativeOriginalWebJSNativeResultBridgeCharacterizesAndroidConversionInformation'
assert documents['readerComposition']['newSelectors']==[newproduct,newplatform]
for rel in CONTROLS:
 for branch in ['rawbaseline','work']:
  dest=ST/branch/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/rel,dest)
def mutate(rel,fn):
 p=ST/'work'/rel;s=p.read_text(encoding='utf-8');s=fn(s);p.write_bytes(s.encode())
def exact_replace(s,old,new):
 assert s.count(old)==1,(old,s.count(old));return s.replace(old,new)

def core(s):
 # Retain the old source checkpoints/assertions in place, then append this
 # fixed currentcore-only set; historical selection groups remain untouched.
 anchor='PARAMETER_MODES = ("transactionrenewal", "handoffrenewal", "currentcore")'
 block='CURRENTCORE_CERTIFICATE_PREUPDATE_CASES = '+repr({k:tuple(v)for k,v in newcases.items()})+'\n'
 block+='CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES = {suite + "/" + method\n    for suite, methods in CURRENTCORE_CERTIFICATE_PREUPDATE_CASES.items() for method in methods}\n'
 block+='assert len(CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES) == 8\n'
 block+='assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES)\n'
 block+='EXPECTED_CASES["currentcore"] |= CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES\n'
 block+='assert len(EXPECTED_CASES["currentcore"]) == 471\n\n'
 s=exact_replace(s,anchor,block+anchor)
 anchor='\n\ndef selection_mode():'
 block='\n\nCURRENTCORE_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS = '+repr(tuple(ownerpaths))+'\n'
 block+='SOURCE_INPUTS += tuple(path for path in CURRENTCORE_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS if path not in SOURCE_INPUTS)\n'
 block+='assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 364\n'
 s=exact_replace(s,anchor,block+anchor)
 # Only live pipeline facts and comparison constants change, never old scopes.
 s=s.replace('prepared.get("intendedQualifiedMethodDefinitions") != 463','prepared.get("intendedQualifiedMethodDefinitions") != 471')
 s=s.replace('prepared.get("intendedArgumentLeafCount") != 466','prepared.get("intendedArgumentLeafCount") != 474')
 s=s.replace('"qualifiedMethodDefinitions": 463, "argumentLeaves": 466','"qualifiedMethodDefinitions": 471, "argumentLeaves": 474')
 s=s.replace('ledger.get("qualifiedMethodDefinitions") != 463','ledger.get("qualifiedMethodDefinitions") != 471')
 s=s.replace('ledger.get("argumentLeaves") != 466','ledger.get("argumentLeaves") != 474')
 return s
mutate(CONTROLS[0],core)
def native(s):
 anchor="            'LegadoNativeOriginalReaderTests/testNativeOriginalGeneralWebJSUsesPreviewBatchAndBookCallbackOwners')}"
 s=exact_replace(s,anchor,anchor[:-2]+",\n            "+repr(newproduct)+")}")
 # Only this exact new product method extends the fixed original product tuple.
 s=s.replace('These two platform characterizations','These three platform characterizations')
 s=s.replace('Keep the established 28 product methods in their original order and host.','Keep the established 28 product methods in their original order and host;\n# append the actual preUpdate public-product method before platform cases.')
 anchor="    'LegadoNativeWebRequestCharacterizationTests/testPublicWebRequestCharacterizesOwnedFramesResourcesAndObserverCancellation',\n)"
 s=exact_replace(s,anchor,anchor[:-2]+'\n    '+repr(newplatform)+',\n)')
 anchor='\n\ndef source_inputs():'
 block='\n\nORIGINAL_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS = '+repr(tuple(ownerpaths))+'\n'
 block+='SOURCE_INPUTS += tuple(path for path in ORIGINAL_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS if path not in SOURCE_INPUTS)\n'
 block+='assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 180\n'
 return exact_replace(s,anchor,block+anchor)
mutate(CONTROLS[2],native)

def coreguards(s):
 assert s.count('Execute463 current-core definitions with466 exact native argument leaves')==3
 s=s.replace('Execute463 current-core definitions with466 exact native argument leaves','Execute471 current-core definitions with474 exact native argument leaves')
 for old,new in [(349,364),(463,471),(466,474)]:s=re.sub(r'\b'+str(old)+r'\b',str(new),s)
 s=exact_replace(s,"|probe.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES)\n", "|probe.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES|probe.CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES)\n")
 # Preserve exact source-inventory matching while accounting for the eight
 # known declarations only; no blanket subset or whole-suite selection.
 s=exact_replace(s,"set(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_CASES.get(suite, ())),actual,suite)","set(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_CASES.get(suite, ())) | set(probe.CURRENTCORE_CERTIFICATE_PREUPDATE_CASES.get(suite, ())),actual,suite)")
 s=exact_replace(s,"set(probe.CURRENTCORE_MATERIAL_REFRESH_CASES.get(suite, ())), suite)","set(probe.CURRENTCORE_MATERIAL_REFRESH_CASES.get(suite, ())) | set(probe.CURRENTCORE_CERTIFICATE_PREUPDATE_CASES.get(suite, ())), suite)")
 # An existing negative-vector test now checks each actually added case.
 s=exact_replace(s,"for case in sorted(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES):\n            for fault in ('missing', 'duplicate', 'skip', 'wrongSuite'):","for case in sorted(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES | probe.CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES):\n            for fault in ('missing', 'duplicate', 'skip', 'wrongSuite'):")
 anchor='''        self.assertEqual(len(probe.CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS), 3)
'''
 insert='''        self.assertEqual(len(probe.CURRENTCORE_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS), 35)
        self.assertTrue(set(probe.CURRENTCORE_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS) <= set(probe.SOURCE_INPUTS))
        self.assertEqual(len(probe.CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES), 8)
        for suite, methods in probe.CURRENTCORE_CERTIFICATE_PREUPDATE_CASES.items():
            source = (HERE.parents[1] / ("Tests/iOS/yuedu appTests/" + suite + ".swift")).read_text(encoding="utf8")
            for method in methods:
                self.assertRegex(source, r"@Test[^\\n]*\\n\\s*func " + re.escape(method) + r"\\(\\) async throws")
                self.assertIn(suite + "/" + method, probe.EXPECTED_CASES["currentcore"])
                for group, selected in probe.EXPECTED_CASES.items():
                    if group != "currentcore": self.assertNotIn(suite + "/" + method, selected)
'''
 s=exact_replace(s,anchor,insert+anchor)
 anchor='''*probe.CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS)):'''
 s=exact_replace(s,anchor,anchor[:-3]+', *probe.CURRENTCORE_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS)):')
 return s
mutate(CONTROLS[1],coreguards)
def nativeguards(s):
 s=s.replace('result["originalReaderTests"]["expectedTests"], 30','result["originalReaderTests"]["expectedTests"], 32')
 s=s.replace('len(native.SOURCE_INPUTS), 161','len(native.SOURCE_INPUTS), 180')
 s=s.replace('Execute1 MainJS and30 original methods','Execute1 MainJS and32 original methods')
 s=s.replace('len(native.NATIVE_GROUPS["original"]["methods"]), 30','len(native.NATIVE_GROUPS["original"]["methods"]), 32')
 anchor="            'LegadoNativeWebRequestCharacterizationTests/testPublicWebRequestCharacterizesOwnedFramesResourcesAndObserverCancellation',\n))"
 s=exact_replace(s,anchor,anchor[:-3]+'\n            '+repr(newplatform)+',\n))')
 s=exact_replace(s,'native.NATIVE_GROUPS["original"]["methods"][-2:]','native.NATIVE_GROUPS["original"]["methods"][-3:]')
 anchor='''        self.assertEqual(len(native.ORIGINAL_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS), 3)
'''
 insert='''        self.assertEqual(len(native.ORIGINAL_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS), 35)
        self.assertTrue(set(native.ORIGINAL_PROXY_REMOTE_CERTIFICATE_PREUPDATE_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertIn('''+repr(newproduct)+''', native.NATIVE_GROUPS["original"]["methods"])
'''
 s=exact_replace(s,anchor,insert+anchor)
 return s
mutate(CONTROLS[3],nativeguards)
mutate(CONTROLS[4],lambda s:s.replace('Execute463 current-core definitions with466','Execute471 current-core definitions with474').replace('requires463 unique qualified native definitions and466','requires471 unique qualified native definitions and474').replace('outside native466','outside native474').replace('All prior mode sets, parameter identities and budgets remain unchanged;', 'Four certificate reuse/profile lifecycle definitions and four preUpdate same-owner identity definitions extend currentcore only. The separate original host adds one preUpdate public-product method and one Android native-result platform characterization; its32 selections comprise29 product and3 platform methods. The independent cold-process pair remains separate, and the unactivated resource sniffer remains excluded. All prior mode sets, parameter identities and budgets remain unchanged;'))
mutate(CONTROLS[5],lambda s:s.replace('Execute1 MainJS and30 original methods','Execute1 MainJS and32 original methods'))
mutate(CONTROLS[6],lambda s:s.replace('463 definitions,466 argument leaves','471 definitions,474 argument leaves'))

# Build an ignored source snapshot for exact path/selector inspection only.
# No test, compiler, subprocess runner, or generated SDK fixture is invoked.
def module(name,path):
 spec=importlib.util.spec_from_file_location(name,path);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod
basecore=module('basecore',ROOT/CONTROLS[0]);basenative=module('basenative',ROOT/CONTROLS[2])
VR=ST/'validation-root'
for rel in sorted(set(basecore.SOURCE_INPUTS)|set(basenative.SOURCE_INPUTS)):
 dest=VR/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/rel,dest)
# Materialize unchanged loader dependencies already referenced by actual tools.
for name in ['verify-native-reuse.py','verify-runtime-reuse.py']:
 p=ROOT/'scripts/legado-ios'/name
 if p.exists():
  dest=VR/p.relative_to(ROOT);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
bindings={}
def apply(rel,p):
 dest=VR/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest);bindings[rel]=fact(p)
for key in ['proxyRemote','certificateReuse','preUpdateBackend']:
 for row in documents[key]['files']:
  p=ROOT/row['candidate']['path'];assert fact(p)['sha256']==row['candidate']['sha256'];apply(row['path'],p)
app=documents['preUpdateApp']
for row in app['productionFiles']:
 p=ROOT/app['productionSourceRoot']/row['path'];assert fact(p)['sha256']==row['sha256'];apply(row['path'],p)
for row in app['files']:
 p=ROOT/row['candidate']['path'];assert fact(p)['sha256']==row['candidate']['sha256'];apply(row['path'],p)
reader=documents['readerComposition']['candidate'];p=ROOT/reader['path'];assert fact(p)['sha256']==reader['sha256'];apply('Tests/iOS/LegadoNativeOriginalReaderTests.swift',p)
for rel in CONTROLS:apply(rel,ST/'work'/rel)
newcore=module('nextcore',VR/CONTROLS[0]);newnative=module('nextnative',VR/CONTROLS[2])
assert len(newcore.SOURCE_INPUTS)==364 and len(newnative.SOURCE_INPUTS)==180
assert len(set(newcore.SOURCE_INPUTS)|set(newnative.SOURCE_INPUTS))==380
assert len(newcore.EXPECTED_CASES['currentcore'])==471 and newcore.expected_leaf_count('currentcore')==474
assert newcore.PARAMETER_CASES==basecore.PARAMETER_CASES and newcore.CURRENTCORE_GLYPH_PARAMETER_CASES==basecore.CURRENTCORE_GLYPH_PARAMETER_CASES
for group in basecore.EXPECTED_CASES:
 if group!='currentcore':assert newcore.EXPECTED_CASES[group]==basecore.EXPECTED_CASES[group]
assert [m for m in newnative.NATIVE_GROUPS['original']['methods']if m in basenative.NATIVE_GROUPS['original']['methods']]==list(basenative.NATIVE_GROUPS['original']['methods'])
assert len(newnative.NATIVE_GROUPS['original']['methods'])==32 and len(newnative.NATIVE_PLATFORM_CHARACTERIZATION_METHODS)==3
controlrows=[]
for rel in CONTROLS:
 before=ST/'rawbaseline'/rel;after=ST/'work'/rel;dest=ST/'diffs'/(rel+'.diff');dest.parent.mkdir(parents=True,exist_ok=True)
 dest.write_bytes(''.join(difflib.unified_diff(before.read_text(encoding='utf-8').splitlines(True),after.read_text(encoding='utf-8').splitlines(True),fromfile='a/'+rel,tofile='b/'+rel)).encode())
 controlrows.append({'path':rel,'baseline':fact(before),'candidate':fact(after),'diff':fact(dest)})
rosters={k:[{'path':rel,**{x:fact(VR/rel)[x]for x in ['bytes','sha256']}}for rel in paths]for k,paths in [('core',newcore.SOURCE_INPUTS),('native',newnative.SOURCE_INPUTS),('union',sorted(set(newcore.SOURCE_INPUTS)|set(newnative.SOURCE_INPUTS)))]}
(ST/'source-rosters-draft-v1.json').write_bytes((json.dumps(rosters,indent=2)+'\n').encode())
draft={'schemaVersion':1,'status':'mutable-controls-draft-awaiting-final-canonical-production-binding-and-affected-portable-checks',
 'baselineCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
 'parents':{k:fact(ROOT/p)for k,p in parents.items()},'controls':controlrows,'productionOwnerPaths':ownerpaths,'sourceOverlayBindings':bindings,
 'counts':{'core':364,'native':180,'union':380,'currentcoreDefinitions':471,'currentcoreLeaves':474,'boolPairs':3,'originalMethods':32,'originalProduct':29,'platformCharacterization':3,'MainJS':1,'coldIndependent':2,'PackageDefinitions':24,'PackageInputs':23},
 'rosters':fact(ST/'source-rosters-draft-v1.json'),'selectorsAdded':{'App':newcases,'NativeProduct':newproduct,'NativePlatform':newplatform},
 'preserved':'All old source paths,13 other selection groups,three Bool parameter identities,SDK mandatory signer/producer,3600/3720 App budgets,1800 original/2700 MainJS,independent cold2,phase/error/exit/source gates and Package24/23 remain. Resource Swift v3 and its method excluded.',
 'execution':{'testExecutions':0,'compilerExecutions':0,'SwiftParserExecutions':0,'cloudQueries':0,'GitWrites':0,'canonicalWrites':0},
 'preparationHistory':['Two exact-text authoring checks stopped before source snapshot/inspection: native tuple indentation and the long source-tampering-loop suffix. The platform-tuple closing indentation was also corrected before reaching that step. The generator anchors were corrected; no candidate test/compiler/cloud execution occurred.'],
 'pending':['Bind final canonical preUpdate production/Reader union bytes after Root integration','Run only affected portable source/selector/summary guards once after final source state','Independent control-delta review before Root integration or tag']}
p=ST/'draft-v1.json';p.write_bytes((json.dumps(draft,ensure_ascii=False,indent=2)+'\n').encode());print(json.dumps(fact(p)))
