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
import kotlinx.coroutines.currentCoroutineContext
import com.script.rhino.runScriptWithContext
import io.yuedu.legado.originalrule.OriginalExploreContexts
import io.yuedu.legado.originalrule.OriginalSourceLoginHost
import io.yuedu.legado.originalrule.GSON
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
        if (operation == "webJsRequest") return task.session.originalPages.request(task, input)
        if (operation == "webJsPageClose") return task.session.originalPages.close(task, input)
        val fields = when (operation) {
            "loginUi" -> setOf("values", "evaluationValues", "reuseState", "timeoutMs")
            "loginV2UI" -> setOf("stateJSON", "timeoutMs")
            "loginV2Action" -> setOf("action", "stateJSON", "form", "timeoutMs")
            "loginAction" -> setOf("action", "credentials", "isLongClick", "inputBindingFailed", "timeoutMs")
            "formLogin", "persistLoginInfo" -> setOf("credentials", "timeoutMs")
            "sourceCallback" -> setOf("event", "timeoutMs")
            "bookCallback" -> setOf("event", "book", "chapter", "result", "timeoutMs")
            "search" -> setOf("key", "page", "timeoutMs")
            "explore" -> setOf("url", "page", "timeoutMs")
            "exploreContext" -> setOf("action", "script", "timeoutMs")
            "details", "getBookInfo" -> setOf("book", "canReName", "timeoutMs")
            "toc", "getChapters" -> setOf("book", "runPreUpdateJs", "isFromBookInfo", "timeoutMs")
            "content", "getContent" -> setOf("book", "chapter", "nextChapterUrl", "needSave", "timeoutMs")
            "contentBatch", "getContentBatch" -> setOf("book", "chapters", "timeoutMs")
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
                        "loginUi" -> OriginalLoginUIRuntime.execute(source, input)
                        "loginV2UI", "loginV2Action" -> OriginalLoginV2Runtime.execute(source, operation, input)
                        "loginAction" -> OriginalLoginActionRuntime.execute(source, input)
                        "persistLoginInfo" -> {
                            require(input.int("timeoutMs", 30_000) in 1..30_000) { "Login-info persistence timeout must be between 1 and 30000 milliseconds" }
                            if (source.isLoginUiV2()) throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Interactive loginUi v2 is not connected")
                            val raw = input.requiredObject("credentials")
                            require(raw.size() <= 4096 && raw.entrySet().all { (_, value) -> value.isJsonPrimitive && value.asJsonPrimitive.isString }) { "Login-info values must be a bounded String map" }
                            val values = raw.entrySet().associateTo(linkedMapOf()) { (key, value) -> key to value.asString }
                            // Non-OK dismissal only persists the working Map. Do not
                            // read/evaluate getLoginJs, prelude, login(), or callbacks.
                            environment.platform.runWebBook(currentCoroutineContext()) {
                                if (values.isEmpty()) {
                                    source.removeLoginInfo()
                                    jsonObject("credentialsStored" to false, "credentialsCleared" to true, "executed" to false)
                                } else {
                                    val accepted = source.putLoginInfo(GSON.toJson(values))
                                    jsonObject("credentialsStored" to accepted, "credentialsCleared" to false, "executed" to false)
                                }
                            }
                        }
                        "formLogin" -> {
                            // The Android dialog has lifecycle cancellation, no fixed
                            // 30s form timer. This is the finite iOS embedding budget.
                            require(input.int("timeoutMs", 30_000) in 1..30_000) { "Form login timeout must be between 1 and 30000 milliseconds" }
                            if (source.isLoginUiV2()) throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Interactive loginUi v2 is not connected")
                            val loginJS = source.getLoginJs()
                            if (loginJS?.startsWith("http://", true) == true || loginJS?.startsWith("https://", true) == true)
                                throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Browser login navigation is not connected")
                            val raw = input.requiredObject("credentials")
                            require(raw.size() <= 4096 && raw.entrySet().all { (_, value) -> value.isJsonPrimitive && value.asJsonPrimitive.isString }) { "Form credentials must be a bounded String map" }
                            val loginData = raw.entrySet().associateTo(linkedMapOf()) { (key, value) -> key to value.asString }
                            environment.platform.runWebBook(currentCoroutineContext()) {
                                if (loginData.isEmpty()) {
                                    source.removeLoginInfo()
                                    jsonObject("credentialsStored" to false, "credentialsCleared" to true, "executed" to false)
                                } else if (!source.putLoginInfo(GSON.toJson(loginData))) {
                                    jsonObject("credentialsStored" to false, "credentialsCleared" to false, "executed" to false)
                                } else {
                                    if (!loginJS.isNullOrBlank()) {
                                        val context = currentCoroutineContext()
                                        OriginalSourceLoginHost(source).use { java ->
                                            runScriptWithContext(context) {
                                                source.evalJS("$loginJS\nif(typeof login=='function'){login.apply(this);}else{throw('Function login not implements!!!');}") {
                                                    put("java", java); put("result", loginData)
                                                    put("book", null); put("chapter", null); put("isLongClick", false)
                                                }
                                            }
                                        }
                                    }
                                    // Return values are ignored by the real dialog.
                                    // Never infer a login header from arbitrary JSON.
                                    jsonObject("credentialsStored" to true, "credentialsCleared" to false, "executed" to !loginJS.isNullOrBlank())
                                }
                            }
                        }
                        "sourceCallback" -> {
                            require(input.int("timeoutMs", 30_000) in 1..30_000) { "Original source callback timeout must be between 1 and 30000 milliseconds" }
                            val event = input.requiredText("event")
                            if (event !in setOf("startShelfRefresh", "endShelfRefresh"))
                                throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "This original source notification event is not connected")
                            val authored = source.getContentRule().callBackJs
                            // callBackSource itself has no eventListener gate. The actual
                            // App refresh caller gates once per listening source.
                            if (authored.isNullOrEmpty()) jsonObject("executed" to false)
                            else environment.platform.runWebBook(currentCoroutineContext()) {
                                val context = currentCoroutineContext()
                                runScriptWithContext(context) {
                                    source.evalJS(authored) {
                                        put("event", event); put("result", null)
                                        put("book", null); put("chapter", null)
                                    }
                                }
                                // Notifications neither consume the return nor request a
                                // UI fallback; no fake empty Book is constructed or saved.
                                jsonObject("executed" to true)
                            }
                        }
                        "bookCallback" -> {
                            val event = input.requiredText("event")
                            if (event !in setOf("startRead", "endRead", "saveRead", "addBookShelf"))
                                throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "This original notification event is not connected")
                            val authored = source.getContentRule().callBackJs
                            if (!task.session.source.boolean("eventListener", false) || authored.isNullOrEmpty())
                                jsonObject("executed" to false)
                            else {
                                val book = OriginalRuleDto.book(input.requiredObject("book"), environment, source.bookSourceUrl)
                                val rawChapter = input["chapter"]?.takeUnless(JsonElement::isJsonNull)
                                val chapter = rawChapter?.let {
                                    require(it.isJsonObject) { "chapter must be an object or null" }
                                    OriginalRuleDto.chapter(it.asJsonObject, environment, book)
                                }
                                val result = input.text("result")
                                environment.platform.runWebBook(currentCoroutineContext()) {
                                    val context = currentCoroutineContext()
                                    runScriptWithContext(context) {
                                        source.evalJS(authored) {
                                            put("event", event); put("result", result)
                                            put("book", book); put("chapter", chapter)
                                        }
                                    }
                                    // callBackBook ignores the authored return. Never stringify
                                    // an arbitrary Java/JS result or treat it as a UI decision.
                                    jsonObject("executed" to true)
                                }
                            }
                        }
                        "explore" -> {
                            val page = if (input.has("page") && input["page"].isJsonNull) null else input.int("page", 1)
                            val scope = environment.platform.exploreOwnerScope(source)
                            OriginalExploreContexts.withScope(scope, source.bookSourceUrl, environment, create = false) {
                                val books = WebBook.exploreBookAwait(source, input.requiredText("url"), page)
                                jsonObject("books" to JsonArray().apply { books.forEach { add(OriginalRuleDto.book(it)) } })
                            }
                        }
                        "exploreContext" -> {
                            val action = input.requiredText("action")
                            require(action in setOf("open", "evaluate", "savePending")) { "Unknown original exploration context action" }
                            require((action == "evaluate") == input.has("script")) { "Only exploration evaluate takes its authored UI expression" }
                            val scope = environment.platform.exploreOwnerScope(source)
                            environment.platform.runWebBook(currentCoroutineContext()) {
                                OriginalExploreContexts.withScope(scope, source.bookSourceUrl, environment, create = action == "open") { map ->
                                    var result: String? = null
                                    if (action == "evaluate") {
                                        val current = map ?: throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Open the original exploration context before evaluating its UI expression")
                                        try {
                                            val context = currentCoroutineContext()
                                            result = runScriptWithContext(context) { source.evalJS(input.requiredText("script")) { put("infoMap", current) } }.toString()
                                        } catch (error: Exception) {
                                            OriginalExploreContexts.rethrowMapTypeFailure(error)
                                            rethrowRuleControlFailure(error)
                                            task.ensureActiveForRuntime()
                                            environment.platform.log("${source.getTag()} exploreUi err: ${error.localizedMessage ?: error.toString()}")
                                        }
                                    } else if (action == "savePending" && map?.needSave == true) map.saveNow()
                                    jsonObject("infoMap" to map?.get(), "needSave" to (map?.needSave ?: false), "result" to result)
                                }
                            }
                        }
                        "search" -> {
                            val page = if (input.has("page") && input["page"].isJsonNull) null else input.int("page", 1)
                            val books = WebBook.searchBookAwait(source, input.requiredText("key"), page)
                            jsonObject("books" to JsonArray().apply { books.forEach { add(OriginalRuleDto.book(it)) } })
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
                        "contentBatch", "getContentBatch" -> {
                            val rawChapters = input["chapters"]
                            require(rawChapters != null && rawChapters.isJsonArray && rawChapters.asJsonArray.size() <= 32) { "Original contentBatch requires at most 32 chapter DTOs" }
                            val rawBook = input.requiredObject("book")
                            require(rawBook.requiredText("origin") == source.bookSourceUrl) { "Batch book belongs to another source" }
                            val identities = rawChapters.asJsonArray.map { raw ->
                                require(raw.isJsonObject) { "Original batch chapter must be an object" }
                                val chapter = raw.asJsonObject
                                require(chapter.requiredText("bookUrl") == rawBook.requiredText("bookUrl")) { "Batch chapter belongs to another book" }
                                chapter.int("index") to chapter.requiredText("url")
                            }
                            require(identities.all { it.first >= 0 && it.second.isNotBlank() } && identities.map { it.first }.toSet().size == identities.size) { "Original batch requires unique nonnegative indexes and chapter URLs" }
                            environment.platform.authorizeOriginalContentBatch(source, rawBook.requiredText("bookUrl"), identities)
                            val book = OriginalRuleDto.book(rawBook, environment, source.bookSourceUrl)
                            val chapters = rawChapters.asJsonArray.map { raw ->
                                require(raw.isJsonObject) { "Original batch chapter must be an object" }
                                OriginalRuleDto.chapter(raw.asJsonObject, environment, book, restorePersistentVariables = false)
                            }
                            require(chapters.map { it.index }.toSet().size == chapters.size) { "Original contentBatch chapter indexes must be unique" }
                            // Only the embedding App's current real BookStore/chapter generations can
                            // authorize body saves. DTOs/preview grants never grant this capability.
                            val missing = WebBook.getContentBatchAwait(source, book, chapters)
                            jsonObject("book" to OriginalRuleDto.book(book), "missingChapters" to JsonArray().apply { missing.forEach { add(OriginalRuleDto.chapter(it)) } })
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
