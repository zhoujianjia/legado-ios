"""Independent owned fixture construction. Never copies private keys into Swift.

All generated keys stay below this ignored stage's .private directory. OpenSSL
performs the actual original signatures and verifies their detached CMS. This
does not execute or validate the new Swift signer on Windows.
"""
from pathlib import Path
import base64, datetime, hashlib, json, plistlib, struct, subprocess

HERE = Path(__file__).resolve().parent
RAW = HERE.parent / "owned-vectors"
PRIVATE = HERE.parent / ".private"
OPENSSL = "D:/app/Git/usr/bin/openssl.exe"
RAW.mkdir(exist_ok=True)
PRIVATE.mkdir(exist_ok=True)

def openssl(*args):
    result = subprocess.run([OPENSSL, *map(str, args)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result.stdout

def tlv(tag, body):
    length = len(body)
    enc = bytes([length]) if length < 128 else bytes([0x80 | ((length.bit_length() + 7) // 8)]) + length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([tag]) + enc + body

def seq(*values): return tlv(0x30, b"".join(values))
def der_set(*values): return tlv(0x31, b"".join(sorted(values)))
def oid(hexadecimal): return tlv(6, bytes.fromhex(hexadecimal))
def integer(value):
    raw = value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")
    return tlv(2, (b"\0" if raw[0] & 128 else b"") + raw)
def attr(value, *values): return seq(value, der_set(*values))
def children(encoded):
    def one(data, offset):
        start = offset; tag = data[offset]; offset += 1; length = data[offset]; offset += 1
        if length & 128:
            count = length & 127; length = int.from_bytes(data[offset:offset+count], "big"); offset += count
        body = data[offset:offset+length]
        assert len(body) == length
        return tag, body, data[start:offset+length], offset+length
    _, body, _, end = one(encoded, 0); assert end == len(encoded)
    result = []; offset = 0
    while offset < len(body):
        tag, content, full, offset = one(body, offset); result.append((tag, content, full))
    return result

DATA = oid("2a864886f70d010701")
SIGNED_DATA = oid("2a864886f70d010702")
SHA256_OID = oid("608648016503040201")
SHA256 = seq(SHA256_OID, tlv(5, b""))
DIGEST_OIDS = {1: oid("2b0e03021a"), 2: SHA256_OID, 3: SHA256_OID, 4: oid("608648016503040202")}

def digest(value, kind):
    raw = hashlib.sha1(value).digest() if kind == 1 else hashlib.sha384(value).digest() if kind == 4 else hashlib.sha256(value).digest()
    return raw[:20] if kind == 3 else raw

def wrapper(magic, body): return struct.pack(">II", magic, len(body)+8) + body
def superblob(blobs):
    start = 12 + len(blobs)*8; index = bytearray(); payload = bytearray()
    for slot, raw in sorted(blobs.items()):
        index += struct.pack(">II", slot, start + len(payload)); payload += raw
    return struct.pack(">III", 0xfade0cc0, start+len(payload), len(blobs)) + index + payload

def der_property(value):
    if isinstance(value, dict):
        return tlv(0x70, integer(1) + tlv(0xb0, b"".join(sorted(seq(tlv(0x0c, k.encode()), der_property(v)) for k,v in value.items()))))
    if isinstance(value, str): return tlv(0x0c, value.encode())
    if isinstance(value, list): return seq(*(der_property(v) for v in value))
    raise AssertionError(type(value))

IDENTIFIER = "org.owned.controlled-resign"
TEAM = "OWNEDTEAM"
ENTITLEMENTS = {"application-identifier": "OWNEDPREFIX."+IDENTIFIER,
                "com.apple.developer.team-identifier": TEAM,
                "keychain-access-groups": ["OWNEDPREFIX."+IDENTIFIER]}
INFO = plistlib.dumps({"CFBundleIdentifier":IDENTIFIER,"CFBundleExecutable":"OwnedFixture"}, fmt=plistlib.FMT_XML, sort_keys=True)
RESOURCES = plistlib.dumps({"files2":{},"rules2":{"^.*":True}}, fmt=plistlib.FMT_XML, sort_keys=True)
EMBEDDED = {2:struct.pack(">III",0xfade0c01,12,0),
            5:wrapper(0xfade7171, plistlib.dumps(ENTITLEMENTS,fmt=plistlib.FMT_XML,sort_keys=True)),
            7:wrapper(0xfade7172, der_property(ENTITLEMENTS))}

def segment(name, vm, vm_size, file_offset, file_size, protections, section=False):
    value = struct.pack("<II16sQQQQIIII",0x19,152 if section else 72,name.encode().ljust(16,b"\0"),vm,vm_size,file_offset,file_size,7 if protections else 0,protections,int(section),0)
    if section:
        value += struct.pack("<16s16sQQIIIIIIII",b"__text".ljust(16,b"\0"),b"__TEXT".ljust(16,b"\0"),vm+4096,256,4096,2,0,0,0x80000400,0,0,0)
    return value

def prefix(capacity):
    base = 0x100000000
    commands = [segment("__PAGEZERO",0,base,0,0,0),
                segment("__TEXT",base,16384,0,16384,5,True),
                segment("__LINKEDIT",base+16384,((capacity+16383)//16384)*16384,16384,capacity,1),
                struct.pack("<IIII",0x1d,16,16384,capacity),
                struct.pack("<IIQQ",0x80000028,24,4096,0),
                struct.pack("<IIIIII",0x32,24,2,0x110000,0x110000,0),
                struct.pack("<II16s",0x1b,24,b"OwnedSigningUUID")]
    header = struct.pack("<IIIIIIII",0xfeedfacf,0x100000c,0,2,len(commands),sum(map(len,commands)),0x200085,0)
    raw = bytearray((header+b"".join(commands)).ljust(16384,b"\0")); raw[4096:4352]=bytes.fromhex("c0035fd6")*64
    return bytes(raw)

def directory(code, kind, resources=True):
    size={1:20,2:32,3:20,4:48}[kind]; head=88; strings=IDENTIFIER.encode()+b"\0"+TEAM.encode()+b"\0"
    count=(len(code)+4095)//4096; hash_offset=head+len(strings)+7*size
    raw=bytearray(head); struct.pack_into(">9I",raw,0,0xfade0c02,hash_offset+count*size,0x20400,0,hash_offset,head,7,count,len(code))
    raw[36:40]=bytes([size,kind,0,12]); struct.pack_into(">I",raw,48,head+len(IDENTIFIER.encode())+1)
    struct.pack_into(">QQQ",raw,64,0,16384,1)
    raw += strings
    materials={1:INFO,**({3:RESOURCES} if resources else {}),**EMBEDDED}
    raw += b"".join(digest(materials[slot],kind) if slot in materials else b"\0"*size for slot in range(7,0,-1))
    raw += b"".join(digest(code[i:i+4096],kind) for i in range(0,len(code),4096))
    return bytes(raw)

def create_identity(name, ec=False):
    key=PRIVATE/(name+".key.pem"); cert=RAW/(name+".cert.pem"); der=RAW/(name+".cert.der")
    if not key.exists():
        openssl("genpkey","-algorithm","EC" if ec else "RSA", "-pkeyopt","ec_paramgen_curve:P-384" if ec else "rsa_keygen_bits:2048","-out",key)
    config=PRIVATE/(name+".request.cnf")
    if not config.exists() or not cert.exists():
        config.write_text("[req]\nprompt=no\ndistinguished_name=dn\n[dn]\nCN="+name+"\n",encoding="ascii")
        openssl("req","-new","-x509","-config",config,"-key",key,"-sha256","-days","3650","-subj","/CN="+name,
                "-addext","basicConstraints=critical,CA:TRUE","-addext","keyUsage=critical,digitalSignature,keyCertSign","-out",cert)
    openssl("x509","-in",cert,"-outform","DER","-out",der)
    return key,cert,der.read_bytes(),ec

def sign_cms(raw_directories, kinds, identity, name, v2=True):
    key,certificate,cert,ec=identity
    cert_fields=children(children(cert)[0][2]); base=1 if cert_fields[0][0]==0xa0 else 0
    sid=seq(cert_fields[base+2][2],cert_fields[base][2])
    ordered=sorted(zip(kinds,raw_directories)); hashes=[digest(cd,kind) for kind,cd in ordered]
    v1=plistlib.dumps({"cdhashes":[d[:20] for d in hashes]},fmt=plistlib.FMT_XML,sort_keys=True)
    attrs=[attr(oid("2a864886f70d010903"),DATA),
        attr(oid("2a864886f70d010904"),tlv(4,hashlib.sha256(raw_directories[0]).digest())),
        attr(oid("2a864886f763640901"),tlv(4,v1))]
    if v2: attrs.append(attr(oid("2a864886f763640902"),*(seq(DIGEST_OIDS[k],tlv(4,d)) for (k,_),d in zip(ordered,hashes))))
    attributes=der_set(*attrs)
    attr_path=RAW/(name+".attrs.der"); sig_path=RAW/(name+".signature.bin"); attr_path.write_bytes(attributes)
    openssl("dgst","-sha256","-sign",key,"-out",sig_path,attr_path)
    signature_algorithm=seq(oid("2a8648ce3d040302")) if ec else seq(oid("2a864886f70d010101"),tlv(5,b""))
    signer=seq(integer(1),sid,SHA256,tlv(0xa0,children(attributes)[0][2]+b"".join(v[2] for v in children(attributes)[1:])),signature_algorithm,tlv(4,sig_path.read_bytes()))
    message=seq(SIGNED_DATA,tlv(0xa0,seq(integer(1),der_set(SHA256),seq(DATA),tlv(0xa0,cert),der_set(signer))))
    cms_path=RAW/(name+".cms.der"); cd_path=RAW/(name+".primary.cd"); cms_path.write_bytes(message); cd_path.write_bytes(raw_directories[0])
    verified=RAW/(name+".verified.cd")
    openssl("cms","-verify","-binary","-inform","DER","-in",cms_path,"-content",cd_path,"-CAfile",certificate,"-purpose","any","-out",verified)
    assert verified.read_bytes()==raw_directories[0]
    return message

def main():
    rsa=create_identity("OwnedOriginalRSA"); ec=create_identity("OwnedOriginalEC",True)
    fixtures={}; records=[]
    for name,kinds,identity,capacity in [("sha256",[2],rsa,8192),("agile",[1,2],rsa,8192),
            ("truncated",[3],rsa,8192),("sha384",[4],rsa,8192),("ecOriginal",[2],ec,8192),("largeTail",[2],rsa,32768),
            ("oidCollision",[2,3],rsa,8192),("noResources",[2],rsa,8192)]:
        code=prefix(capacity); cds=[directory(code,kind,resources=name!="noResources") for kind in kinds]; cms=sign_cms(cds,kinds,identity,name,v2=name!="oidCollision")
        slots={0:cds[0],**{0x1000+i:cd for i,cd in enumerate(cds[1:])},**EMBEDDED,0x10000:wrapper(0xfade0b01,cms)}
        signature=superblob(slots); assert len(signature)<=capacity
        raw=code+signature.ljust(capacity,b"\0"); (RAW/(name+".macho")).write_bytes(raw)
        fixtures[name]=raw
        records.append({"name":name,"hashTypes":kinds,"originalKeyType":"EC384" if identity[3] else "RSA2048",
            "bytes":len(raw),"sha256":hashlib.sha256(raw).hexdigest(),"detachedCMSOpenSSLVerified":True,
            "rawCodeDirectorySHA256":[hashlib.sha256(cd).hexdigest() for cd in cds],"hashAgilityV2":name!="oidCollision","resourceSlotSealed":name!="noResources","newSwiftSignerExecuted":False})
    # Public owned inputs only. Neither private DER nor PEM is embedded here.
    values={"originalRSAAnchor":rsa[2],"originalECAnchor":ec[2],"info":INFO,"resources":RESOURCES,**fixtures}
    lines=["import Foundation","","/// Independently OpenSSL-signed owned bytes; contains no private key.","enum SelfRenewalControlledSigningFixture {"]
    for name,raw in values.items():
        text=base64.b64encode(raw).decode(); lines += [f"    static let {name}Base64 = \"\"\""]+["        "+text[i:i+112] for i in range(0,len(text),112)]+["        \"\"\""]
    lines += ["    static func data(_ encoded: String) throws -> Data {", "        guard let value = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {", "            throw CocoaError(.coderInvalidValue)", "        }", "        return value", "    }", "}", ""]
    (HERE/"SelfRenewalControlledSigningFixture.swift").write_text("\n".join(lines),encoding="utf-8")
    (HERE.parent/"independent-original-fixture-audit.json").write_text(json.dumps({"fixtureCount":len(records),"actualOpenSSLDetachedCMSVerifications":len(records),"records":records,"privateKeysIncludedInSwift":False,"SwiftExecutions":0},indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"fixtures":len(records),"actualOpenSSLVerifications":len(records),"SwiftExecutions":0}))

if __name__ == "__main__": main()
