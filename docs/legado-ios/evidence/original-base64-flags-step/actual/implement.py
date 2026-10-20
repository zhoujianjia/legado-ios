from pathlib import Path
import hashlib,json
S=Path(__file__).parent;R=S.parent.parent
prefix='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/'
p=S/'work'/(prefix+'RulePlatform.kt');text=p.read_text(encoding='utf-8')
old='''    fun base64Decode(value: String, flags: Int): Nothing = unsupportedRule("Android Base64 flags overload")
    fun base64DecodeToByteArray(value: String?): Nothing = unsupportedRule("Android Base64 byte-array overload")
    fun base64DecodeToByteArray(value: String?, flags: Int): Nothing = unsupportedRule("Android Base64 flags overload")
    fun base64Encode(value: String): String = java.util.Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8))
    fun base64Encode(value: String, flags: Int): String {
        if (flags != 2) unsupportedRule("Android Base64 flags other than NO_WRAP")
        return base64Encode(value)
    }'''
new='''    fun base64Decode(value: String, flags: Int): String = String(RuleBase64.decodeAndroid(value, flags), Charsets.UTF_8)
    fun base64DecodeToByteArray(value: String?): ByteArray? = base64DecodeToByteArray(value, 0)
    fun base64DecodeToByteArray(value: String?, flags: Int): ByteArray? =
        if (value.isNullOrBlank()) null else RuleBase64.decodeAndroid(value, flags)
    fun base64Encode(value: String): String = RuleBase64.encodeAndroid(value, 2)
    fun base64Encode(value: String, flags: Int): String = RuleBase64.encodeAndroid(value, flags)'''
assert text.count(old)==1;text=text.replace(old,new);p.write_text(text,encoding='utf-8',newline='\n')
p=S/'work'/(prefix+'RuleBase64.kt');text=p.read_text(encoding='utf-8')
text=text.replace('behavior; Android flags/byte-array overloads are explicitly outside this adapter.','behavior. The separate Android overloads below deliberately do not use this decoder.')
assert text.endswith('}\n');text=text[:-2]+'''
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
        val separator = if (flags and 4 != 0) "\\r\\n" else "\\n"
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
''';p.write_text(text,encoding='utf-8',newline='\n')
mp=S/'work/Packages/LegadoRuntime/vendor/original-rule/manifest.json';m=json.loads(mp.read_text(encoding='utf-8'))
for row in m['portedSources']:
 if row['path'] in [prefix+'RulePlatform.kt',prefix+'RuleBase64.kt']:
  b=(S/'work'/row['path']).read_bytes();row.update(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
mp.write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print('IMPLEMENTED_TWO_SOURCE_ONE_METADATA')
