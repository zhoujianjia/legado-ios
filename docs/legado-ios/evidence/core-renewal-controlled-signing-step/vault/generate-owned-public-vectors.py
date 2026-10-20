"""Ephemeral Python PKI, public outputs only. Never executes Swift or Keychain."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa

OUT = Path(__file__).resolve().parent
RAW = OUT / 'owned-public-vectors'
RAW.mkdir(exist_ok=True)
OPENSSL = 'D:/app/Git/usr/bin/openssl.exe'
DATE = datetime.fromtimestamp(1_792_540_800, timezone.utc)

def tlv(tag, body):
    size = len(body)
    length = bytes([size]) if size < 128 else bytes([0x80 | ((size.bit_length() + 7) // 8)]) + size.to_bytes((size.bit_length() + 7) // 8, 'big')
    return bytes([tag]) + length + body
def seq(*values): return tlv(0x30, b''.join(values))
def oid(value): return tlv(6, bytes.fromhex(value))
def integer(value):
    raw = value.to_bytes(max(1, (value.bit_length() + 7) // 8), 'big')
    return tlv(2, (b'\x00' if raw[0] & 128 else b'') + raw)
def public_bytes(key):
    public = key.public_key()
    return public.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint) if isinstance(public, ec.EllipticCurvePublicKey) else public.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.PKCS1)
def name(key): return seq(tlv(0x31, seq(oid('550403'), tlv(0x0c, ('Owned Runtime ' + hashlib.sha256(public_bytes(key)).hexdigest()[:16]).encode()))))
def algorithm(key): return seq(oid('2a8648ce3d040302')) if isinstance(key, ec.EllipticCurvePrivateKey) else seq(oid('2a864886f70d01010b'), tlv(5, b''))
def sign(key, content): return key.sign(content, ec.ECDSA(hashes.SHA256())) if isinstance(key, ec.EllipticCurvePrivateKey) else key.sign(content, padding.PKCS1v15(), hashes.SHA256())
def time(date): return tlv(0x17, date.strftime('%y%m%d%H%M%SZ').encode())
def certificate(key, issuer=None):
    issuer_key = issuer or key
    is_root = issuer is None
    public_algorithm = seq(oid('2a8648ce3d0201'), oid('2a8648ce3d030107')) if isinstance(key, ec.EllipticCurvePrivateKey) else seq(oid('2a864886f70d010101'), tlv(5, b''))
    spki = seq(public_algorithm, tlv(3, b'\0' + public_bytes(key)))
    constraints = seq(oid('551d13'), tlv(1, b'\xff'), tlv(4, seq(tlv(1, b'\xff')) if is_root else seq()))
    usage = seq(oid('551d0f'), tlv(1, b'\xff'), tlv(4, tlv(3, b'\x02\x84' if is_root else b'\x07\x80')))
    tbs = seq(tlv(0xa0, integer(2)), integer(1 if is_root else 2), algorithm(issuer_key), name(issuer_key),
        seq(time(DATE - timedelta(hours=1)), time(DATE + timedelta(days=30))), name(key), spki, tlv(0xa3, seq(constraints, usage)))
    return seq(tbs, algorithm(issuer_key), tlv(3, b'\0' + sign(issuer_key, tbs)))

def cms(content, issuer_key, issuer_certificate):
    digest = seq(oid('608648016503040201'), tlv(5, b''))
    signer = seq(integer(1), seq(name(issuer_key), integer(1)), digest, algorithm(issuer_key), tlv(4, sign(issuer_key, content)))
    signed = seq(integer(1), tlv(0x31, digest), seq(oid('2a864886f70d010701'), tlv(0xa0, tlv(4, content))),
        tlv(0xa0, issuer_certificate), tlv(0x31, signer))
    return seq(oid('2a864886f70d010702'), tlv(0xa0, signed))
def der_value(value):
    if isinstance(value, dict): return tlv(0x31, b''.join(sorted(seq(tlv(0x0c, key.encode()), der_value(item)) for key, item in value.items())))
    if isinstance(value, list): return seq(*(der_value(item) for item in value))
    if isinstance(value, bytes): return tlv(4, value)
    if isinstance(value, str): return tlv(0x0c, value.encode())
    if isinstance(value, datetime): return time(value)
    if isinstance(value, bool): return tlv(1, b'\xff' if value else b'\0')
    if isinstance(value, int): return integer(value)
    raise TypeError(type(value))
def run(*args, succeeds=True):
    result = subprocess.run([OPENSSL, *map(str, args)], capture_output=True)
    assert (result.returncode == 0) == succeeds, result.stderr.decode(errors='replace')
    return result
def write(name, data):
    path = RAW / name; path.write_bytes(data)
    return {'path': 'owned-public-vectors/' + name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

# The private objects never leave memory and private_bytes/export APIs are not
# called. Only public certificate/key encodings and signatures are persisted.
root_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ec_key = ec.generate_private_key(ec.SECP256R1())
root = certificate(root_key)
leaf = certificate(leaf_key, issuer=root_key)
ec_root = certificate(ec_key)
outputs = []
for label, cert in [('root', root), ('leaf', leaf), ('ec-root', ec_root)]:
    parsed = x509.load_der_x509_certificate(cert)
    outputs.append(write(label + '.cert.der', cert))
    outputs.append(write(label + '.cert.pem', parsed.public_bytes(serialization.Encoding.PEM)))
    assert parsed.not_valid_before_utc <= DATE < parsed.not_valid_after_utc
root_public = x509.load_der_x509_certificate(root).public_key()
root_public.verify(x509.load_der_x509_certificate(leaf).signature,
    x509.load_der_x509_certificate(leaf).tbs_certificate_bytes, padding.PKCS1v15(), hashes.SHA256())
assert x509.load_der_x509_certificate(leaf).public_key().public_numbers() == leaf_key.public_key().public_numbers()
assert root_key.public_key().public_numbers() != leaf_key.public_key().public_numbers()
certificate_checks = []
for label, ca in [('leaf', 'root'), ('ec-root', 'ec-root')]:
    result = run('verify', '-attime', int(DATE.timestamp()), '-CAfile', RAW / (ca + '.cert.pem'), RAW / (label + '.cert.pem'))
    (RAW / (label + '.verify.log')).write_bytes(result.stdout + result.stderr)
    certificate_checks.append({'certificate': label, 'exitCode': result.returncode, 'explicitAnchor': ca})

cms_checks = []
for index, identifier in enumerate(['test.owned.reader', 'test.owned.reader.share', 'test.owned.reader.widget']):
    properties = {'UUID': f'11111111-2222-3333-4444-{index:012d}', 'CreationDate': DATE - timedelta(seconds=60),
        'ExpirationDate': DATE + timedelta(hours=1), 'TeamIdentifier': ['FIXTURE123'],
        'ApplicationIdentifierPrefix': ['OLDPREFIX'], 'DeveloperCertificates': [hashlib.sha256(leaf).digest()],
        'Entitlements': {'application-identifier': 'OLDPREFIX.' + identifier,
            'com.apple.developer.team-identifier': 'FIXTURE123',
            'com.apple.security.application-groups': ['group.test.owned.reader'],
            'keychain-access-groups': ['OLDPREFIX.' + identifier, 'OLDPREFIX.shared'], 'get-task-allow': True}}
    inner_content = der_value(properties)
    inner = cms(inner_content, root_key, root)
    outer_content = plistlib.dumps({'DER-Encoded-Profile': inner}, fmt=plistlib.FMT_XML)
    outer = cms(outer_content, root_key, root)
    for layer, content, envelope in [('inner', inner_content, inner), ('outer', outer_content, outer)]:
        label = str(index) + '-' + layer
        outputs.append(write(label + '.cms.der', envelope))
        outputs.append(write(label + '.content', content))
        result = run('cms', '-verify', '-binary', '-inform', 'DER', '-in', RAW / (label + '.cms.der'), '-noverify', '-out', RAW / (label + '.verified'))
        assert (RAW / (label + '.verified')).read_bytes() == content
        cms_checks.append({'envelope': label, 'exitCode': result.returncode, 'contentMatches': True,
                           'verificationScope': 'Actual CMS signature only; no Apple or profile authority'})
tampered = bytearray(outer); tampered[-1] ^= 1
outputs.append(write('tampered.cms.der', tampered))
result = run('cms', '-verify', '-binary', '-inform', 'DER', '-in', RAW / 'tampered.cms.der', '-noverify', '-out', RAW / 'tampered.verified', succeeds=False)
record = {'schema': 1, 'kind': 'independent-owned-public-PKI-and-double-CMS-vectors', 'swiftOrKeychainExecution': False,
    'sdkMethodsExecuted': 0, 'privateKeyExports': 0, 'privateKeyFiles': 0, 'accountConnections': 0,
    'validationDate': DATE.isoformat(), 'certificateTrustChecks': certificate_checks, 'cmsSignatureChecks': cms_checks,
    'tamperedCMSRejected': result.returncode != 0, 'outputs': outputs,
    'notClaimed': ['Swift PKI helper execution', 'Swift vault execution', 'SecKey Keychain persistence', 'Apple account/provisioning purpose', 'remote revocation', 'installation authorization']}
raw = json.dumps(record, indent=2).encode() + b'\n'
(OUT / 'fixture-generation.json').write_bytes(raw)
print(json.dumps({'actualOpenSSLCertificateChecks': len(certificate_checks), 'actualOpenSSLCMSSignatureChecks': len(cms_checks),
    'tamperedCMSRejected': True, 'privateKeyExports': 0, 'sdkExecuted': 0, 'recordBytes': len(raw), 'recordSHA256': hashlib.sha256(raw).hexdigest()}))
