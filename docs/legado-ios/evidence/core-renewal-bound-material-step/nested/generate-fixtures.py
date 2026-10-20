"""Owned multi-bundle actual CMS/resource seals. No Swift implementation called."""
from pathlib import Path
import base64
import hashlib
import json
import plistlib
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
OWNED = OUT/'owned'; OWNED.mkdir(exist_ok=True)
# Reuse only the independently written DER/CMS signing helpers. Do not execute
# the old fixture producer or modify its already frozen Swift source.
old = ROOT/'.build/renewal-discovery/code-directory-cms-step/generate-fixtures.py'
namespace = {'__file__': str(old)}
exec(compile(old.read_text(encoding='utf-8').split('\ndef fixture(')[0], str(old), 'exec'), namespace)
namespace['OWNED'] = OWNED
namespace['OUT'] = OUT
cms = namespace['cms']; digest = namespace['digest']; tlv = namespace['tlv']; seq = namespace['seq']
blob = namespace['blob']; u32 = namespace['u32']; integer = namespace['integer']
OPENSSL = namespace['OPENSSL']; PKI = namespace['PKI']; DATE = namespace['DATE']
ROOT_HASH = hashlib.sha1((PKI/'root.der').read_bytes()).hexdigest()
LEAF_HASH = hashlib.sha1((PKI/'leaf.der').read_bytes()).hexdigest()

def plist(value): return plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True)
def entitlements(identifier):
    values = {'application-identifier': tlv(12, ('OWNEDTEAM.'+identifier).encode()),
              'com.owned.feature': tlv(1,b'\xff'),
              'com.owned.disabled': tlv(1,b'\0'),
              'com.owned.values': seq(tlv(12,b'alpha'),tlv(12,b'beta'))}
    return tlv(0x70, integer(1)+tlv(0xb0,b''.join(sorted(seq(tlv(12,k.encode()),v) for k,v in values.items()))))
def info(identifier, executable, kind):
    return plist({'CFBundleIdentifier':identifier,'CFBundleExecutable':executable,'CFBundleShortVersionString':'1.0','CFBundleVersion':'1','CFBundlePackageType':kind})
def requirement(identifier):
    return ('identifier "'+identifier+'" and certificate leaf[subject.CN] = "Yuedu Owned Fixture leaf"'
            +' and anchor = H"'+ROOT_HASH+'" and entitlement["com.owned.feature"]'
            +' and ! entitlement["com.owned.disabled"]'
            +' and entitlement["com.owned.values"] = "beta"'
            +' and info[CFBundleIdentifier] = "'+identifier+'"')
def envelope(payload_name, payload, nested):
    files = {payload_name:{'hash':digest(1,payload),'hash2':digest(2,payload),'hash3':digest(3,payload),'hash4':digest(4,payload)}}
    rules = {'^.*':True,'^Info\\.plist$':{'omit':True,'weight':20}}
    for path, (req, hint) in nested.items():
        files[path] = {'requirement':req,'cdhash':hint}
        rules['^'+path.replace('.','\\.')+'$'] = {'nested':True,'weight':100}
    return plist({'files':{},'rules':{},'files2':files,'rules2':rules})

signature_receipts = []
def thin(name, identifier, information, resources, kinds, *, cpu=0x0100000c, alternate_identifier=None, mode='both'):
    limit = 173
    embedded = {2:blob(0xfade0c01,u32(0)),5:blob(0xfade7171,plist({'com.owned.feature':True})),7:blob(0xfade7172,entitlements(identifier))}
    materials = {1:information,3:resources,**embedded}
    code = bytearray((i*17+3)%256 for i in range(limit)); code[:64]=bytes(64)
    struct.pack_into('<IIIIIIII',code,0,0xfeedfacf,cpu,0,2,1,16,0,0)
    identifiers = [identifier]+[alternate_identifier or identifier]*(len(kinds)-1)
    names = [(name+'\0OWNEDTEAM\0').encode() for name in identifiers]
    sizes = [52+len(raw)+10*len(digest(kind,b'')) for kind,raw in zip(kinds,names)]
    count = len(kinds)+len(embedded)+1
    base = 12+count*8+sum(sizes)+sum(map(len,embedded.values()))+8
    cms_length = 0
    for _ in range(4):
        struct.pack_into('<IIII',code,32,0x1d,16,limit,base+cms_length)
        directories = []
        for index,(kind,ident) in enumerate(zip(kinds,names)):
            width=len(digest(kind,b'')); raw=bytearray(52)
            struct.pack_into('>IIII',raw,0,0xfade0c02,sizes[index],0x20200,0)
            raw.extend(ident)
            struct.pack_into('>IIIII',raw,16,len(raw)+7*width,52,7,3,limit)
            raw[36:40]=bytes([width,kind,0,6]);struct.pack_into('>I',raw,48,52+len(identifiers[index].encode())+1)
            for slot in range(7,0,-1):raw.extend(digest(kind,materials[slot]) if slot in materials else bytes(width))
            for offset in range(0,limit,64):raw.extend(digest(kind,code[offset:min(limit,offset+64)]))
            assert len(raw)==sizes[index]
            directories.append((0 if index==0 else 0x1000+index-1,kind,bytes(raw)))
        value = cms(directories[0][2],directories,mode,name,False)
        if len(value)==cms_length:break
        cms_length=len(value)
    else:raise AssertionError('unstable CMS size')
    value=cms(directories[0][2],directories,mode,name,True);assert len(value)==cms_length
    parts=[(slot,raw) for slot,_,raw in directories]+list(embedded.items())+[(0x10000,blob(0xfade0b01,value))]
    signature=bytearray(u32(0xfade0cc0)+u32(base+cms_length)+u32(count));offset=12+count*8
    for slot,part in parts:signature.extend(u32(slot)+u32(offset));offset+=len(part)
    for _,part in parts:signature.extend(part)
    assert len(signature)==base+cms_length
    (OWNED/f'{name}.cms').write_bytes(value);(OWNED/f'{name}.primary.cd').write_bytes(directories[0][2])
    cmd=[str(OPENSSL),'cms','-verify','-binary','-inform','DER','-in',str(OWNED/f'{name}.cms'),'-content',str(OWNED/f'{name}.primary.cd'),'-CAfile',str(PKI/'root.pem'),'-purpose','any','-attime',str(DATE),'-out',str(OWNED/f'{name}.verified.cd')]
    verified=subprocess.run(cmd,capture_output=True,text=True,check=True)
    assert (OWNED/f'{name}.verified.cd').read_bytes()==directories[0][2]
    signature_receipts.append({'name':name,'openssl':verified.stderr.strip(),'primarySHA256':hashlib.sha256(directories[0][2]).hexdigest(),'codeDirectoryKinds':kinds})
    selected=next(value for kind in [4,2,3,1] for value in directories if value[1]==kind)
    return bytes(code+signature),digest(selected[1],selected[2])[:20]

def fat(first,second):
    out=bytearray(48);struct.pack_into('>II',out,0,0xcafebabe,2)
    for index,raw in enumerate([first,second]):
        while len(out)%64:out.append(0)
        cpu=struct.unpack_from('<I',raw,4)[0]
        struct.pack_into('>IIIII',out,8+index*20,cpu,0,len(out),len(raw),6);out.extend(raw)
    return bytes(out)

CHILD='Frameworks/Child.framework';EXT='PlugIns/Extension.appex';GRAND=CHILD+'/Frameworks/Grand.framework'
definitions={'.':('owned.parent','Parent','APPL','root.txt',b'owned root resource'),CHILD:('owned.child','Child','FMWK','child.txt',b'owned child resource'),EXT:('owned.extension','Extension','XPC!','extension.txt',b'owned extension resource'),GRAND:('owned.grand','Grand','FMWK','grand.txt',b'owned grand resource')}
cases={}; blobs={};case_receipts={}
for variant in ['valid','cdHashRequirement','falseRequirement','wrongHint','wrongIdentity','legacyUnbound','fatMismatch','systemPolicy']:
    files={}; built={}
    for path in [GRAND,EXT,CHILD,'.']:
        ident,exe,kind,payload_name,payload=definitions[path]
        information=info(ident,exe,kind);nested={}
        if path==CHILD:nested['Frameworks/Grand.framework']=(requirement('owned.grand'),built[GRAND][1])
        if path=='.':
            req=requirement('wrong.child' if variant=='falseRequirement' else 'owned.child')
            if variant=='cdHashRequirement':req+=' and ('+' or '.join('cdhash H"'+value.hex()+'"' for value in built[CHILD][2])+')'
            if variant=='systemPolicy':req+=' and anchor apple generic'
            nested[CHILD]=(req,bytes(20) if variant=='wrongHint' else built[CHILD][1])
            nested[EXT]=(requirement('owned.extension'),built[EXT][1])
        resources=envelope(payload_name,payload,nested)
        mode='legacy' if path==CHILD and variant=='legacyUnbound' else ('v2Truncated' if path==EXT else 'both')
        kinds=[3] if path==EXT else ([1,4,2] if path==CHILD else [1,2])
        alt='owned.evil' if path==CHILD and variant=='wrongIdentity' else None
        tag=variant+'-'+exe
        code,hint=thin(tag,ident,information,resources,kinds,alternate_identifier=alt,mode=mode)
        selected_hints=[hint]
        if path==CHILD:
            second,second_hint=thin(tag+'-x86',ident,information,resources,kinds,cpu=0x01000007,alternate_identifier='owned.evil' if variant=='fatMismatch' else alt,mode=mode)
            code=fat(code,second)
            selected_hints.append(second_hint)
        built[path]=(code,hint,selected_hints)
        prefix='' if path=='.' else path+'/'
        files[prefix+'Info.plist']=information;files[prefix+exe]=code
        files[prefix+'_CodeSignature/CodeResources']=resources;files[prefix+payload_name]=payload
    manifest={}
    destination=OWNED/variant/'Owned.app'
    for path,raw in files.items():
        sha=hashlib.sha256(raw).hexdigest();blobs[sha]=base64.b64encode(raw).decode();manifest[path]=sha
        target=destination/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
    cases[variant]=manifest
    case_receipts[variant]={'files':len(files),'components':4,'universalNestedSlices':2,'filesSHA256':manifest}

record={'producer':'Independent Python hashlib/plistlib/wire construction and OpenSSL actual detached signatures; no Swift SDK',
        'validationUnixTime':DATE,'genericOwnedRootSHA1':ROOT_HASH,'genericOwnedLeafSHA1':LEAF_HASH,
        'cases':case_receipts,'actualOpenSSLDetachedCMSVerifications':signature_receipts,
        'unverified':['Apple-specific/system-policy context','profile authorization','replacement/renewal','Swift SDK execution'],
        'privateKeyShipped':False}
(OUT/'independent-owned-vectors.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8',newline='\n')
lines=['import Foundation','','/// Owned independent actual CMS/resource bundles. Public fixture bytes only.','enum SelfRenewalNestedResourceFixture {','    enum Failure: Error { case missingCase }','    static let rootSHA1 = "'+ROOT_HASH+'"','    static let leafSHA1 = "'+LEAF_HASH+'"','    static func files(_ name: String) throws -> [String: Data] {','        guard let values = cases[name] else { throw Failure.missingCase }','        return try values.mapValues { hash in','            guard let value = blobs[hash], let bytes = Data(base64Encoded: value) else { throw Failure.missingCase }','            return bytes','        }','    }','    private static let cases: [String: [String: String]] = [']
for name,manifest in cases.items():
    lines+=['        "'+name+'": [']+['            "'+p+'": "'+sha+'",' for p,sha in manifest.items()]+['        ],']
lines+=['    ]','    private static let blobs: [String: String] = [']
for sha,encoded in blobs.items():lines+=['        "'+sha+'": "'+encoded+'",']
lines+=['    ]','}','']
(ROOT/'Tests/iOS/yuedu appTests/SelfRenewalNestedResourceFixture.swift').write_text('\n'.join(lines),encoding='utf-8',newline='\n')
print(json.dumps({'cases':len(cases),'componentsPerCase':4,'uniqueBlobs':len(blobs),'actualOpenSSLVerifiedCMS':len(signature_receipts),'swiftOrSDKExecutions':0}))
