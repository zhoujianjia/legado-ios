"""Independent Python stdlib ZIP/decompression checks, never a Swift SDK claim."""
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
fixture = ROOT / 'Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialFixture.swift'
raw = fixture.read_bytes()
source = raw.decode()
pattern = r'Bundle\(relativePath: "([^"]+)", identifier: "([^"]+)",\s+infoBase64: """(.*?)""",\s+profileBase64: """(.*?)""",\s+resourcesBase64: """(.*?)""",\s+codeBase64: """(.*?)"""'
bundles = re.findall(pattern, source, re.S)[:3]
assert len(bundles) == 3
files = {}
for relative, identifier, info, profile, resources, code in bundles:
    prefix = 'Payload/Owned.app' + ('' if relative == '.' else '/' + relative)
    for name, value in [('Info.plist', info), ('embedded.mobileprovision', profile), ('_CodeSignature/CodeResources', resources), ('Owned', code)]:
        files[prefix + '/' + name] = base64.b64decode(value)
    files[prefix + '/chapter.txt'] = b'abc'

class DescriptorSink(io.RawIOBase):
    def __init__(self): self.data = bytearray()
    def write(self, data): self.data.extend(data); return len(data)
    def tell(self): return len(self.data)
    def seekable(self): return False

def make_zip(method, descriptors=False):
    sink = DescriptorSink() if descriptors else io.BytesIO()
    with zipfile.ZipFile(sink, 'w', compression=method, allowZip64=False) as archive:
        for path, data in files.items():
            info = zipfile.ZipInfo(path, date_time=(2026, 10, 20, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = method
            archive.writestr(info, data)
    return bytes(sink.data) if descriptors else sink.getvalue()

def without_descriptor_signatures(data):
    end = len(data) - 22
    central = struct.unpack_from('<I', data, end + 16)[0]
    with zipfile.ZipFile(io.BytesIO(data)) as archive: entries = archive.infolist()
    local = bytearray()
    central_bytes = bytearray(data[central:end])
    central_cursor = 0
    for entry in entries:
        old_offset = entry.header_offset
        name, extra = struct.unpack_from('<HH', data, old_offset + 26)
        payload_end = old_offset + 30 + name + extra + entry.compress_size
        assert data[payload_end:payload_end + 4] == b'PK\x07\x08'
        struct.pack_into('<I', central_bytes, central_cursor + 42, len(local))
        local.extend(data[old_offset:payload_end])
        local.extend(data[payload_end + 4:payload_end + 16])
        n, x, c = struct.unpack_from('<HHH', central_bytes, central_cursor + 28)
        central_cursor += 46 + n + x + c
    assert central_cursor == len(central_bytes)
    new_end = bytearray(data[end:])
    struct.pack_into('<I', new_end, 16, len(local))
    return bytes(local + central_bytes + new_end)

def verify(data):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        assert archive.testzip() is None
        entries = archive.infolist()
        assert len(entries) == len(files) == 15
        assert {entry.filename for entry in entries} == set(files)
        descriptor_counts = {'signed': 0, 'unsigned': 0, 'absent': 0}
        for entry in entries:
            assert archive.read(entry) == files[entry.filename]
            offset = entry.header_offset
            n, x = struct.unpack_from('<HH', data, offset + 26)
            start = offset + 30 + n + x
            compressed = data[start:start + entry.compress_size]
            if entry.compress_type == zipfile.ZIP_DEFLATED:
                decoder = zlib.decompressobj(-15)
                plain = decoder.decompress(compressed) + decoder.flush()
                assert decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
            else: plain = compressed
            assert plain == files[entry.filename]
            assert zlib.crc32(plain) == entry.CRC
            assert len(plain) == entry.file_size
            if entry.flag_bits & 8:
                at = start + entry.compress_size
                signed = data[at:at + 4] == b'PK\x07\x08'
                base = at + (4 if signed else 0)
                assert struct.unpack_from('<III', data, base) == (entry.CRC, entry.compress_size, entry.file_size)
                descriptor_counts['signed' if signed else 'unsigned'] += 1
            else: descriptor_counts['absent'] += 1
        return {'entries': len(entries), 'compressedBytes': sum(e.compress_size for e in entries),
                'expandedBytes': sum(e.file_size for e in entries), 'descriptorCounts': descriptor_counts,
                'standardLibraryZipCRCAndReadsPassed': True, 'strictRawDeflateEndAndNoTailPassed': True}

archives = {
    'owned-stored.ipa': make_zip(zipfile.ZIP_STORED),
    'owned-deflate-signed-descriptor.ipa': make_zip(zipfile.ZIP_DEFLATED, descriptors=True),
}
archives['owned-deflate-unsigned-descriptor.ipa'] = without_descriptor_signatures(archives['owned-deflate-signed-descriptor.ipa'])
results = []
(OUT / 'owned-fixtures').mkdir(exist_ok=True)
for name, data in archives.items():
    path = OUT / 'owned-fixtures' / name
    path.write_bytes(data)
    results.append({'path': 'owned-fixtures/' + name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), **verify(data)})

plain = b'owned independent raw-deflate vector'
compressor = zlib.compressobj(wbits=-15)
compressed = compressor.compress(plain) + compressor.flush()
negative = []
for name, data in [('trailing-compressed-data', compressed + b'\x00'), ('truncated-compressed-data', compressed[:-1])]:
    decoder = zlib.decompressobj(-15)
    decoded = decoder.decompress(data) + decoder.flush()
    rejected = not decoder.eof or bool(decoder.unused_data) or bool(decoder.unconsumed_tail)
    assert rejected
    negative.append({'kind': name, 'compressedBase64': base64.b64encode(data).decode(),
        'inputFullyConsumedAndEnded': not rejected, 'rejectedByStrictBoundary': True})

record = {'schema': 1, 'kind': 'independent-owned-IPA-fixtures-and-stdlib-ZIP-validation',
    'swiftExecution': False, 'sdkTestsExecuted': 0,
    'publicCMSFixtureSource': {'path': str(fixture.relative_to(ROOT)).replace('\\', '/'), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()},
    'archives': results, 'negativeRawDeflateBoundaries': negative,
    'notClaimed': ['Swift validator execution', 'Swift ZIP extraction execution', 'new CMS verification', 'Apple signing authority', 'installation or replacement authorization'],
    'privateKeysOrUserArchivesRead': False}
output = json.dumps(record, indent=2).encode() + b'\n'
(OUT / 'fixture-generation.json').write_bytes(output)
print(json.dumps({'ownedArchivesVerifiedByPython': len(results), 'membersPerArchive': 15, 'negativeDeflateBoundaries': len(negative),
    'sdkExecuted': 0, 'recordBytes': len(output), 'recordSHA256': hashlib.sha256(output).hexdigest()}))
