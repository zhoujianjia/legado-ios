from pathlib import Path
import types,sys,hashlib,json,ast,collections
sys.dont_write_bytecode=True
s=Path(__file__).resolve().parents[1];w=s/'work';b=s/'rawbaseline'
def fact(p):
 raw=p.read_bytes();return {'path':p.as_posix(),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def mod(name,old=False):
 p=w/'scripts/reader-experience'/name;raw=(b/'scripts/reader-experience'/name).read_bytes() if old else p.read_bytes()
 m=types.ModuleType(('old_' if old else 'new_')+name.replace('-','_'));m.__file__=str(p.resolve());exec(compile(raw,str(p),'exec'),m.__dict__);return m
oc,nc=mod('renewal-probe-tools.py',True),mod('renewal-probe-tools.py')
on,nn=mod('native-smoke-tools.py',True),mod('native-smoke-tools.py')
op,np=mod('original-api-package-tools.py',True),mod('original-api-package-tools.py')
modes={}
for mode,cases in oc.EXPECTED_CASES.items():
 if mode!='currentcore':assert cases==nc.EXPECTED_CASES[mode]
 modes[mode]={'baselineCount':len(cases),'candidateCount':len(nc.EXPECTED_CASES[mode]),'baselineSetSHA256':hashlib.sha256(json.dumps(sorted(cases)).encode()).hexdigest(),'candidateSetSHA256':hashlib.sha256(json.dumps(sorted(nc.EXPECTED_CASES[mode])).encode()).hexdigest(),'unchanged':mode!='currentcore'}
added=nc.EXPECTED_CASES['currentcore']-oc.EXPECTED_CASES['currentcore']
assert oc.EXPECTED_CASES['currentcore']<=nc.EXPECTED_CASES['currentcore'] and added==nc.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES and len(added)==4
assert nc.PARAMETER_CASES==oc.PARAMETER_CASES and nc.CURRENTCORE_GLYPH_PARAMETER_CASES==oc.CURRENTCORE_GLYPH_PARAMETER_CASES
assert nc.SDK_REQUIRED_CASE==oc.SDK_REQUIRED_CASE and nc.CURRENTCORE_PHASES==oc.CURRENTCORE_PHASES
assert nn.NATIVE_GROUPS['mainjs']==on.NATIVE_GROUPS['mainjs']
oldmethods=on.NATIVE_GROUPS['original']['methods'];newmethods=nn.NATIVE_GROUPS['original']['methods']
assert newmethods[:len(oldmethods)]==oldmethods and len(newmethods)==len(set(newmethods))==19
assert {k:v for k,v in on.NATIVE_GROUPS['original'].items() if k!='methods'}=={k:v for k,v in nn.NATIVE_GROUPS['original'].items() if k!='methods'}
for attr in ['EXPECTED','CURRENTCORE_EXPECTED','PUBLICBATCH_EXPECTED','EFFECTS_EXPECTED','PACKAGE_INPUTS','CONTROL_INPUTS','SOURCE_INPUTS']:assert getattr(op,attr)==getattr(np,attr),attr
assert len(np.LOGINUI_EXPECTED)==22 and np.LOGINUI_EXPECTED-np.EFFECTS_EXPECTED==np.LOGINUI_EXTRA
def funcs(raw):return {n.name:n for n in ast.parse(raw).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
class Counts(ast.NodeTransformer):
 def visit_Constant(self,node):
  if type(node.value) is int and node.value in (459,463):node.value='current-core-definitions'
  if type(node.value) is int and node.value in (462,466):node.value='current-core-leaves'
  return node
fe={}
for name in ['renewal-probe-tools.py','native-smoke-tools.py','original-api-package-tools.py']:
 old=funcs((b/'scripts/reader-experience'/name).read_text(encoding='utf-8'));new=funcs((w/'scripts/reader-experience'/name).read_text(encoding='utf-8'))
 changed=[n for n in old if ast.dump(old[n],include_attributes=False)!=ast.dump(new[n],include_attributes=False)]
 fe[name]={'changedFunctions':changed,'newFunctions':sorted(set(new)-set(old))}
 if name=='native-smoke-tools.py':assert not changed and set(old)==set(new)
 if name=='renewal-probe-tools.py':
  assert set(changed)=={'result','_currentcore_source_state','run_currentcore','verify_currentcore_pipeline'}
  for n in changed:
   if n!='result':assert ast.dump(Counts().visit(old[n]),include_attributes=False)==ast.dump(Counts().visit(new[n]),include_attributes=False),n
  before=[n.value for n in ast.walk(old['result']) if isinstance(n,ast.Constant) and isinstance(n.value,str)];after=[n.value for n in ast.walk(new['result']) if isinstance(n,ast.Constant) and isinstance(n.value,str)]
  removed=list((collections.Counter(before)-collections.Counter(after)).elements());inserted=list((collections.Counter(after)-collections.Counter(before)).elements())
  fe[name]['resultScopeProseChanges']={'removed':removed,'added':inserted}
  class Prose(ast.NodeTransformer):
   def visit_Constant(self,node):
    if isinstance(node.value,str) and node.value in removed+inserted:node.value='reviewed-current-scope-prose'
    return node
  assert ast.dump(Prose().visit(old['result']),include_attributes=False)==ast.dump(Prose().visit(new['result']),include_attributes=False)
 if name=='original-api-package-tools.py':
  assert set(changed)=={'publicbatch_selected','expected_cases','selected_mode','result'}
  for n in ('expected_cases','selected_mode'):
   new[n].body=new[n].body[1:];assert ast.dump(old[n],include_attributes=False)==ast.dump(new[n],include_attributes=False),n
closures={}
for kind,m in [('core',nc),('native',nn),('package',np)]:
 entries=[]
 for f in m.SOURCE_INPUTS:
  p=w/f;assert p.is_file(),(kind,f);entries.append({'path':f,'bytes':len(p.read_bytes()),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
 assert len(entries)==len({r['path'] for r in entries});closures[kind]={'count':len(entries),'sources':entries}
assert [closures[k]['count'] for k in ['core','native','package']]==[322,113,22]
coreAdded=sorted(set(nc.SOURCE_INPUTS)-set(oc.SOURCE_INPUTS));nativeAdded=sorted(set(nn.SOURCE_INPUTS)-set(on.SOURCE_INPUTS))
assert len(coreAdded)==2 and len(nativeAdded)==6
pkgactual={'Packages/LegadoRuntime/Package.swift'}|{p.relative_to(w).as_posix() for d in ['Sources','Tests'] for p in (w/'Packages/LegadoRuntime'/d).rglob('*') if p.is_file()}
assert pkgactual==set(np.PACKAGE_INPUTS)
manifest=json.loads((w/'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_text(encoding='utf-8'))
for row in manifest['portedSources']:
 raw=(w/row['path']).read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],row['path']
assert len(manifest['portedSources'])==55
(s/'preparation/source-closures-final.json').write_text(json.dumps(closures,indent=2)+'\n',encoding='utf-8')
record={'oldCoreModeSets':modes,'currentcoreAddedDefinitions':sorted(added),'parameterCases':nc.parameter_cases('currentcore'),'requiredSameJobFixture':nc.SDK_REQUIRED_CASE,'currentcoreDefinitions':len(nc.EXPECTED_CASES['currentcore']),'currentcoreLeaves':nc.expected_leaf_count('currentcore'),'currentcorePhases':list(nc.CURRENTCORE_PHASES),'nativeGroups':nn.NATIVE_GROUPS,'oldNative17PreservedInOrder':True,'packageModes':{'historical':len(np.EXPECTED),'unflaggedCurrentcore':len(np.CURRENTCORE_EXPECTED),'publicbatch':len(np.PUBLICBATCH_EXPECTED),'effects':len(np.EFFECTS_EXPECTED),'loginui':len(np.LOGINUI_EXPECTED)},'loginuiExtra':sorted(np.LOGINUI_EXTRA),'functions':fe,'sourceClosureCounts':{k:v['count'] for k,v in closures.items()},'newCoreInputs':coreAdded,'newNativeInputs':nativeAdded,'packageCompiledInputs':len(pkgactual),'packageControls':len(np.CONTROL_INPUTS),'portedSourceFactsVerified':len(manifest['portedSources']),'localActualSDKJNIOrSwiftPMExecution':0}
(s/'preparation/selection-and-gate-invariants-final.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
print('Validated oldmodes,3Boolpairs,samejob fixture,phase AST/count-only changes; native function AST unchanged; closure322/113/22; ported55; no Git/SDK calls.')
