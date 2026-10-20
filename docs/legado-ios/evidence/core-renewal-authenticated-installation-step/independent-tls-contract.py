"""Independent real Python/OpenSSL TCP+mTLS wire experiment; NOT Swift execution.

Only synthetic private keys in ignored .private are read. Peers bind loopback,
and the published result contains no keys, pairing records or app/user payload.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import select
import socket
import ssl
import struct
import subprocess
import threading
import time
import uuid

WORK = Path(__file__).resolve().parents[1]
PRIVATE = WORK / '.private'
PRIVATE.mkdir(exist_ok=True)
OPENSSL = 'D:/app/Git/usr/bin/openssl.exe'
MAGIC = 0x4141504c36414643
ARCHIVE = bytes((index * 37) & 255 for index in range(150001))
PUBLIC = {}

def openssl(*args):
    result = subprocess.run([OPENSSL, *map(str, args)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if result.returncode:
        raise RuntimeError('Owned OpenSSL certificate generation failed; private material is not printed')

def generate_owned_pki():
    for name in ('root', 'host', 'device', 'wrong'):
        key = PRIVATE / (name + '.key')
        openssl('genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', key)
        cert = PRIVATE / (name + '.pem')
        if name == 'root':
            config = PRIVATE / 'root.cnf'
            config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ca\n[dn]\n[ca]\n'
                              'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n'
                              'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n')
            openssl('req', '-new', '-x509', '-config', config, '-key', key, '-out', cert, '-days', '30', '-sha256',
                    '-subj', '/CN=OwnedInstallationRoot')
        else:
            csr = PRIVATE / (name + '.csr')
            extension = PRIVATE / (name + '.ext')
            extension.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\n')
            openssl('req', '-new', '-key', key, '-out', csr, '-subj', '/CN=OwnedInstallation-' + name)
            openssl('x509', '-req', '-in', csr, '-CA', PRIVATE / 'root.pem', '-CAkey', PRIVATE / 'root.key',
                    '-set_serial', str(('host', 'device', 'wrong').index(name) + 2), '-out', cert,
                    '-days', '30', '-sha256', '-extfile', extension)
        der = ssl.PEM_cert_to_DER_cert(cert.read_text())
        PUBLIC[name] = der

class Reject(Exception):
    pass

def exact(stream, count):
    result = bytearray()
    while len(result) < count:
        data = stream.recv(count - len(result))
        if not data:
            raise Reject('truncated stream')
        result.extend(data)
    return bytes(result)

def send_plist(stream, value):
    data = plistlib.dumps(value, fmt=plistlib.FMT_XML)
    assert len(data) <= 262144
    stream.sendall(struct.pack('>I', len(data)) + data)

def read_plist(stream):
    size, = struct.unpack('>I', exact(stream, 4))
    if not 0 < size <= 262144:
        raise Reject('plist length')
    value = plistlib.loads(exact(stream, size))
    if not isinstance(value, dict):
        raise Reject('plist dictionary')
    if 'Error' in value or 'ErrorDescription' in value:
        raise Reject('device error takes priority over Complete')
    return value

def read_afc(stream):
    magic, total, header, sequence, operation = struct.unpack('<5Q', exact(stream, 40))
    if magic != MAGIC or not 40 <= header <= total <= 69672 or header - 40 > 4096:
        raise Reject('AFC bounds')
    return sequence, operation, exact(stream, header - 40), exact(stream, total - header)

def send_afc(stream, sequence, operation, header=b'', payload=b''):
    stream.sendall(struct.pack('<5Q', MAGIC, 40 + len(header) + len(payload), 40 + len(header), sequence, operation) + header + payload)

def tls_context(server, no_client_identity=False):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER if server else ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.maximum_version = ssl.TLSVersion.TLSv1_2
    if not server:
        context.check_hostname = False  # Exact pairing identity pin below, never DNS identity.
    context.verify_mode = ssl.CERT_REQUIRED
    context.load_verify_locations(cafile=str(PRIVATE / 'root.pem'))
    context.options |= ssl.OP_NO_TICKET
    if not no_client_identity:
        name = 'device' if server else 'host'
        context.load_cert_chain(str(PRIVATE / (name + '.pem')), str(PRIVATE / (name + '.key')))
    return context

class Peer:
    def __init__(self, mode):
        self.mode = mode
        self.stop_read, self.stop_write = socket.socketpair()
        self.listeners = [socket.socket() for _ in range(3)]
        for listener in self.listeners:
            listener.bind(('127.0.0.1', 0)); listener.listen(2)
        self.ports = [listener.getsockname()[1] for listener in self.listeners]
        self.observed = {'authenticatedChannels': 0, 'upgrades': 0, 'lookups': 0,
                         'uploadedBytes': 0, 'removed': 0, 'stops': 0, 'sameFDStartTLS': []}
        self.lock = threading.Lock()
        self.session_seen = threading.Event()
        self.pool = ThreadPoolExecutor(max_workers=3)
        self.futures = [self.pool.submit(self.lockdown), self.pool.submit(self.afc), self.pool.submit(self.proxy)]

    def observe(self, key, amount=1):
        with self.lock:
            self.observed[key] += amount

    def accept(self, index):
        available, _, _ = select.select([self.listeners[index], self.stop_read], [], [], 5)
        if self.stop_read in available or not available:
            raise Reject('owned peer stopped')
        stream, _ = self.listeners[index].accept()
        stream.settimeout(2)
        return stream

    def secure(self, stream):
        encrypted = tls_context(True).wrap_socket(stream, server_side=True)
        expected = PUBLIC['wrong'] if self.mode == 'wrong-host-pin' else PUBLIC['host']
        if encrypted.getpeercert(binary_form=True) != expected:
            encrypted.close(); raise Reject('actual host certificate pin mismatch')
        assert encrypted.version() == 'TLSv1.2'
        self.observe('authenticatedChannels')
        return encrypted

    def lockdown(self):
        for round_index in range(2 if self.mode == 'disconnect-recovery' else 1):
            with self.accept(0) as plain:
                start = read_plist(plain)
                assert start['Request'] == 'StartSession' and start['HostID'] == 'owned-host' and start['SystemBUID'] == 'owned-system'
                session = 'owned-session-' + str(round_index)
                send_plist(plain, {'Request': 'StartSession', 'SessionID': session, 'EnableSessionSSL': True})
                self.session_seen.set()
                if self.mode == 'cancel-handshake':
                    exact(plain, 1048576); return
                with self.secure(plain) as secure:
                    for _ in range(1 if round_index else 2):
                        request = read_plist(secure)
                        assert request['Request'] == 'StartService'
                        index = {'com.apple.afc': 1, 'com.apple.mobile.installation_proxy': 2}[request['Service']]
                        send_plist(secure, {'Request': 'StartService', 'Port': self.ports[index], 'EnableServiceSSL': True})
                    try:
                        stop = read_plist(secure)
                    except (OSError, Reject):
                        if self.mode == 'disconnect-recovery' and round_index == 0:
                            continue
                        raise
                    assert stop['Request'] == 'StopSession' and stop['SessionID'] == session
                    self.observe('stops'); send_plist(secure, {'Request': 'StopSession', 'SessionID': session})

    def afc(self):
        with self.secure(self.accept(1)) as stream:
            actual = bytearray()
            owned_path = None
            while True:
                try:
                    sequence, operation, header, payload = read_afc(stream)
                except (OSError, Reject):
                    if self.mode == 'disconnect-recovery' and bytes(actual) == ARCHIVE:
                        return
                    raise
                if self.mode == 'truncated-afc':
                    stream.sendall(b'123456789'); return
                response_sequence = sequence + (self.mode == 'wrong-afc-sequence')
                if operation == 10:
                    if header == b'PublicStaging\0':
                        send_afc(stream, response_sequence, 2, payload=b'st_ifmt\0S_IFDIR\0')
                    else:
                        send_afc(stream, response_sequence, 1, struct.pack('<Q', 8))
                elif operation == 13:
                    assert header[:8] == struct.pack('<Q', 3) and header[8:].startswith(b'PublicStaging/reader-renewal-') and header.endswith(b'.ipa\0')
                    owned_path = header[8:]
                    send_afc(stream, response_sequence, 14, struct.pack('<Q', 42))
                elif operation == 16:
                    assert header == struct.pack('<Q', 42) and 0 < len(payload) <= 65536
                    actual.extend(payload); self.observe('uploadedBytes', len(payload))
                    send_afc(stream, response_sequence, 1, struct.pack('<Q', 0))
                elif operation == 20:
                    assert bytes(actual) == ARCHIVE
                    send_afc(stream, response_sequence, 1, struct.pack('<Q', 0))
                elif operation == 8:
                    assert header == owned_path
                    self.observe('removed'); send_afc(stream, response_sequence, 1, struct.pack('<Q', 0)); return
                else:
                    raise Reject('unexpected AFC request')

    def proxy(self):
        for round_index in range(2 if self.mode == 'disconnect-recovery' else 1):
            with self.secure(self.accept(2)) as stream:
                request = read_plist(stream)
                if round_index == 0:
                    assert request['Command'] == 'Upgrade' and request['ClientOptions'] == {'CFBundleIdentifier': 'owned.reader'}
                    assert request['PackagePath'].startswith('PublicStaging/reader-renewal-')
                    self.observe('upgrades')
                    if self.mode == 'disconnect-recovery':
                        continue
                    if self.mode == 'installation-error':
                        send_plist(stream, {'Status': 'Complete', 'Error': 'OwnedFailure'}); return
                    if self.mode == 'oversized-plist':
                        stream.sendall(struct.pack('>I', 1048576)); return
                    for _ in range(257 if self.mode == 'progress-budget' else 1):
                        send_plist(stream, {'Status': 'Installing', 'PercentComplete': 100})
                    if self.mode in ('no-complete', 'progress-budget'):
                        exact(stream, 1); return
                    send_plist(stream, {'Status': 'Complete'})
                    request = read_plist(stream)
                assert request == {'Command': 'Lookup', 'ClientOptions': {'ApplicationType': 'Any', 'BundleIDs': ['owned.reader']}}
                self.observe('lookups')
                send_plist(stream, {'LookupResult': {'owned.reader': {'CFBundleIdentifier': 'owned.reader', 'CFBundleVersion': 'wrong' if self.mode == 'wrong-lookup' else '42'}}})

    def close(self, require_success=False):
        self.stop_write.send(b'x')
        outcomes = []
        for future in self.futures:
            try:
                future.result(timeout=6); outcomes.append('passed')
            except (OSError, Reject, AssertionError) as error:
                if require_success:
                    print('peer rejection:', type(error).__name__, str(error)[:240], flush=True)
                outcomes.append('expected-rejection-or-cleanup' if not require_success else 'failed')
        self.pool.shutdown(wait=True)
        for stream in self.listeners + [self.stop_read, self.stop_write]:
            stream.close()
        if require_success:
            assert outcomes == ['passed'] * 3, outcomes
        return outcomes

class ReferenceClient:
    def __init__(self, peer):
        self.peer = peer
        self.streams = []
        self.stage = 'session'

    def connect(self, port, encrypted=True):
        raw = socket.create_connection(('127.0.0.1', port), timeout=1)
        self.streams.append(raw)
        return self.secure(raw) if encrypted else raw

    def secure(self, raw):
        descriptor = raw.fileno()
        secure = tls_context(False, no_client_identity=self.peer.mode == 'no-client-identity').wrap_socket(raw)
        self.streams.append(secure)
        assert secure.fileno() == descriptor
        self.peer.observed['sameFDStartTLS'].append(True)
        expected = PUBLIC['wrong'] if self.peer.mode == 'wrong-device-pin' else PUBLIC['device']
        if secure.getpeercert(binary_form=True) != expected:
            raise Reject('actual device pin mismatch')
        assert secure.version() == 'TLSv1.2' and not secure.session_reused
        return secure

    def session(self):
        raw = self.connect(self.peer.ports[0], encrypted=False)
        send_plist(raw, {'Label': 'Reading', 'Request': 'StartSession', 'HostID': 'owned-host', 'SystemBUID': 'owned-system'})
        response = read_plist(raw)
        assert response['EnableSessionSSL'] is True
        return self.secure(raw), response['SessionID']

    def service(self, lockdown, name):
        send_plist(lockdown, {'Request': 'StartService', 'Service': name})
        response = read_plist(lockdown)
        assert response['EnableServiceSSL'] is True and 0 < response['Port'] <= 65535
        return response['Port']

    def finish(self, lockdown, session):
        send_plist(lockdown, {'Request': 'StopSession', 'SessionID': session})
        assert read_plist(lockdown)['SessionID'] == session

    def lookup(self):
        lockdown, session = self.session()
        proxy = self.connect(self.service(lockdown, 'com.apple.mobile.installation_proxy'))
        send_plist(proxy, {'Command': 'Lookup', 'ClientOptions': {'ApplicationType': 'Any', 'BundleIDs': ['owned.reader']}})
        result = read_plist(proxy)['LookupResult']
        self.finish(lockdown, session)
        return result

    def upgrade(self):
        lockdown, session = self.session()
        afc_port = self.service(lockdown, 'com.apple.afc')
        proxy_port = self.service(lockdown, 'com.apple.mobile.installation_proxy')
        afc = self.connect(afc_port); proxy = self.connect(proxy_port)
        sequence = 0
        def exchange(op, header=b'', payload=b'', expected=1, status=0):
            nonlocal sequence
            send_afc(afc, sequence, op, header, payload)
            response_sequence, operation, result, data = read_afc(afc)
            if response_sequence != sequence or operation != expected:
                raise Reject('AFC operation or sequence mismatch')
            sequence += 1
            if expected == 1 and (data or result != struct.pack('<Q', status)):
                raise Reject('AFC status mismatch')
            return result, data
        self.stage = 'upload'
        _, attributes = exchange(10, b'PublicStaging\0', expected=2)
        assert attributes == b'st_ifmt\0S_IFDIR\0'
        path = 'PublicStaging/reader-renewal-' + str(uuid.uuid4()) + '.ipa'
        exchange(10, path.encode() + b'\0', status=8)
        handle, _ = exchange(13, struct.pack('<Q', 3) + path.encode() + b'\0', expected=14)
        digest = hashlib.sha256()
        for offset in range(0, len(ARCHIVE), 65536):
            data = ARCHIVE[offset:offset + 65536]
            exchange(16, handle, data); digest.update(data)
        exchange(20, handle)
        assert digest.digest() == hashlib.sha256(ARCHIVE).digest()
        self.stage = 'upgrade'
        send_plist(proxy, {'Command': 'Upgrade', 'PackagePath': path, 'ClientOptions': {'CFBundleIdentifier': 'owned.reader'}})
        for _ in range(256):
            result = read_plist(proxy)
            if result.get('Status') == 'Complete':
                break
        else:
            raise Reject('progress message budget')
        self.stage = 'lookup'
        send_plist(proxy, {'Command': 'Lookup', 'ClientOptions': {'ApplicationType': 'Any', 'BundleIDs': ['owned.reader']}})
        if read_plist(proxy).get('LookupResult') != {'owned.reader': {'CFBundleIdentifier': 'owned.reader', 'CFBundleVersion': '42'}}:
            raise Reject('lookup mismatch')
        exchange(8, path.encode() + b'\0'); self.finish(lockdown, session)

    def close(self):
        for stream in self.streams:
            stream.close()

def cancellation_case():
    peer = Peer('cancel-handshake')
    wake_read, wake_write = socket.socketpair()
    observed = {'cancelled': False, 'sameFD': False, 'upgradeRequests': 0}
    def work():
        raw = socket.create_connection(('127.0.0.1', peer.ports[0]), timeout=2)
        send_plist(raw, {'Request': 'StartSession', 'HostID': 'owned-host', 'SystemBUID': 'owned-system'})
        read_plist(raw)
        descriptor = raw.fileno()
        secure = tls_context(False).wrap_socket(raw, do_handshake_on_connect=False)
        secure.setblocking(False)
        observed['sameFD'] = secure.fileno() == descriptor
        try:
            while True:
                try:
                    secure.do_handshake(); raise AssertionError('Stalled peer cannot authenticate')
                except ssl.SSLWantReadError:
                    ready, _, _ = select.select([secure, wake_read], [], [], 2)
                    if wake_read in ready:
                        observed['cancelled'] = True; return
                    if not ready:
                        raise AssertionError('Cancellation was not delivered')
        finally:
            secure.close()
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(work)
        assert peer.session_seen.wait(2)
        wake_write.send(b'x')
        future.result(timeout=3)
    outcomes = peer.close()
    wake_read.close(); wake_write.close()
    assert observed['cancelled'] and observed['sameFD'] and peer.observed['upgrades'] == 0
    return {'case': 'cancel-stalled-in-place-handshake', 'status': 'passed', 'actualTLSClientHello': True, **observed, 'peerOutcomes': outcomes}

def main():
    generate_owned_pki()
    assert struct.pack('<Q', MAGIC).hex() == '434641364c504141'
    records = []
    modes = ['normal', 'wrong-device-pin', 'wrong-host-pin', 'no-client-identity', 'wrong-afc-sequence',
             'truncated-afc', 'installation-error', 'no-complete', 'wrong-lookup', 'oversized-plist',
             'progress-budget', 'disconnect-recovery']
    for mode in modes:
        peer = Peer(mode); client = ReferenceClient(peer)
        rejected = False
        try:
            client.upgrade()
        except (OSError, Reject) as error:
            rejected = True
            print(mode, 'reference rejection:', type(error).__name__, str(error)[:240], flush=True)
        finally:
            client.close()
        if mode == 'disconnect-recovery':
            assert rejected and client.stage == 'upgrade'
            recovery = ReferenceClient(peer)
            try:
                result = recovery.lookup()
                assert result == {'owned.reader': {'CFBundleIdentifier': 'owned.reader', 'CFBundleVersion': '42'}}
            finally:
                recovery.close()
        outcomes = peer.close(require_success=mode in ('normal', 'disconnect-recovery'))
        assert rejected == (mode != 'normal')
        if mode in ('normal', 'disconnect-recovery'):
            assert peer.observed['uploadedBytes'] == len(ARCHIVE) and peer.observed['upgrades'] == 1 and peer.observed['lookups'] == 1
        if mode in ('wrong-device-pin', 'wrong-host-pin', 'no-client-identity', 'wrong-afc-sequence', 'truncated-afc'):
            assert peer.observed['upgrades'] == 0
        records.append({'case': mode, 'status': 'passed', 'rejected': rejected, 'stage': client.stage,
                        'observed': peer.observed, 'peerOutcomes': outcomes})
        print(mode, 'passed', flush=True)
    records.append(cancellation_case())
    result = {'recordedAtUTC': datetime.now(timezone.utc).isoformat(), 'status': 'passed', 'actualReferenceExperiments': len(records),
              'runtime': ssl.OPENSSL_VERSION, 'referenceOnlyNotSwift': True, 'swiftExecutions': 0,
              'archiveBytes': len(ARCHIVE), 'archiveSHA256': hashlib.sha256(ARCHIVE).hexdigest(),
              'publicCertificateSHA256': {name: hashlib.sha256(data).hexdigest() for name, data in PUBLIC.items()},
              'privateKeysPublished': False, 'physicalDeviceUsed': False, 'appleAccountUsed': False,
              'cases': records,
              'limitations': ['Only independently implemented Python/OpenSSL reference sockets ran. The new Swift SecureTransport code and seven native methods have not run.',
                              'Synthetic loopback peers do not establish actual iOS pairing, installation permission, same-device reachability, no-VPN routing or automatic renewal.']}
    (WORK / 'independent-tls-contract.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print('13 independent TCP/TLS reference cases passed; Swift SDK executions 0', flush=True)

if __name__ == '__main__':
    main()
