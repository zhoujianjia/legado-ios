package io.legado.app.model.webBook

import io.yuedu.legado.originalrule.*
import io.legado.app.utils.mapAsync

import io.legado.app.data.entities.*
import io.legado.app.exception.NoStackTraceException
import io.legado.app.model.analyzeRule.*
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.yuedu.legado.originalrule.*
import io.yuedu.legado.StrResponse
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Retained WebBook await orchestration through the single task-owned JVM HTTP.
 * Android launch/UI wrappers, durable saving, mainJs, media, file downloads,
 * explore UI navigation/rendering remain explicit unsupported. Batch persistence
 * requires the existing explicitly injected owner; this is not App save authorization.
 * This class name does not imply the full Android WebBook ABI or App routing.
 */
object WebBook {
    private suspend fun <T> owned(source: BookSource, book: Book? = null, chapter: BookChapter? = null, action: suspend () -> T): T {
        val environment = source.environment
        check(book == null || book.environment === environment) { "Book belongs to another original environment" }
        check(chapter == null || chapter.environment === environment) { "Chapter belongs to another original environment" }
        if (source.isJsSource()) unsupportedRule("WebBook mainJs uses the separate retained JsSourceBook route")
        if (source.bookSourceType != 0) unsupportedRule("original WebBook media/file source type")
        return environment.platform.runWebBook(currentCoroutineContext(), action)
    }
    suspend fun searchBookAwait(bookSource: BookSource, key: String, page: Int? = 1,
        filter: ((String, String, String?) -> Boolean)? = null, shouldBreak: ((Int) -> Boolean)? = null): ArrayList<SearchBook> =
        owned(bookSource) { searchBookAwaitOwned(bookSource, key, page, filter, shouldBreak) }
    suspend fun getBookInfoAwait(bookSource: BookSource, book: Book, canReName: Boolean = true): Book =
        owned(bookSource, book) { getBookInfoAwaitOwned(bookSource, book, canReName) }
    suspend fun runPreUpdateJs(bookSource: BookSource, book: Book, isFromBookInfo: Boolean = false): Result<Unit> =
        owned(bookSource, book) { runPreUpdateJsOwned(bookSource, book, isFromBookInfo) }
    suspend fun getChapterListAwait(bookSource: BookSource, book: Book, runPerJs: Boolean = false, isFromBookInfo: Boolean = false): Result<List<BookChapter>> =
        owned(bookSource, book) { getChapterListAwaitOwned(bookSource, book, runPerJs, isFromBookInfo) }
    suspend fun getContentAwait(bookSource: BookSource, book: Book, bookChapter: BookChapter, nextChapterUrl: String? = null, needSave: Boolean = true): String =
        owned(bookSource, book, bookChapter) { getContentAwaitOwned(bookSource, book, bookChapter, nextChapterUrl, needSave) }
    suspend fun preciseSearchAwait(bookSource: BookSource, name: String, author: String): Result<Book> =
        owned(bookSource) { preciseSearchAwaitOwned(bookSource, name, author) }
    suspend fun getContentBatchAwait(bookSource: BookSource, book: Book, chapters: List<BookChapter>): List<BookChapter> =
        owned(bookSource, book) {
            require(chapters.all { it.environment === book.environment && it.bookUrl == book.bookUrl }) { "Batch chapter belongs to another book/owner" }
            BookContent.analyzeContentBatch(bookSource, book, chapters)
        }
    suspend fun exploreBookAwait(bookSource: BookSource, url: String, page: Int? = 1): ArrayList<SearchBook> =
        owned(bookSource) { exploreBookAwaitOwned(bookSource, url, page) }
    private suspend fun exploreBookAwaitOwned(bookSource: BookSource, url: String, page: Int?): ArrayList<SearchBook> {
        val ruleData = RuleData()
        val sourceUrl = bookSource.bookSourceUrl
        val exploreInfoMap = OriginalExploreContexts.peek()
        val analyzeUrl = AnalyzeUrl(
            mUrl = url,
            page = page,
            baseUrl = sourceUrl,
            source = bookSource,
            ruleData = ruleData,
            coroutineContext = currentCoroutineContext(),
            environment = bookSource.environment,
            infoMap = exploreInfoMap
        )
        val checkJs = bookSource.loginCheckJs
        val res = kotlin.runCatching {
            analyzeUrl.getStrResponseAwait().let {
                if (!checkJs.isNullOrBlank()) { //检测书源是否已登录
                    analyzeUrl.evalJS(checkJs, it) as StrResponse
                } else {
                    it
                }
            }
        }.getOrElse { throwable ->
            if (throwable is Exception) { OriginalExploreContexts.rethrowMapTypeFailure(throwable); rethrowRuleControlFailure(throwable) }
            currentCoroutineContext().ensureActive()
            if (!checkJs.isNullOrBlank()) {
                val errResponse = analyzeUrl.getErrStrResponse(throwable)
                try {
                    (analyzeUrl.evalJS(checkJs, errResponse) as StrResponse).also {
                        if (it.code() == 500) {
                            throw throwable
                        }
                    }
                } catch (checkError: Throwable) {
                    if (checkError is Exception) { OriginalExploreContexts.rethrowMapTypeFailure(checkError); rethrowRuleControlFailure(checkError) }
                    currentCoroutineContext().ensureActive()
                    throw throwable
                }
            } else {
                throw throwable
            }
        }
        checkRedirect(bookSource, res)
        return BookList.analyzeBookList(
            bookSource = bookSource,
            ruleData = ruleData,
            analyzeUrl = analyzeUrl,
            baseUrl = res.url(),
            body = res.body(),
            isSearch = false
        )
    }

    private suspend fun searchBookAwaitOwned(
        bookSource: BookSource,
        key: String,
        page: Int? = 1,
        filter: ((name: String, author: String, kind: String?) -> Boolean)? = null,
        shouldBreak: ((size: Int) -> Boolean)? = null
    ): ArrayList<SearchBook> = run {
        val searchUrl = bookSource.searchUrl
        if (searchUrl.isNullOrBlank()) {
            throw NoStackTraceException("搜索url不能为空")
        }
        val ruleData = RuleData()
        val analyzeUrl = AnalyzeUrl(
            mUrl = searchUrl,
            key = key,
            page = page,
            baseUrl = bookSource.bookSourceUrl,
            source = bookSource,
            ruleData = ruleData,
            environment = bookSource.environment,
                    coroutineContext = currentCoroutineContext()
        )
        val checkJs = bookSource.loginCheckJs
        val res = kotlin.runCatching {
            analyzeUrl.getStrResponseAwait().let {
                if (!checkJs.isNullOrBlank()) { //检测书源是否已登录
                    analyzeUrl.evalJS(checkJs, it) as StrResponse
                } else {
                    it
                }
            }
        }.getOrElse { throwable ->
            if (throwable is Exception) rethrowRuleControlFailure(throwable)
            currentCoroutineContext().ensureActive()
            if (!checkJs.isNullOrBlank()) {
                val errResponse = analyzeUrl.getErrStrResponse(throwable)
                try {
                    (analyzeUrl.evalJS(checkJs, errResponse) as StrResponse).also {
                        if (it.code() == 500) {
                            throw throwable
                        }
                    }
                } catch (checkError: Throwable) {
                    if (checkError is Exception) rethrowRuleControlFailure(checkError)
                    currentCoroutineContext().ensureActive()
                    throw throwable
                }
            } else {
                throw throwable
            }
        }
        checkRedirect(bookSource, res)
        BookList.analyzeBookList(
            bookSource = bookSource,
            ruleData = ruleData,
            analyzeUrl = analyzeUrl,
            baseUrl = res.url(),
            body = res.body(),
            isSearch = true,
            isRedirect = res.raw().priorResponse?.isRedirect == true,
            filter = filter,
            shouldBreak = shouldBreak
        )
    }

    private suspend fun getBookInfoAwaitOwned(
        bookSource: BookSource,
        book: Book,
        canReName: Boolean = true,
    ): Book {
        book.removeAllBookType()
        book.addType(bookSource.getBookType())
        if (!book.infoHtml.isNullOrEmpty()) {
            BookInfo.analyzeBookInfo(
                bookSource = bookSource,
                book = book,
                baseUrl = book.bookUrl,
                redirectUrl = book.bookUrl,
                body = book.infoHtml,
                canReName = canReName
            )
        } else {
            val analyzeUrl = AnalyzeUrl(
                mUrl = book.bookUrl,
                baseUrl = bookSource.bookSourceUrl,
                source = bookSource,
                ruleData = book,
                environment = bookSource.environment,
                    coroutineContext = currentCoroutineContext()
            )
            val checkJs = bookSource.loginCheckJs
            val res = kotlin.runCatching {
                analyzeUrl.getStrResponseAwait().let {
                    if (!checkJs.isNullOrBlank()) { //检测书源是否已登录
                        analyzeUrl.evalJS(checkJs, it) as StrResponse
                    } else {
                        it
                    }
                }
            }.getOrElse { throwable ->
            if (throwable is Exception) rethrowRuleControlFailure(throwable)
            currentCoroutineContext().ensureActive()
                if (!checkJs.isNullOrBlank()) {
                    val errResponse = analyzeUrl.getErrStrResponse(throwable)
                    try {
                        (analyzeUrl.evalJS(checkJs, errResponse) as StrResponse).also {
                            if (it.code() == 500) {
                                throw throwable
                            }
                        }
                    } catch (checkError: Throwable) {
                        if (checkError is Exception) rethrowRuleControlFailure(checkError)
                        currentCoroutineContext().ensureActive()
                        throw throwable
                    }
                } else {
                    throw throwable
                }
            }
            checkRedirect(bookSource, res)
            BookInfo.analyzeBookInfo(
                bookSource = bookSource,
                book = book,
                baseUrl = book.bookUrl,
                redirectUrl = res.url(),
                body = res.body(),
                canReName = canReName
            )
        }
        return book
    }

    private suspend fun runPreUpdateJsOwned(bookSource: BookSource, book: Book, isFromBookInfo : Boolean = false): Result<Unit> {
        return kotlin.runCatching {
            val preUpdateJs = bookSource.ruleToc?.preUpdateJs
            if (!preUpdateJs.isNullOrBlank()) {
                AnalyzeRule(book, bookSource, true, isFromBookInfo)
                    .setCoroutineContext(currentCoroutineContext())
                    .evalJS(preUpdateJs)
            }
        }.onFailure {
            if (it is Exception) rethrowRuleControlFailure(it)
            currentCoroutineContext().ensureActive()
            if (it is Exception) rethrowRuleControlFailure(it)
            Debug.log(bookSource.bookSourceUrl, "执行preUpdateJs规则失败: $it")
        }
    }

    private suspend fun getChapterListAwaitOwned(
        bookSource: BookSource,
        book: Book,
        runPerJs: Boolean = false,
        isFromBookInfo : Boolean = false
    ): Result<List<BookChapter>> {
        book.removeAllBookType()
        book.addType(bookSource.getBookType())
        return kotlin.runCatching {
            if (runPerJs) {
                runPreUpdateJs(bookSource, book, isFromBookInfo).getOrThrow()
            }
            if (book.bookUrl == book.tocUrl && !book.tocHtml.isNullOrEmpty()) {
                BookChapterList.analyzeChapterList(
                    bookSource = bookSource,
                    book = book,
                    baseUrl = book.tocUrl,
                    redirectUrl = book.tocUrl,
                    body = book.tocHtml,
                    isFromBookInfo = isFromBookInfo
                )
            } else {
                val analyzeUrl = AnalyzeUrl(
                    mUrl = book.tocUrl,
                    baseUrl = book.bookUrl,
                    source = bookSource,
                    ruleData = book,
                    environment = bookSource.environment,
                    coroutineContext = currentCoroutineContext()
                )
                val checkJs = bookSource.loginCheckJs
                val res = kotlin.runCatching {
                    analyzeUrl.getStrResponseAwait().let {
                        if (!checkJs.isNullOrBlank()) { //检测书源是否已登录
                            analyzeUrl.evalJS(checkJs, it) as StrResponse
                        } else {
                            it
                        }
                    }
                }.getOrElse { throwable ->
            if (throwable is Exception) rethrowRuleControlFailure(throwable)
            currentCoroutineContext().ensureActive()
                    if (!checkJs.isNullOrBlank()) {
                        val errResponse = analyzeUrl.getErrStrResponse(throwable)
                        try {
                            (analyzeUrl.evalJS(checkJs, errResponse) as StrResponse).also {
                                if (it.code() == 500) {
                                    throw throwable
                                }
                            }
                        } catch (checkError: Throwable) {
                            if (checkError is Exception) rethrowRuleControlFailure(checkError)
                            currentCoroutineContext().ensureActive()
                            throw throwable
                        }
                    } else {
                        throw throwable
                    }
                }
                checkRedirect(bookSource, res)
                BookChapterList.analyzeChapterList(
                    bookSource = bookSource,
                    book = book,
                    baseUrl = book.tocUrl,
                    redirectUrl = res.url(),
                    body = res.body(),
                    isFromBookInfo = isFromBookInfo
                )
            }
        }.onFailure {
            if (it is Exception) rethrowRuleControlFailure(it)
            currentCoroutineContext().ensureActive()
        }
    }

    private suspend fun getContentAwaitOwned(
        bookSource: BookSource,
        book: Book,
        bookChapter: BookChapter,
        nextChapterUrl: String? = null,
        needSave: Boolean = true
    ): String {
        val saveToken = if (needSave) book.environment.webBook.contentSaveToken(book, bookChapter) else null
        if (saveToken != null && saveToken.version > 0) {
            book.environment.webBook.getContent(book, bookChapter, saveToken)?.let { return it }
        }
        if (bookChapter.isVolume && bookChapter.url.startsWith(bookChapter.title)) {
            Debug.log(bookSource.bookSourceUrl, "⇒一级目录正文不解析规则")
            return ""
        }
        val contentRule = bookSource.getContentRule()
        if (contentRule.content.isNullOrEmpty()) {
            Debug.log(bookSource.bookSourceUrl, "⇒正文规则为空,使用章节链接:${bookChapter.url}")
            return bookChapter.url
        }
        val content = if (bookChapter.url == book.bookUrl && !book.tocHtml.isNullOrEmpty()) {
            BookContent.analyzeContent(
                bookSource = bookSource,
                book = book,
                bookChapter = bookChapter,
                baseUrl = bookChapter.getAbsoluteURL(),
                redirectUrl = bookChapter.getAbsoluteURL(),
                body = book.tocHtml,
                nextChapterUrl = nextChapterUrl,
                needSave = false
            )
        } else {
            val analyzeUrl = AnalyzeUrl(
                mUrl = bookChapter.getAbsoluteURL(),
                baseUrl = book.tocUrl,
                source = bookSource,
                ruleData = book,
                chapter = bookChapter,
                environment = bookSource.environment,
                    coroutineContext = currentCoroutineContext()
            )
            val checkJs = bookSource.loginCheckJs
            val res = kotlin.runCatching {
                analyzeUrl.getStrResponseAwait(
                    jsStr = contentRule.webJs,
                    sourceRegex = contentRule.sourceRegex
                ).let {
                    if (!checkJs.isNullOrBlank()) { //检测书源是否已登录
                        analyzeUrl.evalJS(checkJs, it) as StrResponse
                    } else {
                        it
                    }
                }
            }.getOrElse { throwable ->
            if (throwable is Exception) rethrowRuleControlFailure(throwable)
            currentCoroutineContext().ensureActive()
                if (!checkJs.isNullOrBlank()) {
                    val errResponse = analyzeUrl.getErrStrResponse(throwable)
                    try {
                        (analyzeUrl.evalJS(checkJs, errResponse) as StrResponse).also {
                            if (it.code() == 500) {
                                throw throwable
                            }
                        }
                    } catch (checkError: Throwable) {
                        if (checkError is Exception) rethrowRuleControlFailure(checkError)
                        currentCoroutineContext().ensureActive()
                        throw throwable
                    }
                } else {
                    throw throwable
                }
            }
            checkRedirect(bookSource, res)
            BookContent.analyzeContent(
                bookSource = bookSource,
                book = book,
                bookChapter = bookChapter,
                baseUrl = bookChapter.getAbsoluteURL(),
                redirectUrl = res.url(),
                body = res.body(),
                nextChapterUrl = nextChapterUrl,
                needSave = false
            )
        }
        if (saveToken != null) {
            val saved = book.environment.webBook.saveContent(book, bookChapter, content, saveToken)
            book.environment.webBook.getContent(book, bookChapter, saveToken)?.let { return it }
            if (!saved) throw NoStackTraceException("正文缓存已更新,请重试")
        }
        return content
    }

    private suspend fun preciseSearchAwaitOwned(
        bookSource: BookSource,
        name: String,
        author: String,
    ): Result<Book> {
        return kotlin.runCatching {
            currentCoroutineContext().ensureActive()
            searchBookAwait(
                bookSource, name,
                filter = { fName, fAuthor, _ -> fName == name && fAuthor == author },
                shouldBreak = { it > 0 }
            ).firstOrNull()?.let { searchBook ->
                currentCoroutineContext().ensureActive()
                return@runCatching searchBook.toBook()
            }
            throw NoStackTraceException("未搜索到 $name($author) 书籍")
        }.onFailure {
            if (it is Exception) rethrowRuleControlFailure(it)
            currentCoroutineContext().ensureActive()
        }
    }
    private fun checkRedirect(bookSource: BookSource, response: StrResponse) {
        response.raw().priorResponse?.let { if (it.isRedirect) Debug.log(bookSource.bookSourceUrl, "重定向: ${response.url()}") }
    }
}
