package io.yuedu.legado

import io.legado.app.lib.icu4j.CharsetDetector
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import org.jsoup.Jsoup
import java.nio.charset.Charset

/** OkHttpUtils.ResponseBody.text + EncodingDetect.getHtmlEncode's byte[] path. */
internal object LegadoResponseText {
    fun decode(input: ByteArray, contentType: String?): String {
        // Preserve Utf8BomUtils's strict size > 3 condition, including BOM-only input.
        val bytes = if (input.size > 3 && input[0] == 0xef.toByte() && input[1] == 0xbb.toByte() && input[2] == 0xbf.toByte())
            input.copyOfRange(3, input.size) else input
        val headerCharset = contentType?.toMediaTypeOrNull()?.charset()
        if (headerCharset != null) return String(bytes, headerCharset)
        return String(bytes, Charset.forName(detect(bytes)))
    }

    private fun detect(bytes: ByteArray): String {
        try {
            val start = indexOf(bytes, "<head>".toByteArray())
            val end = if (start >= 0) indexOf(bytes, "</head>".toByteArray(), start) else -1
            val head = if (end >= 0) String(bytes.copyOfRange(start, end + 7))
                else Regex("(?i)<head>[\\s\\S]*?</head>").find(String(bytes))!!.value
            for (meta in Jsoup.parseBodyFragment(head).getElementsByTag("meta")) {
                val charset = meta.attr("charset")
                if (charset.isNotEmpty()) return charset
                if (meta.attr("http-equiv").equals("content-type", true)) {
                    val content = meta.attr("content")
                    val offset = content.indexOf("charset=", ignoreCase = true)
                    val value = if (offset > -1) content.substring(offset + 8) else content.substringAfter(';')
                    if (value.isNotEmpty()) return value
                }
            }
        } catch (_: Exception) { /* Original EncodingDetect falls back to its ICU detector. */ }
        return CharsetDetector().setText(bytes).detect()?.name ?: "UTF-8"
    }

    private fun indexOf(bytes: ByteArray, needle: ByteArray, start: Int = 0): Int {
        for (offset in start..bytes.size - needle.size) {
            if (needle.indices.all { bytes[offset + it] == needle[it] }) return offset
        }
        return -1
    }
}
