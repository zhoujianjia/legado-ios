import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
source = out / 'hutool-primary/RegexPool.java'
text = source.read_text(encoding='utf-8')
expressions = {}
assignments = {}
for name in ['IPV4', 'IPV6']:
    match = re.search(r'^\s*String ' + name + r' = ("(?:[^"\\]|\\.)*");', text, re.M)
    assert match
    expressions[name] = json.loads(match.group(1))
    assignments[name] = match.group(0).strip()
target = root / 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalIpValidator.kt'
assert not target.exists()
code = '''package io.yuedu.legado.originalrule

/** Hutool 5.8.22 Validator.isIpv4/isIpv6 + exact RegexPool patterns (MIT).
 * Primary bytes and notices are recorded in vendor/original-rule/manifest.json.
 * No DNS lookup, address canonicalization or approximate suffix classification.
 */
internal object OriginalIpValidator {
'''
for name, expression in expressions.items():
    code += '    private val ' + name.lower() + ' = Regex("""' + expression + '""")\n'
code += '    fun isIpv4(value: CharSequence?): Boolean = value != null && ipv4.matches(value)\n'
code += '    fun isIpv6(value: CharSequence?): Boolean = value != null && ipv6.matches(value)\n}\n'
target.write_text(code, encoding='utf-8', newline='\n')
reference = root / 'Packages/LegadoRuntime/jvm/src/test/java/io/yuedu/legado/reference/HutoolIpPatterns.java'
assert not reference.exists()
reference.parent.mkdir(parents=True, exist_ok=True)
reference.write_text('package io.yuedu.legado.reference;\n\n/** Exact Hutool 5.8.22 RegexPool assignments, test reference only (MIT). */\npublic interface HutoolIpPatterns {\n' + '\n'.join('    ' + value for value in assignments.values()) + '\n}\n', encoding='utf-8', newline='\n')
record = {'originalRegexPool': {'path': source.relative_to(root).as_posix(), 'bytes': source.stat().st_size, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()},
          'production': {'path': target.relative_to(root).as_posix(), 'bytes': target.stat().st_size, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()},
          'testReference': {'path': reference.relative_to(root).as_posix(), 'bytes': reference.stat().st_size, 'sha256': hashlib.sha256(reference.read_bytes()).hexdigest()},
          'methodSeam': 'Validator delegates PatternPool.IPV4/IPV6 to ReUtil.isMatch(pattern,value), which is a null check then pattern.matcher(value).matches(). Source bytes retained separately; no full Hutool dependency added.'}
(out / 'ip-regex-port.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
print(json.dumps(record))
