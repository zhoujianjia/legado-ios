package io.yuedu.legado.originalrule

/**
 * Hutool 5.8.22 Base64Decoder's four-sextet algorithm, translated to Kotlin.
 * Upstream author: looly. Licensed under MulanPSL-2.0; see vendor/originalrule/licenses.
 * The original JsExtensions String overload uses Hutool, not Android or JDK's strict decoder.
 * Preserve mixed standard/URL-safe alphabet, ignored bytes, and the original malformed-input
 * behavior. The separate Android overloads below deliberately do not use this decoder.
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

    /*
     * Android flags decoding state machine adapted from android.util.Base64:
     * Copyright (C) 2010 The Android Open Source Project.
     * Licensed under the Apache License, Version 2.0 (the "License");
     * you may not use this file except in compliance with the License.
     * You may obtain a copy at https://www.apache.org/licenses/LICENSE-2.0
     * Unless required by applicable law or agreed to in writing, software is
     * distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
     * KIND, either express or implied. See the License for the specific language
     * governing permissions and limitations under the License. The full license
     * is retained in vendor/licenses/htmlunit-core-js/5.3.0-legado.4/LICENSE-APACHE-2.0.txt.
     * This one-shot Kotlin port omits the original streaming/fast paths.
     */
    fun decodeAndroid(value: String, flags: Int): ByteArray {
        val input = value.toByteArray(Charsets.UTF_8)
        val output = ByteArray(input.size * 3 / 4)
        val webSafe = flags and 8 != 0
        var state = 0
        var bits = 0
        var count = 0
        fun invalid(): Nothing = throw IllegalArgumentException("bad base-64")
        for (byte in input) {
            val c = byte.toInt() and 255
            val digit = when (c) {
                in 65..90 -> c - 65
                in 97..122 -> c - 71
                in 48..57 -> c + 4
                (if (webSafe) 45 else 43) -> 62
                (if (webSafe) 95 else 47) -> 63
                61 -> -2
                else -> -1
            }
            when (state) {
                0, 1 -> if (digit >= 0) {
                    bits = (bits shl 6) or digit
                    state++
                } else if (digit != -1) invalid()
                2 -> if (digit >= 0) {
                    bits = (bits shl 6) or digit
                    state = 3
                } else if (digit == -2) {
                    output[count++] = (bits shr 4).toByte()
                    state = 4
                }
                3 -> if (digit >= 0) {
                    bits = (bits shl 6) or digit
                    output[count++] = (bits shr 16).toByte()
                    output[count++] = (bits shr 8).toByte()
                    output[count++] = bits.toByte()
                    state = 0
                    bits = 0
                } else if (digit == -2) {
                    output[count++] = (bits shr 10).toByte()
                    output[count++] = (bits shr 2).toByte()
                    state = 5
                }
                4 -> if (digit == -2) state = 5 else if (digit != -1) invalid()
                5 -> if (digit != -1) invalid()
            }
        }
        when (state) {
            1, 4 -> invalid()
            2 -> output[count++] = (bits shr 4).toByte()
            3 -> {
                output[count++] = (bits shr 10).toByte()
                output[count++] = (bits shr 2).toByte()
            }
        }
        return if (count == output.size) output else output.copyOf(count)
    }

    fun encodeAndroid(value: String, flags: Int): String {
        var encoder = if (flags and 8 != 0) java.util.Base64.getUrlEncoder() else java.util.Base64.getEncoder()
        if (flags and 1 != 0) encoder = encoder.withoutPadding()
        val encoded = encoder.encodeToString(value.toByteArray(Charsets.UTF_8))
        if (flags and 2 != 0 || encoded.isEmpty()) return encoded
        val separator = if (flags and 4 != 0) "\r\n" else "\n"
        return buildString {
            var start = 0
            while (start < encoded.length) {
                val end = minOf(start + 76, encoded.length)
                append(encoded, start, end)
                append(separator)
                start = end
            }
        }
    }
}
