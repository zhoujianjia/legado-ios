import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import urllib.request
import zipfile

BASE = Path(__file__).resolve().parent
REPO_API = 'https://api.github.com/repos/zhoujianjia/legado-ios/actions/'
SOURCE_A = 'a76d380fdc108db83be68961905ee49edd209571'
FONT_SOURCE = 'ccafee529e802b28fafc7b89e2c38cf9fc91d4c7'
HEADERS = {'Accept': 'application/vnd.github+json', 'User-Agent': 'yuedu-after-font-checkpoint-review'}

def request(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=45)

def get_json(url, path):
    with request(url) as stream:
        raw = stream.read()
    path.open('xb').write(raw)
    return json.loads(raw)

def write_json(path, value):
    path.open('xb').write((json.dumps(value, indent=2) + '\n').encode('utf-8'))

def extract_safely(path, destination):
    destination.mkdir()
    resolved_root = destination.resolve()
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        assert len(entries) < 30000
        assert sum(item.file_size for item in entries) < 3 * 1024**3
        seen = set()
        for item in entries:
            name = item.filename
            relative = PurePosixPath(name)
            assert not relative.is_absolute() and '..' not in relative.parts and ':' not in name and '\\' not in name and '\x00' not in name
            assert item.file_size <= 512 * 1024**2 and not item.flag_bits & 1
            assert (item.external_attr >> 16) & 0o170000 != 0o120000
            key = name.rstrip('/').casefold()
            assert key not in seen
            seen.add(key)
            target = destination.joinpath(*relative.parts)
            assert target.resolve().is_relative_to(resolved_root)
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, target.open('xb') as output:
                    while block := source.read(1024 * 1024):
                        output.write(block)

def checkpoint(kind):
    run_id, tag, workflow, expected = {
        'renewal': (39272841721, 'reader-renewal-a76d380', '.github/workflows/reader-renewal-probe.yml', {'reader-renewal-probe-evidence'}),
        'reader': (39272843081, 'reader-legado-a76d380', '.github/workflows/legado-reader.yml', {'legado-native-reader-unsigned', 'legado-native-reader-build-evidence'}),
    }[kind]
    root = BASE / 'cloud-a76d380'
    root.mkdir(exist_ok=True)
    prefix = 'after-font-checkpoint-' + kind
    url = REPO_API + 'runs/' + str(run_id)
    run = get_json(url, root / (prefix + '-run.json'))
    jobs = get_json(url + '/jobs', root / (prefix + '-jobs.json'))
    assert run['head_sha'] == SOURCE_A and run['head_branch'] == tag and run['path'] == workflow
    record = {'kind': kind, 'runID': run_id, 'url': run['html_url'], 'sourceCommit': SOURCE_A,
              'status': run['status'], 'conclusion': run.get('conclusion'),
              'jobs': [{'name': job['name'], 'status': job['status'], 'conclusion': job.get('conclusion'),
                        'activeOrFailedSteps': [{'name': step['name'], 'status': step['status'], 'conclusion': step.get('conclusion')}
                            for step in job['steps'] if step['status'] == 'in_progress' or step.get('conclusion') in {'failure', 'cancelled'}]}
                       for job in jobs['jobs']], 'artifacts': []}
    if run['status'] == 'completed':
        artifacts = get_json(url + '/artifacts', root / (prefix + '-artifacts.json'))['artifacts']
        assert {item['name'] for item in artifacts} <= expected
        if run['conclusion'] == 'success':
            assert {item['name'] for item in artifacts} == expected
        for artifact in artifacts:
            assert not artifact['expired'] and artifact.get('digest', '').startswith('sha256:')
            assert artifact['size_in_bytes'] <= 512 * 1024**2
            archive_path = root / ('after-font-checkpoint-' + artifact['name'] + '.zip')
            sha = hashlib.sha256()
            count = 0
            download = 'https://nightly.link/zhoujianjia/legado-ios/actions/runs/' + str(run_id) + '/' + artifact['name'] + '.zip'
            with request(download) as stream, archive_path.open('xb') as output:
                while block := stream.read(1024 * 1024):
                    count += len(block)
                    assert count <= 512 * 1024**2
                    sha.update(block)
                    output.write(block)
            assert count == artifact['size_in_bytes']
            assert 'sha256:' + sha.hexdigest() == artifact['digest']
            destination = root / ('after-font-checkpoint-' + artifact['name'])
            extract_safely(archive_path, destination)
            record['artifacts'].append({'name': artifact['name'], 'bytes': count, 'sha256': sha.hexdigest(),
                'githubArtifactDigestMatched': True, 'archivePath': str(archive_path), 'extractedRoot': str(destination),
                'packageFiles': [str(path) for path in destination.rglob('*') if path.is_file()
                    and (path.name.endswith('.ipa') or path.name in {'build-manifest.json', 'LocalBookshelf-source.zip', 'result.json',
                                                                  'unit-summary.json', 'discovery-summary.json', 'ui-summary.json'})]})
    write_json(root / (prefix + '-inspection.json'), record)
    print(json.dumps(record, indent=2))

def font_initial():
    root = BASE / 'cloud-ccafee5'
    root.mkdir(exist_ok=True)
    query = get_json(REPO_API + 'workflows/reader-smoke.yml/runs?head_sha=' + FONT_SOURCE + '&per_page=10',
                     root / 'initial-source-query.json')
    matches = [run for run in query['workflow_runs'] if run['head_sha'] == FONT_SOURCE and run['event'] == 'push'
               and run['head_branch'] == 'reader-smoke-ccafee5' and run['path'] == '.github/workflows/reader-smoke.yml']
    assert len(matches) <= 1
    if matches:
        write_json(root / 'initial-run.json', matches[0])
    record = {'sourceCommit': FONT_SOURCE, 'tag': 'reader-smoke-ccafee5', 'matchingRunCount': len(matches),
              'run': {key: matches[0].get(key) for key in ('id', 'html_url', 'status', 'conclusion')} if matches else None}
    write_json(root / 'initial-inspection.json', record)
    print(json.dumps(record, indent=2))

parser = argparse.ArgumentParser()
parser.add_argument('kind', choices=('renewal', 'reader', 'font'))
args = parser.parse_args()
font_initial() if args.kind == 'font' else checkpoint(args.kind)
