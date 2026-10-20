"""Actual loopback mTLS cleanup reference experiment; zero Swift execution.

Reuses the frozen reference's wire codec/owned PKI, not its old 13-case run.
This does not exercise or mint a Swift Journal grant or verifier proof.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import struct
import threading
import uuid

WORK = Path(__file__).resolve().parents[1]
BASE_PATH = WORK.parents[0] / 'authenticated-installation-step/work/independent-tls-contract.py'
spec = importlib.util.spec_from_file_location('owned_frozen_wire', BASE_PATH)
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)
wire.WORK = WORK
wire.PRIVATE = WORK / '.private'
wire.PRIVATE.mkdir(exist_ok=True)
read_plist, send_plist, read_afc, send_afc = wire.read_plist, wire.send_plist, wire.read_afc, wire.send_afc


class CleanupPeer(wire.Peer):
    def __init__(self, mode):
        self.owned_path = None
        self.exists = False
        self.removal_seen = threading.Event()
        super().__init__(mode)

    @property
    def unknown(self):
        return self.mode in ('unknown-upgrade-found', 'unknown-upgrade-missing')

    @property
    def rounds(self):
        return 3 if self.mode in ('remove-denied-retry', 'stop-disconnect-retry', 'cancel-stall-retry', 'deadline-stall-retry', 'truncated-remove-retry') else 2

    def secure_round(self, plain, round_index=0):
        context = wire.tls_context(True)
        if self.mode == 'wrong-device-certificate' and round_index:
            context.load_cert_chain(str(wire.PRIVATE / 'wrong.pem'), str(wire.PRIVATE / 'wrong.key'))
        stream = context.wrap_socket(plain, server_side=True)
        if stream.getpeercert(binary_form=True) != wire.PUBLIC['host']:
            stream.close()
            raise wire.Reject('host pin mismatch')
        assert stream.version() == 'TLSv1.2' and not stream.session_reused
        self.observe('authenticatedChannels')
        return stream

    def lockdown(self):
        for round_index in range(self.rounds):
            with self.accept(0) as plain:
                start = read_plist(plain)
                assert start['Request'] == 'StartSession' and start['HostID'] == 'owned-host' and start['SystemBUID'] == 'owned-system'
                session = 'owned-cleanup-session-' + str(round_index)
                send_plist(plain, {'Request': 'StartSession', 'EnableSessionSSL': True, 'SessionID': session})
                with self.secure_round(plain, round_index) as stream:
                    for _ in range(2 if round_index == 0 else 1):
                        request = read_plist(stream)
                        assert request['Request'] == 'StartService'
                        expected = 'com.apple.mobile.installation_proxy' if self.unknown and round_index else 'com.apple.afc'
                        if round_index:
                            assert request['Service'] == expected
                        index = {'com.apple.afc': 1, 'com.apple.mobile.installation_proxy': 2}[request['Service']]
                        send_plist(stream, {'Request': 'StartService', 'Port': self.ports[index], 'EnableServiceSSL': True})
                    try:
                        stop = read_plist(stream)
                    except (OSError, wire.Reject):
                        if round_index == 0 or (round_index == 1 and self.rounds == 3):
                            continue
                        raise
                    assert stop['Request'] == 'StopSession' and stop['SessionID'] == session
                    self.observe('stops')
                    if self.mode == 'stop-disconnect-retry' and round_index == 1:
                        continue
                    send_plist(stream, {'Request': 'StopSession', 'SessionID': session})

    def afc(self):
        for round_index in range(1 if self.unknown else self.rounds):
            with self.secure_round(self.accept(1), round_index) as stream:
                if round_index:
                    sequence, operation, header, payload = read_afc(stream)
                    assert sequence == 0 and operation == 8 and header == self.owned_path and not payload
                    self.observe('removeAttempts')
                    self.removal_seen.set()
                    if self.mode in ('cancel-stall-retry', 'deadline-stall-retry') and round_index == 1:
                        try:
                            wire.exact(stream, 1)
                            raise AssertionError('No data follows a cleanup Remove request')
                        except (OSError, wire.Reject):
                            continue
                    if self.mode == 'truncated-remove-retry' and round_index == 1:
                        stream.sendall(b'123456789')
                        continue
                    status = 10 if self.mode == 'remove-denied-retry' and round_index == 1 else (0 if self.exists else 8)
                    if status == 0:
                        self.exists = False
                        self.observe('removed')
                    send_afc(stream, sequence, 1, struct.pack('<Q', status))
                    continue
                while True:
                    try:
                        sequence, operation, header, payload = read_afc(stream)
                    except (OSError, wire.Reject):
                        if self.unknown:
                            return
                        raise
                    if operation == 10:
                        if header == b'PublicStaging\0':
                            send_afc(stream, sequence, 2, payload=b'st_ifmt\0S_IFDIR\0')
                        else:
                            send_afc(stream, sequence, 1, struct.pack('<Q', 8))
                    elif operation == 13:
                        self.owned_path = header[8:]
                        assert header[:8] == struct.pack('<Q', 3) and self.owned_path.startswith(b'PublicStaging/reader-renewal-')
                        self.exists = self.mode != 'already-absent'
                        self.observe('fileOpens')
                        send_afc(stream, sequence, 14, struct.pack('<Q', 42))
                    elif operation == 16:
                        self.observe('uploadedBytes', len(payload))
                        assert header == struct.pack('<Q', 42) and 0 < len(payload) <= 65536
                        if not self.unknown:
                            break  # Actual first-chunk TLS disconnect, no ACK.
                        send_afc(stream, sequence, 1, struct.pack('<Q', 0))
                    elif operation == 20:
                        self.observe('fileCloses')
                        send_afc(stream, sequence, 1, struct.pack('<Q', 0))
                    else:
                        raise AssertionError('No Remove/extra upload is allowed on the interrupted first channel')

    def proxy(self):
        for round_index in range(2 if self.unknown else 1):
            with self.secure_round(self.accept(2), round_index) as stream:
                try:
                    request = read_plist(stream)
                except (OSError, wire.Reject):
                    if not self.unknown:
                        return
                    raise
                if round_index == 0:
                    assert self.unknown and request['Command'] == 'Upgrade'
                    assert request['PackagePath'].encode() + b'\0' == self.owned_path
                    self.observe('upgrades')
                    continue  # No terminal reply: asynchronous outcome unknown.
                assert request == {'Command': 'Lookup', 'ClientOptions': {'ApplicationType': 'Any', 'BundleIDs': ['owned.reader']}}
                self.observe('lookups')
                result = {} if self.mode == 'unknown-upgrade-missing' else {'owned.reader': {'CFBundleIdentifier': 'owned.reader', 'CFBundleVersion': '42'}}
                send_plist(stream, {'LookupResult': result})


class CleanupClient(wire.ReferenceClient):
    def __init__(self, peer):
        super().__init__(peer)
        self.removal = None
        self.stop_ack = False
        self.active_afc = None

    def partial_upload(self):
        lockdown, _ = self.session()
        afc_port = self.service(lockdown, 'com.apple.afc')
        proxy_port = self.service(lockdown, 'com.apple.mobile.installation_proxy')
        afc = self.connect(afc_port)
        self.connect(proxy_port)
        path = 'PublicStaging/reader-renewal-' + str(uuid.uuid4()) + '.ipa'
        # Independent reference metadata only. This is NOT a Swift sealed grant.
        fact = {'phase': 'uploadIntent', 'path': path, 'sha256': hashlib.sha256(wire.ARCHIVE).hexdigest(),
                'bytes': len(wire.ARCHIVE), 'devicePin': hashlib.sha256(wire.PUBLIC['device']).hexdigest()}
        record = wire.PRIVATE / ('reference-intent-' + str(uuid.uuid4()) + '.json')
        record.write_text(json.dumps(fact))
        assert json.loads(record.read_text()) == fact
        for sequence, (op, header, payload) in enumerate([
            (10, b'PublicStaging\0', b''), (10, path.encode() + b'\0', b''),
            (13, struct.pack('<Q', 3) + path.encode() + b'\0', b''),
            (16, struct.pack('<Q', 42), wire.ARCHIVE[:65536])]):
            send_afc(afc, sequence, op, header, payload)
            read_afc(afc)  # Final reply must fail with actual peer EOF.
        raise AssertionError('First upload did not disconnect')

    def cleanup(self, short_timeout=False):
        lockdown, session = self.session()
        afc = self.connect(self.service(lockdown, 'com.apple.afc'))
        self.active_afc = afc
        if short_timeout:
            afc.settimeout(0.25)  # Actual socket read deadline, no scheduling sleep.
        send_afc(afc, 0, 8, self.peer.owned_path)
        sequence, op, header, payload = read_afc(afc)
        assert sequence == 0 and op == 1 and not payload and len(header) == 8
        status, = struct.unpack('<Q', header)
        if status not in (0, 8):
            raise wire.Reject('actual Remove error ' + str(status))
        self.removal = 'removedAcknowledged' if status == 0 else 'alreadyAbsentAcknowledged'
        afc.close()
        self.finish(lockdown, session)
        self.stop_ack = True

    def cancel_actual_socket(self):
        assert self.active_afc is not None
        self.active_afc.shutdown(socket.SHUT_RDWR)


def rejected(action):
    try:
        action()
    except (OSError, wire.Reject):
        return True
    return False


def run(mode):
    peer = CleanupPeer(mode)
    # Extra observations are initialized before any client connects.
    peer.observed.update(removeAttempts=0, fileOpens=0, fileCloses=0)
    first = CleanupClient(peer)
    try:
        assert rejected(first.upgrade if peer.unknown else first.partial_upload)
    finally:
        first.close()
    recovery = CleanupClient(peer)
    attempts = []
    try:
        if peer.unknown:
            result = recovery.lookup()
            assert (not result) == (mode == 'unknown-upgrade-missing')
            assert peer.observed['removed'] == 0 and peer.observed['removeAttempts'] == 0
            attempts.append({'lookupOnly': True, 'reported': bool(result), 'removal': None})
        elif mode == 'cancel-stall-retry':
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(rejected, recovery.cleanup)
                assert peer.removal_seen.wait(3)
                recovery.cancel_actual_socket()
                assert future.result(timeout=3)
            attempts.append({'actualSocketCancelled': True, 'removal': recovery.removal, 'stopAck': recovery.stop_ack})
        else:
            failed = rejected(lambda: recovery.cleanup(short_timeout=mode == 'deadline-stall-retry'))
            expected_failure = peer.rounds == 3 or mode == 'wrong-device-certificate'
            assert failed == expected_failure
            attempts.append({'rejected': failed, 'removal': recovery.removal, 'stopAck': recovery.stop_ack})
    finally:
        recovery.close()
    if peer.rounds == 3:
        retry = CleanupClient(peer)
        try:
            retry.cleanup()
            assert retry.stop_ack and retry.removal is not None
            attempts.append({'freshAuthenticatedRetry': True, 'removal': retry.removal, 'stopAck': retry.stop_ack})
        finally:
            retry.close()
    outcomes = peer.close(require_success=mode != 'wrong-device-certificate')
    assert peer.observed['upgrades'] == (1 if peer.unknown else 0)
    assert peer.observed['fileOpens'] == 1
    assert peer.observed['uploadedBytes'] == (len(wire.ARCHIVE) if peer.unknown else 65536)
    assert all(peer.observed['sameFDStartTLS'])
    if mode == 'stop-disconnect-retry':
        assert attempts[0]['removal'] == 'removedAcknowledged' and not attempts[0]['stopAck']
        assert attempts[1]['removal'] == 'alreadyAbsentAcknowledged'
    if mode == 'wrong-device-certificate':
        assert peer.observed['removeAttempts'] == 0
    return {'case': mode, 'status': 'passed', 'attempts': attempts, 'observed': peer.observed, 'peerOutcomes': outcomes}


def main():
    wire.generate_owned_pki()
    modes = ['safe-remove', 'already-absent', 'unknown-upgrade-found', 'unknown-upgrade-missing',
             'wrong-device-certificate', 'remove-denied-retry', 'stop-disconnect-retry',
             'cancel-stall-retry', 'deadline-stall-retry', 'truncated-remove-retry']
    records = []
    for mode in modes:
        records.append(run(mode))
        print(mode + ': passed', flush=True)
    result = {'recordedAtUTC': datetime.now(timezone.utc).isoformat(), 'status': 'passed',
              'actualReferenceExperiments': len(records), 'runtime': ssl.OPENSSL_VERSION,
              'referenceOnlyNotSwift': True, 'swiftExecutions': 0, 'swiftJournalExecutions': 0,
              'frozenWireReferenceSHA256': hashlib.sha256(BASE_PATH.read_bytes()).hexdigest(),
              'publicCertificateSHA256': {k: hashlib.sha256(v).hexdigest() for k, v in wire.PUBLIC.items()},
              'privateKeysPublished': False, 'physicalDeviceUsed': False, 'appleAccountUsed': False,
              'cases': records, 'limitations': [
                  'Only independent Python/OpenSSL reference sockets ran; production Swift TLS and Journal APIs did not run.',
                  'Reference JSON metadata is not a Swift sealed cleanup grant.',
                  'Loopback does not prove Apple installation authority, same-device/no-VPN route or self-renewal.']}
    (WORK / 'independent-cleanup-tls-contract.json').write_text(json.dumps(result, indent=2) + '\n')
    print('10 independent real mTLS cleanup cases passed; Swift executions 0', flush=True)


if __name__ == '__main__':
    main()
