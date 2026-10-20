package io.yuedu.legado.originalrule

import com.script.ScriptException
import io.yuedu.legado.StrResponse
import io.legado.app.data.entities.BaseBook
import io.legado.app.data.entities.BaseSource
import io.legado.app.model.analyzeRule.RuleDataInterface
import io.legado.app.model.analyzeRule.AnalyzeUrl
import kotlin.coroutines.CoroutineContext
import java.util.logging.Logger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import io.yuedu.legado.RuntimeFailure
import org.htmlunit.corejs.javascript.WrappedException

class UnsupportedRuleCapability(val capability: String) : IllegalStateException("UNSUPPORTED_CAPABILITY: $capability")
internal fun unsupportedRule(capability: String): Nothing = throw UnsupportedRuleCapability(capability)

/** Keep escaping host control failures typed without changing JavaScript try/catch. */
internal fun rethrowRuleControlFailure(error: Exception) {
    var current: Throwable = error
    repeat(32) {
        current = when (val failure = current) {
            is UnsupportedRuleCapability -> throw failure
            is RulePersistenceException -> throw failure
            is CancellationException -> throw failure
            is RuntimeFailure -> {
                if (failure.code == "UNSUPPORTED_CAPABILITY") throw UnsupportedRuleCapability(failure.message.orEmpty())
                return
            }
            is ScriptException -> failure.cause ?: return
            is WrappedException -> failure.wrappedException ?: return
            else -> return
        }
    }
}

/** No network/browser/update-book capability is inferred from the existing mainJs hosts. */
open class RulePlatform {
    open suspend fun <T> runWebBook(context: CoroutineContext, action: suspend () -> T): T =
        unsupportedRule("original WebBook execution owner")
    open fun executeUrl(analyzed: AnalyzeUrl): StrResponse = unsupportedRule("original AnalyzeUrl execution")
    open fun exploreOwnerScope(source: BaseSource): String = unsupportedRule("original explore owner scope")
    /** Existing task deadline; no fresh rate-wait budget or scheduling owner. */
    open fun originalRateDelayBudgetMillis(source: BaseSource): Long =
        unsupportedRule("original concurrent rate needs the existing task deadline")
    /** Explicit embedding authority for actual body saves; never inferred from DTOs. */
    open fun authorizeOriginalContentBatch(source: BaseSource, bookUrl: String, chapters: List<Pair<Int, String>>) {
        unsupportedRule("original public batch requires the App book/chapter-generation save owner")
    }
    open fun storeLoginHeader(source: BaseSource, value: String?): Boolean = false
    open fun loginInfo(source: BaseSource): String? = unsupportedRule("checked source login-info owner")
    open fun storeLoginInfo(source: BaseSource, value: String?): Boolean = unsupportedRule("checked source login-info owner")
    open fun protectLoginDiagnostics(source: BaseSource) {}
    /** Transient same-task UI facts; never a credential/state owner or Host call. */
    open fun updateLoginUI(source: BaseSource, data: Map<String, Any?>?): Unit =
        unsupportedRule("form login UI data updates")
    open fun renderLoginUI(source: BaseSource, deltaUp: Boolean): Unit =
        unsupportedRule("form login UI refresh")
    /** Live checked presentation request, never a terminal UI-event payload. */
    open fun startLoginBrowser(source: BaseSource, url: String, title: String): Unit =
        unsupportedRule("original login browser presentation")
    open fun awaitLoginBrowser(source: BaseSource, url: String, title: String, refetchAfterSuccess: Boolean): StrResponse =
        unsupportedRule("original awaited login browser")
    open fun startLoginBrowser(source: BaseSource, url: String, title: String, html: String?) {
        if (html != null) unsupportedRule("original local HTML WebJS browser")
        startLoginBrowser(source, url, title)
    }
    open fun awaitLoginBrowser(source: BaseSource, url: String, title: String, refetchAfterSuccess: Boolean, html: String?): StrResponse {
        if (html != null) unsupportedRule("original local HTML WebJS browser")
        return awaitLoginBrowser(source, url, title, refetchAfterSuccess)
    }
    /** Existing parser/URL diagnostic sink; production may protect the current login task. */
    open fun ruleDiagnostic(error: Throwable, loggerName: String = "io.yuedu.legado.originalrule",
                            message: String = "Original rule evaluation diagnostic") {
        Logger.getLogger(loggerName).log(java.util.logging.Level.FINE, message, error)
    }
    open val userAgent: String? = null
    open val cookie: RuleCookieHost = RuleCookieHost()
    open fun request(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext): StrResponse =
        unsupportedRule("AnalyzeUrl HTTP orchestration is not connected to original rules")
    open fun request(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext,
                     requester: RuleJsExtensions): StrResponse = request(url, headers, callTimeout, context)
    open fun ajax(url: String, context: CoroutineContext, requester: RuleJsExtensions,
                  ruleData: RuleDataInterface?): String? = try { request(url, null, null, context, requester).body() }
    catch (error: Exception) { rethrowRuleControlFailure(error); throw error }
    /** Explicit WebBook URL inputs; nested ajax/connect keep their original empty defaults. */
    open fun requestUrl(url: String, source: BaseSource?, baseUrl: String, context: CoroutineContext,
                        key: String? = null, page: Int? = null): StrResponse = unsupportedRule("original WebBook URL request")
    open fun webJs(baseUrl: String?, html: String, js: String, result: Any, context: CoroutineContext): String =
        unsupportedRule("original-rule WebJS/browser")
    open fun refreshBookInfo(book: BaseBook?, source: BaseSource?, context: CoroutineContext): Nothing =
        unsupportedRule("original-rule WebBook refresh")
    open fun refreshToc(book: BaseBook?, source: BaseSource?, context: CoroutineContext): Nothing =
        unsupportedRule("original-rule WebBook TOC refresh")
    open fun log(value: Any?): Any? { Logger.getLogger("io.yuedu.legado.originalrule").fine(value?.toString()); return value }
}

open class RuleCookieHost {
    open fun getCookie(url: String): String = unsupportedRule("original CookieStore")
    open fun getCookie(url: String, key: String?): String = unsupportedRule("original CookieStore")
    open fun getKey(url: String, key: String): String = getCookie(url, key)
    open fun cookieToMap(cookie: String): MutableMap<String, String> = OriginalCookieText.cookieToMap(cookie)
    open fun mapToCookie(cookieMap: Map<String, String>?): String? = OriginalCookieText.mapToCookie(cookieMap)
    open fun setCookie(url: String, value: String?): Unit = unsupportedRule("original CookieStore")
    open fun setWebCookie(url: String, value: String): Unit = unsupportedRule("original CookieStore.setWebCookie browser mutation")
    open fun clear(): Unit = unsupportedRule("original CookieStore.clear OkHttp DB subset")
    open fun replaceCookie(url: String, value: String): Unit = unsupportedRule("original CookieStore")
    open fun removeCookie(url: String): Unit = unsupportedRule("original CookieStore")
}

/** A finite ABI, deliberately not the full upstream JsExtensions/JsEncodeUtils interface. */
interface RuleJsExtensions {
    fun getSource(): BaseSource?
    fun getTag(): String?
    fun getBatchContext(): io.legado.app.model.BatchContentContext? = null
    fun getRuleEnvironment(): RuleEnvironment
    fun getRuleCoroutineContext(): CoroutineContext
    fun ajax(url: Any): String?
    fun ajax(url: Any, callTimeout: Long?): String? = connect(if (url is List<*>) url.firstOrNull().toString() else url.toString(), null, callTimeout).body()
    fun connect(url: String): StrResponse = connect(url, null, null)
    fun connect(url: String, header: String?): StrResponse = connect(url, header, null)
    fun connect(url: String, header: String?, callTimeout: Long?): StrResponse {
        getRuleEnvironment().ensureOpen()
        return getRuleEnvironment().platform.request(url, header, callTimeout, getRuleCoroutineContext(), this)
    }
    fun webView(html: String?, url: String?, js: String?): Nothing = unsupportedRule("original-rule browser")
    fun cacheContent(chapter: Any?, content: String): Boolean {
        com.script.rhino.rhinoContextOrNull?.ensureActive()
        getRuleEnvironment().ensureOpen()
        getRuleCoroutineContext().ensureActive()
        val batchContext = getBatchContext()
            ?: throw io.legado.app.exception.NoStackTraceException("java.cacheContent 只能在批量正文规则中调用")
        val identifier = if (chapter is org.htmlunit.corejs.javascript.Wrapper) chapter.unwrap() else chapter
        return batchContext.saveContent(identifier, content)
    }
    fun refreshBookInfo(): Nothing = unsupportedRule("original-rule refreshBookInfo")
    fun refreshBookToc(): Nothing = unsupportedRule("original-rule refreshBookToc")
    fun refreshContent(): Nothing = unsupportedRule("original-rule refreshContent")
    fun log(value: Any?): Any? = getRuleEnvironment().platform.log(value)
    fun base64Decode(value: String?): String = RuleBase64.decode(value, "UTF-8")
    fun base64Decode(value: String?, charset: String): String = RuleBase64.decode(value, charset)
    fun base64Decode(value: String, flags: Int): String = String(RuleBase64.decodeAndroid(value, flags), Charsets.UTF_8)
    fun base64DecodeToByteArray(value: String?): ByteArray? = base64DecodeToByteArray(value, 0)
    fun base64DecodeToByteArray(value: String?, flags: Int): ByteArray? =
        if (value.isNullOrBlank()) null else RuleBase64.decodeAndroid(value, flags)
    fun base64Encode(value: String): String = RuleBase64.encodeAndroid(value, 2)
    fun base64Encode(value: String, flags: Int): String = RuleBase64.encodeAndroid(value, flags)
    fun strToBytes(value: String): ByteArray = value.toByteArray(Charsets.UTF_8)
    fun strToBytes(value: String, charset: String): ByteArray = value.toByteArray(charset(charset))
    fun bytesToStr(value: ByteArray): String = String(value, Charsets.UTF_8)
    fun bytesToStr(value: ByteArray, charset: String): String = String(value, charset(charset))
}


