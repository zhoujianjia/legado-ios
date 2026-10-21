"""Full device-build fixture branch of the existing owned SDK producer.

No compilation, HTTP, private key or signer is introduced here. The caller owns
the same temporary Keychain and supplies its existing CMS/codesign callbacks.
"""
from pathlib import Path
import hashlib,importlib.util,json,os,plistlib,re,shutil,stat,struct,zipfile

MAX_ARCHIVE=536_870_912
MAX_NATIVE_FILE=268_435_456

def native_component_shape(binary):
    """Bounded shape admission only; the actual vtool IOS check stays required.

    Xcode can replace a static framework's executable with an arm64 dylib stub
    and run lipo -create even for one slice. Keep that FAT32 container intact.
    Never select/drop architectures or treat an ar archive as executable code.
    """
    with binary.open('rb') as stream:
        size=os.fstat(stream.fileno()).st_size
        if not 32<=size<=MAX_NATIVE_FILE:raise ValueError('native file size outside signer bound')
        header=stream.read(32)
        if len(header)!=32:raise ValueError('truncated native header')
        prefix=header[:4]
        offset=0;slice_size=size;outer=None;container='thin64'
        if prefix==b'\xca\xfe\xba\xbe':
            magic,count,cpu,subtype,offset,slice_size,alignment=struct.unpack('>7I',header[:28])
            if count!=1:raise ValueError('FAT32 requires exactly one architecture')
            if (alignment>30 or offset<28 or offset%(1<<alignment)!=0
                or slice_size<32 or offset>size or slice_size!=size-offset):
                raise ValueError('FAT32 slice bounds or alignment invalid')
            outer=(cpu,subtype);container='fat32-single-arm64'
            stream.seek(offset);header=stream.read(32)
        elif prefix!=b'\xcf\xfa\xed\xfe':
            raise ValueError('unsupported native container magic '+prefix.hex())
        if len(header)!=32 or header[:4]!=b'\xcf\xfa\xed\xfe':
            raise ValueError('slice is not little-endian Mach-O64')
        magic,cpu,subtype,filetype,commands,command_bytes,flags,reserved=struct.unpack('<8I',header)
        if cpu!=0x0100000c or subtype&0x00ffffff!=0 or (outer is not None and outer!=(cpu,subtype)):
            raise ValueError('native CPU/subtype mismatch or unsupported architecture')
        if filetype not in (2,6):raise ValueError('native file is not MH_EXECUTE or MH_DYLIB')
        if not 0<commands<=4096 or not commands*8<=command_bytes<=1048576 or command_bytes>slice_size-32 or reserved!=0:
            raise ValueError('native command header outside structural bounds')
        if os.fstat(stream.fileno()).st_size!=size:raise ValueError('native file changed during header read')
        return {'container':container,'architectures':1,'cpuType':cpu,'cpuSubtype':subtype,
            'sliceOffset':offset,'sliceBytes':slice_size,'fileBytes':size,'fileType':filetype}

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def checked(path):
    path=Path(path).absolute()
    if any(p.is_symlink() for p in (path,*path.parents)):raise ValueError('full-app symlinked input')
    return path

def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

def validate_input(base,build):
    repo=base.HERE.parents[2];build=checked(build)
    manifest_path=build/'output/build-manifest.json'
    manifest=json.loads(manifest_path.read_bytes())
    source=base.run(['git','-C',repo,'rev-parse','HEAD']).decode().strip()
    if (not re.fullmatch('[0-9a-f]{40}',source) or manifest.get('sourceCommit')!=source
        or manifest.get('artifactKind')!='legado-mainjs-reader-prototype'
        or manifest.get('platform')!='iPhoneOS' or manifest.get('architecture')!='arm64'
        or manifest.get('configuration')!='Release' or manifest.get('signed') is not False
        or manifest.get('deviceCompilationPassed') is not True
        or manifest.get('jvmIntegratedIntoReading') is not True
        or manifest.get('deviceValidationPassed') is not False):
        raise ValueError('full-app requires this source fresh Release iPhoneOS JVM build')
    app=checked(build/'output/Payload/YueduReader.app')
    ipa=checked(build/'output/YueduReader-experience-unsigned.ipa')
    if not app.is_dir() or not ipa.is_file() or ipa.stat().st_size!=manifest.get('ipaBytes') or digest(ipa)!=manifest.get('ipaSHA256'):
        raise ValueError('full-app unsigned build binding mismatch')
    config=load_module('full_owned_stage_config',repo/'scripts/reader-experience/stage-config.py')
    # Existing validator checks source-staged Java modules, actual fresh ordinary
    # JAR/provenance/licenses, runtime lock and no packaged private source pack.
    runtime=config.verify_jvm_payload(app)
    config.require_no_bundled_sources([repo/'Resources',app])
    if config.bundle_summary(app,with_jvm=True)!=manifest.get('bundleValidation'):
        raise ValueError('full-app runtime or original bundle summary changed')
    if plistlib.loads((app/'Info.plist').read_bytes()).get('YueduExperienceSourceCommit')!=source:
        raise ValueError('full-app product source stamp mismatch')
    native=checked(build/'native-reuse.json')
    provenance=json.loads(native.read_bytes())
    if (not os.environ.get('GITHUB_RUN_ID') or provenance.get('workflowRunID')!=os.environ['GITHUB_RUN_ID']
        or provenance.get('status')!='restored' or provenance.get('sourceCommit')!=source or provenance.get('nativeRuntimeRecompiled') is not False
        or provenance.get('freshOrdinaryJVMRequired') is not True or provenance.get('deviceValidationPassed') is not False):
        raise ValueError('full-app same-job native restoration proof missing')
    return {'repo':repo,'build':build,'app':app,'source':source,'runtime':runtime,
        'buildManifest':{'bytes':manifest_path.stat().st_size,'sha256':digest(manifest_path)},
        'nativeReuse':{'bytes':native.stat().st_size,'sha256':digest(native)}}

def produce(base,out,owned,prepared,cms,codesign,root,at):
    source_app=prepared['app'];app=owned/'Payload/YueduReader.app'
    shutil.copytree(source_app,app,symlinks=True)
    repo=prepared['repo'];source=prepared['source']
    # Existing build.sh pins these exact products; keep their real metadata,
    # resources and source entitlements. No minimal-product substitution.
    expected={'.':repo/'Resources/Yuedu-Reader.entitlements',
        'PlugIns/yuedu_app_Widget.appex':repo/'Widget/Yuedu-Reader-Widget.entitlements',
        'PlugIns/yuedu_app_ShareExtension.appex':repo/'ShareExtension/Yuedu-Reader-ShareExtension.entitlements'}
    file_facts=[];components=[];executables=set();class_count=0
    for path in sorted(app.rglob('*')):
        if path.is_symlink():raise ValueError('full-app symlink is unsupported; not flattened')
        if not path.is_file():continue
        relative=path.relative_to(app).as_posix()
        file_facts.append({'path':relative,'bytes':path.stat().st_size,'sha256':digest(path)})
        if relative.startswith('lib/modules/') and relative.endswith('.class'):class_count+=1
        if path.name!='Info.plist':continue
        info=plistlib.loads(path.read_bytes());executable=info.get('CFBundleExecutable')
        if not isinstance(executable,str) or '/' in executable or not (path.parent/executable).is_file():continue
        binary=path.parent/executable
        relative_bundle=path.parent.relative_to(app).as_posix()
        kind=info.get('CFBundlePackageType')
        if relative_bundle not in expected and kind!='FMWK':raise ValueError('full-app unknown native component')
        if relative_bundle in expected and info.get('CFBundleSupportedPlatforms')!=['iPhoneOS']:
            raise ValueError('full-app must preserve real device platform')
        identifier=info.get('CFBundleIdentifier')
        if not isinstance(identifier,str) or not re.fullmatch('[A-Za-z0-9.-]{1,255}',identifier):raise ValueError('full-app malformed identity')
        try:
            shape=native_component_shape(binary)
            if shape['fileType']!=(6 if kind=='FMWK' else 2):raise ValueError('native file type disagrees with bundle role')
        except ValueError as error:
            # Only public relative path/header facts: make a future refusal
            # attributable without exporting a full App or private build files.
            with binary.open('rb') as stream:prefix=stream.read(8).hex()
            raise ValueError('full-app native component rejected '+json.dumps({
                'path':binary.relative_to(app).as_posix(),'prefixHex':prefix,
                'bytes':binary.stat().st_size,'reason':str(error)},sort_keys=True)) from error
        print('FULL_APPLICATION_NATIVE_COMPONENT '+json.dumps({'path':binary.relative_to(app).as_posix(),**shape},sort_keys=True),flush=True)
        # Public Apple tool inspects the actual Mach-O, independently of plist.
        build_log=base.run(['xcrun','vtool','-show-build',binary],public_log=out/(str(len(components))+'.device-platform.log')).decode()
        platforms=re.findall(r'^\s*platform\s+(\S+)\s*$',build_log,re.M)
        if platforms!=['IOS']:raise ValueError('full-app Mach-O is not iPhoneOS; no platform rewrite')
        components.append({'path':relative_bundle,'bundle':path.parent,'executable':binary,'identifier':identifier,'kind':kind})
        executables.add(binary.relative_to(app).as_posix())
    if len(file_facts)>32_768 or class_count<10_000 or len(components)>64 or {c['path'] for c in components if c['kind']!='FMWK'}!=set(expected):
        raise ValueError('full-app actual JVM/three-bundle cardinality mismatch')
    by_path={c['path']:c for c in components}
    if len(by_path)!=len(components):raise ValueError('full-app duplicate component')
    jar_path=app/'LegadoRuntime/legado-runtime.jar'
    if not jar_path.is_file():raise ValueError('full-app real ordinary JAR missing')
    unchanged={f['path']:f for f in file_facts}
    for index,component in enumerate(sorted(components,key=lambda c:(c['path'].count('/'),c['path']),reverse=True)):
        relative=component['path'];bundle=component['bundle'];identifier=component['identifier']
        entitlements=None
        if relative in expected:
            # Add only the controlled code-signing identity fields; retain every
            # original authored entitlement (including App Group and CloudKit).
            claims=plistlib.loads(expected[relative].read_bytes())
            if not isinstance(claims,dict):raise ValueError('full-app original entitlements malformed')
            claims=dict(claims)
            claims['application-identifier']='FULLFIXTURE.'+identifier
            claims['com.apple.developer.team-identifier']='FIXTURE123'
            if 'keychain-access-groups' not in claims:claims['keychain-access-groups']=['FULLFIXTURE.'+identifier]
            props={'UUID':f'88888888-2222-3333-4444-{index:012d}','CreationDate':at-base.timedelta(minutes=5),
                'ExpirationDate':at+base.timedelta(days=2),'Platform':['iOS'],'TeamIdentifier':['FIXTURE123'],
                'ApplicationIdentifierPrefix':['FULLFIXTURE'],'DeveloperCertificates':[hashlib.sha256(root).digest()],'Entitlements':claims}
            profile=cms(plistlib.dumps({'DER-Encoded-Profile':cms(base.der(props),str(index)+'-full-inner')}),str(index)+'-full-outer')
            (bundle/'embedded.mobileprovision').write_bytes(profile)
            entitlements=owned/(str(index)+'.full-public-entitlements.plist');entitlements.write_bytes(plistlib.dumps(claims))
        codesign(bundle,identifier,entitlements)
    # Verify actual original signatures and all nested resources using Apple's
    # verifier before production Swift independently verifies and re-signs them.
    base.run(['codesign','--verify','--deep','--strict','--verbose=4',app],public_log=out/'full-original-codesign-verification.log')
    allowed=set()
    for c in components:
        prefix='' if c['path']=='.' else c['path']+'/'
        allowed.update([c['executable'].relative_to(app).as_posix(),prefix+'_CodeSignature/CodeResources'])
        if c['path'] in expected:allowed.add(prefix+'embedded.mobileprovision')
    for relative,f in unchanged.items():
        if relative not in allowed and (not (app/relative).is_file() or (app/relative).stat().st_size!=f['bytes'] or digest(app/relative)!=f['sha256']):
            raise ValueError('full-app producer changed unrelated compiled code/resource bytes')
    archive=out/'full-sdk-owned-package.ipa'
    with zipfile.ZipFile(archive,'x',compression=zipfile.ZIP_STORED,allowZip64=False) as z:
        for path in sorted(app.rglob('*')):
            if path.is_symlink():raise ValueError('full-app signing introduced symlink')
            if not path.is_file():continue
            relative=path.relative_to(app).as_posix()
            item=zipfile.ZipInfo('Payload/YueduReader.app/'+relative,(2026,10,21,0,0,0));item.create_system=3
            item.external_attr=(stat.S_IFREG|(0o755 if relative in executables else 0o644))<<16
            with path.open('rb') as src,z.open(item,'w') as dest:shutil.copyfileobj(src,dest,65_536)
    if not 0<archive.stat().st_size<=MAX_ARCHIVE:raise ValueError('full-app exceeds existing production archive budget')
    with zipfile.ZipFile(archive) as z:
        if z.testzip() is not None or len(z.namelist())>32_770:raise ValueError('full-app ZIP integrity/cardinality failure')
    metadata={'schema':1,'kind':'full-current-source-iphoneos-jvm-application','sourceCommit':source,
        'archiveFile':'full-sdk-owned-package.ipa','archiveBytes':archive.stat().st_size,'archiveSHA256':digest(archive),
        'anchor':base.base64.b64encode(root).decode(),'verificationEpochSeconds':int(at.timestamp()),
        'ordinaryJar':{'path':jar_path.relative_to(app).as_posix(),'bytes':jar_path.stat().st_size,'sha256':digest(jar_path)},
        'realJavaClassResourceCount':class_count,'componentPaths':sorted(by_path),'bundlePaths':sorted(expected),
        'originalBuildManifest':prepared['buildManifest'],'sameJobNativeReuse':prepared['nativeReuse'],
        'allUnrelatedDeviceBuildFilesPreserved':True,'privateMaterialArtifacts':0,'realAppleAccountUsed':False,
        'controlledOriginalSigningOnly':True,'realDeviceExecution':False}
    (out/'full-sdk-owned-package.json').write_text(json.dumps(metadata,indent=2)+'\n')
    return {'fullApplication':metadata,'actualSDKProducedMachOs':[
            {'role':c['path'],'bundleIdentifier':c['identifier'],'platform':'iPhoneOS',
             'bytes':c['executable'].stat().st_size,'sha256':digest(c['executable']),
             'originalAppleCodesignDeepVerificationPassed':True} for c in components],
        'archiveSHA256':metadata['archiveSHA256'],'archiveBytes':metadata['archiveBytes'],
        'fullApplicationInputFiles':len(file_facts),'fullApplicationInputTreeSHA256':hashlib.sha256(json.dumps(file_facts,separators=(',',':')).encode()).hexdigest()}
