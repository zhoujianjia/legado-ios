from pathlib import Path
import base64, hashlib, hmac, json, plistlib, re, struct
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

R = Path('F:/yuedu-reader')
S = R / '.build/s2-authenticated-spd-challenge-step'
P = 'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift'
original = (R/P).read_text(encoding='utf-8-sig')
encoded = re.findall(r'static let base64 = "([A-Za-z0-9+/=]{500,})"', original.split('private enum Vectors {', 1)[1])
assert len(encoded) == 1
vectors = json.loads(base64.b64decode(encoded[0]))['appleDerived']
assert len(vectors) == 2
def mac(key, data): return hmac.new(key, data, hashlib.sha256).digest()
def prefix(data): return struct.pack('<I', len(data)) + data
def negotiation(v, spd):
    sc = bytes.fromhex(v['sc'])
    transcript = ('s2k,s2k_fo||'+v['protocol']+'|').encode() + prefix(spd) + b'|' + prefix(sc) + b'|'
    return mac(mac(bytes.fromhex(v['K']), b'HMAC key:'), hashlib.sha256(transcript).digest())
def cipher(v):
    k = bytes.fromhex(v['K'])
    return Cipher(algorithms.AES(mac(k, b'extra data key:')), modes.CBC(mac(k, b'extra data iv:')[:16]))
def decrypt(v, spd):
    dec = cipher(v).decryptor(); padded = dec.update(spd)+dec.finalize()
    n = padded[-1]; assert 1 <= n <= 16 and padded[-n:] == bytes([n])*n
    return padded[:-n]
changes = {
    'manual': {'status-code': 409},
    'trusted': {'status-code': 409, 'url': 'trustedDeviceSecondaryAuth'},
    'normal': {'status-code': 200},
    'sms': {'status-code': 409, 'url': 'secondaryAuth'},
    'absolute': {'status-code': 409, 'url': 'https://untrusted.invalid/collect'},
    'empty': {'status-code': 409, 'url': ''},
    'typedURL': {'status-code': 409, 'url': 1},
    'textCode': {'status-code': '409'},
    'boolCode': {'status-code': True},
    'unexpected': {'status-code': 403},
    'dangling': {'url': 'trustedDeviceSecondaryAuth'},
}
records = []
checks = []
for v in vectors:
    assert hmac.compare_digest(negotiation(v, bytes.fromhex(v['spd'])), bytes.fromhex(v['np']))
    baseline = plistlib.loads(decrypt(v, bytes.fromhex(v['spd'])))
    assert set(baseline) == {'adsid', 'GsIdmsToken', 'sk', 'c'}
    for name, fields in changes.items():
        plain = plistlib.dumps(dict(baseline, **fields), fmt=plistlib.FMT_XML, sort_keys=True)
        n = 16-len(plain)%16; padded = plain+bytes([n])*n
        enc = cipher(v).encryptor(); sealed = enc.update(padded)+enc.finalize()
        np = negotiation(v, sealed)
        assert np != bytes.fromhex(v['np'])
        assert decrypt(v, sealed) == plain
        assert plistlib.loads(decrypt(v, sealed)) == dict(baseline, **fields)
        # All newly sealed variants must fail the original negotiation MAC.
        assert not hmac.compare_digest(negotiation(v, sealed), bytes.fromhex(v['np']))
        records.append(dict(protocol=v['protocol'], name=name, spd=sealed.hex(), np=np.hex()))
        checks.append(dict(protocol=v['protocol'], name=name, spdBytes=len(sealed),
                           plainSHA256=hashlib.sha256(plain).hexdigest(),
                           spdSHA256=hashlib.sha256(sealed).hexdigest(),
                           negotiationSHA256=hashlib.sha256(np).hexdigest(),
                           roundTrip=True, staleNegotiationRejected=True))
payload = json.dumps(records, ensure_ascii=True, separators=(',', ':')).encode()
(S/'owned-spd-fixtures.json').write_bytes(payload)
(S/'owned-spd-fixtures.base64').write_bytes(base64.b64encode(payload))
result = dict(schema=1, fixtureOnly=True, actualSwiftExecutions=0,
    description='Owned/public existing SRP session vectors, independently AES-CBC sealed and HMAC negotiation recomputed; no real credentials, no network.',
    input=dict(path=P, bytes=len((R/P).read_bytes()),sha256=hashlib.sha256((R/P).read_bytes()).hexdigest()),
    fixture=dict(path=str((S/'owned-spd-fixtures.json').relative_to(R)),bytes=len(payload),sha256=hashlib.sha256(payload).hexdigest()),
    protocols=2, variantsPerProtocol=len(changes), checks=checks)
(S/'owned-spd-fixtures-reference-v1.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n',encoding='utf-8', newline='\n')
print(json.dumps(dict(protocols=2, variants=len(records), allRoundTrips=True, allStaleNegotiationsRejected=True, actualSwiftExecutions=0)))
