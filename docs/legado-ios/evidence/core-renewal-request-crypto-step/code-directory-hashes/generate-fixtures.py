import base64
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
INFO = b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>owned.reader</string><key>CFBundleExecutable</key><string>Owned</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>'
RESOURCES = b'owned raw CodeResources bytes; resource envelope intentionally unverified'
def u32(value): return struct.pack('>I', value)
def wrapped(magic, payload): return u32(magic) + u32(8 + len(payload)) + payload
EMBEDDED = {2: wrapped(0xfade0c01, u32(0)),
            5: wrapped(0xfade7171, b'<plist version="1.0"><dict/></plist>'),
            7: wrapped(0xfade7172, b'\x30\x00')}
def digest(kind, data):
    return {1: lambda: hashlib.sha1(data).digest(), 2: lambda: hashlib.sha256(data).digest(),
            3: lambda: hashlib.sha256(data).digest()[:20], 4: lambda: hashlib.sha384(data).digest()}[kind]()
def fixture(kinds, *, limit=173, page=6, cpu=0x0100000c, bare=False, special_count=7):
    materials = {} if bare else {1: INFO, 3: RESOURCES, **EMBEDDED}
    embedded = {} if bare else EMBEDDED
    special_count = 0 if bare else special_count
    slots = 1 if page == 0 else (limit - 1) // (1 << page) + 1
    code = bytearray((index * 17 + 3) % 256 for index in range(limit))
    code[:64] = bytes(64)
    struct.pack_into('<IIIIIIII', code, 0, 0xfeedfacf, cpu, 0, 2, 1, 16, 0, 0)
    count = len(kinds) + len(embedded) + 1
    sizes = [52 + len(b'owned.reader\0OWNEDTEAM\0') + (special_count + slots) * len(digest(kind, b'')) for kind in kinds]
    total_signature = 12 + count * 8 + sum(sizes) + sum(map(len, embedded.values())) + 8
    struct.pack_into('<IIII', code, 32, 0x1d, 16, limit, total_signature)
    directories = []
    vector = []
    for index, kind in enumerate(kinds):
        length = len(digest(kind, b''))
        directory = bytearray(52)
        struct.pack_into('>III', directory, 0, 0xfade0c02, sizes[index], 0x20200)
        struct.pack_into('>I', directory, 12, 2)
        directory.extend(b'owned.reader\0OWNEDTEAM\0')
        hash_offset = len(directory) + special_count * length
        struct.pack_into('>IIIII', directory, 16, hash_offset, 52, special_count, slots, limit)
        directory[36:40] = bytes([length, kind, 0, page])
        struct.pack_into('>I', directory, 48, 65)
        specials = {slot: digest(kind, value) for slot, value in materials.items()}
        for slot in range(special_count, 0, -1): directory.extend(specials.get(slot, bytes(length)))
        pages = []
        page_bytes = limit if page == 0 else 1 << page
        for offset in range(0, limit, page_bytes):
            hashed = digest(kind, code[offset:min(limit, offset + page_bytes)])
            pages.append(hashed.hex())
            directory.extend(hashed)
        assert len(directory) == sizes[index]
        slot = 0 if index == 0 else 0x1000 + index - 1
        directories.append((slot, bytes(directory)))
        vector.append({'slot': slot, 'hashType': kind, 'hashOffset': hash_offset,
                       'codePageDigests': pages,
                       'specialSlotDigests': {str(slot): value.hex() for slot, value in specials.items()}})
    parts = [*directories, *embedded.items(), (0x10000, wrapped(0xfade0b01, b''))]
    signature = bytearray(u32(0xfade0cc0) + u32(total_signature) + u32(count))
    offset = 12 + count * 8
    for slot, part in parts:
        signature.extend(u32(slot) + u32(offset)); offset += len(part)
    for _, part in parts: signature.extend(part)
    assert len(signature) == total_signature
    return {'limit': limit, 'prefixBase64': base64.b64encode(code[:64]).decode(),
            'signatureBase64': base64.b64encode(signature).decode(),
            'fileSHA256': hashlib.sha256(code + signature).hexdigest(), 'directories': vector}
fixtures = {f'thin{kind}': fixture([kind]) for kind in [1, 2, 3, 4]}
fixtures['infinite'] = fixture([2], page=0)
fixtures['alternate'] = fixture([2, 4])
fixtures['largePage'] = fixture([2], limit=131089, page=17)
fixtures['secondCPU'] = fixture([4], cpu=0x01000007)
fixtures['bare'] = fixture([2], bare=True)
fixtures['unsupportedSpecial'] = fixture([2], special_count=12)
record = {'producer': 'Python stdlib hashlib + independently constructed Apple wire layouts; no Swift implementation called',
          'infoBase64': base64.b64encode(INFO).decode(), 'resourcesBase64': base64.b64encode(RESOURCES).decode(),
          'abcDigests': {str(kind): digest(kind, b'abc').hex() for kind in [1,2,3,4]},
          'fixtures': fixtures}
(OUT / 'independent-digest-vectors.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8', newline='\n')
lines = ['    private static let fixtures: [String: Fixture] = [']
for name, value in fixtures.items():
    lines.append(f'        "{name}": Fixture(limit: {value["limit"]}, prefix: "{value["prefixBase64"]}",')
    lines.append(f'            signature: "{value["signatureBase64"]}"),')
lines.append('    ]')
(OUT / 'fixture-declarations.swift').write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
print(json.dumps({'fixtures': len(fixtures), 'algorithms': 4, 'swiftOrSDKExecution': 0}))
