package io.yuedu.legado.originalrule

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStreamWriter
import java.nio.charset.Charset

/** AnalyzeUrl's exact RFC3986.UNRESERVED + authored safe-character codec.
 * Retains Hutool 5.8.22 PercentCodec's char-by-char writer/flush ordering,
 * including surrogate state across safe characters; no whole-string shortcut.
 */
internal object OriginalQueryEncoder {
    private const val SAFE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$%&()*+,/:;=?@[\\]^`{|}"
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
    fun escape(src: String): String {
        val tmp = StringBuilder()
        for (char in src) {
            val charCode = char.code
            if (charCode in 48..57 || charCode in 65..90 || charCode in 97..122) {
                tmp.append(char)
                continue
            }

            val prefix = when {
                charCode < 16 -> "%0"
                charCode < 256 -> "%"
                else -> "%u"
            }
            tmp.append(prefix).append(charCode.toString(16))
        }
        return tmp.toString()
    }

}
