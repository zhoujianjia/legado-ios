#!/usr/bin/env python3
"""Two actual App hosts, one fresh owned fixture; no same-process reopen claim."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('cold_native_helpers', HERE / 'native-smoke-tools.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
METHODS = {
    'producer': 'LegadoNativeOriginalReaderTests/testNativeOriginalColdProducerPersistsPublicReaderBeforeProcessExit',
    'consumer': 'LegadoNativeOriginalReaderTests/testNativeOriginalColdConsumerRestoresOwnedReaderWithoutNetwork',
}
EXTRA_INPUTS = ('scripts/reader-experience/original-cold-process-tools.py',
    'scripts/reader-experience/test-original-cold-process-tools.py')


def fact(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('Cold evidence must be a regular file')
    return {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def read_json(path):
    if fact(path)['bytes'] > 16_777_216:
        raise ValueError('Cold evidence exceeds its bounded size')
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_new(path, value):
    path = Path(path)
    with path.open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')


def commit_marker(path, value):
    """One complete, exclusive marker, committed only after the host verdict."""
    path = Path(path)
    pending = path.with_name('.' + path.name + '-' + uuid.uuid4().hex)
    try:
        with pending.open('x', encoding='utf-8') as stream:
            stream.write(json.dumps(value, indent=2) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.link(pending, path)  # Atomic and refuses an existing receipt.
    finally:
        if pending.exists():
            pending.unlink()


def check_control(value):
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'runID', 'nonce', 'sourceCommit', 'container'}
            or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1 or str(uuid.UUID(value['runID'])) != value['runID']
            or re.fullmatch('[0-9a-f]{64}', value['nonce']) is None
            or re.fullmatch('[0-9a-f]{40}', value['sourceCommit']) is None
            or not Path(value['container']).is_absolute()):
        raise ValueError('Malformed cold-process descriptor')
    return value


def validate_producer(receipt, control, accepted):
    check_control(control)
    if (receipt.get('control') != control or receipt.get('hostAccepted') is not accepted
            or type(receipt.get('producerPID')) is not int or receipt['producerPID'] <= 1
            or receipt.get('peerStopped') is not True or type(receipt.get('activeConnections')) is not int or receipt['activeConnections'] != 0
            or len(receipt.get('chapterIDs', [])) != 2 or len(set(receipt['chapterIDs'])) != 2
            or len(receipt.get('cacheFingerprints', [])) != 2 or len(receipt.get('bodySHA256', [])) != 2
            or len(receipt.get('files', {})) != 4 or receipt.get('position') != {'spineIndex': 1, 'charOffset': 7}):
        raise ValueError('Missing, stale or incomplete cold producer receipt')
    uuid.UUID(receipt['bookID']); uuid.UUID(receipt['sourceID'])
    for chapter in receipt['chapterIDs']:
        uuid.UUID(chapter)
    expected_files = {'books_meta.reading.json', 'books_meta.chapters/' + receipt['bookID'] + '.json',
        'positions/' + receipt['bookID'] + '.json', 'source.json'}
    if set(receipt['files']) != expected_files:
        raise ValueError('Cold producer metadata paths differ')
    expected_cache = {'.txt', '.meta.json', '.raw.html', '.normalized.xhtml', '.package.json'}
    hashes = [*receipt['bodySHA256'], receipt.get('positionSHA256'), *receipt['files'].values()]
    for cache in receipt['cacheFingerprints']:
        if set(cache) != expected_cache:
            raise ValueError('Cold producer cache identity differs')
        hashes.extend(cache.values())
    if any(not isinstance(h, str) or re.fullmatch('[0-9a-f]{64}', h) is None for h in hashes):
        raise ValueError('Cold producer has missing or malformed file hashes')
    expected_targets = ['/' + control['runID'] + suffix for suffix in
        ('/search?key=native-original&page=2', '/book', '/toc-rewritten', '/toc2', '/c1', '/c1p2', '/c2')]
    if receipt.get('requestTargets') != expected_targets:
        raise ValueError('Cold producer did not fetch real next-page content')
    return receipt


def validate_consumer(receipt, producer, control, accepted):
    validate_producer(producer, control, True)
    if (receipt.get('control') != control or receipt.get('hostAccepted') is not accepted
            or receipt.get('producerPID') != producer['producerPID']
            or type(receipt.get('consumerPID')) is not int or receipt['consumerPID'] <= 1
            or receipt['consumerPID'] == producer['producerPID'] or receipt.get('bookID') != producer['bookID']
            or type(receipt.get('sourceResolutions')) is not int or receipt['sourceResolutions'] != 0 or receipt.get('fileHashesUnchanged') is not True
            or receipt.get('bodySHA256') != producer['bodySHA256']):
        raise ValueError('Cold consumer is not an immutable different-process offline read')
    return receipt


def verify_case(tests, expected):
    if not isinstance(tests, dict) or not isinstance(tests.get('testNodes'), list):
        raise ValueError('Cold host needs original test-result nodes')
    found = []; visited = 0
    def visit(node, depth=0):
        nonlocal visited
        visited += 1
        if not isinstance(node, dict) or depth > 64 or visited > 10_000:
            raise ValueError('Malformed cold test tree')
        kind = node.get('nodeType')
        if kind in ('Arguments', 'Repetition') or node.get('result') in ('Failed', 'Skipped'):
            raise ValueError('Retries, skips or failures cannot establish a cold host')
        if kind in ('Test Case', 'Test Case Run') and node.get('result') != 'Passed':
            raise ValueError('Incomplete cold host execution')
        if kind == 'Test Case':
            value = node.get('nodeIdentifier', '').removesuffix('()')
            if value not in (expected, 'yuedu appTests/' + expected):
                raise ValueError('Unexpected cold test method')
            found.append(value)
        children = node.get('children', [])
        if not isinstance(children, list):
            raise ValueError('Malformed cold test children')
        if kind == 'Test Case' and sum(c.get('nodeType') == 'Test Case Run' for c in children) > 1:
            raise ValueError('Repeated cold test execution')
        for child in children:
            visit(child, depth + 1)
    for node in tests['testNodes']:
        visit(node)
    if len(found) != 1:
        raise ValueError('Cold host requires exactly one qualified case')


def additional_inputs(base, extra):
    existing = {row['path']: row for row in base}
    if len(existing) != len(base):
        raise ValueError('Duplicated native source inputs')
    added = []
    for row in extra:
        if row['path'] in existing:
            if existing[row['path']] != row:
                raise ValueError('Cold protocol source differs from native binding')
        else:
            existing[row['path']] = row
            added.append(row)
    return added


def source_state(work):
    base = native._source_state(work)
    extra = []
    for relative in EXTRA_INPUTS:
        path = REPO / relative
        if path.read_bytes() != native.smoke.git('show', 'HEAD:' + relative, binary=True):
            raise ValueError('Cold protocol source differs from tracked HEAD')
        extra.append({'path': relative, **fact(path)})
    return {'nativeSourceState': base,
        'coldProtocolInputs': additional_inputs(base['sourceInputs'], extra)}


def command(work, phase, udid):
    uuid.UUID(udid)
    return ['env', 'YUEDU_TEST_ACTION=test-without-building', 'YUEDU_DEST=id=' + udid, 'bash', str(REPO / 'scripts/xctest.sh'),
        '-l', str(work / (phase + '.log')), '-t', '900', '--', *native._build_args(),
        '-resultBundlePath', str(work / (phase + '.xcresult')),
        '-only-testing:yuedu appTests/' + METHODS[phase]]


def run_checked(argv, log):
    result = subprocess.run(argv, capture_output=True)
    write_new(log.with_suffix('.json'), {'argv': argv, 'exitCode': result.returncode})
    log.write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError('Cold Simulator command failed: ' + argv[2])
    return result.stdout.decode('utf-8').strip()


def get_container(udid, bundle, kind, log):
    value = run_checked(['xcrun', 'simctl', 'get_app_container', udid, bundle, kind], log)
    path = Path(value).resolve(strict=True)
    if not path.is_dir():
        raise ValueError('Simulator container is missing')
    return path


def run_host(work, phase, expected_source, expected_container, udid, bundle):
    if source_state(work.parent) != expected_source:
        raise ValueError('Cold source changed before host launch')
    before = get_container(udid, bundle, 'data', work / (phase + '-container-before.log'))
    if before != expected_container:
        raise ValueError('App installation changed the cold data container')
    outputs = [work / (phase + '-driver.log'), work / (phase + '-summary.json'), work / (phase + '-tests.json')]
    commands = [command(work, phase, udid),
        ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(work / (phase + '.xcresult'))],
        ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(work / (phase + '.xcresult'))]]
    results = [native._capture(argv, output, timeout) for argv, output, timeout in zip(commands, outputs, (960, 60, 60))]
    after = get_container(udid, bundle, 'data', work / (phase + '-container-after.log'))
    observed = source_state(work.parent)
    ledger = {'phase': phase, 'expectedMethod': METHODS[phase], 'sourceBefore': expected_source,
        'sourceAfter': observed, 'containerBefore': str(before), 'containerAfter': str(after), 'commands': results}
    write_new(work / (phase + '-execution.json'), ledger)
    if after != before or observed != expected_source:
        raise ValueError('Cold host changed source or its persistent container')
    if any(r['exitCode'] != 0 or r['timedOut'] is not False for r in results):
        raise ValueError('Cold host invocation/export failed or timed out')
    summary = read_json(outputs[1])
    if summary.get('expectedFailures', 0) != 0:
        raise ValueError('Expected failures cannot establish a cold host')
    native.smoke.verify_summary(summary, 1)
    verify_case(read_json(outputs[2]), METHODS[phase])
    return ledger


def terminate_producer(udid, bundle, pid, work):
    """Await the real owned host exit if XCTest left it alive; never sleep."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        write_new(work / 'producer-process-exit.json', {'producerPID': pid, 'alreadyExited': True})
        return
    # Kill only this app via simctl. Refuse to signal a PID which has been reused.
    installed = get_container(udid, bundle, 'app', work / 'producer-installed-app.log')
    process = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='], capture_output=True, check=True).stdout.decode().strip()
    if not process.startswith(str(installed) + '/'):
        raise ValueError('Producer PID no longer identifies the owned installed App')
    queue = select.kqueue()
    try:
        event = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
            fflags=select.KQ_NOTE_EXIT)
        try:
            queue.control([event], 0, 0)
        except ProcessLookupError:
            write_new(work / 'producer-process-exit.json', {'producerPID': pid, 'alreadyExited': True,
                'observedDuring': 'kernelRegistration'})
            return
        run_checked(['xcrun', 'simctl', 'terminate', udid, bundle], work / 'producer-terminate.log')
        events = queue.control(None, 1, 30)
        if len(events) != 1 or events[0].ident != pid or not events[0].fflags & select.KQ_NOTE_EXIT:
            raise ValueError('The actual producer process did not exit')
        write_new(work / 'producer-process-exit.json', {'producerPID': pid, 'observedKernelExit': True})
    finally:
        queue.close()


def run(work, udid):
    if sys.platform != 'darwin':
        raise ValueError('Actual cold process execution requires Apple Simulator')
    work = native.smoke.config.checked_path(work)
    work.mkdir(exist_ok=False)
    expected = source_state(work.parent)
    source = expected['nativeSourceState']['sourceCommit']
    settings = native.smoke.read_json(work.parent / 'build-settings.json')
    matches = [i['buildSettings'] for i in settings if i.get('target') == 'yuedu app']
    if len(matches) != 1:
        raise ValueError('Cold process requires one built main App')
    app = Path(matches[0]['TARGET_BUILD_DIR']) / matches[0]['FULL_PRODUCT_NAME']
    info = native.smoke.config.read_info(app)
    native.smoke.require_local_info(info); native.smoke.require_source_stamp(info, source)
    bundle = native.smoke.config.MAIN_BUNDLE
    run_checked(['xcrun', 'simctl', 'install', udid, str(app)], work / 'install.log')
    container = get_container(udid, bundle, 'data', work / 'installed-container.log')
    base = container / 'Library/Application Support/YueduNativeColdProcess'
    base.parent.mkdir(parents=True, exist_ok=True)
    base.mkdir(exist_ok=False)  # Stale fixture is failure, never an old pass.
    control = check_control({'schemaVersion': 1, 'runID': str(uuid.uuid4()), 'nonce': uuid.uuid4().hex + uuid.uuid4().hex,
        'sourceCommit': source, 'container': str(container)})
    owned = base / control['runID']; owned.mkdir(exist_ok=False)
    write_new(base / 'control.json', control); write_new(work / 'control.json', control)
    run_host(work, 'producer', expected, container, udid, bundle)
    producer = validate_producer(read_json(owned / 'producer-pending.json'), control, False)
    claim = read_json(owned / 'claim.json')
    if claim != {'control': control, 'bookID': producer['bookID']}:
        raise ValueError('Producer cache claim differs from its accepted fixture')
    producer['hostAccepted'] = True
    producer['hostExecutionSHA256'] = fact(work / 'producer-execution.json')['sha256']
    terminate_producer(udid, bundle, producer['producerPID'], work)
    commit_marker(owned / 'producer.json', producer); write_new(work / 'producer.json', producer)
    run_host(work, 'consumer', expected, container, udid, bundle)
    consumer = validate_consumer(read_json(owned / 'consumer-pending.json'), producer, control, False)
    if (owned / 'data').exists():
        raise ValueError('Consumer failed to clean its owned fixture data')
    consumer['hostAccepted'] = True
    consumer['hostExecutionSHA256'] = fact(work / 'consumer-execution.json')['sha256']
    commit_marker(owned / 'consumer.json', consumer); write_new(work / 'consumer.json', consumer)
    result = {'schemaVersion': 1, 'sourceState': expected, 'control': control,
        'producer': fact(work / 'producer.json'), 'consumer': fact(work / 'consumer.json'),
        'producerExitObservation': {'path': 'producer-process-exit.json', **fact(work / 'producer-process-exit.json')},
        'status': 'passed', 'actualIndependentHosts': 2, 'sourceResolutions': 0,
        'sameContainer': True, 'producerPeerStopped': True, 'differentPIDs': True,
        'scope': 'Synthetic original public reader/process restart only; no full source/device acceptance'}
    write_new(work / 'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=REPO / '.build/native-reader-test/cold-process')
    parser.add_argument('--udid', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.work, args.udid), indent=2))
    except Exception as error:
        # Preserve actual controller/host evidence. Unknown errors cannot create
        # producer/consumer accepted markers or an empty successful result.
        if args.work.is_dir() and not (args.work / 'failure.json').exists():
            write_new(args.work / 'failure.json', {'status': 'failed', 'errorType': type(error).__name__})
        raise


if __name__ == '__main__':
    main()
