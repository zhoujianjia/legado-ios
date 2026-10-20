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
            'files': {n: 'e' * 64 for n in ('books_meta.reading.json', 'books_meta.chapters/' + book + '.json',
                'positions/' + book + '.json', 'source.json')},
            'requestTargets': ['/' + self.control['runID'] + suffix for suffix in
                ('/search?key=native-original&page=2', '/book', '/toc-rewritten', '/toc2', '/c1', '/c1p2', '/c2')]}
        self.consumer = {'control': self.control, 'hostAccepted': False, 'producerPID': 41001,
            'consumerPID': 41002, 'bookID': book, 'sourceResolutions': 0, 'fileHashesUnchanged': True,
            'bodySHA256': ['c' * 64] * 2}

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
        inputs = [{'path': 'base.swift', 'bytes': 1, 'sha256': 'a' * 64}]
        extra = [{'path': n, 'bytes': 1, 'sha256': 'b' * 64} for n in cold.EXTRA_INPUTS]
        self.assertEqual(cold.additional_inputs(inputs, extra), extra)
        self.assertEqual(cold.additional_inputs(inputs + extra, extra), [])
        changed = deepcopy(extra); changed[0]['sha256'] = 'c' * 64
        with self.assertRaises(ValueError):
            cold.additional_inputs(inputs + extra, changed)


if __name__ == '__main__':
    unittest.main()
