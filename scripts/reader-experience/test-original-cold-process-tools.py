#!/usr/bin/env python3
"""Protocol/receipt guards only; these never pass actual Swift/host execution."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('original_cold_protocol', HERE / 'original-cold-process-tools.py')
cold = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cold)


class ColdProcessProtocolTests(unittest.TestCase):
    def setUp(self):
        self.control = {'schemaVersion': 1, 'runID': '286a8d77-e3d1-43c1-9239-151fc91a0262',
            'nonce': 'f' * 64, 'sourceCommit': 'a' * 40, 'container': str(Path.cwd().resolve())}
        book = 'A7B5E128-44D9-42F0-A47C-33BDA05224D3'
        self.producer = {'control': self.control, 'hostAccepted': True, 'producerPID': 41001, 'peerStopped': True,
            'activeConnections': 0, 'bookID': book, 'sourceID': '01987FAE-3F5B-413C-8D35-87B43513C496',
            'chapterIDs': ['284FFCC5-43F0-4F3D-8679-6361DD437077', '8511ED53-2BE5-4F4A-8E51-165E9308C9BB'],
            'cacheFingerprints': [{n: 'b' * 64 for n in ('.txt', '.meta.json', '.raw.html', '.normalized.xhtml', '.package.json')}] * 2,
            'bodySHA256': ['c' * 64] * 2, 'positionSHA256': 'd' * 64,
            'position': {'spineIndex': 1, 'charOffset': 7},
            'files': {'books_meta.json': '1' * 64, 'books_meta.reading.json': '2' * 64,
                'books_meta.chapters/' + book + '.json': '4' * 64,
                'positions/' + book + '.json': 'd' * 64, 'book_sources.json': '3' * 64},
            'requestTargets': ['/' + self.control['runID'] + suffix for suffix in
                ('/search?key=native-original&page=2', '/book', '/toc-rewritten', '/toc2', '/c1', '/c1p2', '/c2')]}
        self.consumer = {'control': self.control, 'hostAccepted': False, 'producerPID': 41001,
            'consumerPID': 41002, 'bookID': book, 'sourceResolutions': 0, 'fileHashesUnchanged': True,
            'bodySHA256': ['c' * 64] * 2}
        self.producer['renewal'] = {'schemaVersion': 1,
            'transactionID': '73318374-9AA6-4AFD-A544-C9F193D37610', 'phase': 'receiptObserved',
            'revision': 2, 'recordSHA256': '5' * 64, 'candidateBytes': 4096, 'candidateSHA256': '7' * 64,
            'preparationProcessID': '70CB491B-198E-43C8-ADEC-0310A1996AF5',
            'handoffProcessID': '70CB491B-198E-43C8-ADEC-0310A1996AF5', 'clockEpochSeconds': 1700000000.0,
            'files': {'shelf': '1' * 64, 'reading': '2' * 64, 'sources': '3' * 64},
            'positionSHA256': 'd' * 64, 'positionBytes': 72, 'uploadBytes': 4096,
            'uploadSHA256': '7' * 64, 'upgradeRequests': 1, 'lookupRequests': 1,
            'reportedCompleteCleanup': True, 'installedMaterial': None,
            'installedDifferentProcess': None, 'renewalVerified': False}
        self.consumer['renewal'] = {'schemaVersion': 1,
            'transactionID': self.producer['renewal']['transactionID'], 'phase': 'receiptObserved',
            'beforeRevision': 2, 'revision': 3, 'beforeRecordSHA256': '5' * 64, 'recordSHA256': '6' * 64,
            'candidateBytes': 4096, 'candidateSHA256': '7' * 64,
            'handoffProcessID': self.producer['renewal']['handoffProcessID'],
            'normalReadProcessID': '9791435F-65BB-4EC9-819D-07FFB653C6D4', 'clockEpochSeconds': 1700000000.0,
            'dataReadInDifferentProcess': True, 'selectedFilesMatch': True,
            'sourceWasBootstrapped': False, 'unchangedExceptDataRead': True,
            'candidateFileUnchanged': True, 'recoveryOnly': True,
            'installedMaterial': None, 'installedDifferentProcess': None, 'renewalVerified': False}

    def test_receipts_require_current_nonce_accepted_host_and_different_pid(self):
        cold.validate_producer(self.producer, self.control, True)
        cold.validate_consumer(self.consumer, self.producer, self.control, False)
        for key, value in [('consumerPID', 41001), ('sourceResolutions', 1), ('sourceResolutions', False), ('fileHashesUnchanged', False),
                           ('bookID', '87D24C99-C10B-4C14-91C4-36C78BF9C747')]:
            changed = deepcopy(self.consumer); changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                cold.validate_consumer(changed, self.producer, self.control, False)
        for key in ('nonce', 'sourceCommit', 'container', 'runID'):
            changed = deepcopy(self.producer); changed['control'][key] += 'x'
            with self.subTest(key=key), self.assertRaises(ValueError):
                cold.validate_producer(changed, self.control, True)
        changed = deepcopy(self.producer); changed['hostAccepted'] = False
        with self.assertRaises(ValueError):
            cold.validate_consumer(self.consumer, changed, self.control, False)
        producer_process = self.producer['renewal']['preparationProcessID']
        # The reader receipt alone cannot prove local renewal recovery. Reject
        # mixed transactions, stale records, same-process UUIDs and fake install.
        vectors = [('transactionID', self.producer['sourceID']), ('phase', 'installedObserved'),
            ('beforeRevision', 3), ('revision', 2), ('revision', True),
            ('beforeRecordSHA256', '8' * 64), ('recordSHA256', '5' * 64),
            ('candidateBytes', True), ('candidateSHA256', '8' * 64),
            ('handoffProcessID', self.producer['sourceID']),
            ('normalReadProcessID', producer_process.lower()), ('normalReadProcessID', 'not-a-uuid'),
            ('clockEpochSeconds', True), ('clockEpochSeconds', float('nan')),
            ('clockEpochSeconds', float('inf')), ('clockEpochSeconds', 1700000001),
            ('dataReadInDifferentProcess', False), ('selectedFilesMatch', False),
            ('sourceWasBootstrapped', True), ('unchangedExceptDataRead', False),
            ('candidateFileUnchanged', False), ('recoveryOnly', False),
            ('installedMaterial', {}), ('installedDifferentProcess', True), ('renewalVerified', True)]
        for key, value in vectors:
            changed = deepcopy(self.consumer); changed['renewal'][key] = value
            with self.subTest(renewal=key), self.assertRaises(ValueError):
                cold.validate_consumer(changed, self.producer, self.control, False)
        for key in ('installedMaterial', 'installedDifferentProcess', 'renewalVerified'):
            changed = deepcopy(self.consumer); del changed['renewal'][key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                cold.validate_consumer(changed, self.producer, self.control, False)
        changed = deepcopy(self.consumer); changed['renewal']['upgradeRequests'] = 0
        with self.assertRaises(ValueError):
            cold.validate_consumer(changed, self.producer, self.control, False)
        changed = deepcopy(self.consumer); changed['producerPID'] = 41001.0
        with self.assertRaises(ValueError):
            cold.validate_consumer(changed, self.producer, self.control, False)

    def test_offline_marker_requires_two_real_bodies_all_artifacts_and_stopped_peer(self):
        vectors = [('activeConnections', 1), ('activeConnections', False), ('peerStopped', False), ('bodySHA256', []),
            ('position', {'spineIndex': 1, 'charOffset': 8}), ('requestTargets', []), ('files', {})]
        for key, value in vectors:
            changed = deepcopy(self.producer); changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                cold.validate_producer(changed, self.control, True)
        changed = deepcopy(self.producer); changed['cacheFingerprints'][0]['.txt'] = 'missing'
        with self.assertRaises(ValueError):
            cold.validate_producer(changed, self.control, True)
        # Successful transport/lookup and a second process must never stand in
        # for the same candidate, normal owner files and reported-complete seal.
        vectors = [('schemaVersion', True), ('revision', True), ('revision', 0), ('revision', 1 << 64),
            ('candidateBytes', 0), ('candidateBytes', True), ('preparationProcessID', self.producer['sourceID']),
            ('handoffProcessID', 'not-a-uuid'), ('clockEpochSeconds', True),
            ('clockEpochSeconds', float('nan')), ('clockEpochSeconds', float('inf')),
            ('positionBytes', True), ('positionSHA256', '9' * 64), ('uploadBytes', 4095),
            ('uploadBytes', True), ('uploadSHA256', '9' * 64), ('upgradeRequests', 2),
            ('upgradeRequests', True), ('lookupRequests', True), ('reportedCompleteCleanup', False),
            ('installedMaterial', {}), ('installedDifferentProcess', False), ('renewalVerified', True),
            ('files', {'shelf': '3' * 64, 'reading': '2' * 64, 'sources': '1' * 64})]
        for key, value in vectors:
            changed = deepcopy(self.producer); changed['renewal'][key] = value
            with self.subTest(renewal=key), self.assertRaises(ValueError):
                cold.validate_producer(changed, self.control, True)
        for key in ('installedMaterial', 'installedDifferentProcess', 'renewalVerified'):
            changed = deepcopy(self.producer); del changed['renewal'][key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                cold.validate_producer(changed, self.control, True)
        changed = deepcopy(self.producer)
        changed['files']['source.json'] = changed['files'].pop('book_sources.json')
        with self.assertRaises(ValueError):
            cold.validate_producer(changed, self.control, True)
        changed = deepcopy(self.producer); del changed['files']['books_meta.json']
        with self.assertRaises(ValueError):
            cold.validate_producer(changed, self.control, True)
        changed = deepcopy(self.producer); changed['files']['positions/' + changed['bookID'] + '.json'] = '9' * 64
        with self.assertRaises(ValueError):
            cold.validate_producer(changed, self.control, True)

    def test_each_host_requires_one_exact_passed_case_without_retry_or_skip(self):
        expected = cold.METHODS['producer']
        node = {'nodeType': 'Test Case', 'nodeIdentifier': 'yuedu appTests/' + expected, 'result': 'Passed', 'children': []}
        cold.verify_case({'testNodes': [node]}, expected)
        for nodes in ([], [node, node], [{**node, 'result': 'Skipped'}],
                [{**node, 'nodeIdentifier': cold.METHODS['consumer']}],
                [{**node, 'children': [{'nodeType': 'Repetition'}]}]):
            with self.subTest(nodes=nodes), self.assertRaises(ValueError):
                cold.verify_case({'testNodes': nodes}, expected)

    def test_marker_commit_is_complete_and_refuses_stale_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'producer.json'
            cold.commit_marker(path, self.producer)
            self.assertEqual(json.loads(path.read_text()), self.producer)
            with self.assertRaises(FileExistsError):
                cold.commit_marker(path, {'hostAccepted': False})
            self.assertEqual(json.loads(path.read_text()), self.producer)
        # Real controller branch: the owned process disappears between the
        # initial liveness check and kernel event registration. No simctl or
        # process is executed in this portable vector.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); queue = Mock(); queue.control.side_effect = ProcessLookupError()
            installed = Path('/controlled/YueduReader.app')
            completed = Mock(); completed.stdout = (str(installed) + '/YueduReader').encode()
            with patch.object(cold.os, 'kill', return_value=None), \
                 patch.object(cold, 'get_container', return_value=installed), \
                 patch.object(cold.subprocess, 'run', return_value=completed), \
                 patch.object(cold.select, 'kqueue', return_value=queue, create=True), \
                 patch.object(cold.select, 'kevent', return_value=object(), create=True), \
                 patch.multiple(cold.select, create=True, KQ_FILTER_PROC=1, KQ_EV_ADD=2, KQ_EV_ONESHOT=4, KQ_NOTE_EXIT=8):
                cold.terminate_producer('controlled-udid', 'local.controlled', 41001, root)
            observed = json.loads((root / 'producer-process-exit.json').read_text())
            self.assertEqual(observed, {'producerPID': 41001, 'alreadyExited': True,
                'observedDuring': 'kernelRegistration'})
            queue.close.assert_called_once()

    def test_two_qualified_invocations_use_frozen_binary_and_keep_host_budget(self):
        udid = 'A08A4C4D-3384-4BB6-B785-288570157975'
        producer = cold.command(Path('/owned'), 'producer', udid); consumer = cold.command(Path('/owned'), 'consumer', udid)
        self.assertEqual(producer[:2], ['env', 'YUEDU_TEST_ACTION=test-without-building'])
        self.assertEqual(consumer[:2], producer[:2])
        self.assertIn('YUEDU_DEST=id=' + udid, producer); self.assertIn('YUEDU_DEST=id=' + udid, consumer)
        self.assertIn('-t', producer); self.assertEqual(producer[producer.index('-t') + 1], '900')
        self.assertEqual([v for v in producer if v.startswith('-only-testing:')],
            ['-only-testing:yuedu appTests/' + cold.METHODS['producer']])
        self.assertEqual([v for v in consumer if v.startswith('-only-testing:')],
            ['-only-testing:yuedu appTests/' + cold.METHODS['consumer']])
        self.assertNotEqual(producer[-1], consumer[-1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); relative = cold.EXTRA_INPUTS[0]
            source = root / relative; source.parent.mkdir(parents=True); source.write_bytes(b"source")
            base = {"sourceCommit": "a" * 40, "sourceInputs": []}
            with patch.object(cold, "REPO", root), patch.object(cold, "EXTRA_INPUTS", (relative,)), \
                    patch.object(cold.native, "_source_state", return_value=base) as state, \
                    patch.object(cold.native, "verify_cold_build", return_value={}) as built, \
                    patch.object(cold.native.smoke, "git", return_value=b"source"):
                cold.source_state(root)
                state.assert_called_once_with(root, "full"); built.assert_not_called()
                cold.source_state(root, "cold-only")
                state.assert_called_with(root, "cold-only"); built.assert_called_once_with(root)
                with patch.object(cold.native, "verify_cold_build", side_effect=ValueError("missing current build")), self.assertRaises(ValueError):
                    cold.source_state(root, "cold-only")
        # Neither admission changes host argv, method identity or host budgets.
        self.assertEqual(cold.command(Path('/owned'), 'producer', udid), producer)

        inputs = [{'path': 'base.swift', 'bytes': 1, 'sha256': 'a' * 64}]
        extra = [{'path': n, 'bytes': 1, 'sha256': 'b' * 64} for n in cold.EXTRA_INPUTS]
        self.assertEqual(cold.additional_inputs(inputs, extra), extra)
        self.assertEqual(cold.additional_inputs(inputs + extra, extra), [])
        changed = deepcopy(extra); changed[0]['sha256'] = 'c' * 64
        with self.assertRaises(ValueError):
            cold.additional_inputs(inputs + extra, changed)


if __name__ == '__main__':
    unittest.main()
