package io.yuedu.legado

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.rule.TocRule
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.legado.app.model.webBook.BookChapterList
import io.yuedu.legado.originalrule.RuleEnvironment
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** Synthetic fixed vectors: no imported source rules, credentials, or live HTTP. */
class OriginalAesChapterUrlTest {
    @Test fun originalStringRuleDecryptsBase64AndHexAsUtf8WithoutDecodingKeyOrIv() {
        for (ciphertext in listOf(UNICODE_BASE64, UNICODE_HEX, UNICODE_HEX.uppercase())) {
            assertEquals(UNICODE_URL, decode(ciphertext))
        }
    }

    @Test fun originalStringRuleKeepsHutoolUrlSafeUnpaddedAndIgnoredByteBehavior() {
        for ((ciphertext, expected) in listOf(
            UNICODE_BASE64.trimEnd('=') to UNICODE_URL,
            UNICODE_BASE64.replace('+', '-').replace('/', '_').trimEnd('=') to UNICODE_URL,
            ASCII_BASE64.replace('+', '-').replace('/', '_').trimEnd('=') to ASCII_URL,
            UNICODE_BASE64.chunked(8).joinToString(" \n!") to UNICODE_URL,
        )) {
            assertEquals(expected, decode(ciphertext))
        }
    }

    @Test fun originalStringRuleAcceptsOddHexByAddingTheOriginalLeadingZero() {
        assertEquals("/r/1/chapter.html", decode(ODD_HEX))
    }

    @Test fun nativeReaderCiphertextFixturesKeepTheOriginalArgumentOrder() {
        for ((ciphertext, expected) in listOf(
            "xtsq3Y/W+IzkuzkuThYL1g==" to "/c1",
            "Rlmx38MFPxOh3PWApThsow==" to "/c2",
        )) {
            assertEquals(expected, decode(ciphertext, iv = "abcdef0123456789"))
        }
    }

    @Test fun invalidKeyIvPaddingAndBlockLengthThrowInsteadOfReturningABaseUrl() {
        for ((ciphertext, key, iv) in listOf(
            Triple(UNICODE_BASE64, "short", IV),
            Triple(UNICODE_BASE64, KEY, "short"),
            Triple(INVALID_PADDING_BASE64, KEY, IV),
            Triple(UNICODE_HEX.dropLast(2), KEY, IV),
        )) {
            assertThrows(Exception::class.java) { decode(ciphertext, key, iv, isUrl = true) }
        }
    }

    @Test fun originalDecoderChecksItsEnvironmentAndCallerCancellation() {
        val environment = RuleEnvironment()
        AnalyzeRule(environment = environment).use { rule ->
            environment.close()
            assertThrows(IllegalStateException::class.java) {
                rule.aesBase64DecodeToString(UNICODE_BASE64, KEY, "AES/CBC/PKCS5Padding", IV)
            }
        }
        AnalyzeRule().use { rule ->
            val job = Job()
            rule.setCoroutineContext(job)
            job.cancel()
            assertThrows(CancellationException::class.java) {
                rule.aesBase64DecodeToString(UNICODE_BASE64, KEY, "AES/CBC/PKCS5Padding", IV)
            }
        }
    }

    @Test fun originalJsonChapterListDecryptsItsActualChapterUrls() = runBlocking {
        RuleEnvironment().use { environment ->
            val source = BookSource(environment, ORIGIN, "Synthetic AES source")
            source.ruleToc = TocRule(chapterList = "$.chapters", chapterName = "$.name", chapterUrl = urlRule())
            val book = Book(environment, bookUrl = "$ORIGIN/book", tocUrl = "$ORIGIN/toc")
            val body = """{"chapters":[{"name":"中文章","path":"$UNICODE_BASE64"},{"name":"ASCII chapter","path":"$ASCII_HEX"}]}"""
            val chapters = BookChapterList.analyzeChapterList(source, book, book.tocUrl, book.tocUrl, body)
            assertEquals(listOf(UNICODE_URL, ASCII_URL), chapters.map { it.url })
            assertEquals(listOf(0, 1), chapters.map { it.index })
            assertEquals(listOf(book.tocUrl, book.tocUrl), chapters.map { it.baseUrl })
            assertEquals(2, book.totalChapterNum)
        }
    }

    @Test fun originalJsonChapterListRejectsAnUndecryptableUrl() {
        RuleEnvironment().use { environment ->
            val source = BookSource(environment, ORIGIN, "Synthetic AES source")
            source.ruleToc = TocRule(chapterList = "$.chapters", chapterName = "$.name", chapterUrl = urlRule())
            val book = Book(environment, bookUrl = "$ORIGIN/book", tocUrl = "$ORIGIN/toc")
            val body = """{"chapters":[{"name":"Invalid padding","path":"$INVALID_PADDING_BASE64"}]}"""
            assertThrows(Exception::class.java) {
                runBlocking { BookChapterList.analyzeChapterList(source, book, book.tocUrl, book.tocUrl, body) }
            }
            assertEquals(0, book.totalChapterNum)
            assertEquals(emptyList<Any>(), environment.webBook.chapters(book.bookUrl))
        }
    }

    private fun decode(ciphertext: String, key: String = KEY, iv: String = IV, isUrl: Boolean = false): String =
        AnalyzeRule().use { rule ->
            rule.setContent(jsonObject("path" to ciphertext).toString(), "$ORIGIN/toc")
            rule.getString(urlRule(key, iv), isUrl = isUrl)
        }

    private fun urlRule(key: String = KEY, iv: String = IV): String =
        "$.path@js:java.aesBase64DecodeToString(result,'$key','AES/CBC/PKCS5Padding','$iv')"

    companion object {
        private const val ORIGIN = "https://aes-fixture.invalid"
        // Literal UTF-8 keys are deliberate: both strings also look like hexadecimal.
        private const val KEY = "0123456789abcdef"
        private const val IV = "fedcba9876543210"
        private const val UNICODE_URL = "/reader/第一章.html?book=42"
        private const val ASCII_URL = "/reader/chapter-42.html"
        // Independently generated AES-128-CBC/PKCS7 vectors; no encrypt/decrypt round-trip oracle.
        private const val UNICODE_BASE64 = "PzXlRdnI1MU0ZZ+5qdEvsG11H+XaGYNQMTX45OVQejw="
        private const val UNICODE_HEX = "3f35e545d9c8d4c534659fb9a9d12fb06d751fe5da1983503135f8e4e5507a3c"
        private const val ASCII_BASE64 = "rcDdHgj6ppfvv6KQ0u2lblOS2WuDje6/zCyM0aFUIqI="
        private const val ASCII_HEX = "adc0dd1e08faa697efbfa290d2eda56e5392d96b838deebfcc2c8cd1a15422a2"
        private const val ODD_HEX = "29cb16df888b71259308af8a125743020058be14605f31974767f610464d431"
        // Decrypts to sixteen zero bytes, which cannot contain valid PKCS5/7 padding.
        private const val INVALID_PADDING_BASE64 = "C0vWcfZwfwm4OMPWyhxqPQ=="
    }
}
