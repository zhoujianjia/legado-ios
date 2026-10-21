from pathlib import Path
import ast
import datetime
import difflib
import hashlib
import json
import re

R=Path('F:/yuedu-reader')
S=R/'.build/consolidated-sdk-native-characterization-jvm-fixtures-checkpoint'
PATHS=[
 'scripts/reader-experience/renewal-probe-tools.py',
 'scripts/reader-experience/native-smoke-tools.py',
 '.github/workflows/legado-native-reader-test.yml',
 'scripts/reader-experience/test-renewal-probe-tools.py',
 'scripts/reader-experience/test-native-smoke-tools.py',
]
ADDED=(
 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalAnalyzeRuleTest.kt',
 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalUrlExecutionTest.kt',
 'Tests/iOS/LegadoNativeWebRequestCharacterizationTests.swift',
)
CHARACTERIZATIONS=(
 'LegadoNativeOriginalReaderTests/testNativeOriginalOrderedWebJSCharacterizesCSPAndOriginalJSONInSamePageWorld',
 'LegadoNativeWebRequestCharacterizationTests/testPublicWebRequestCharacterizesOwnedFramesResourcesAndObserverCancellation',
)
def fact(p):
 b=p.read_bytes();return dict(path=p.relative_to(R).as_posix(),bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,text):
 p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text,encoding='utf-8',newline='\n')
def module_inputs(text):
 """Evaluate source-list constant declarations only, no module imports/tests."""
 namespace={};needed={'SOURCE_INPUTS'};selected=[]
 for node in reversed(ast.parse(text).body):
  target=node.targets[0] if isinstance(node,ast.Assign) and len(node.targets)==1 else node.target if isinstance(node,ast.AugAssign) else None
  if isinstance(target,ast.Name) and target.id in needed:
   selected.append(node)
   needed.update(n.id for n in ast.walk(node.value) if isinstance(n,ast.Name) and isinstance(n.ctx,ast.Load))
 for node in reversed(selected):
  exec(compile(ast.Module(body=[node],type_ignores=[]),'<source-roster-constant>','exec'),namespace)
 return namespace['SOURCE_INPUTS']
def groups(text):
 namespace={}
 for node in ast.parse(text).body:
  if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name) and node.targets[0].id in ['NATIVE_GROUPS','NATIVE_PLATFORM_CHARACTERIZATION_METHODS']:
   exec(compile(ast.Module(body=[node],type_ignores=[]),'<group-constant>','exec'),namespace)
  elif isinstance(node,ast.AugAssign) and isinstance(node.target,ast.Subscript) and ast.unparse(node.target)=='NATIVE_GROUPS[\'original\'][\'methods\']':
   exec(compile(ast.Module(body=[node],type_ignores=[]),'<group-constant>','exec'),namespace)
 return namespace['NATIVE_GROUPS']
def functions(text):
 return [(n.name,ast.dump(n,include_attributes=False)) for n in ast.parse(text).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))]

old={p:(R/p).read_text(encoding='utf-8') for p in PATHS}
base_core=module_inputs(old[PATHS[0]]);base_native=module_inputs(old[PATHS[1]])
assert (len(base_core),len(base_native),len(set(base_core)|set(base_native)))==(346,158,362)
assert all(p not in base_core and p not in base_native for p in ADDED)
assert len(groups(old[PATHS[1]])['original']['methods'])==28
new=dict(old)
core_block='\nCURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS = (\n'+''.join('    '+repr(p)+',\n' for p in ADDED)+')\nSOURCE_INPUTS += tuple(path for path in CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS if path not in SOURCE_INPUTS)\nassert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 349\n'
anchor='assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 346\n'
assert new[PATHS[0]].count(anchor)==1
new[PATHS[0]]=new[PATHS[0]].replace(anchor,anchor+core_block)
native_block='\nORIGINAL_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS = (\n'+''.join('    '+repr(p)+',\n' for p in ADDED)+')\nSOURCE_INPUTS += tuple(path for path in ORIGINAL_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS if path not in SOURCE_INPUTS)\nassert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 161\n'
anchor='assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 158\n'
assert new[PATHS[1]].count(anchor)==1
new[PATHS[1]]=new[PATHS[1]].replace(anchor,anchor+native_block)
selector_block='''# These two platform characterizations are not production original-rule cases.
# Keep the established 28 product methods in their original order and host.
NATIVE_PLATFORM_CHARACTERIZATION_METHODS = (
'''+''.join('    '+repr(p)+',\n' for p in CHARACTERIZATIONS)+''')
NATIVE_GROUPS["original"]["methods"] += NATIVE_PLATFORM_CHARACTERIZATION_METHODS

'''
assert new[PATHS[1]].count('SOURCE_INPUTS = (\n')==1
new[PATHS[1]]=new[PATHS[1]].replace('SOURCE_INPUTS = (\n',selector_block+'SOURCE_INPUTS = (\n',1)
new[PATHS[2]]=new[PATHS[2]].replace('Execute1 MainJS and28 original methods in separate required hosts','Execute1 MainJS and30 original methods in separate required hosts')
new[PATHS[3]]=re.sub(r'\b346\b','349',new[PATHS[3]])
core_test_anchor='        self.assertTrue(set(probe.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS) <= set(probe.SOURCE_INPUTS))\n'
core_test_addition='''        self.assertEqual(len(probe.CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS), 3)
        self.assertTrue(set(probe.CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS) <= set(probe.SOURCE_INPUTS))
        for relative in probe.CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS:
            self.assertTrue((HERE.parents[1] / relative).is_file())
'''
assert new[PATHS[3]].count(core_test_anchor)==1
new[PATHS[3]]=new[PATHS[3]].replace(core_test_anchor,core_test_anchor+core_test_addition)
mutation_anchor='*probe.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS)):'
assert new[PATHS[3]].count(mutation_anchor)==1
new[PATHS[3]]=new[PATHS[3]].replace(mutation_anchor,'*probe.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS, *probe.CURRENTCORE_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS)):')
new[PATHS[4]]=re.sub(r'\b158\b','161',new[PATHS[4]])
new[PATHS[4]]=new[PATHS[4]].replace('Execute1 MainJS and28 original methods in separate required hosts','Execute1 MainJS and30 original methods in separate required hosts')
new[PATHS[4]]=new[PATHS[4]].replace('["expectedTests"], 28)','["expectedTests"], 30)').replace('len(native.NATIVE_GROUPS["original"]["methods"]), 28)','len(native.NATIVE_GROUPS["original"]["methods"]), 30)')
anchor='        self.assertTrue(set(native.ORIGINAL_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS) <= set(native.SOURCE_INPUTS))\n'
addition='''        self.assertEqual(len(native.ORIGINAL_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS), 3)
        self.assertTrue(set(native.ORIGINAL_NATIVE_CHARACTERIZATION_JVM_FIXTURE_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(native.NATIVE_PLATFORM_CHARACTERIZATION_METHODS, (
'''+''.join('            '+repr(p)+',\n' for p in CHARACTERIZATIONS)+'''))
        self.assertEqual(native.NATIVE_GROUPS["original"]["methods"][-2:], native.NATIVE_PLATFORM_CHARACTERIZATION_METHODS)
'''
assert new[PATHS[4]].count(anchor)==1
new[PATHS[4]]=new[PATHS[4]].replace(anchor,anchor+addition)
anchor='''                else:
                    self.assertRegex(source, r"#if LEGADO_REQUIRE_NATIVE_MAINJS\\s+required = true")
'''
replacement='''                elif suite == "LegadoNativeWebRequestCharacterizationTests":
                    # This is a public-WK platform observation, not a JVM case.
                    # Actual unsupported/skip still fails the unchanged group gate.
                    self.assertIn("guard #available(iOS 18.4, *)", source)
                    self.assertIn("WKWebExtensionController", source)
                    self.assertIn("try await current.sealAndStop()", source)
                    self.assertNotIn("requireNativeRuntime()", source)
                else:
                    self.assertRegex(source, r"#if LEGADO_REQUIRE_NATIVE_MAINJS\\s+required = true")
'''
assert new[PATHS[4]].count(anchor)==1
new[PATHS[4]]=new[PATHS[4]].replace(anchor,replacement)

candidate_core=module_inputs(new[PATHS[0]]);candidate_native=module_inputs(new[PATHS[1]])
union=sorted(set(candidate_core)|set(candidate_native))
assert (len(candidate_core),len(candidate_native),len(union))==(349,161,365)
assert candidate_core[:346]==base_core and candidate_native[:158]==base_native
assert candidate_core[346:]==ADDED and candidate_native[158:]==ADDED
old_groups=groups(old[PATHS[1]]);new_groups=groups(new[PATHS[1]])
assert new_groups['original']['methods'][:28]==old_groups['original']['methods']
assert new_groups['original']['methods'][28:]==CHARACTERIZATIONS
assert new_groups['mainjs']==old_groups['mainjs']
assert new_groups['original']['seconds']==old_groups['original']['seconds']==1800
assert functions(new[PATHS[0]])==functions(old[PATHS[0]])
assert functions(new[PATHS[1]])==functions(old[PATHS[1]])
files=[]
for p in PATHS:
 bp=S/'rawbaseline'/p;wp=S/'work'/p;dp=S/'diffs'/(p+'.diff')
 if bp.exists():assert bp.read_bytes()==(R/p).read_bytes()
 else:bp.parent.mkdir(parents=True,exist_ok=True);bp.write_bytes((R/p).read_bytes())
 write(wp,new[p]);write(dp,''.join(difflib.unified_diff(old[p].splitlines(True),new[p].splitlines(True),fromfile='a/'+p,tofile='b/'+p)))
 files.append(dict(path=p,baseline=fact(bp),candidate=fact(wp),diff=fact(dp)))
draft=dict(schemaVersion=1,status='DRAFT ONLY. No guard tests executed, no final freeze or canonical writes. Await Root source integration and SDK outcome before one affected guard cohort.',preparedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),baselineSourceCommit='5b0422e',files=files,
 counts=dict(core=349,native=161,uniqueUnion=365,AppDefinitions=463,AppExecutions=466,BoolPairs=3,oldProductNativeMethods=28,platformCharacterizationMethods=2,totalOriginalGroupMethods=30,MainJS=1,separateColdHosts=2,PackageMethods=24,PackageInputs=23),
 sourceAdditions=list(ADDED),groupMethods=list(new_groups['original']['methods']),characterizations=list(CHARACTERIZATIONS),
 sourceROSTERS=dict(core=list(candidate_core),native=list(candidate_native),union=union),
 invariants=dict(oldSourceRosterPrefixesExact=True,old28SelectorsOrderedExact=True,productionToolsFunctionsASTExact=True,mainjsGroupExact=True,originalSeconds=1800,mainjsSeconds=2700,coreWrapperSeconds=3600,coreParentSeconds=3720,allOldSourceExitPhaseGatesUnchanged=True,old14ModesBool3App463_466Package24_23Unchanged=True,SDKExecutionStarted=False),
 pending=['Resource source-only approval must be accepted and copied by Root; Ordered source must be integrated by Root. Future final stamp must bind actual canonical bytes.','Wait Root current SDK result and instruction for the single four-guard execution. No current workflow/tag/cohort is modified.'],
 actualGuardsExecuted=0,finalFrozen=False,canonicalMutations=False,cloudQueries=0,tagsCreated=0)
write(S/'draft-v1.json',json.dumps(draft,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(dict(draft=fact(S/'draft-v1.json'),counts=draft['counts'],actualGuardsExecuted=0),ensure_ascii=False))
