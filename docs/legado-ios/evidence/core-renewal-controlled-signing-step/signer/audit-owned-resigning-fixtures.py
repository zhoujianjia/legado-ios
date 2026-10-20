"""Read public owned bytes independently of their constructor and Swift signer."""
from pathlib import Path
import hashlib, json, plistlib, struct, subprocess

ROOT=Path(__file__).resolve().parent.parent
RAW=ROOT/"owned-vectors"
OPENSSL="D:/app/Git/usr/bin/openssl.exe"

def n32(raw,offset,little=False): return int.from_bytes(raw[offset:offset+4],"little" if little else "big")
def n64(raw,offset): return int.from_bytes(raw[offset:offset+8],"little")
def hashed(raw,kind):
    result=hashlib.sha1(raw).digest() if kind==1 else hashlib.sha384(raw).digest() if kind==4 else hashlib.sha256(raw).digest()
    return result[:20] if kind==3 else result
def values(raw):
    def value(raw,start):
        cursor=start+1; length=raw[cursor]; cursor+=1
        if length&128:
            size=length&127; length=int.from_bytes(raw[cursor:cursor+size],"big"); cursor+=size
        end=cursor+length; assert end<=len(raw)
        return raw[start],raw[cursor:end],raw[start:end],end
    _,body,_,end=value(raw,0); assert end==len(raw)
    output=[]; cursor=0
    while cursor<len(body):
        tag,content,full,cursor=value(body,cursor); output.append((tag,content,full))
    return output

def audit(raw,external):
    assert n32(raw,0,True)==0xfeedfacf and n32(raw,4,True)==0x0100000c
    cursor=32; sig=None; linkedit=None
    for _ in range(n32(raw,16,True)):
        cmd=n32(raw,cursor,True); size=n32(raw,cursor+4,True); assert size>=8 and size%8==0
        if cmd==0x1d: sig=(n32(raw,cursor+8,True),n32(raw,cursor+12,True))
        if cmd==0x19 and raw[cursor+8:cursor+24].rstrip(b"\0")==b"__LINKEDIT":
            linkedit=(n64(raw,cursor+40),n64(raw,cursor+48),n64(raw,cursor+32))
        cursor+=size
    assert cursor==32+n32(raw,20,True)
    offset,capacity=sig; assert offset+capacity==len(raw) and offset%16==0 and capacity%16==0
    assert linkedit[0]+linkedit[1]==len(raw) and linkedit[2]==((linkedit[1]+16383)//16384)*16384
    envelope=raw[offset:]; assert n32(envelope,0)==0xfade0cc0
    count=n32(envelope,8); size=n32(envelope,4); assert size<=capacity and not any(envelope[size:])
    blobs={}; occupied=[]
    for index in range(count):
        slot=n32(envelope,12+index*8); start=n32(envelope,16+index*8); length=n32(envelope,start+4)
        assert slot not in blobs and start>=12+count*8 and start+length<=size
        assert all(start>=end or start+length<=begin for begin,end in occupied)
        occupied.append((start,start+length)); blobs[slot]=envelope[start:start+length]
    directories=[]; pages=0; specials=0
    for slot,blob in sorted(blobs.items()):
        if slot!=0 and not 0x1000<=slot<0x1005: continue
        assert n32(blob,0)==0xfade0c02 and n32(blob,4)==len(blob)
        hash_offset=n32(blob,16); special=n32(blob,24); code_slots=n32(blob,28); limit=n32(blob,32)
        width,kind,_,page=blob[36:40]; assert limit==offset and width=={1:20,2:32,3:20,4:48}[kind]
        chunk=(1<<page) if page else limit; assert code_slots==(limit+chunk-1)//chunk
        for index in range(code_slots):
            expected=blob[hash_offset+index*width:hash_offset+(index+1)*width]
            assert expected==hashed(raw[index*chunk:min(limit,(index+1)*chunk)],kind); pages+=1
        for special_slot in range(1,special+1):
            material=external.get(special_slot,blobs.get(special_slot))
            expected=hashed(material,kind) if material is not None else bytes(width)
            assert blob[hash_offset-special_slot*width:hash_offset-(special_slot-1)*width]==expected; specials+=1
        directories.append((kind,blob))
    cms=blobs[0x10000]; assert n32(cms,0)==0xfade0b01
    signed_data=values(values(values(cms[8:])[1][2])[0][2])
    assert signed_data[2][0]==0x30 and len(values(signed_data[2][2]))==1 # detached content
    signer=values(values(signed_data[4][2])[0][2]); attrs=values(signer[3][2]); mapping={}
    for _,_,attribute in attrs:
        fields=values(attribute); mapping[fields[0][1]]=values(fields[1][2])
    primary=dict((0 if kind==directories[0][0] else index+1,blob) for index,(kind,blob) in enumerate(directories))[0]
    assert mapping[bytes.fromhex('2a864886f70d010904')][0][1]==hashlib.sha256(primary).digest()
    assert mapping[bytes.fromhex('2a864886f70d010903')][0][1]==bytes.fromhex('2a864886f70d010701')
    ordered=sorted(directories); expected=[hashed(blob,kind) for kind,blob in ordered]
    assert plistlib.loads(mapping[bytes.fromhex('2a864886f763640901')][0][1])['cdhashes']==[v[:20] for v in expected]
    v2=mapping.get(bytes.fromhex('2a864886f763640902'))
    if v2:
        actual={values(full)[0][1]:values(full)[1][1] for _,_,full in v2}
        oids={1:bytes.fromhex('2b0e03021a'),2:bytes.fromhex('608648016503040201'),3:bytes.fromhex('608648016503040201'),4:bytes.fromhex('608648016503040202')}
        assert len(actual)==len(directories)
        for (kind,_),digest in zip(ordered,expected): assert actual[oids[kind]]==digest
    return {'codeDirectories':len(directories),'pageDigests':pages,'specialDigestsIncludingAbsent':specials,'v2':bool(v2)}

def main():
    # These bytes are exported public owned fixtures, not inputs chosen by an app user.
    source=json.loads((ROOT/'independent-original-fixture-audit.json').read_text())
    fixture=__import__('importlib.util').util
    spec=fixture.spec_from_file_location('construct_public_fixture',ROOT/'work/generate-owned-resigning-fixtures.py')
    mod=fixture.module_from_spec(spec); spec.loader.exec_module(mod)
    external={1:mod.INFO,3:mod.RESOURCES}
    records=[]; negative_page=0; negative_special=0; negative_cms=0
    for record in source['records']:
        name=record['name']; raw=(RAW/(name+'.macho')).read_bytes()
        actual_external=external if record['resourceSlotSealed'] else {1:external[1]}
        checked=audit(raw,actual_external)
        assert hashlib.sha256(raw).hexdigest()==record['sha256']
        changed=bytearray(raw); changed[4096]^=1
        try: audit(changed,actual_external); raise RuntimeError('Modified page accepted')
        except AssertionError: negative_page+=1
        try: audit(raw,{**actual_external,1:external[1]+b' '}); raise RuntimeError('Modified special material accepted')
        except AssertionError: negative_special+=1
        message=bytearray((RAW/(name+'.cms.der')).read_bytes()); message[-1]^=1
        path=RAW/(name+'.tampered.cms.der'); path.write_bytes(message)
        p=subprocess.run([OPENSSL,'cms','-verify','-binary','-inform','DER','-in',str(path),'-content',str(RAW/(name+'.primary.cd')),'-noverify','-out',str(RAW/(name+'.tampered.out'))],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert p.returncode!=0; negative_cms+=1
        records.append({'name':name,**checked})
    result={'status':'passed','ownedFixturesIndependentlyDecoded':len(records),'records':records,
        'independentActualPageDigests':sum(x['pageDigests'] for x in records),
        'independentActualSpecialDigestsIncludingAbsent':sum(x['specialDigestsIncludingAbsent'] for x in records),
        'rejectedChangedPages':negative_page,'rejectedChangedInfoSpecialMaterial':negative_special,
        'actualOpenSSLRejectedChangedCMSSignatures':negative_cms,'SwiftExecutions':0,
        'limitations':['These are owned original input vectors; this is not an execution of the new Swift signer.','The new Swift calls existing Hash/CMS/Signed verifiers after signing, but SDK execution remains required.']}
    (ROOT/'independent-byte-audit.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2))

if __name__=='__main__': main()
