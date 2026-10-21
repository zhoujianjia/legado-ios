"""ROOT ONLY. Consume root-saved actual observations; no query/poll/commit/push."""
import argparse
import datetime
import json
from pathlib import Path
from common import (ROOT, STAGE, CHECKPOINT, PLAN, FLAGS, WORKFLOWS, OLD_TERMINALS,
                    read, clean_head, closed_88, checkpoint_state, public_run_url,
                    fact, write_new, normalized_copy)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--observation', type=Path, required=True)
    args = parser.parse_args()
    observed_path = args.observation.resolve()
    assert observed_path.is_file() and observed_path.is_relative_to(ROOT / '.build')
    submission = read(STAGE / 'submission-v1.json')
    source = clean_head(submission['sourceCommit'])
    plan = read(ROOT / PLAN)
    cloud, history = closed_88(plan)
    _, counts, roster = checkpoint_state()
    assert submission['sourceCheckpoint'] == CHECKPOINT and submission['counts'] == counts
    assert submission['checkpointFact'] == fact(ROOT / CHECKPOINT)
    assert submission['canonicalSourceRoster'] == roster and submission['oldEvidencePreserved'] == history
    assert submission['newIPATag'] is False and submission['actualCloudHandlesObservedYet'] is False
    assert submission['atomicBranchAndTwoTagPushSucceeded'] is True
    observed = read(observed_path)
    assert isinstance(observed['observedUTC'], str) and observed['observedUTC']
    expected_tags = {prefix + source[:7]: name for prefix, name in WORKFLOWS.items()}
    assert set(submission['tags']) == set(expected_tags)
    assert len(observed['runs']) == 2 and {x['tag'] for x in observed['runs']} == set(expected_tags)
    handles, public_runs = [], []
    old_runs = {x[1] for x in OLD_TERMINALS}
    old_jobs = {x[2] for x in OLD_TERMINALS}
    for run in observed['runs']:
        assert run['sourceCommit'] == source and run['name'] == expected_tags[run['tag']]
        assert type(run['runID']) is int and run['runID'] > 0 and run['runID'] not in old_runs
        assert run['status'] in ('queued', 'in_progress') and run['conclusion'] is None, 'Already-terminal observation needs actual terminal archival, not a live handle'
        assert len(run['jobs']) == 1
        job = run['jobs'][0]
        assert type(job['jobID']) is int and job['jobID'] > 0 and job['jobID'] not in old_jobs
        assert job['status'] in ('queued', 'in_progress') and job['conclusion'] is None
        url = public_run_url(run['url'], run['runID'])
        handles.append(dict(workflow=run['name'], runID=run['runID'], jobID=job['jobID'],
            tag=run['tag'], sourceCommit=source, statusAtObservation=job['status'], url=url))
        public_runs.append(dict(name=run['name'], runID=run['runID'], tag=run['tag'],
            sourceCommit=source, status=run['status'], conclusion=None, url=url,
            jobs=[dict(jobID=job['jobID'], status=job['status'], conclusion=None)]))
    assert len({x['runID'] for x in handles}) == len({x['jobID'] for x in handles}) == 2
    rows = [(k, v) for k, v in plan['execution']['stepByStep'].items()
            if isinstance(v, dict) and v.get('record') == CHECKPOINT]
    assert len(rows) == 1 and not rows[0][1].get('submittedRequest')
    key, checkpoint_row = rows[0]
    request_relative = 'docs/legado-ios/core-sdk-' + source[:7] + '-request.json'
    request_path = ROOT / request_relative
    base = ROOT / ('docs/legado-ios/evidence/sdk-' + source[:7] + '-request')
    assert not request_path.exists() and not base.exists()
    assert not (STAGE / 'submission-canonical-roster.json').exists()
    preserved = []
    for source_name, target_name in [('submission-v1.json', 'submission.json'),
        ('submission-attempt-v1.json', 'submission-attempt.json'), ('common.py', 'root-helper-common.py'),
        ('submit-reviewed-checkpoint.py', 'submit-source.py'), ('record-submission.py', 'record-submission.py')]:
        preserved.append(normalized_copy(STAGE / source_name, base / target_name))
    public = base / 'initial-cloud-observation.json'
    write_new(public, dict(observedUTC=observed['observedUTC'], runs=public_runs))
    preserved.append({**fact(public), 'originalEvidence': fact(observed_path),
        'projection': 'Only actual public run/job/tag/source/status facts. Arbitrary connector fields and signed URLs are excluded.'})
    request = dict(schemaVersion=1, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        status='actual-sdk-native-api-characterization-pair-submitted-no-terminal-acceptance',
        sourceCommit=source, sourceCheckpoint=CHECKPOINT, observedUTC=observed['observedUTC'],
        handles=handles, counts=counts, newIPATag=False, actualResultAccepted=False,
        NativeProductCases=28, NativePlatformCharacterizations=2,
        previousClosedRunIDs=sorted(old_runs), previousTerminalAndInitialRequestFacts=history,
        oldTerminalJobsRepolled=False, preservedEvidence=preserved,
        limits='Workflow admission only. Both88 terminal failures and their original request remain historical failures. Pending platform characterization and Headless recompile have no new SDK/WK/JNI/device/renewal acceptance.',
        **{x: False for x in FLAGS})
    cloud['onlyLiveSDKHandles'] = handles
    cloud['currentUnifiedCheckpoint'] = dict(sourceCommit=source, requestRecord=request_relative,
        observedUTC=observed['observedUTC'], counts=counts, actualResultAccepted=False)
    cloud['alreadyRunningTasks'] = 'Exactly this newly observed SDK/Native pair; no IPA. Both88 terminal failures remain archived and must not be queried again.'
    cloud['nextPlannedCheckpoint'] = 'Preserve real terminal artifacts for these two handles only; repair actual failures before another coherent pair. Continue independent work without changing this source snapshot.'
    checkpoint_row['submittedRequest'] = request_relative
    checkpoint_row['submittedSourceCommit'] = source
    checkpoint_row['pendingUnifiedSDK'] = True
    next_actions = {
        'S1': '88轮SDK因两处生产API编译错误执行App0项；对应修复已合入，当前统一源码重新验证真实Bundle/IPA及材料读取。独立Package24通过不代表App验收；真实Apple材料与设备授权仍未验证。',
        'S2': '账号与材料生命周期及SPD二次认证分支已接线，当前统一SDK验证公开受控认证场景。真实Apple账号授权、证书/profile签发和有效期延长仍未验证。',
        'S3': 'CMS BER包络修复与严格signedAttrs/签名证书门禁已合入；当前统一SDK要求同job真实产物重签及独立验签用例实际通过。旧88仅producer成功，App签名用例执行0，真实设备续签未验证。',
        'S4': 'Lookup终态Complete、双向TLS服务端状态判定和peer事件退出修复已合入，当前统一SDK复验认证传输与安装客户端。已导入配对身份和显式可达安装服务仍为前提；免费团队单App无VPN/无伴侣/电脑关闭的同机安装通道仍未实现和验收。',
        'S5': '事务恢复等待环、uploadIntent前置和强解包修复已合入，当前统一SDK验证真实受控重签到安装事务及恢复；覆盖安装后冷启动与用户数据保留仍需设备证据。',
        'S6': '前台及系统允许的后台触发已有生产接线和持久节流，当前统一SDK复验触发与事务衔接；设备调度、到期恢复及长期无人值守仍未验证。',
    }
    for step in plan['execution']['stepByStep']['steps']:
        if step['id'] in next_actions:
            step['nextActionZh'] = next_actions[step['id']]
            step['pendingSDKRequest'] = request_relative
    assert all(plan[x] is False for x in FLAGS)
    write_new(request_path, request)
    # New admission records only; never overwrite any old request/terminal.
    (ROOT / PLAN).write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    for old in history:
        assert fact(ROOT / old['path']) == old
    paths = [request_path, ROOT / PLAN] + [ROOT / x['path'] for x in preserved]
    write_new(STAGE / 'submission-canonical-roster.json', [fact(p) for p in paths])
    print(json.dumps(dict(reviewedPaths=len(paths), handles=handles, planCheckpointKey=key, newIPATag=False)))


if __name__ == '__main__':
    main()
