"""Public whole-package vectors; every private key stays in Python memory.
This executes OpenSSL and Python byte audits only, never the Swift coordinator.
"""
from pathlib import Path
from datetime import datetime, timezone, timedelta
from cryptography import x509
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import rsa, padding
import base64, hashlib, io, json, plistlib, struct, subprocess, zipfile
HERE=Path(__file__).resolve().parent
OUT=HERE.parent/'owned-public-vectors'; OUT.mkdir(exist_ok=True)
OPENSSL='D:/app/Git/usr/bin/openssl.exe'
DATE=datetime.fromtimestamp(1792540800,timezone.utc)
def tlv(tag,body):
    n=len(body); c=(n.bit_length()+7)//8
    return bytes([tag])+(bytes([n]) if n<128 else bytes([0x80|c])+n.to_bytes(c,'big'))+body
def seq(*values):return tlv(0x30,b''.join(values))
def integer(n):
    b=n.to_bytes(max(1,(n.bit_length()+7)//8),'big');return tlv(2,(b'\0' if b[0]&128 else b'')+b)
def oid(s):return tlv(6,bytes.fromhex(s))
def time(d):return tlv(0x17,d.strftime('%y%m%d%H%M%SZ').encode())
def der(v,ent=False):
    if isinstance(v,dict):
        b=b''.join(sorted(seq(tlv(0x0c,k.encode()),der(x)) for k,x in v.items()))
        return tlv(0x70,integer(1)+tlv(0xb0,b)) if ent else tlv(0x31,b)
    if isinstance(v,list):return seq(*(der(x) for x in v))
    if isinstance(v,str):return tlv(0x0c,v.encode())
    if isinstance(v,bytes):return tlv(4,v)
    if isinstance(v,datetime):return time(v)
    if isinstance(v,bool):return tlv(1,b'\xff' if v else b'\0')
    if isinstance(v,int):return integer(v)
    raise TypeError(type(v))
KEY=rsa.generate_private_key(public_exponent=65537,key_size=2048)
PUB=KEY.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.PKCS1)
NAME=seq(tlv(0x31,seq(oid('550403'),tlv(0x0c,b'Owned Package Root'))))
ALG=seq(oid('2a864886f70d01010b'),tlv(5,b''))
def sign(content):return KEY.sign(content,padding.PKCS1v15(),hashes.SHA256())
spki=seq(seq(oid('2a864886f70d010101'),tlv(5,b'')),tlv(3,b'\0'+PUB))
constraints=seq(oid('551d13'),tlv(1,b'\xff'),tlv(4,seq(tlv(1,b'\xff'))))
usage=seq(oid('551d0f'),tlv(1,b'\xff'),tlv(4,tlv(3,b'\x02\x84')))
tbs=seq(tlv(0xa0,integer(2)),integer(1),ALG,NAME,seq(time(DATE-timedelta(days=1)),time(DATE+timedelta(days=30))),NAME,spki,tlv(0xa3,seq(constraints,usage)))
CERT=seq(tbs,ALG,tlv(3,b'\0'+sign(tbs)))
(OUT/'root.cert.der').write_bytes(CERT)
(OUT/'root.cert.pem').write_bytes(x509.load_der_x509_certificate(CERT).public_bytes(serialization.Encoding.PEM))
CMS_RECORDS=[]
def cms(content,label,detached=False):
    digest=seq(oid('608648016503040201'),tlv(5,b''))
    signer=seq(integer(1),seq(NAME,integer(1)),digest,ALG,tlv(4,sign(content)))
    enc=seq(oid('2a864886f70d010701'),*([] if detached else [tlv(0xa0,tlv(4,content))]))
    value=seq(oid('2a864886f70d010702'),tlv(0xa0,seq(integer(1),tlv(0x31,digest),enc,tlv(0xa0,CERT),tlv(0x31,signer))))
    src=OUT/(label+'.cms'); raw=OUT/(label+'.content'); dest=OUT/(label+'.verified')
    src.write_bytes(value);raw.write_bytes(content)
    args=[OPENSSL,'cms','-verify','-binary','-inform','DER','-in',str(src),'-CAfile',str(OUT/'root.cert.pem'),'-purpose','any','-attime',str(int(DATE.timestamp())),'-out',str(dest)]
    if detached:args+=['-content',str(raw)]
    r=subprocess.run(args,capture_output=True)
    assert r.returncode==0,r.stderr.decode();assert dest.read_bytes()==content
    CMS_RECORDS.append({'name':label,'detached':detached,'sha256':hashlib.sha256(value).hexdigest(),'verifiedContentSHA256':hashlib.sha256(content).hexdigest()})
    return value

def wrapper(magic,body):return struct.pack('>II',magic,len(body)+8)+body
def segment(name,vm,vmsize,fo,fs,prot,section=False):
    v=struct.pack('<II16sQQQQIIII',0x19,152 if section else 72,name.encode().ljust(16,b'\0'),vm,vmsize,fo,fs,7 if prot else 0,prot,int(section),0)
    if section:v+=struct.pack('<16s16sQQIIIIIIII',b'__text'.ljust(16,b'\0'),b'__TEXT'.ljust(16,b'\0'),vm+4096,256,4096,2,0,0,0x80000400,0,0,0)
    return v
def prefix():
    cap=8192;base=0x100000000
    cs=[segment('__PAGEZERO',0,base,0,0,0),segment('__TEXT',base,16384,0,16384,5,True),segment('__LINKEDIT',base+16384,16384,16384,cap,1),struct.pack('<IIII',0x1d,16,16384,cap),struct.pack('<IIQQ',0x80000028,24,4096,0),struct.pack('<IIIIII',0x32,24,2,0x110000,0x110000,0),struct.pack('<II16s',0x1b,24,b'OwnedPackageUUID')]
    raw=bytearray((struct.pack('<8I',0xfeedfacf,0x100000c,0,2,len(cs),sum(map(len,cs)),0x200085,0)+b''.join(cs)).ljust(16384,b'\0'))
    raw[4096:4352]=bytes.fromhex('c0035fd6')*64
    return bytes(raw)
def macho(identifier,info,resources,ent,label,code=None):
    slots={2:struct.pack('>III',0xfade0c01,12,0),5:wrapper(0xfade7171,plistlib.dumps(ent)),7:wrapper(0xfade7172,der(ent,ent=True))}
    code=code or prefix();strings=identifier.encode()+b'\0FIXTURE123\0';ho=88+len(strings)+7*32
    cd=bytearray(88);struct.pack_into('>9I',cd,0,0xfade0c02,ho+((len(code)+4095)//4096)*32,0x20400,0,ho,88,7,(len(code)+4095)//4096,len(code));cd[36:40]=bytes([32,2,0,12]);struct.pack_into('>I',cd,48,89+len(identifier));struct.pack_into('>QQQ',cd,64,0,16384,1)
    materials={1:info,3:resources,**slots}
    cd+=strings+b''.join(hashlib.sha256(materials[n]).digest() if n in materials else b'\0'*32 for n in range(7,0,-1))
    cd+=b''.join(hashlib.sha256(code[n:n+4096]).digest() for n in range(0,len(code),4096));cd=bytes(cd)
    slots[0]=cd;slots[0x10000]=wrapper(0xfade0b01,cms(cd,label+'.code',True))
    index=bytearray();body=bytearray();offset=12+8*len(slots)
    for slot,raw in sorted(slots.items()):index+=struct.pack('>II',slot,offset+len(body));body+=raw
    signature=struct.pack('>III',0xfade0cc0,offset+len(body),len(slots))+index+body
    assert len(signature)<=8192
    return code+signature.ljust(8192,b'\0'),hashlib.sha256(cd).digest()[:20]
BUNDLES=[('.', 'test.owned.reader',None),('PlugIns/OwnedShare.appex','test.owned.reader.share','com.apple.share-services'),('PlugIns/OwnedWidget.appex','test.owned.reader.widget','com.apple.widgetkit-extension')]
def package(label,requirement='identifier',alternate_groups=False):
    files={};children={}
    for i,(path,identifier,point) in reversed(list(enumerate(BUNDLES))):
        base='' if path=='.' else path+'/'
        info={'CFBundleIdentifier':identifier,'CFBundleExecutable':'Owned','CFBundleShortVersionString':'1.0','CFBundleVersion':'12','CFBundlePackageType':'APPL' if path=='.' else 'XPC!'}
        if point:info['NSExtension']={'NSExtensionPointIdentifier':point}
        info=plistlib.dumps(info,sort_keys=True)
        ent={'application-identifier':'OLDPREFIX.'+identifier,'com.apple.developer.team-identifier':'FIXTURE123','com.apple.security.application-groups':['group.test.owned.reader'],'keychain-access-groups':['OLDPREFIX.'+identifier,'OLDPREFIX.shared'],'get-task-allow':True}
        actual=dict(ent)
        if alternate_groups:actual['com.apple.security.application-groups']=['group.test.owned.reader.other']
        ent_allowance=dict(ent);ent_allowance['com.apple.security.application-groups']=['group.test.owned.reader','group.test.owned.reader.other']
        props={'UUID':f'11111111-2222-3333-4444-{i:012d}','CreationDate':DATE-timedelta(hours=1),'ExpirationDate':DATE+timedelta(days=2),'Platform':['iOS'],'TeamIdentifier':['FIXTURE123'],'ApplicationIdentifierPrefix':['OLDPREFIX'],'DeveloperCertificates':[hashlib.sha256(CERT).digest()],'Entitlements':ent_allowance}
        inner=cms(der(props),label+f'.{i}.profile-inner')
        profile=cms(plistlib.dumps({'DER-Encoded-Profile':inner}),label+f'.{i}.profile-outer')
        seals={'chapter.txt':{'hash2':hashlib.sha256(b'abc').digest()},'embedded.mobileprovision':{'hash2':hashlib.sha256(profile).digest()}}
        rules={'^.*':True,'^Info\\.plist$':{'omit':True,'weight':20}}
        if path=='.':
            rules['^PlugIns/.*\\.appex$']={'nested':True,'weight':10}
            for child,(childid,hashvalue) in children.items():
                req='identifier "'+childid+'"' if requirement=='identifier' else 'never' if requirement=='false' else 'anchor apple'
                seals[child]={'requirement':req,'cdhash':hashvalue}
        resources=plistlib.dumps({'files':{},'rules':{},'files2':seals,'rules2':rules},sort_keys=True)
        code,cdhash=macho(identifier,info,resources,actual,label+f'.{i}')
        for name,raw in [('Info.plist',info),('embedded.mobileprovision',profile),('_CodeSignature/CodeResources',resources),('Owned',code),('chapter.txt',b'abc')]:files['Payload/Owned.app/'+base+name]=raw
        if path!='.':children[path]=(identifier,cdhash)
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w',compression=zipfile.ZIP_STORED) as archive:
        for path,raw in sorted(files.items()):
            item=zipfile.ZipInfo(path,(2026,10,21,0,0,0));item.create_system=3;item.external_attr=0o100644<<16;archive.writestr(item,raw)
    raw=stream.getvalue();(OUT/(label+'.ipa')).write_bytes(raw)
    # Independent ZIP and raw CD/page/special-slot audit after generation.
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        assert z.testzip() is None and set(z.namelist())==set(files)
        for path,value in files.items():assert z.read(path)==value
        observed_cd_hashes={}; nested_hints=[]
        for path,identifier,_ in BUNDLES:
            b='Payload/Owned.app/'+('' if path=='.' else path+'/');exe=z.read(b+'Owned');off,capacity=16384,8192
            magic,size,count=struct.unpack_from('>III',exe,off);assert magic==0xfade0cc0 and size<=capacity
            slots={}
            for n in range(count):
                slot,at=struct.unpack_from('>II',exe,off+12+8*n);length=struct.unpack_from('>I',exe,off+at+4)[0];slots[slot]=exe[off+at:off+at+length]
            cd=slots[0];ho=struct.unpack_from('>I',cd,16)[0]
            observed_cd_hashes[path]=hashlib.sha256(cd).digest()[:20]
            for n in range(4):assert cd[ho+n*32:ho+(n+1)*32]==hashlib.sha256(exe[n*4096:(n+1)*4096]).digest()
            for slot,value in {1:z.read(b+'Info.plist'),3:z.read(b+'_CodeSignature/CodeResources'),2:slots[2],5:slots[5],7:slots[7]}.items():assert cd[ho-slot*32:ho-(slot-1)*32]==hashlib.sha256(value).digest()
            resources=plistlib.loads(z.read(b+'_CodeSignature/CodeResources'))
            assert all(isinstance(resources[k],dict) for k in ['files','rules','files2','rules2'])
            for name,seal in resources['files2'].items():
                if 'hash2' in seal:assert seal['hash2']==hashlib.sha256(z.read(b+name)).digest()
                if 'cdhash' in seal:nested_hints.append((name,seal['cdhash']))
        for child,hint in nested_hints:assert hint==observed_cd_hashes[child]
    return raw
def dynamic_prefix(library):
    base=0 if library else 0x100000000
    cmds=[] if library else [segment('__PAGEZERO',0,base,0,0,0)]
    cmds += [segment('__TEXT',base,16384,0,16384,5,True),segment('__LINKEDIT',base+16384,32768,16384,24576,1)]
    cmds += [struct.pack('<IIIIII',2,24,16384,1,16400,16)]
    # Real table ranges, not just zero-count padding. nlist_64, indirect,
    # reference, TOC and dylib_module_64 bytes stay at their original offsets.
    cmds += [struct.pack('<20I',0xb,80,0,1,1,0,1,0,16424,1 if library else 0,16432,1 if library else 0,16420,1 if library else 0,16416,1,0,0,0,0)]
    cmds += [struct.pack('<IIII',0x1d,16,32768,8192)]
    if library:
        name=b'@rpath/OwnedFramework.framework/OwnedFramework\0';n=(24+len(name)+7)//8*8
        cmds += [(struct.pack('<6I',0xd,n,24,0,0x10000,0x10000)+name).ljust(n,b'\0')]
    else:cmds += [struct.pack('<IIQQ',0x80000028,24,4096,0)]
    cmds += [struct.pack('<IIIIII',0x32,24,2,0x110000,0x110000,0)]
    raw=bytearray((struct.pack('<8I',0xfeedfacf,0x100000c,0,6 if library else 2,len(cmds),sum(map(len,cmds)),0x200085,0)+b''.join(cmds)).ljust(32768,b'\0'))
    raw[4096:4352]=bytes.fromhex('c0035fd6')*64
    raw[16384:16400]=struct.pack('<IBBHQ',1,0xf,1,0,base+4096)
    raw[16400:16416]=b'\0_owned_value\0'.ljust(16,b'\0')
    # Zero indexes reference the actual sole symbol/module; table bytes are
    # public data. Remaining 56-byte module fields are valid empty ranges.
    return bytes(raw)
layout_info=plistlib.dumps({'CFBundleIdentifier':'test.owned.layout','CFBundleExecutable':'Owned','CFBundleVersion':'12','CFBundleShortVersionString':'1.0'})
layout_resources=plistlib.dumps({'files2':{},'rules2':{'^.*':True}})
layout_ent={'application-identifier':'OLDPREFIX.test.owned.layout','com.apple.developer.team-identifier':'FIXTURE123'}
layout_values={}
for name,library in [('dysymtabExecutable',False),('dysymtabLibrary',True)]:
    code,cdhash=macho('test.owned.layout',layout_info,layout_resources,layout_ent,name,code=dynamic_prefix(library))
    (OUT/(name+'.macho')).write_bytes(code);layout_values[name]=code
    count,command_size=struct.unpack_from('<II',code,16);cursor=32;sym_count=None
    for _ in range(count):
        cmd,size=struct.unpack_from('<II',code,cursor)
        if cmd==2:sym_count=struct.unpack_from('<I',code,cursor+12)[0]
        if cmd==0xb:
            assert size==80 and sym_count==1
            for field in [8,16,24]:
                start,length=struct.unpack_from('<II',code,cursor+field);assert start<=sym_count and length<=sym_count-start
            for field,width in [(32,8),(40,56),(48,4),(56,4),(64,8),(72,8)]:
                start,length=struct.unpack_from('<II',code,cursor+field);assert start+length*width<=32768
        cursor+=size
    assert cursor==32+command_size and len(code)==40960
values={'anchor':CERT,'valid':package('valid'),'falseRequirement':package('falseRequirement','false'),'unresolvedRequirement':package('unresolvedRequirement','unresolved'),'differentActualGroups':package('differentActualGroups',alternate_groups=True),'layoutInfo':layout_info,'layoutResources':layout_resources,**layout_values}
lines=['import Foundation','','/// Owned public inputs; no private key or production app data.','enum SelfRenewalControlledPackageFixture {']
for key,raw in values.items():
    s=base64.b64encode(raw).decode();lines += [f'    static let {key}Base64 = """']+['        '+s[i:i+112] for i in range(0,len(s),112)]+['        """']
lines += ['    static func data(_ encoded: String) throws -> Data {','        guard let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { throw CocoaError(.coderInvalidValue) }','        return bytes','    }','}','']
(HERE/'SelfRenewalControlledPackageFixture.swift').write_text('\n'.join(lines),encoding='utf-8')
record={'schema':1,'validationDate':DATE.isoformat(),'actualOpenSSLCMSVerifications':len(CMS_RECORDS),'CMS':CMS_RECORDS,'actualZipCRCReadAll':4,'actualRawPageAndSpecialSlotAudits':12,'actualResourceHashAudits':12,'actualDynamicSymbolTableLayoutAudits':2,'archiveEntriesPerPackage':15,'outputs':[{ 'name':k,'bytes':len(v),'sha256':hashlib.sha256(v).hexdigest()} for k,v in values.items()],'privateKeysExported':0,'privateKeyFiles':0,'SwiftExecutions':0,'SDKExecutions':0,'scope':'Controlled thin64 arm64 MH_EXECUTE fixture only; not an Xcode-produced app or framework.'}
(HERE.parent/'fixture-generation.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:record[k] for k in ['actualOpenSSLCMSVerifications','actualZipCRCReadAll','actualRawPageAndSpecialSlotAudits','SwiftExecutions','SDKExecutions']}))
