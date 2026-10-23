"""Public opaque ADSID fixtures; independent CBC/HMAC math, no Apple requests.

Reuses the original public SRP session vectors without modifying their bytes.
Run normally to generate owned-vectors.json; --check also verifies the embedded
Swift payload. This script never reads real accounts, registration or logs.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import hmac
import json
import plistlib
import re
import struct

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


ROOT = Path(__file__).resolve().parents[4]
TEST = ROOT / "Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift"
OUTPUT = Path(__file__).with_name("owned-vectors.json")


def mac(key, data):
    return hmac.digest(key, data, "sha256")


def cipher(vector):
    key = bytes.fromhex(vector["K"])
    return Cipher(algorithms.AES(mac(key, b"extra data key:")),
                  modes.CBC(mac(key, b"extra data iv:")[:16]))


def decrypt(vector, sealed):
    worker = cipher(vector).decryptor()
    padded = worker.update(sealed) + worker.finalize()
    count = padded[-1]
    assert 1 <= count <= 16 and padded[-count:] == bytes([count]) * count
    return padded[:-count]


def negotiation(vector, sealed):
    # Match the observed optional-SC response: missing SC contributes no length
    # prefix, while the SPD still remains authenticated by the mandatory MAC.
    transcript = (("s2k,s2k_fo||" + vector["protocol"] + "|").encode()
                  + struct.pack("<I", len(sealed)) + sealed + b"||")
    return mac(mac(bytes.fromhex(vector["K"]), b"HMAC key:"),
               hashlib.sha256(transcript).digest())


def seal(vector, fields):
    plain = plistlib.dumps(fields, fmt=plistlib.FMT_XML, sort_keys=True)
    count = 16 - len(plain) % 16
    padded = plain + bytes([count]) * count
    worker = cipher(vector).encryptor()
    sealed = worker.update(padded) + worker.finalize()
    assert plistlib.loads(decrypt(vector, sealed)) == fields
    return sealed.hex(), negotiation(vector, sealed).hex()


def generate(source):
    original = source.split("private enum Vectors {", 1)[1]
    encoded = re.findall(r'static let base64 = "([A-Za-z0-9+/=]{500,})"', original)
    assert len(encoded) == 1
    original_bytes = base64.b64decode(encoded[0], validate=True)
    vectors = json.loads(original_bytes)["appleDerived"]
    assert len(vectors) == 2
    opaque = "Public-Fixture.ADS-ID-" + "Ab9-" * 20
    maximum = opaque + "X" * (128 - len(opaque.encode()))
    assert 64 < len(opaque.encode()) < 128
    assert len(maximum.encode()) == 128
    identifiers = {"opaque": opaque, "maximum": maximum, "empty": "",
                   "control": "Public-Fixture\nIdentifier", "c1": "Public-Fixture\u0085Identifier",
                   "oversized": maximum + "X"}
    records = []
    for vector in vectors:
        baseline = plistlib.loads(decrypt(vector, bytes.fromhex(vector["spd"])))
        assert baseline["adsid"] == vector["dsid"]
        for name, identifier in identifiers.items():
            fields = dict(baseline, adsid=identifier)
            initial, initial_np = seal(vector, dict(fields, **{
                "status-code": 409, "url": "trustedDeviceSecondaryAuth"}))
            final, final_np = seal(vector, dict(fields, **{"status-code": 200}))
            checksum = mac(bytes.fromhex(vector["sk"]),
                           b"apptokens" + identifier.encode() + b"com.apple.gs.xcode.auth")
            # Changing the authenticated account data cannot reuse either old
            # transcript's MAC, even when the SRP session proof is unchanged.
            assert initial_np != vector["np"] and final_np != vector["np"]
            assert initial_np != final_np
            records.append(dict(protocol=vector["protocol"], name=name, adsid=identifier,
                                initialSPD=initial, initialNP=initial_np,
                                finalSPD=final, finalNP=final_np, checksum=checksum.hex()))
    return dict(schemaVersion=1, publicFixturesOnly=True,
                originalVectorSHA256=hashlib.sha256(original_bytes).hexdigest(),
                scPresent=False, vectors=records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    source = TEST.read_text(encoding="utf-8-sig")
    result = generate(source)
    payload = (json.dumps(result, ensure_ascii=True, separators=(",", ":")) + "\n").encode()
    if arguments.check:
        assert OUTPUT.read_bytes() == payload, "Independent fixture file differs"
        section = source.split("private enum IdentifierVectors {", 1)[1].split("private enum Vectors {", 1)[0]
        encoded = re.findall(r'static let base64 = "([A-Za-z0-9+/=]{500,})"', section)
        assert len(encoded) == 1 and base64.b64decode(encoded[0], validate=True) == payload
    else:
        OUTPUT.write_bytes(payload)
    print(json.dumps(dict(publicFixturesOnly=True, protocols=2, variants=len(result["vectors"]),
                          originalVectorSHA256=result["originalVectorSHA256"],
                          payloadSHA256=hashlib.sha256(payload).hexdigest(),
                          roundTrips=24, missingSC=True, actualSwiftExecutions=0, appleRequests=0,
                          embeddedChecked=arguments.check)))


if __name__ == "__main__":
    main()
