from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
original = (out / 'original-reference/AnalyzeUrl.kt').read_text(encoding='utf-8')
start = original.index('    private fun encodeParams(')
end = original.index('\n\n    /**\n     * 执行JS', start)
methods = original[start:end]
path = root / 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeUrl.kt'
text = path.read_text(encoding='utf-8')
start_port = text.index('    private fun encodeParams(')
end_port = text.index('    private fun analyzeJs()', start_port)
path.write_text(text[:start_port] + methods + '\n\n' + text[end_port:], encoding='utf-8', newline='\n')
original_network = (out / 'original-reference/NetworkUtils.kt').read_text(encoding='utf-8')
start = original_network.index('    private val notNeedEncodingQuery:')
end = original_network.index('\n    /**\n     * 获取绝对地址', start)
network_methods = original_network[start:end]
path = root / 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleCompat.kt'
text = path.read_text(encoding='utf-8')
text = text.replace('import java.net.URL\n', 'import java.net.URL\nimport java.util.BitSet\n')
text = text.replace('internal object NetworkUtils {\n', 'internal object NetworkUtils {\n' + network_methods + '\n')
path.write_text(text, encoding='utf-8', newline='\n')
encoder_source = (out / 'original-reference/EncoderUtils.kt').read_text(encoding='utf-8')
start = encoder_source.index('    fun escape(')
end = encoder_source.index('\n    @JvmOverloads', start)
escape = encoder_source[start:end]
path = root / 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalUrlEncoding.kt'
assert not path.exists()
code = '''package io.yuedu.legado.originalrule

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStreamWriter
import java.nio.charset.Charset

/** AnalyzeUrl's exact RFC3986.UNRESERVED + authored safe-character codec.
 * Retains Hutool 5.8.22 PercentCodec's char-by-char writer/flush ordering,
 * including surrogate state across safe characters; no whole-string shortcut.
 */
internal object OriginalQueryEncoder {
    private const val SAFE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$%&()*+,/:;=?@[\\\\]^`{|}"
    fun encode(path: String, charset: Charset): String {
        if (path.isEmpty()) return path
        val rewritten = StringBuilder(path.length)
        val buffer = ByteArrayOutputStream()
        val writer = OutputStreamWriter(buffer, charset)
        for (char in path) {
            if (char in SAFE) rewritten.append(char)
            else {
                try { writer.write(char.code); writer.flush() }
                catch (_: IOException) { buffer.reset(); continue }
                for (byte in buffer.toByteArray()) {
                    val value = byte.toInt() and 255
                    rewritten.append('%').append("0123456789ABCDEF"[value ushr 4]).append("0123456789ABCDEF"[value and 15])
                }
                buffer.reset()
            }
        }
        return rewritten.toString()
    }
}

internal object EncoderUtils {
'''
path.write_text(code + escape + '\n}\n', encoding='utf-8', newline='\n')
record = {'encodeParamsAndAppendEncodedUtf8LFSHA256': hashlib.sha256(methods.encode()).hexdigest(),
          'networkEncodedClassifiersUtf8LFSHA256': hashlib.sha256(network_methods.encode()).hexdigest(),
          'encoderUtilsEscapeUtf8LFSHA256': hashlib.sha256(escape.encode()).hexdigest(),
          'scope': 'Original AnalyzeUrl loop, original NetworkUtils query/form classifier and original EncoderUtils.escape method bytes retained as LF text. Hutool PercentCodec char-writer algorithm is a finite port of pinned official 5.8.22 primary source.'}
(out / 'encoding-retention.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
print(json.dumps(record))
