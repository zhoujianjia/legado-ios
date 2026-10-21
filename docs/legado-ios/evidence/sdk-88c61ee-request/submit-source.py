"""ROOT ONLY. Review this draft before execution. No IPA or other workflow tag."""
import datetime
import json
import subprocess
from common import (ROOT, STAGE, GIT, CHECKPOINT, WORKFLOWS, clean_head,
                    read, closed_fc3, checkpoint_state, fact, write_new)

def main():
    output = STAGE / 'submission-v1.json'
    assert not output.exists()
    source = clean_head()
    assert subprocess.check_output([GIT, 'symbolic-ref', '--short', 'HEAD'], cwd=ROOT).decode().strip() == 'legado-ios-prototype'
    plan = read(ROOT / 'docs/legado-ios/completion-plan.json')
    closed_fc3(plan)
    record, counts, union = checkpoint_state()
    tags = [prefix + source[:7] for prefix in WORKFLOWS]
    for tag in tags:
        existing = subprocess.run([GIT, 'show-ref', '--verify', '--quiet', 'refs/tags/' + tag], cwd=ROOT)
        assert existing.returncode == 1, (tag, existing.returncode)
        remote = subprocess.check_output([GIT, 'ls-remote', '--tags', 'origin', 'refs/tags/' + tag], cwd=ROOT)
        assert not remote.strip(), tag
    subprocess.run([GIT, 'push', 'origin', 'legado-ios-prototype'], cwd=ROOT, check=True)
    for tag in tags:
        subprocess.run([GIT, 'tag', tag, source], cwd=ROOT, check=True)
    subprocess.run([GIT, 'push', '--atomic', 'origin', *['refs/tags/' + tag for tag in tags]], cwd=ROOT, check=True)
    write_new(output, {
        'schemaVersion': 1, 'submittedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'sourceCommit': source, 'tags': tags, 'counts': counts, 'sourceCheckpoint': CHECKPOINT,
        'checkpointFact': fact(ROOT / CHECKPOINT), 'canonicalUnionEvidence': union,
        'controls': 5, 'productionSourceBindings': 30, 'exactBoundInputCount': 362,
        'GeneralWebJSBase64RuntimeAndCookieRepairsIncluded': True,
        'blankRegexSuccessorIncluded': True, 'independentColdHosts': 2,
        'newIPATag': False, 'actualSwiftSDKOrJNIResultYet': False,
        'actualCloudHandlesObservedYet': False, 'oldTerminalJobsRepolled': False,
    })
    print(json.dumps({'sourceCommit': source, 'tags': tags, 'newIPATag': False}))

if __name__ == '__main__':
    main()
