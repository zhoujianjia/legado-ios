package io.yuedu.legado.originalrule

/**
 * Hutool 5.8.22 Base64Decoder's four-sextet algorithm, translated to Kotlin.
 * Upstream author: looly. Licensed under MulanPSL-2.0; see vendor/originalrule/licenses.
 * The original JsExtensions String overload uses Hutool, not Android or JDK's strict decoder.
 * Preserve mixed standard/URL-safe alphabet, ignored bytes, and the original malformed-input
 * behavior; Android flags/byte-array overloads are explicitly outside this adapter.
 */
internal object RuleBase64 {
    private const val PADDING = -2
    private val table = IntArray(123) { -1 }.apply {
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".forEachIndexed { index, c -> this[c.code] = index }
        this['+'.code] = 62; this['-'.code] = 62
        this['/'.code] = 63; this['_'.code] = 63; this['='.code] = PADDING
    }
    fun decode(value: String?, charset: String): String {
        // Kotlin's original non-null String return rejects Hutool's null platform result.
        if (value == null) throw NullPointerException("decodeStr(...) must not be null")
        return String(decodeBytes(value.toByteArray(Charsets.UTF_8)), charset(charset))
    }
    private fun decodeBytes(input: ByteArray): ByteArray {
        if (input.isEmpty()) return input
        var offset = 0
        fun next(): Int {
            while (offset < input.size) {
                val byte = input[offset++].toInt()
                if (byte > -1) {
                    // This indexing intentionally retains Hutool 5.8.22's ASCII boundary behavior.
                    val decoded = table[byte]
                    if (decoded > -1) return decoded
                }
            }
            return PADDING
        }
        val output = ByteArray(input.size * 3 / 4)
        var index = 0
        while (offset < input.size) {
            val a = next(); val b = next(); val c = next(); val d = next()
            if (b != PADDING) output[index++] = ((a shl 2) or (b ushr 4)).toByte()
            if (c != PADDING) output[index++] = (((b and 15) shl 4) or (c ushr 2)).toByte()
            if (d != PADDING) output[index++] = (((c and 3) shl 6) or d).toByte()
        }
        return if (index == output.size) output else output.copyOf(index)
    }
}
