#!/usr/bin/env python3
"""Audit an exact Git source ZIP against the independently verified snapshot.

No archive content is extracted. This is source-byte verification, not license
clearance or a claim that external dependency sources are fully included.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

BASE = Path(__file__).resolve().parent
SOURCE_SHA = "a76d380fdc108db83be68961905ee49edd209571"
SNAPSHOT_RECORD_SHA256 = "8687680613095f3355da0d5ea3c084b4e7cf50074b5ace4cd9bc71f628c9c234"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(not os.path.lexists(args.output), 'Audit output already exists')
    result = {'schemaVersion': 1, 'sourceCommit': SOURCE_SHA, 'passed': False, 'sourceArchiveByteAuditPassed': False,
              'licenseOrDependencySourceClosureEstablished': False, 'signingOrDeviceExecutionPerformed': False,
              'scope': 'Exact tracked Git archive bytes; external dependency source closure remains separate.', 'issues': []}
    try:
        raw_record = (BASE / 'snapshot-record.json').read_bytes()
        require(sha(raw_record) == SNAPSHOT_RECORD_SHA256, 'The source snapshot record changed')
        record = json.loads(raw_record)
        require(record['sourceCommit'] == SOURCE_SHA and record['allGitBlobBytesVerified'] is True,
                'The independently verified source record has a different identity')
        expected = {item['path']: item for item in record['files']}
        require(len(expected) == record['fileCount'], 'Snapshot file paths repeat')
        prefix = 'LocalBookshelf-source/'
        allowed_directories = {prefix}
        for path in expected:
            parts = PurePosixPath(path).parts
            allowed_directories.update(prefix + '/'.join(parts[:count]) + '/' for count in range(1, len(parts)))
        with args.zip.open('rb') as stream:
            archive_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        observed = set()
        aggregate = hashlib.sha256()
        total = 0
        directories = 0
        with zipfile.ZipFile(args.zip) as archive:
            require(archive.comment == SOURCE_SHA.encode('ascii'), 'ZIP comment does not name the exact Git source commit')
            entries = archive.infolist()
            require(len(entries) <= 100_000 and sum(item.file_size for item in entries) <= 2 * 1024**3,
                    'Source ZIP exceeds bounded archive limits')
            names = set()
            for info in entries:
                name = info.filename
                require(name == info.orig_filename and name not in names and '\x00' not in name and '\\' not in name,
                        'Duplicate or invalid ZIP member path')
                names.add(name)
                parts = name.rstrip('/').split('/')
                require(name.startswith(prefix) and all(part and part not in {'.', '..'} and ':' not in part for part in parts),
                        'Source ZIP member escaped the expected prefix')
                require(not info.flag_bits & 1 and stat.S_IFMT(info.external_attr >> 16) in {0, stat.S_IFREG, stat.S_IFDIR},
                        'Encrypted or linked source ZIP member')
                if info.is_dir():
                    require(name in allowed_directories and info.file_size == 0, 'Unexpected source ZIP directory')
                    directories += 1
                    continue
                relative = name[len(prefix):]
                require(relative in expected and relative not in observed and 0 <= info.file_size <= 512 * 1024**2,
                        'Unexpected, duplicate or oversized source file: ' + relative)
                data = archive.read(info)
                frozen = expected[relative]
                blob = hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()
                digest = sha(data)
                require(len(data) == info.file_size == frozen['bytes'] and digest == frozen['sha256'] and blob == frozen['gitBlob'],
                        'Source ZIP bytes differ from the exact Git blob: ' + relative)
                observed.add(relative)
                total += len(data)
            require(observed == set(expected), 'Source ZIP omitted tracked source files')
        for relative in sorted(expected):
            aggregate.update(relative.encode('utf-8') + b'\0' + bytes.fromhex(expected[relative]['sha256']))
        result.update({'archivePath': str(args.zip), 'archiveBytes': args.zip.stat().st_size, 'archiveSHA256': archive_digest,
                       'snapshotRecordSHA256': SNAPSHOT_RECORD_SHA256, 'zipCommentMatchesCommit': True,
                       'gitTree': record['gitTree'], 'fileCount': len(observed), 'directoryCount': directories,
                       'uncompressedFileBytes': total, 'pathAndFileSHA256Digest': aggregate.hexdigest(),
                       'allFileBytesAndGitBlobsMatched': True, 'unsafeAndDuplicatePathsAbsent': True,
                       'passed': True, 'sourceArchiveByteAuditPassed': True})
    except Exception as error:
        result['issues'].append(type(error).__name__ + ': ' + str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({'sourceArchiveByteAuditPassed': result['sourceArchiveByteAuditPassed'],
                      'issues': result['issues'], 'output': str(args.output)}, indent=2))
    raise SystemExit(0 if result['sourceArchiveByteAuditPassed'] else 1)


if __name__ == '__main__':
    main()
