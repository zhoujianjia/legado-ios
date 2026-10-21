from pathlib import Path
import hashlib,json,re,shutil
R=Path('F:/yuedu-reader'); S=R/'.build/s2-first-registration-step'; W=S/'work'
p=W/'Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountClient.swift';s=p.read_text()
s=s.replace('dispatched','intents')
block='''        var requiredGroups: [String] = []
        for bundle in bundles {
            for name in bundle.appGroups {
                guard Self.headerValue(name, limit: 255), name.hasPrefix("group."),
                      !name.contains("$") else { throw Failure.invalidInput }
                if !requiredGroups.contains(where: { Self.same($0, name) }) { requiredGroups.append(name) }
            }
        }
        guard requiredGroups.count <= 8 else { throw Failure.limit }
'''
assert block in s;s=s.replace(block,'',1)
block=block.replace('!name.contains("$")','name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 })')
start=s.index('    private func prepareRegistration(');pos=s.index('        try await verify()',start)
s=s[:pos]+block+s[pos:]
needle='''        for (index, bundle) in bundles.enumerated() where apps[bundle.identifier] == nil {'''
s=s.replace(needle,'''        guard Set(apps.values.map(\\.portalID)).count == apps.count else { throw Failure.ambiguousAppIdentifier }
'''+needle,1)
s=s.replace('''            apps[bundle.identifier] = app; progress.accepted.append("app.add"); try await verify()''','''            guard !apps.values.contains(where: { Self.same($0.portalID, app.portalID) }) else { throw Failure.ambiguousAppIdentifier }
            apps[bundle.identifier] = app; progress.accepted.append("app.add"); try await verify()''',1)
s=s.replace('''            for (index, name) in requiredGroups.enumerated() where groups[name] == nil {''','''            guard Set(groups.values).count == groups.count else { throw Failure.malformedResponse }
            for (index, name) in requiredGroups.enumerated() where groups[name] == nil {''',1)
s=s.replace('''                groups[name] = try Self.identifier(group["applicationGroup"])
                progress.accepted.append("group.add"); try await verify()''','''                let portalID = try Self.identifier(group["applicationGroup"])
                guard !groups.values.contains(where: { Self.same($0, portalID) }) else { throw Failure.malformedResponse }
                groups[name] = portalID
                progress.accepted.append("group.add"); try await verify()''',1)
p.write_text(s,encoding='utf-8',newline='\n')
# Exact already-pinned upstream Lockdown request and String-value contracts.
prev=R/'.build/self-renewal-route-recheck-20261021/primary'
for src,name in [(prev/'libimobiledevice/libimobiledevice/src/lockdown.c','libimobiledevice-lockdown.c'),(prev/'SideStore/idevice/idevice/src/services/lockdown.rs','idevice-lockdown.rs')]:
 shutil.copyfile(src,S/'primary'/name)
def fact(p):
 b=p.read_bytes();return {'path':p.relative_to(R).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
base=json.loads((S/'baseline-v1.json').read_text());files=[]
for row in base['files']:
 p=W/row['path']; assert p.read_bytes()!= (S/'rawbaseline'/row['path']).read_bytes()
 assert (R/row['path']).read_bytes()==(S/'rawbaseline'/row['path']).read_bytes()
 files.append({'path':row['path'],'baseline':row['baseline'],'candidate':fact(p)})
def method(source,name):
 at=source.index('    static func '+name+'(');end=source.index('\n    }',at)+6;return source[at:end]
installer='Modules/Services/SelfRenewal/SelfRenewalAuthenticatedInstallationClient.swift'
old=(S/'rawbaseline'/installer).read_text();new=(W/installer).read_text()
for name in ['openSession','startService','stopSession']:
 assert method(old,name)==method(new,name),name
assert 'GetValue' in new and 'UniqueDeviceID' in new
assert 'RegistrationDeviceObservation(identifier:' in new
assert 'fileprivate init(identifier:' in new
assert 'private let lifetime:' in new
assert 'case devices = "ios/listDevices.action"' in s
assert s.index('guard loaded.record.pending == nil')<s.index('let identifiers = try await prepareRegistration')
assert 'request.timeoutInterval = min(30, try pairedDevice.remainingSeconds())' in s
assert 'return apps.mapValues(\\.portalID)' in s
assert 'try?' not in s
assert not any(x in s for x in ['deleteAppID.action','revokeCertificate.action','identifierForVendor'])
tests={}
for row in files:
 if not row['path'].startswith('Tests/'):continue
 a=(S/'rawbaseline'/row['path']).read_text();b=(W/row['path']).read_text()
 oldnames=re.findall(r'\bfunc\s+(\w+)\(',a);newnames=re.findall(r'\bfunc\s+(\w+)\(',b)
 tests[row['path']]={'oldTestDefinitions':len(re.findall(r'@Test\b',a)),'newTestDefinitions':len(re.findall(r'@Test\b',b)),
  'removedFunctionNames':sorted(set(oldnames)-set(newnames)),'addedFunctionNames':sorted(set(newnames)-set(oldnames))}
 assert not set(oldnames)-set(newnames)
html=(S/'primary/apple-supported-capabilities-ios.html').read_text();i=html.index('<p>App groups</p>');lo=html.rfind('<tr>',0,i);hi=html.index('</tr>',i)+5;row=html[lo:hi]
assert row.count('icon-checksolid')==3 and row.count('alt="yes"')==3
(S/'source-check-v1.json').write_text(json.dumps({'kind':'read-only source and provenance checks; not Swift parsing/typechecking or test execution','files':files,'testDefinitions':tests,'unchangedTLSFunctions':['openSession','startService','stopSession'],'appleCapabilityRaw':fact(S/'primary/apple-supported-capabilities-ios.html'),'appleAppGroupsThreeChecks':True,'SDKExecutions':0,'controlledTLSExecutions':0,'AppleRequests':0},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'changedFiles':len(files),'sourceCheck':'passed','newTestDefinitions':sum(x['newTestDefinitions']-x['oldTestDefinitions'] for x in tests.values())}))
