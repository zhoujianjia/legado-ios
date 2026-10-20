"""Owned synthetic Mach-O/CD/CMS vectors. No production parser is called."""
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
OWNED = OUT / "owned"
OWNED.mkdir(exist_ok=True)
PKI = ROOT / ".build/renewal-discovery/cms-profile-step/owned"
OPENSSL = Path("D:/app/Git/usr/bin/openssl.exe")
DATE = 1792463713
INFO = b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>owned.reader</string><key>CFBundleExecutable</key><string>Owned</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>'
RESOURCES = b'owned raw CodeResources bytes; resource envelope intentionally unverified'

def u32(n): return struct.pack(">I", n)
def blob(magic, body): return u32(magic) + u32(len(body) + 8) + body
def tlv(tag, body):
    n = len(body)
    length = bytes([n]) if n < 128 else bytes([0x80 + (n.bit_length() + 7) // 8]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([tag]) + length + body
def seq(*values): return tlv(0x30, b"".join(values))
def aset(*values): return tlv(0x31, b"".join(sorted(values)))
def oid(s):
    arcs = list(map(int, s.split(".")))
    out = bytes([arcs[0] * 40 + arcs[1]])
    for arc in arcs[2:]:
        encoded = [arc & 127]
        arc >>= 7
        while arc:
            encoded.insert(0, 0x80 | (arc & 127)); arc >>= 7
        out += bytes(encoded)
    return tlv(6, out)
def integer(n): return tlv(2, bytes([n]))
def algorithm(s): return seq(oid(s), tlv(5, b""))
SHA = {1: "1.3.14.3.2.26", 2: "2.16.840.1.101.3.4.2.1", 3: "2.16.840.1.101.3.4.2.1", 4: "2.16.840.1.101.3.4.2.2"}
DATA = "1.2.840.113549.1.7.1"
def attr(s, *values): return seq(oid(s), aset(*values))
def digest(kind, data):
    if kind == 1: return hashlib.sha1(data).digest()
    if kind == 2: return hashlib.sha256(data).digest()
    if kind == 3: return hashlib.sha256(data).digest()[:20]
    if kind == 4: return hashlib.sha384(data).digest()
    raise AssertionError(kind)
def node(data, start=0):
    tag, cursor = data[start], start + 1
    length = data[cursor]; cursor += 1
    if length & 128:
        width = length & 127
        length = int.from_bytes(data[cursor:cursor + width], "big"); cursor += width
    end = cursor + length
    return tag, data[start:end], data[cursor:end], end
def children(body):
    result, cursor = [], 0
    while cursor < len(body):
        value = node(body, cursor); result.append(value); cursor = value[3]
    return result

LEAF = (PKI / "leaf.der").read_bytes()
ROOT_CERT = (PKI / "root.der").read_bytes()
certificate = children(node(LEAF)[2])
tbs = children(certificate[0][2])
start = 1 if tbs[0][0] == 0xa0 else 0
ISSUER_SERIAL = seq(tbs[start + 2][1], tbs[start][1])
EMBEDDED = {2: blob(0xfade0c01, u32(0)), 5: blob(0xfade7171, b'<plist version="1.0"><dict/></plist>'), 7: blob(0xfade7172, b'\x30\x00')}

def cms(primary, directories, mode, name, sign):
    attrs = [attr("1.2.840.113549.1.9.3", oid(DATA)), attr("1.2.840.113549.1.9.4", tlv(4, hashlib.sha256(primary).digest()))]
    ordered = sorted(directories, key=lambda value: value[1])
    if mode in ("v1", "both", "v1WrongOrder", "gap"):
        hashes = [digest(kind, raw)[:20] for _, kind, raw in ordered]
        if mode == "v1WrongOrder": hashes.reverse()
        # Unknown dictionary keys are accepted by the original Apple reader.
        value = plistlib.dumps({"cdhashes": hashes, "owned-extra": "preserved"}, fmt=plistlib.FMT_BINARY, sort_keys=True)
        attrs.append(attr("1.2.840.113635.100.9.1", tlv(4, value)))
    if mode in ("v2", "both", "v2Truncated", "v2WrongLength", "v2DuplicateOID", "v2WrongDigest"):
        values = []
        for _, kind, raw in ordered:
            value = digest(kind, raw)
            if mode == "v2WrongLength": value = hashlib.sha256(raw).digest()
            if mode == "v2WrongDigest": value = bytes([value[0] ^ 1]) + value[1:]
            values.append(seq(oid(SHA[kind]), tlv(4, value)))
        attrs.append(attr("1.2.840.113635.100.9.2", *values))
    signed_set = aset(*attrs)
    signature = bytes(256)
    if sign:
        (OWNED / f"{name}.attrs.der").write_bytes(signed_set)
        subprocess.run([str(OPENSSL), "dgst", "-sha256", "-sign", str(PKI / "leaf.key"), "-out", str(OWNED / f"{name}.signature"), str(OWNED / f"{name}.attrs.der")], check=True, capture_output=True)
        signature = (OWNED / f"{name}.signature").read_bytes()
        assert len(signature) == 256
    signer = seq(integer(1), ISSUER_SERIAL, algorithm(SHA[2]), tlv(0xa0, node(signed_set)[2]), algorithm("1.2.840.113549.1.1.1"), tlv(4, signature))
    signed = seq(integer(1), aset(algorithm(SHA[2])), seq(oid(DATA)), tlv(0xa0, b"".join(sorted([LEAF, ROOT_CERT]))), aset(signer))
    return seq(oid("1.2.840.113549.1.7.2"), tlv(0xa0, signed))

def fixture(name, kinds, mode, slots=None, ad_hoc=False):
    slots = slots or [0] + list(range(0x1000, 0x1000 + len(kinds) - 1))
    limit, page, special_count = 173, 6, 7
    material = {1: INFO, 3: RESOURCES, **EMBEDDED}
    code = bytearray((index * 17 + 3) % 256 for index in range(limit))
    code[:64] = bytes(64)
    cpu = 0x01000007 if name == "v2" else 0x0100000c
    struct.pack_into("<IIIIIIII", code, 0, 0xfeedfacf, cpu, 0, 2, 1, 16, 0, 0)
    sizes = [52 + len(b"owned.reader\0OWNEDTEAM\0") + (special_count + 3) * len(digest(kind, b"")) for kind in kinds]
    count = len(kinds) + len(EMBEDDED) + 1
    base_size = 12 + count * 8 + sum(sizes) + sum(map(len, EMBEDDED.values())) + 8
    cms_length = 0
    directories, cms_bytes = [], b""
    for _ in range(4):
        struct.pack_into("<IIII", code, 32, 0x1d, 16, limit, base_size + cms_length)
        directories = []
        for index, (slot, kind) in enumerate(zip(slots, kinds)):
            n = len(digest(kind, b""))
            cd = bytearray(52)
            struct.pack_into(">IIII", cd, 0, 0xfade0c02, sizes[index], 0x20200, 2 if ad_hoc else 0)
            cd.extend(b"owned.reader\0OWNEDTEAM\0")
            struct.pack_into(">IIIII", cd, 16, len(cd) + special_count * n, 52, special_count, 3, limit)
            cd[36:40] = bytes([n, kind, 0, page])
            struct.pack_into(">I", cd, 48, 65)
            for special in range(7, 0, -1): cd.extend(digest(kind, material[special]) if special in material else bytes(n))
            for offset in range(0, limit, 64): cd.extend(digest(kind, code[offset:min(limit, offset + 64)]))
            assert len(cd) == sizes[index]
            directories.append((slot, kind, bytes(cd)))
        loaded = [directories[0]] if mode == "gap" else directories
        cms_bytes = b"" if ad_hoc else cms(directories[0][2], loaded, mode, name, False)
        if len(cms_bytes) == cms_length: break
        cms_length = len(cms_bytes)
    else: raise AssertionError("unstable CMS size")
    if not ad_hoc:
        cms_bytes = cms(directories[0][2], loaded, mode, name, True)
        assert len(cms_bytes) == cms_length
    parts = [(slot, raw) for slot, _, raw in directories] + list(EMBEDDED.items()) + [(0x10000, blob(0xfade0b01, cms_bytes))]
    signature = bytearray(u32(0xfade0cc0) + u32(base_size + cms_length) + u32(count))
    offset = 12 + count * 8
    for slot, part in parts: signature.extend(u32(slot) + u32(offset)); offset += len(part)
    for _, part in parts: signature.extend(part)
    assert len(signature) == base_size + cms_length
    entire = code + signature
    (OWNED / f"{name}.macho").write_bytes(entire)
    result = {"prefix": base64.b64encode(code[:64]).decode(), "signature": base64.b64encode(signature).decode(), "fileSHA256": hashlib.sha256(entire).hexdigest(), "directories": [{"slot": slot, "hashType": kind, "rawCodeDirectorySHA256": hashlib.sha256(raw).hexdigest(), "cdhash": digest(kind, raw)[:20].hex(), "fullCDHash": digest(kind, raw).hex()} for slot, kind, raw in directories]}
    if not ad_hoc:
        (OWNED / f"{name}.cms").write_bytes(cms_bytes)
        (OWNED / f"{name}.primary.cd").write_bytes(directories[0][2])
        command = [str(OPENSSL), "cms", "-verify", "-binary", "-inform", "DER", "-in", str(OWNED / f"{name}.cms"), "-content", str(OWNED / f"{name}.primary.cd"), "-CAfile", str(PKI / "root.pem"), "-purpose", "any", "-attime", str(DATE), "-out", str(OWNED / f"{name}.verified.cd")]
        verified = subprocess.run(command, check=True, capture_output=True, text=True)
        assert (OWNED / f"{name}.verified.cd").read_bytes() == directories[0][2]
        result["opensslDetachedVerification"] = verified.stderr.strip()
        # Independently show signature depends on raw primary bytes.
        changed = bytearray(directories[0][2]); changed[52] ^= 1
        (OWNED / f"{name}.changed.cd").write_bytes(changed)
        command[command.index(str(OWNED / f"{name}.primary.cd"))] = str(OWNED / f"{name}.changed.cd")
        command[-1] = str(OWNED / f"{name}.rejected.cd")
        rejected = subprocess.run(command, capture_output=True, text=True)
        assert rejected.returncode != 0
        result["opensslChangedPrimaryRejected"] = True
    return result

cases = [("legacy", [1, 2], "legacy"), ("v1", [1, 4, 2], "v1"), ("v2", [1, 4, 2], "v2"), ("both", [1, 4, 2], "both"), ("v2Truncated", [3], "v2Truncated"), ("v2WrongLength", [3], "v2WrongLength"), ("v2DuplicateOID", [2, 3], "v2DuplicateOID"), ("v1WrongOrder", [1, 4, 2], "v1WrongOrder"), ("v2WrongDigest", [1, 4, 2], "v2WrongDigest"), ("gap", [1, 2], "gap"), ("adHoc", [1, 2], "legacy"), ("duplicateHashType", [2, 2], "legacy")]
fixtures = {name: fixture(name, kinds, mode, slots=[0, 0x1001] if name == "gap" else None, ad_hoc=name == "adHoc") for name, kinds, mode in cases}
record = {"producer": "Python hashlib/plistlib/struct independent layout + OpenSSL actual owned RSA signature verification; no Swift or SDK", "validationUnixTime": DATE, "openssl": subprocess.run([str(OPENSSL), "version"], capture_output=True, text=True, check=True).stdout.strip(), "fixtures": fixtures, "limitations": ["Synthetic generic test anchors only; not Apple authority", "CodeResources content digests only; no resource tree validation", "No real app/IPA/account/device inputs", "SDK executions: 0"]}
(OUT / "independent-owned-vectors.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8", newline="\n")
lines = ['import Foundation', '', '/// Independently generated owned wire fixtures; all CMS payloads were verified', '/// by OpenSSL against synthetic generic anchors before embedding. No private key.', 'enum SelfRenewalSignedCodeFixture {', '    enum Failure: Error { case missingFixture }', '    static let info = Data(#"' + INFO.decode() + '"#.utf8)', '    static let resources = Data("' + RESOURCES.decode() + '".utf8)', '    static let truncatedFullHashHex = "' + fixtures["v2Truncated"]["directories"][0]["fullCDHash"] + '"', '    static func data(_ name: String) throws -> Data {', '        guard let fixture = fixtures[name], let prefix = Data(base64Encoded: fixture.0),', '              let signature = Data(base64Encoded: fixture.1) else { throw Failure.missingFixture }', '        var bytes = Data((0..<173).map { UInt8(($0 * 17 + 3) % 256) })', '        bytes.replaceSubrange(0..<64, with: prefix)', '        bytes.append(signature)', '        return bytes', '    }', '    private static let fixtures: [String: (String, String)] = [']
for name, value in fixtures.items(): lines += [f'        "{name}": ("{value["prefix"]}",', f'            "{value["signature"]}"),']
lines += ['    ]', '}', '']
(ROOT / "Tests/iOS/yuedu appTests/SelfRenewalSignedCodeFixture.swift").write_text("\n".join(lines), encoding="utf-8", newline="\n")
print(json.dumps({"ownedFixtures": len(fixtures), "opensslValidDetachedCMS": sum("opensslDetachedVerification" in f for f in fixtures.values()), "opensslChangedPrimaryRejected": sum(f.get("opensslChangedPrimaryRejected", False) for f in fixtures.values()), "swiftOrSDKExecution": 0}))
