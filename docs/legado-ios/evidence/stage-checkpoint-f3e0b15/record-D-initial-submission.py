"""One bounded initial receipt for the two already-pushed source-D tags.
No triggering, polling, downloads of artifacts, test execution or Git mutation.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import copy
import hashlib
import importlib.util
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'f3e0b15aae3b74e820f2ee86e5468c05a6c1d842'
OUT = ROOT / 'docs/legado-ios/evidence/stage-checkpoint-f3e0b15'
RECORD = ROOT / 'docs/legado-ios/stage-checkpoint-f3e0b15-initial.json'
FLAGS = ('allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished')
JOBS = (('smoke', 'reader-smoke.yml', 'reader-smoke-f3e0b15'),
        ('measurements', 'reader-measurements.yml', 'reader-measurements-f3e0b15'))


def require(test, message):
    if not test:
        raise ValueError(message)


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def exclusive(path, data):
    with path.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    require(path.read_bytes() == data, 'Written bytes differ')


def ref(path):
    data = path.read_bytes()
    return {'path': path.relative_to(ROOT).as_posix(), 'bytes': len(data),
            'sha256': hashlib.sha256(data).hexdigest()}


def fetch(job):
    name, workflow, tag = job
    url = 'https://api.github.com/repos/zhoujianjia/legado-ios/actions/workflows/' + workflow + '/runs?' + urlencode({
        'branch': tag, 'event': 'push', 'per_page': 20,
        'codex_initial_receipt': datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')})
    req = Request(url, headers={'User-Agent': 'Yuedu-source-bound-checkpoint-receipt',
                               'Accept': 'application/vnd.github+json', 'Cache-Control': 'no-cache'})
    with urlopen(req, timeout=45) as response:
        raw = response.read()
        status, headers = response.status, dict(response.headers.items())
    body = OUT / (name + '-runs.raw.json')
    http = OUT / (name + '-runs.http.json')
    exclusive(body, raw)
    exclusive(http, encoded({'URL': url, 'status': status, 'headers': headers,
                             'observedAtUTC': datetime.now(timezone.utc).isoformat()}))
    candidates = json.loads(raw)['workflow_runs']
    found = [run for run in candidates if run['head_sha'] == SOURCE and run['head_branch'] == tag
             and run['event'] == 'push' and run['path'] == '.github/workflows/' + workflow
             and run['repository']['full_name'] == 'zhoujianjia/legado-ios']
    require(len(found) <= 1, 'Ambiguous exact source/tag/workflow run')
    return {'name': name, 'workflow': '.github/workflows/' + workflow, 'tag': tag,
            'sourceCommit': SOURCE, 'sourceTagWorkflowBound': len(found) == 1,
            'run': None if not found else {key: found[0][key] for key in
                                           ('id', 'html_url', 'status', 'conclusion', 'created_at', 'updated_at')},
            'raw': [ref(body), ref(http)]}


def main():
    require(not OUT.exists() and not RECORD.exists(), 'Refusing repeated receipt')
    git = 'D:/app/Git/cmd/git.exe'
    require(subprocess.check_output([git, 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip() == SOURCE,
            'Source HEAD changed before recording')
    for _, _, tag in JOBS:
        require(subprocess.check_output([git, 'rev-parse', tag], cwd=ROOT).decode().strip() == SOURCE, 'Wrong tag')
    OUT.mkdir()
    with ThreadPoolExecutor(max_workers=2) as pool:
        runs = list(pool.map(fetch, JOBS))
    receipt = {'schemaVersion': 1, 'kind': 'initial-source-bound-stage-D-submission-receipt',
               'observedAtUTC': datetime.now(timezone.utc).isoformat(), 'sourceCommit': SOURCE,
               'runs': runs, 'APIRequests': 2, 'pollingPerformed': False,
               'statusIsOnlySavedObservation': True, 'newRuntimeOrCompatibilityAcceptance': False,
               'originalCFailurePreserved': True, 'AReleaseRebuilt': False,
               'unchangedRenewalRetriggered': False,
               'scope': 'Coherent new source-only smoke plus independent memory1/UI1/pure-UMD11; literal UMD reading5 is isolated and excluded. No device, Release or whole-feature acceptance.'}
    exclusive(RECORD, encoded(receipt))
    submission = {'sourceCommit': SOURCE, 'record': ref(RECORD), 'tagsPushed': True,
                  'runs': [{key: value for key, value in item.items() if key != 'raw'} for item in runs],
                  'passedCasesOrSamplesAccepted': False, 'originalResultsRemainSourceBound': True}
    names = ('completion-plan', 'reader-measurements-runner-batch', 'reader-launch-memory-batch',
             'umd-parser-preparation-batch', 'user-font-transaction-batch',
             'reading-position-integrity-batch', 'source-schema-reference-batch')
    paths = [ROOT / 'docs/legado-ios' / (name + '.json') for name in names]
    before = {p: p.read_bytes() for p in paths}
    values = {name: json.loads(before[path]) for name, path in zip(names, paths, strict=True)}
    plan = values['completion-plan']
    original = copy.deepcopy(plan)
    require(all(plan[k] is False for k in FLAGS), 'Global completion boundary changed')
    for name in names[1:]:
        values[name]['submittedStageDCheckpoint'] = copy.deepcopy(submission)
    for name, key in (('reader-measurements-runner-batch', 'measurementCloudSubmission'),
                      ('reader-launch-memory-batch', 'measurementCloudSubmission'),
                      ('umd-parser-preparation-batch', 'otherRunnerPreparation')):
        state = values[name][key]
        require(state['submitted'] is False, 'Already submitted')
        state['submitted'] = True
        state['submissionRecord'] = RECORD.relative_to(ROOT).as_posix()
        state['sourceCommit'] = SOURCE
    runner_state = values['reader-measurements-runner-batch']['measurementCloudSubmission']
    values['reader-measurements-runner-batch']['status'] = 'submitted-source-only-checkpoint-awaiting-actual-native-evidence'
    measurement = next(item for item in runs if item['name'] == 'measurements')
    runner_state['newTag'] = measurement['tag']
    runner_state['newRunID'] = measurement['run']['id'] if measurement['run'] else None
    for identity in ('reading-performance-and-prefetch', 'reading-experience-design',
                     'reading-position-write-integrity', 'source-schema'):
        package = next(p for p in plan['workpackages'] if p['id'] == identity)
        state = package['execution']
        state['currentState'] += ' 后续已按同阶段固定源码 f3e0b15 统一提交 smoke 与独立 measurement 检查点；此处仅记录提交，不推断新 Swift 用例、schema 行或性能样本通过。'
        if identity == 'reading-performance-and-prefetch':
            state['currentState'] = state['currentState'].replace('但该批尚未提交', '该批已统一提交，结果待验')
            state['remainingWork'][0] = '读取固定 f3e0b15 的独立 measurement 实际结果，逐组核对 memory 1/1、launch UI 1/1、UMD 11/11 与源码、环境和原始样本；保留旧 TXT 1 方法及 stage 50 行协议，不将提交等同通过。'
            state['nextAction'] = '检查集中提交的真实原始结果；仅对新改动、实际失败或未解决问题追加验证。云测期间继续其他 ready 开发，不重复触发或轮询等待。'
        else:
            state['nextAction'] = '读取 f3e0b15 同阶段 smoke 的实际对应分组与原始证据，按本包现有计数和边界分别验收；只有实际失败才追加必要修复，提交本身不建立通过或兼容。'
        state['evidence'].append(RECORD.relative_to(ROOT).as_posix())
    registration = plan['existingEvidence']['reader-measurements-runner-integration']
    registration['scope'] = registration['scope'].replace('code is present, not submitted:', 'code submitted at f3e0b15; actual results pending:')
    plan['existingEvidence']['stage-checkpoint-f3e0b15'] = {'path': RECORD.relative_to(ROOT).as_posix(),
        'scope': 'Two initial source/tag/workflow observations after coherent source-only submission; no passed case, sample or compatibility acceptance.'}
    policy = plan['execution']['cloudTriggerPolicy']
    policy['nextPlannedCheckpoint'] = 'Reviewed parser16, launch/memory9, runner8 and actual C test-owned temp-root repair are submitted together at source f3e0b15 as source-only smoke and independent memory1/UI1/UMD11. Reuse unchanged evidence, retain raw failures and continue ready work. No new Release or unchanged renewal run; literal UMD reading5 remains isolated.'
    policy['alreadyRunningTasks'] += ' Stage D f3e0b15 tags reader-smoke-f3e0b15 and reader-measurements-f3e0b15 were pushed together; initial receipt docs/legado-ios/stage-checkpoint-f3e0b15-initial.json records exactly two API reads, not current status or passing evidence.'
    for key in ('readyQueue', 'awaitingEvidenceQueue', 'deferredQueue', 'nextReadyBatch', 'currentDeviceCandidate'):
        require(plan['execution'][key] == original['execution'][key], 'Unexpected scheduling/device mutation')
    require(all(plan[k] is False for k in FLAGS), 'Completion boundary changed')
    for path, name in zip(paths, names, strict=True):
        raw = encoded(values[name])
        require(b'\xef\xbf\xbd' not in raw, 'Damaged UTF-8')
        exclusive(OUT / (name + '.before.json'), before[path])
        exclusive(OUT / (name + '.after.json'), raw)
    exclusive(OUT / Path(__file__).name, Path(__file__).read_bytes())
    require(all(p.read_bytes() == raw for p, raw in before.items()), 'Concurrent document mutation')
    for path, name in zip(paths, names, strict=True):
        raw = (OUT / (name + '.after.json')).read_bytes()
        temp = path.with_name('.' + path.name + '.D-receipt.tmp')
        exclusive(temp, raw)
        os.replace(temp, path)
    spec = importlib.util.spec_from_file_location('D_plan_check', ROOT / 'scripts/reader-experience/check-completion-plan.py')
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    checked = checker.validate(plan, json.loads((ROOT / 'docs/legado-ios/feature-catalog.json').read_bytes()), ROOT, require_execution=True)
    require(checked['status'] == 'passed', 'Plan structural gate failed')
    exclusive(OUT / 'plan-check.json', encoded(checked))
    print(json.dumps({'sourceCommit': SOURCE, 'record': ref(RECORD), 'runs': submission['runs'],
                      'newRuntimeAcceptance': False, 'planCheck': checked['status']}))


if __name__ == '__main__':
    main()
