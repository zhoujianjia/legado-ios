#!/usr/bin/env python3
"""Finite owned macOS producer check; never a native/Swift CMS acceptance gate."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
TAG_PREFIX = 'reader-owned-sdk-'
TOOL_ROOT = 'scripts/reader-experience/owned-package-fixture/'
SOURCE_INPUTS = (
    '.github/workflows/reader-owned-sdk-producer.yml',
    'scripts/reader-experience/owned-sdk-producer-check.py',
    'scripts/reader-experience/test-owned-sdk-producer-check.py',
    'scripts/reader-experience/renewal-probe-tools.py',
    'scripts/reader-experience/smoke-tools.py',
    'scripts/reader-experience/stage-config.py',
    'scripts/reader-experience/test-renewal-probe-tools.py',
    'Tests/iOS/yuedu appTests/SelfRenewalControlledPackageFixture.swift',
    'scripts/sim.sh',
    *(TOOL_ROOT + name for name in ('generate-sdk-owned-package.py','ImportOwnedIdentity.swift','main.c','extension.c','framework.c',
                                   'test-producer-diagnostics.py','test-producer-timeouts.py','test-producer-keychain-reopen.py')),
)
PHASES = ('toolchain','xcode-version','sdk-path','producer','stage')
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 17


def load_probe(repo):
    spec = importlib.util.spec_from_file_location('owned_sdk_existing_probe', repo/'scripts/reader-experience/renewal-probe-tools.py')
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    if probe.SDK_TOOL_ROOT != TOOL_ROOT:
        raise ValueError('Producer source ownership changed')
    return probe


def source_state(probe):
    probe.require_source_only()
    source = probe.smoke.source_sha()
    tag = TAG_PREFIX + source[:7]
    if (os.environ.get('GITHUB_SHA') != source or os.environ.get('GITHUB_REF_NAME') != tag
            or os.environ.get('GITHUB_REF') != 'refs/tags/' + tag
            or probe.smoke.git('rev-parse','--verify','refs/tags/' + tag + '^{commit}') != source):
        raise ValueError('Expected an exact owned-producer source tag and checkout')
    records = []
    for path in SOURCE_INPUTS:
        original = probe.smoke.git('show','HEAD:' + path,binary=True)
        actual, fact = probe._bounded_fact(probe.smoke.REPO/path, 8_388_608)
        if original != actual:
            raise ValueError('Owned producer input differs from source tag')
        records.append({'path':path,**fact})
    return {'sourceCommit':source,'sourceTag':tag,'sourceInputs':records,'runtimeSourceOnly':True}


def command_exit(command):
    if command.get('timedOut') is True: return 124
    if command.get('oversized') is True: return 125
    code = command.get('exitCode')
    if type(code) is not int: return 1
    return min(255,128-code) if code < 0 else min(255,code)


def capture_phase(probe, work, name, argv, seconds, expected):
    row = {'phase':name,'state':'failed','sourceBefore':None,'sourceAfter':None,
           'developerDirectory':os.environ.get('DEVELOPER_DIR'),'command':None,'timeoutSeconds':seconds}
    started = time.monotonic()
    try:
        row['sourceBefore'] = source_state(probe)
        if row['sourceBefore'] != expected: raise ValueError('Source changed before tool')
        row['command'] = probe._capture_xcresult(argv,work/('phase-' + name + '.log'),seconds=seconds,maximum=4_194_304)
        row['sourceAfter'] = source_state(probe)
        if row['sourceAfter'] != expected: raise ValueError('Source changed during tool')
        row['state'] = 'succeeded' if command_exit(row['command']) == 0 else 'failed'
    except Exception as error:
        # Commands are public and contain no passwords, but still avoid arbitrary
        # exception descriptions/tracebacks becoming new diagnostic channels.
        row['errorType'] = type(error).__name__
    row['elapsedSeconds'] = round(time.monotonic()-started,6)
    probe.smoke.config.write_new_json(work/('phase-' + name + '.json'),row)
    return row


def stage_public(probe, work, produced, inputs):
    # Reuse the one complete existing source/structure/hash/allowlist validator.
    # This does NOT run Swift verifiers, load an XCTest resource, or execute a
    # native method. The original generator itself performs its OpenSSL checks.
    verified = probe._verify_sdk_public(produced,inputs)
    destination = probe.smoke.config.checked_path(work/'sdk-produced-public')
    destination.mkdir(exist_ok=False)
    for name in sorted(probe._sdk_output_names() | {'sdk-produced-fixture-manifest.json'}):
        with (destination/name).open('xb') as stream:
            stream.write((produced/name).read_bytes())
    if probe._verify_sdk_public(destination,inputs) != verified:
        raise ValueError('Staged public bytes changed')
    return {'publicValidation':verified,'xctestResourceWritten':False,'nativeMethodsExecuted':0,
            'swiftCMSVerifierExecuted':False,'verificationKind':'existing source/structure/hash/allowlist checks',
            'generatorOpenSSLDetachedCMSCommandCount':4}


def intended_commands(repo, produced):
    return {
        'toolchain':(['bash',str(repo/'scripts/sim.sh'),'xcode'],20),
        'xcode-version':(['xcodebuild','-version'],30),
        'sdk-path':(['xcrun','--sdk','iphoneos','--show-sdk-path'],30),
        'producer':([sys.executable,str(repo/(TOOL_ROOT+'generate-sdk-owned-package.py')),'--output',str(produced)],600),
    }


def verify_pass(probe, work, produced, prepared, rows, guards_outcome):
    if guards_outcome != 'success': raise ValueError('Actual workflow portable guards must succeed')
    if source_state(probe) != prepared: raise ValueError('Final source changed')
    if tuple(row.get('phase') for row in rows) != PHASES: raise ValueError('Incomplete or reordered producer phases')
    selected_raw, _ = probe._bounded_fact(work/'phase-toolchain.log',4096)
    selected = selected_raw.decode('utf-8').strip()
    if os.environ.get('DEVELOPER_DIR') != selected or any(row.get('developerDirectory') != selected for row in rows[1:]):
        raise ValueError('Selected toolchain changed between phases')
    for row in rows:
        if row.get('state') != 'succeeded' or row.get('sourceBefore') != prepared or row.get('sourceAfter') != prepared:
            raise ValueError('A required actual producer phase did not succeed')
        stored = probe.smoke.read_json(work/('phase-' + row['phase'] + '.json'))
        if stored != row: raise ValueError('Phase evidence changed')
        if row['phase'] == 'stage':
            current = probe._verify_sdk_public(work/'sdk-produced-public',prepared['sourceInputs'])
            verification = row.get('verification')
            if (not isinstance(verification,dict) or verification.get('publicValidation') != current
                    or verification.get('xctestResourceWritten') is not False
                    or type(verification.get('nativeMethodsExecuted')) is not int or verification['nativeMethodsExecuted'] != 0
                    or verification.get('swiftCMSVerifierExecuted') is not False):
                raise ValueError('Staged public evidence changed or overstates acceptance')
            continue
        command = row.get('command')
        if (not isinstance(command,dict) or command_exit(command) != 0
                or command.get('timedOut') is not False or command.get('oversized') is not False):
            raise ValueError('Actual public tool failed or lacks its real verdict')
        argv, seconds = intended_commands(probe.smoke.REPO,produced)[row['phase']]
        if command.get('argv') != argv or row.get('timeoutSeconds') != seconds:
            raise ValueError('A different command or budget cannot replace the actual producer')
        for key,byte_key,hash_key in [('output','bytes','sha256'),('stderr','stderrBytes','stderrSHA256')]:
            path = work/command[key]
            _, actual = probe._bounded_fact(path,4_194_304)
            if path.name != command[key] or actual != {'bytes':command[byte_key],'sha256':command[hash_key]}:
                raise ValueError('Original public tool log changed')


def run_check(probe, work, produced):
    if sys.platform != 'darwin': raise ValueError('This finite check requires actual macOS/Xcode')
    if work.exists() or produced.exists(): raise ValueError('Refusing previous producer evidence or outputs')
    probe.smoke.config.checked_path(work).mkdir(parents=True)
    prepared = source_state(probe)
    probe.smoke.config.write_new_json(work/'source-inputs.json',prepared)
    rows = []
    developer = None
    first = None
    guards = os.environ.get('YUEDU_OWNED_PRODUCER_GUARDS_OUTCOME')
    if guards != 'success': first = {'phase':'portable-guards','exitCode':1}
    try:
        repo = probe.smoke.REPO
        commands = intended_commands(repo,produced)
        row = capture_phase(probe,work,'toolchain',*commands['toolchain'],prepared)
        rows.append(row)
        if row['state'] != 'succeeded': raise ValueError('Toolchain selection failed')
        raw_bytes, _ = probe._bounded_fact(work/'phase-toolchain.log',4096)
        raw = raw_bytes.decode('utf-8')
        if len(raw) > 4096 or not raw.endswith('\n') or len(raw.splitlines()) != 1:
            raise ValueError('Expected exactly one installed developer directory')
        path = Path(raw.strip())
        if not path.is_absolute() or not path.is_dir() or path.parts[-2:] != ('Contents','Developer'):
            raise ValueError('Selected toolchain directory is unavailable')
        probe.smoke.config.checked_path(path)
        developer = str(path); os.environ['DEVELOPER_DIR'] = developer
        for name in ('xcode-version','sdk-path','producer'):
            argv, seconds = commands[name]
            row = capture_phase(probe,work,name,argv,seconds,prepared)
            rows.append(row)
            if row['state'] != 'succeeded': raise ValueError('Required producer tool failed')
        started = time.monotonic()
        stage = {'phase':'stage','state':'failed','sourceBefore':source_state(probe),'sourceAfter':None,
                 'developerDirectory':developer,'command':None}
        try:
            if stage['sourceBefore'] != prepared: raise ValueError('Source changed before staging')
            stage['verification'] = stage_public(probe,work,produced,prepared['sourceInputs'])
            stage['sourceAfter'] = source_state(probe)
            if stage['sourceAfter'] != prepared: raise ValueError('Source changed while staging')
            stage['state'] = 'succeeded'
        except Exception as error: stage['errorType'] = type(error).__name__
        stage['elapsedSeconds'] = round(time.monotonic()-started,6)
        probe.smoke.config.write_new_json(work/'phase-stage.json',stage)
        rows.append(stage)
        verify_pass(probe,work,produced,prepared,rows,guards)
        result = {'schemaVersion':1,'scope':'ownedSDKProducerOnly','source':prepared,'developerDirectory':developer,
                  'actualProducerExitCode':0,'publicStagingVerified':True,'nativeMethodsExecuted':0,
                  'swiftCMSVerifierExecuted':False,'xctestResourceWritten':False,
                  'generatorOpenSSLDetachedCMSCommandCount':4,
                  'notAccepted':['native255','Swift CMS verifier','iPhone installation','Apple authorization','automatic renewal']}
        probe.smoke.config.write_new_json(work/'result.json',result)
    except Exception as error:
        for row in rows:
            if row['state'] != 'succeeded' and first is None:
                first = {'phase':row['phase'],'exitCode':command_exit(row['command']) if row.get('command') else 1}
        if first is None: first = {'phase':'validation','exitCode':1}
        error_type = type(error).__name__
    else: error_type = None
    after = None
    try: after = source_state(probe)
    except Exception as error:
        if first is None: first = {'phase':'final-source','exitCode':1}
        error_type = type(error).__name__
    # Never let an earlier successful result survive a final integrity failure.
    if (after != prepared or first is not None) and (work/'result.json').exists():
        (work/'result.json').unlink()
    if after != prepared and first is None: first = {'phase':'final-source','exitCode':1}
    for name in PHASES[len(rows):]:
        blocked = {'phase':name,'state':'blocked','blockedBy':first['phase'] if first else 'validation',
                   'sourceBefore':None,'sourceAfter':None,'command':None}
        probe.smoke.config.write_new_json(work/('phase-' + name + '.json'),blocked)
        rows.append(blocked)
    completed = {'schemaVersion':1,'scope':'ownedSDKProducerOnly','sourceBefore':prepared,'sourceAfter':after,
                 'developerDirectory':developer,'portableGuardsOutcome':guards,'phases':rows,'firstFailure':first,
                 'errorType':error_type,'passed':first is None,'nativeMethodsExecuted':0,'swiftCMSVerifierExecuted':False,
                 'rawProducerOutputsUploaded':False}
    probe.smoke.config.write_new_json(work/'completion.json',completed)
    return first['exitCode'] if first else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['run','validate-source'])
    arguments = parser.parse_args()
    probe = load_probe(REPO)
    try:
        if arguments.command == 'validate-source':
            print(json.dumps(source_state(probe),indent=2)); return 0
        code = run_check(probe,REPO/'.build/owned-sdk-producer-check',REPO/'.build/owned-sdk-producer-raw')
    except Exception as error:
        print('Owned producer check failed before execution: ' + type(error).__name__,file=sys.stderr)
        code = 1
    return code


if __name__ == '__main__': sys.exit(main())
