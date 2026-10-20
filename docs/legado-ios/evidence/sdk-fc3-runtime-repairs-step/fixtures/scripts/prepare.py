from pathlib import Path
import hashlib, json
R=Path.cwd(); S=Path(__file__).parent
items=[]
def edit(path, changes):
    baseline=(R/path).read_bytes(); text=baseline.decode('utf-8')
    for old,new in changes:
        assert text.count(old)==1,(path,old,text.count(old))
        text=text.replace(old,new)
    data=text.encode('utf-8')
    for branch,body in [('baseline',baseline),('work',data)]:
        p=S/branch/path; p.parent.mkdir(parents=True,exist_ok=True); assert not p.exists(); p.write_bytes(body)
    items.append(dict(path=path,baseline=dict(bytes=len(baseline),sha256=hashlib.sha256(baseline).hexdigest()),candidate=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())))
edit('Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift',[
    ('let root = directory.appendingPathComponent("AppSession")','let root = directory.appendingPathComponent("SelfRenewalApp")')])
edit('Tests/iOS/yuedu appTests/SelfRenewalAnisetteV3ProviderTests.swift',[
    ('let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)\n            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,\n                attributes: [.posixPermissions: 0o700])\n            defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("fixture cleanup failed") } }',
     'let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)\n            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,\n                attributes: [.posixPermissions: 0o700])\n            defer { do { try FileManager.default.removeItem(at: parent) } catch { Issue.record("fixture cleanup failed") } }\n            let root = parent.appendingPathComponent("SelfRenewalApp", isDirectory: true)')])
edit('Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift',[
    ('#expect(failure.underlying is EnrollmentFixtureStop)\n                        #expect(!failure.upgradeMayHaveExecuted)',
     'try #require(failure.underlying is EnrollmentFixtureStop)\n                        try #require(!failure.upgradeMayHaveExecuted)'),
    ('#expect(loaded.record.phase == .uploadIntent && loaded.record.remoteHistory == .started)',
     '// A failed TLS prerequisite must stop this case before any enrollment request.\n                try #require(loaded.record.phase == .uploadIntent && loaded.record.remoteHistory == .started)')])
report=dict(version=1,scope='Three fixture repairs for actual fc3 SDK failures; production ownership and trust checks unchanged.',sourceCommit='fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a',files=items,
    evidence=dict(runID=39507170170,jobID=118918888695,log='.build/sdk-fc3b01c-terminal/extracted-12307712232/reader-renewal-probe/currentcore-tests.log',
    storageCases=['endpointSelectionIsLocalAndBackwardCompatible','appSessionAuthenticatesThroughSameVaultAndReopensStoredSession','appOwnerCancellationClearsTheSamePendingChallenge'],
    actualFailure='SDK storage exceptions from wrong requested basename; AccountSession test logged POSIX54 and missing uploadIntent but continued into remote enrollment and profileExpired.'),
    limits=['No Swift compiler or Apple SDK on this Windows host; existing cases require unified SDK execution.','TLS root cause is separate and remains under repair. No new tests or selected-case counts.'])
(S/'candidate-v1.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(files=len(items),productionChanges=0,SDKExecuted=0,report=str(S/'candidate-v1.json'))))
