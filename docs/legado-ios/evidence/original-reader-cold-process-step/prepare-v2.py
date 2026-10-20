from pathlib import Path
import hashlib,json,shutil
S=Path(__file__).parent;V=S/'successor-v2';V.mkdir(exist_ok=False);manifest=S/'final-v1.json';assert hashlib.sha256(manifest.read_bytes()).hexdigest()=='5f274d3fabcf82bfb94e59e9ad0cb11848b556064c63491fb024f9a7e8001bf9'
shutil.copytree(S/'snapshot-v1/work',V/'work');shutil.copytree(S/'snapshot-v1/rawbaseline',V/'rawbaseline')
p=V/'work/scripts/reader-experience/original-cold-process-tools.py';text=p.read_text(encoding='utf-8')
a='''        except ProcessLookupError:
            return
        run_checked''';b='''        except ProcessLookupError:
            write_new(work / 'producer-process-exit.json', {'producerPID': pid, 'alreadyExited': True,
                'observedDuring': 'kernelRegistration'})
            return
        run_checked''';assert text.count(a)==1;text=text.replace(a,b)
a='''    commit_marker(owned / 'producer.json', producer); write_new(work / 'producer.json', producer)
    terminate_producer(udid, bundle, producer['producerPID'], work)''';b='''    terminate_producer(udid, bundle, producer['producerPID'], work)
    commit_marker(owned / 'producer.json', producer); write_new(work / 'producer.json', producer)''';assert text.count(a)==1;text=text.replace(a,b)
a="        'producer': fact(work / 'producer.json'), 'consumer': fact(work / 'consumer.json'),";b=a+"\n        'producerExitObservation': {'path': 'producer-process-exit.json', **fact(work / 'producer-process-exit.json')},";assert text.count(a)==1;text=text.replace(a,b);p.write_text(text,encoding='utf-8',newline='\n')
p=V/'work/scripts/reader-experience/test-original-cold-process-tools.py';text=p.read_text(encoding='utf-8');text=text.replace('import unittest\n','import unittest\nfrom unittest.mock import Mock, patch\n')
a="            self.assertEqual(json.loads(path.read_text()), self.producer)\n\n    def test_two_qualified";b="""            self.assertEqual(json.loads(path.read_text()), self.producer)
        # Real controller branch: the owned process disappears between the
        # initial liveness check and kernel event registration. No simctl or
        # process is executed in this portable vector.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); queue = Mock(); queue.control.side_effect = ProcessLookupError()
            completed = Mock(); completed.stdout = b'/controlled/YueduReader.app/YueduReader'
            with patch.object(cold.os, 'kill', return_value=None), \\
                 patch.object(cold, 'get_container', return_value=Path('/controlled/YueduReader.app')), \\
                 patch.object(cold.subprocess, 'run', return_value=completed), \\
                 patch.object(cold.select, 'kqueue', return_value=queue, create=True), \\
                 patch.object(cold.select, 'kevent', return_value=object(), create=True), \\
                 patch.multiple(cold.select, create=True, KQ_FILTER_PROC=1, KQ_EV_ADD=2, KQ_EV_ONESHOT=4, KQ_NOTE_EXIT=8):
                cold.terminate_producer('controlled-udid', 'local.controlled', 41001, root)
            observed = json.loads((root / 'producer-process-exit.json').read_text())
            self.assertEqual(observed, {'producerPID': 41001, 'alreadyExited': True,
                'observedDuring': 'kernelRegistration'})
            queue.close.assert_called_once()

    def test_two_qualified""";assert text.count(a)==1;text=text.replace(a,b);p.write_text(text,encoding='utf-8',newline='\n')
print('successor-v2 prepared; v1/work/snapshot untouched')
