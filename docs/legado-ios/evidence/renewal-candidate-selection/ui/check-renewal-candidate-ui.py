"""Static localization and Swift grammar checks, never Swift/SDK execution."""
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '.build/renewal-candidate-ui-validation'
SKIP = re.compile(r'(?:\s+|/\*.*?\*/|//[^\n]*(?:\n|$))*', re.S)
ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)


def table(raw):
    text, position, values = raw.decode('utf-8'), 0, {}
    assert '\ufffd' not in text
    while position < len(text):
        position = SKIP.match(text, position).end()
        if position == len(text):
            break
        match = ENTRY.match(text, position)
        assert match and match[1] not in values, 'Malformed or duplicate string'
        values[match[1]] = match[2]
        position = match.end()
    return values


def main():
    assert not OUT.exists()
    OUT.mkdir()
    paths = sorted((ROOT / 'Resources').glob('*.lproj/Localizable.strings'))
    assert len(paths) == 5
    tables = [table(p.read_bytes()) for p in paths]
    assert all(set(value) == set(tables[0]) for value in tables)
    keys = {'候選入口總數', '本輪未選擇的入口', '本輪選中的入口已失效',
            '本輪只會嘗試選中的部分入口，其餘候選未檢查。TCP 連通不能確認設備服務或自續簽。'}
    assert keys <= set(tables[0])
    relative = 'Modules/Features/Settings/SelfRenewalProbeView.swift'
    raw = (ROOT / relative).read_bytes()
    assert set(re.findall(r'localized\("([^"\\]+)"\)', raw.decode('utf-8'))) <= set(tables[0])
    sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
    from tree_sitter import Language, Parser
    import tree_sitter_swift
    parsed = Parser(Language(tree_sitter_swift.language())).parse(raw)
    assert not parsed.root_node.has_error, 'Swift grammar error (not typecheck)'
    files = [*paths, ROOT / relative]
    result = {'status': 'passed', 'languages': 5, 'keysPerLanguage': len(tables[0]),
              'newKeys': sorted(keys), 'duplicates': 0, 'grammarFiles': 1,
              'SwiftTypecheckPerformed': False, 'SDKOrIOSTestsExecuted': 0,
              'files': [{'path': p.relative_to(ROOT).as_posix(), 'bytes': len(p.read_bytes()),
                         'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]}
    with (OUT / 'result.json').open('xb') as stream:
        stream.write((json.dumps(result, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
    print(json.dumps({k: v for k, v in result.items() if k not in ('files', 'newKeys')}))


if __name__ == '__main__':
    main()
