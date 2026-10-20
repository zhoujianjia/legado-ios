package io.yuedu.legado

import com.google.gson.JsonElement
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import io.legado.app.exception.ContentEmptyException
import io.legado.app.exception.TocEmptyException
import io.legado.app.exception.NoStackTraceException
import io.legado.app.model.webBook.WebBook
import io.yuedu.legado.OriginalRuleDto.boolean
import io.yuedu.legado.OriginalRuleDto.int
import io.yuedu.legado.OriginalRuleDto.requiredObject
import io.yuedu.legado.OriginalRuleDto.requiredText
import io.yuedu.legado.OriginalRuleDto.text
import io.yuedu.legado.originalrule.rethrowRuleControlFailure
import kotlinx.coroutines.runBlocking
import java.io.IOException

/** Opt-in business execution at the existing public JSON/JNI boundary. This is not a probe,
 * a second parser/transport/state owner, or selection of the App's traditional-source route. */
internal object OriginalTraditionalRuntime {
    const val MAX_REQUEST_BYTES = 4 * 1024 * 1024
    const val MAX_RESULT_BYTES = 8 * 1024 * 1024
    fun checkRequestBudget(raw: String) {
        if (raw.length > MAX_REQUEST_BYTES || raw.toByteArray(Charsets.UTF_8).size > MAX_REQUEST_BYTES)
            throw RuntimeFailure("PAYLOAD_TOO_LARGE", "Original traditional request exceeds 4 MiB UTF-8")
    }
    fun validateSource(source: JsonObject) {
        require(source.requiredText("bookSourceUrl").isNotBlank()) { "Original source requires a stable bookSourceUrl" }
        if (!source.text("mainJs").isNullOrBlank()) throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Original traditional mode does not accept mainJs sources")
        if (source.int("bookSourceType", 0) != 0) throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Original traditional mode currently supports text sources only")
    }
    fun execute(task: RuntimeTask, operation: String, input: JsonObject): JsonElement {
        val fields = when (operation) {
            "search" -> setOf("key", "page", "timeoutMs")
            "details", "getBookInfo" -> setOf("book", "canReName", "timeoutMs")
            "toc", "getChapters" -> setOf("book", "runPreUpdateJs", "isFromBookInfo", "timeoutMs")
            "content", "getContent" -> setOf("book", "chapter", "nextChapterUrl", "needSave", "timeoutMs")
            else -> throw RuntimeFailure("UNSUPPORTED_OPERATION", "Original traditional mode does not support $operation")
        }
        require(input.keySet().all { it in fields }) { "Unknown original traditional request field" }
        // Saving requires App UUID/ChapterCacheRepository generation publication. The internal
        // owner save seam is separately tested, but this public API cannot invent that mapping.
        if (operation in setOf("content", "getContent") && (!input.has("needSave") || input.boolean("needSave", true)))
            throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Public original content requires explicit needSave=false until App generation mapping is connected")
        return try {
            LegadoRuntime.originalRuleEnvironment(task).use { environment ->
                val source = LegadoRuntime.originalBookSource(task, environment)
                val result = runBlocking(task.job) {
                    when (operation) {
                        "search" -> {
                            val page = if (input.has("page") && input["page"].isJsonNull) null else input.int("page", 1)
                            val books = WebBook.searchBookAwait(source, input.requiredText("key"), page)
                            jsonObject("books" to JsonArray().apply { books.forEach { add(OriginalRuleDto.book(it.toBook())) } })
                        }
                        "details", "getBookInfo" -> {
                            val book = OriginalRuleDto.book(input.requiredObject("book"), environment, source.bookSourceUrl)
                            WebBook.getBookInfoAwait(source, book, input.boolean("canReName", true))
                            jsonObject("book" to OriginalRuleDto.book(book))
                        }
                        "toc", "getChapters" -> {
                            val book = OriginalRuleDto.book(input.requiredObject("book"), environment, source.bookSourceUrl)
                            val chapters = WebBook.getChapterListAwait(source, book, input.boolean("runPreUpdateJs", false), input.boolean("isFromBookInfo", false)).getOrThrow()
                            jsonObject("book" to OriginalRuleDto.book(book), "chapters" to JsonArray().apply { chapters.forEach { add(OriginalRuleDto.chapter(it)) } })
                        }
                        else -> {
                            val book = OriginalRuleDto.book(input.requiredObject("book"), environment, source.bookSourceUrl)
                            val chapter = OriginalRuleDto.chapter(input.requiredObject("chapter"), environment, book)
                            val content = WebBook.getContentAwait(source, book, chapter, input.text("nextChapterUrl"), needSave = false)
                            jsonObject("book" to OriginalRuleDto.book(book), "chapter" to OriginalRuleDto.chapter(chapter), "content" to content)
                        }
                    }
                }
                task.ensureActiveForRuntime()
                if (result.toString().toByteArray(Charsets.UTF_8).size > MAX_RESULT_BYTES)
                    throw RuntimeFailure("PAYLOAD_TOO_LARGE", "Original traditional result exceeds 8 MiB UTF-8")
                result
            }
        } catch (error: Exception) {
            rethrowRuleControlFailure(error)
            task.ensureActiveForRuntime()
            when (error) {
                is TocEmptyException -> throw RuntimeFailure("TOC_EMPTY", error.message.orEmpty())
                is ContentEmptyException -> throw RuntimeFailure("CONTENT_EMPTY", error.message.orEmpty())
                is NoStackTraceException -> throw RuntimeFailure("RULE_ERROR", error.message.orEmpty())
                is IOException -> throw RuntimeFailure("HTTP_ERROR", error.message.orEmpty())
                else -> throw error
            }
        }
    }
}
