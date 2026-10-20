"""Bounded local PBX proof and exact source-D failure archive. No Git/CI/tests."""
from datetime import datetime, timezone
import difflib
import hashlib
import json
from pathlib import Path
import re
from urllib.request import Request, urlopen

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/".build/renewal-discovery/umd-fixture-packaging-fix"
FAIL=ROOT/".build/renewal-discovery/D-after-build12-report-20261020T002448Z-fba330"
SHORT=ROOT/".build/D12-fba330"
DEST=ROOT/"docs/legado-ios/evidence/stage-checkpoint-f3e0b15-failure"
PROJECT=ROOT/"Yuedu-Reader.xcodeproj/project.pbxproj"
SOURCE_D="f3e0b15aae3b74e820f2ee86e5468c05a6c1d842"
SYNC="460D36692F51C5B9006E774C"
TARGET="460D36652F51C5B9006E774C"
RESOURCES="460D36642F51C5B9006E774C"
RELATIVE="yuedu appTests/Fixtures/UMD"
def sha(raw):return hashlib.sha256(raw).hexdigest()
def encoded(value):return (json.dumps(value,ensure_ascii=True,indent=2)+"\n").encode()
def write(path,raw):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open("xb") as output:output.write(raw)
def info(path):
    raw=path.read_bytes();return dict(path=str(path),bytes=len(raw),sha256=sha(raw))

class OpenStep:
    """Parse the full existing project grammar, without rewriting its syntax."""
    token=re.compile(r'\s+|//[^\r\n]*|/\*.*?\*/|"(?:[^"\\]|\\.)*"|[{}()=;,]|[^\s{}()=;,\"]+',re.S)
    def __init__(self,text):
        self.tokens=[];position=0
        for match in self.token.finditer(text):
            assert match.start()==position;position=match.end();value=match.group()
            if not value.isspace() and not value.startswith(("//","/*")):self.tokens.append(value)
        assert position==len(text);self.position=0
    def take(self,wanted=None):
        value=self.tokens[self.position];self.position+=1
        assert wanted is None or value==wanted,(wanted,value)
        return value
    def atom(self):
        value=self.take();assert value not in '{}()=;,'
        return json.loads(value) if value.startswith('"') else value
    def value(self):
        value=self.tokens[self.position]
        if value=='{':
            self.take('{');result={}
            while self.tokens[self.position]!='}':
                key=self.atom();assert key not in result
                self.take('=');result[key]=self.value();self.take(';')
            self.take('}');return result
        if value=='(':
            self.take('(');result=[]
            while self.tokens[self.position]!=')':
                result.append(self.value())
                if self.tokens[self.position]==',':self.take(',')
                else:break
            self.take(')');return result
        return self.atom()
    def parse(self):
        result=self.value();assert self.position==len(self.tokens);return result

before=(OUT/"project.before.pbxproj").read_bytes();after=PROJECT.read_bytes()
assert sha(before)=="aa3de7d6d4a4cdaf2ee3be00ebcee3fe434ca5bd1e4f257b0ed7a7cd3d7d306d"
old='\t\t460D36692F51C5B9006E774C /* Tests/iOS */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n'.encode()
addition='\t\t\texplicitFolders = (\n\t\t\t\t"yuedu appTests/Fixtures/UMD",\n\t\t\t);\n'.encode()
assert before.count(old)==1 and before.replace(old,old+addition,1)==after
old_graph=OpenStep(before.decode()).parse();new_graph=OpenStep(after.decode()).parse()
objects=new_graph['objects'];group=objects[SYNC]
assert group['isa']=='PBXFileSystemSynchronizedRootGroup' and group['path']=='Tests/iOS' and group['sourceTree']=='<group>'
assert group['explicitFolders']==[RELATIVE]
assert objects[TARGET]['isa']=='PBXNativeTarget' and objects[TARGET]['name']=='yuedu appTests'
assert objects[TARGET]['fileSystemSynchronizedGroups']==[SYNC] and RESOURCES in objects[TARGET]['buildPhases']
assert objects[RESOURCES]['isa']=='PBXResourcesBuildPhase' and objects[RESOURCES]['files']==['D4C329B2F01E414A88BD6077']
attached=[key for key,value in objects.items() if isinstance(value,dict) and SYNC in value.get('fileSystemSynchronizedGroups',[])]
assert attached==[TARGET]
del new_graph['objects'][SYNC]['explicitFolders'];assert new_graph==old_graph
assert (ROOT/'Tests/iOS'/RELATIVE).resolve()==(ROOT/'Tests/iOS/yuedu appTests/Fixtures/UMD').resolve()
assert not list((ROOT/'Tests/iOS'/RELATIVE).rglob('*.swift'))
frozen=json.loads((ROOT/'.build/reader-umd-worktree/.build/reader-umd-parser-preparation.json').read_bytes())
assert len(frozen['files'])==16
for item in frozen['files']:
    raw=(ROOT/item['path']).read_bytes();assert len(raw)==item['bytes'] and sha(raw)==item['sha256']
literal=json.loads((ROOT/'.build/reader-umd-reading-worktree/.build/reader-umd-reading-preparation.json').read_bytes())
loader_paths=['Tests/iOS/yuedu appTests/UMDTextDecoderTests.swift','Tests/iOS/yuedu appTests/UMDReadingPreparationTests.swift']
loader_pins={item['path']:item for item in frozen['files']+literal['files'] if item['path'] in loader_paths}
assert set(loader_pins)==set(loader_paths)
for path in loader_paths:
    raw=(ROOT/path).read_bytes();assert sha(raw)==loader_pins[path]['sha256']
    text=raw.decode();assert 'URL(fileURLWithPath: #filePath).deletingLastPathComponent()' in text
    assert '.appendingPathComponent("Fixtures/UMD")' in text and 'Bundle.' not in text
write(OUT/'project.after.pbxproj',after)
diff=''.join(difflib.unified_diff(before.decode().splitlines(keepends=True),after.decode().splitlines(keepends=True),
    fromfile='a/Yuedu-Reader.xcodeproj/project.pbxproj',tofile='b/Yuedu-Reader.xcodeproj/project.pbxproj'))
write(OUT/'project.patch',diff.encode())
primary=[]
for filename,url in (
    ('PBXFileSystemSynchronizedRootGroup.swift','https://raw.githubusercontent.com/tuist/XcodeProj/main/Sources/XcodeProj/Objects/Files/PBXFileSystemSynchronizedRootGroup.swift'),
    ('XcodeGen-ProjectSpec.md','https://raw.githubusercontent.com/yonaskolb/XcodeGen/master/Docs/ProjectSpec.md')):
    with urlopen(Request(url,headers={'User-Agent':'Yuedu-fixture-packaging-primary-contract'}),timeout=30) as response:
        raw=response.read(512*1024+1);assert response.status==200 and len(raw)<=512*1024
    path=OUT/'primary'/filename;write(path,raw);primary.append(dict(url=url,**info(path)))
assert b'A list of relative paths to children folder' in (OUT/'primary/PBXFileSystemSynchronizedRootGroup.swift').read_bytes()
assert b'child folders that Xcode should treat as folder references' in (OUT/'primary/XcodeGen-ProjectSpec.md').read_bytes()
write(OUT/'primary/index.json',encoded(primary))
observed=json.loads((FAIL/'observation.json').read_bytes())
assert observed['sourceCommit']==SOURCE_D and observed['APIRequests']==4 and observed['polling'] is False
assert all(row['status']=='completed' and row['conclusion']=='failure' and row['exactSourceTagWorkflowRepoEventBound'] is True for row in observed['observations'])
downloads=json.loads((FAIL/'artifact-download-summary.json').read_bytes())['downloads']
assert len(downloads)==2
for item in downloads:
    raw=Path(item['archive']).read_bytes();assert len(raw)==item['bytes'] and sha(raw)==item['sha256'] and 'sha256:'+sha(raw)==item['githubDigest']
assert sha((FAIL/'actual-failure-summary.json').read_bytes())=='7cbd2032b97ea8ff87fd91b4b0b5f0fb282c77c89e043823d94d35ea000bc282'
record=dict(schemaVersion=1,recordedAtUTC=datetime.now(timezone.utc).isoformat(),sourceD=SOURCE_D,
    repairScope='Only three added PBX lines mark one existing fixture subtree as a folder reference inside the app-test synchronized root.',
    before=info(OUT/'project.before.pbxproj'),after=info(OUT/'project.after.pbxproj'),patch=info(OUT/'project.patch'),
    OpenStepFullProjectParseBeforeAfter=True,onlyNewGraphField='objects.'+SYNC+'.explicitFolders',otherProjectGraphFieldsEqual=True,
    synchronizedRoot=dict(id=SYNC,path='Tests/iOS',sourceTree='<group>',onlyTarget=TARGET,explicitFolders=[RELATIVE]),
    target=dict(id=TARGET,name='yuedu appTests',resourcesPhase=RESOURCES,existingResourceFilesUnchanged=['D4C329B2F01E414A88BD6077']),
    frozenParser16Unchanged=frozen['files'],fixtureLoadersUnchanged=[loader_pins[path] for path in loader_paths],
    loaderContract='Both suites derive source-adjacent Fixtures/UMD from #filePath, not Bundle. The checkout path and fixture bytes remain unchanged. This repairs packaging intent without changing lookup expressions. Actual Simulator host access and folder-copy behavior still require the next consolidated SDK run.',
    noSwiftSourcesHiddenInsideOpaqueSubtree=True,primary=primary,
    originalFailureSummary=info(FAIL/'actual-failure-summary.json'),artifactOriginals=[{key:item[key] for key in ('name','bytes','sha256','githubDigest','githubSizeAndDigestMatched')} for item in downloads],
    actualVerification=dict(staticOnly=True,newXcodeBuilds=0,newSwiftTests=0,newIOSTests=0,CIQueriesOrTriggers=0,GitCommands=0),
    XcodeFailureResolvedEstablished=False,identitiesAndResourcesPhasePreserved=True,displayNamesAndOtherSettingsUnchanged=True)
write(OUT/'verification.json',encoded(record))
# No deep xcresult member is copied here. Original ZIPs retain all original bytes;
# readable members and immutable API/HTTP/source-digest receipts remain easy to inspect.
assert not DEST.exists();DEST.mkdir()
archived=[]
def archive(source,name,kind):
    assert '..' not in Path(name).parts and not Path(name).is_absolute()
    raw=source.read_bytes();destination=DEST/name;write(destination,raw)
    assert destination.read_bytes()==raw
    archived.append(dict(path=destination.relative_to(ROOT).as_posix(),source=str(source),bytes=len(raw),sha256=sha(raw),kind=kind))
for path in sorted(FAIL.iterdir()):
    assert path.is_file()
    archive(path,('artifacts/' if path.suffix=='.zip' else 'source-observation/')+path.name,'original-artifact' if path.suffix=='.zip' else 'original-source-observation')
members=[]
for item in downloads:
    base=Path(item['extractedRoot'])
    assert base.parent==SHORT
    for member in item['files']:
        path=Path(member['path']);assert path.is_relative_to(base)
        relative=path.relative_to(base)
        raw=path.read_bytes();assert len(raw)==member['bytes'] and sha(raw)==member['sha256']
        readable=(not any(part.endswith('.xcresult') for part in relative.parts)
                  and path.name!='completion-plan.json' and path.suffix in ('.log','.json','.stderr','.stdout') and len(raw)<=2*1024*1024)
        entry=dict(workflow=base.name,member=member['member'],bytes=len(raw),sha256=sha(raw),readableArchived=readable)
        if readable:
            name='readable/'+base.name+'/'+relative.as_posix();archive(path,name,'original-readable-artifact-member');entry['archivePath']=(DEST/name).relative_to(ROOT).as_posix()
        members.append(entry)
write(DEST/'artifact-members.json',encoded(dict(sourceD=SOURCE_D,files=members,deepXCResultMembersNotExpandedHere=True,allOriginalMembersRetainedInVerifiedZIPs=True)))
archived.append(dict(path=(DEST/'artifact-members.json').relative_to(ROOT).as_posix(),source='generated exact member digest index',
                     bytes=(DEST/'artifact-members.json').stat().st_size,sha256=sha((DEST/'artifact-members.json').read_bytes()),kind='member-manifest'))
for path in sorted(OUT.rglob('*')):
    if path.is_file():archive(path,'repair/'+path.relative_to(OUT).as_posix(),'static-repair-evidence')
archive(Path(__file__),'verify-and-archive-umd-fixture-packaging.py','bounded-recorder-source')
manifest=dict(schemaVersion=1,sourceD=SOURCE_D,status='saved-terminal-failure-and-static-packaging-repair-preparation',
    sourceBoundFailures=[dict(runID=row['runID'],status=row['status'],conclusion=row['conclusion']) for row in observed['observations']],
    files=archived,manifestExcludesItself=True,originalZIPsPreserved=True,deepXCResultFoldersCopied=False,
    newCITriggered=False,newNativeTestsExecuted=0,canonicalOrBatchEdits=False,GitCommands=0,
    packagingRepairSDKAcceptanceEstablished=False,countsAreArtifactFilesNotTests=True)
write(DEST/'manifest.json',encoded(manifest))
print(json.dumps(dict(verification=info(OUT/'verification.json'),projectSHA256=sha(after),archivedFiles=len(archived),
    manifest=info(DEST/'manifest.json'),sourceD=SOURCE_D,newNativeTests=0,CITriggered=False),indent=2))
