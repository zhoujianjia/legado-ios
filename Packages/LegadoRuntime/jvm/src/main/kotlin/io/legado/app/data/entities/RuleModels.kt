package io.legado.app.data.entities

import io.legado.app.model.analyzeRule.RuleDataInterface
import io.yuedu.legado.originalrule.*
import com.script.buildScriptBindings
import com.script.ScriptBindings
import com.script.rhino.RhinoScriptEngine
import com.script.rhino.rhinoContextOrNull
import com.script.rhino.ScriptExecutionGuard
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/** Java-bean rule model, not the Android Book/Room entity or its application methods. */
class Book(
    @Transient internal val environment: RuleEnvironment,
    override var name: String = "",
    override var author: String = "",
    override var bookUrl: String = "",
    var tocUrl: String = "",
    var origin: String = "loc_book",
    override var kind: String? = null,
    override var wordCount: String? = null,
    override var variable: String? = null,
    override var infoHtml: String? = null,
    override var tocHtml: String? = null,
    var originName: String = "",
    var originOrder: Int = 0,
    var type: Int = 8,
    var coverUrl: String? = null,
    var intro: String? = null,
    var latestChapterTitle: String? = null,
    var latestChapterTime: Long = System.currentTimeMillis(),
    var lastCheckTime: Long = System.currentTimeMillis(),
    var lastCheckCount: Int = 0,
    var totalChapterNum: Int = 0,
    var durChapterTitle: String? = null,
    var durChapterIndex: Int = 0,
) : BaseBook {
    init {
        if (environment.persistence != null && bookUrl.isNotEmpty())
            variable = environment.state.restoreVariables("book", bookUrl, "", variable)
    }
    private var reverseToc = false
    fun setReverseToc(value: Boolean) { reverseToc = value }
    fun getReverseToc(): Boolean = reverseToc
    fun removeAllBookType() { type = type and (4 or 8 or 32 or 64 or 128).inv() }
    fun addType(value: Int) { type = type or value }
    fun toSearchBook(): SearchBook = SearchBook(environment, bookUrl, origin, originName, type, name, author,
        kind, coverUrl, intro, wordCount, latestChapterTitle, tocUrl, variable = variable, originOrder = originOrder).also {
        it.infoHtml = infoHtml; it.tocHtml = tocHtml
    }
    @delegate:Transient override val variableMap: HashMap<String, String> by lazy {
        GSON.fromJsonObject<HashMap<String, String>>(variable).getOrNull() ?: hashMapOf()
    }
    override fun putVariable(key: String, value: String?): Boolean {
        environment.ensureOpen()
        if (environment.persistence != null && bookUrl.isNotEmpty()) {
            if (environment.state.putVariable("book", bookUrl, "", variableMap, key, value)) variable = GSON.toJson(variableMap)
            return true
        }
        return super.putVariable(key, value)
    }
    override fun hashCode(): Int = bookUrl.hashCode()
    override fun equals(other: Any?): Boolean = other is Book && other.bookUrl == bookUrl
    override fun putBigVariable(key: String, value: String?) = environment.state.putBook(bookUrl, key, value)
    override fun getBigVariable(key: String): String? = environment.state.getBook(bookUrl, key)
    override fun putCustomVariable(value: String?) { putVariable("custom", value) }
    override fun getCustomVariable(): String = getVariable("custom")
    override fun getKindList(): List<String> = arrayListOf<String>().apply {
        wordCount?.takeIf(String::isNotBlank)?.let(::add)
        kind?.let { addAll(it.splitNotBlank(",", "\n")) }
    }
}

/** BookChapter:42–66/101–125 field defaults and variable semantics, without persistence/UI. */
data class BookChapter(
    @Transient internal val environment: RuleEnvironment,
    var url: String = "",
    var title: String = "",
    var isVolume: Boolean = false,
    var baseUrl: String = "",
    var bookUrl: String = "",
    var index: Int = 0,
    var isVip: Boolean = false,
    var isPay: Boolean = false,
    var resourceUrl: String? = null,
    var tag: String? = null,
    var wordCount: String? = null,
    var start: Long? = null,
    var end: Long? = null,
    var startFragmentId: String? = null,
    var endFragmentId: String? = null,
    var variable: String? = null,
    var imgUrl: String? = null,
    // Explicit batch DTOs are supplied by the actual App chapter owner. Skipping
    // only eager restoration lets index-distinct duplicate URLs keep their body
    // identity; later URL-keyed variable accesses still require the real owner.
    @Transient private val restorePersistentVariables: Boolean = true,
) : RuleDataInterface {
    init {
        if (restorePersistentVariables && environment.persistence != null && bookUrl.isNotEmpty() && url.isNotEmpty())
            variable = environment.state.restoreVariables("chapter", bookUrl, url, variable)
    }
    @delegate:Transient override val variableMap: HashMap<String, String> by lazy {
        GSON.fromJsonObject<HashMap<String, String>>(variable).getOrNull() ?: hashMapOf()
    }
    override fun putVariable(key: String, value: String?): Boolean {
        environment.ensureOpen()
        if (environment.persistence != null && bookUrl.isNotEmpty() && url.isNotEmpty()) {
            if (environment.state.putVariable("chapter", bookUrl, url, variableMap, key, value)) variable = GSON.toJson(variableMap)
            return true
        }
        if (super.putVariable(key, value)) variable = GSON.toJson(variableMap)
        return true
    }
    override fun putBigVariable(key: String, value: String?) = environment.state.putChapter(bookUrl, url, key, value)
    override fun getBigVariable(key: String): String? = environment.state.getChapter(bookUrl, url, key)
    override fun hashCode(): Int = url.hashCode()
    override fun equals(other: Any?): Boolean = other is BookChapter && other.url == url
    fun primaryStr(): String = bookUrl + url
    var titleMD5: String? = null
    fun getAbsoluteURL(): String {
        if (url.startsWith(title) && isVolume) return baseUrl
        val matcher = io.legado.app.model.analyzeRule.AnalyzeUrl.paramPattern.matcher(url)
        val before = if (matcher.find()) url.substring(0, matcher.start()) else url
        val absolute = NetworkUtils.getAbsoluteURL(baseUrl, before)
        return if (before.length == url.length) absolute else "$absolute," + url.substring(matcher.end())
    }
    fun update(): Nothing = unsupportedRule("BookChapter persistence")
}

/** BaseSource's source/cache namespace and eval binding core; not a full BookSource entity. */
class BookSource(
    @Transient internal val environment: RuleEnvironment,
    var bookSourceUrl: String = "",
    var bookSourceName: String = "",
    override var jsLib: String? = null,
    override var header: String? = null,
    override var enabledCookieJar: Boolean? = true,
    override var concurrentRate: String? = null,
    var bookSourceType: Int = 0,
    var bookUrlPattern: String? = null,
    var customOrder: Int = 0,
    var searchUrl: String? = null,
    var exploreUrl: String? = null,
    var loginCheckJs: String? = null,
    var mainJs: String? = null,
    var ruleSearch: io.legado.app.data.entities.rule.SearchRule? = null,
    var ruleExplore: io.legado.app.data.entities.rule.ExploreRule? = null,
    var ruleBookInfo: io.legado.app.data.entities.rule.BookInfoRule? = null,
    var ruleToc: io.legado.app.data.entities.rule.TocRule? = null,
    var ruleContent: io.legado.app.data.entities.rule.ContentRule? = null,
) : BaseSource {
    fun getSearchRule() = ruleSearch ?: io.legado.app.data.entities.rule.SearchRule().also { ruleSearch = it }
    fun getExploreRule() = ruleExplore ?: io.legado.app.data.entities.rule.ExploreRule().also { ruleExplore = it }
    fun getBookInfoRule() = ruleBookInfo ?: io.legado.app.data.entities.rule.BookInfoRule().also { ruleBookInfo = it }
    fun getTocRule() = ruleToc ?: io.legado.app.data.entities.rule.TocRule().also { ruleToc = it }
    fun getContentRule() = ruleContent ?: io.legado.app.data.entities.rule.ContentRule().also { ruleContent = it }
    fun isJsSource(): Boolean = !mainJs.isNullOrBlank()
    override fun getKey(): String = bookSourceUrl
    override fun getTag(): String = bookSourceName
    override fun getSource(): BookSource = this
    override fun getRuleEnvironment(): RuleEnvironment = environment
    override fun getRuleCoroutineContext(): CoroutineContext = rhinoContextOrNull?.coroutineContext ?: EmptyCoroutineContext
    override fun put(key: String, value: String): String {
        environment.cache.put("v_${getKey()}_${key}", value)
        return value
    }
    override fun get(key: String): String = environment.cache.get("v_${getKey()}_${key}") ?: ""
    fun setVariable(value: String?) = putVariable(value)
    fun putVariable(value: String?) {
        val key = "sourceVariable_${getKey()}"
        if (value == null) environment.cache.delete(key) else environment.cache.put(key, value)
    }
    fun getVariable(): String = environment.cache.get("sourceVariable_${getKey()}") ?: ""
    fun getLoginHeader(): String? = environment.cache.get("loginHeader_${getKey()}")
    fun getLoginHeaderMap(): Map<String, String>? = GSON.fromJsonObject<Map<String, String>>(getLoginHeader()).getOrNull()
    override fun getHeaderMap(hasLoginHeader: Boolean): Map<String, String> = HashMap<String, String>().apply {
        environment.ensureOpen()
        header?.let { text ->
            try {
                val matcher = AppPattern.JS_PATTERN.matcher(text.trim())
                val json = if (matcher.matches()) normalizeRuleJsResult(evalJS((matcher.group(1) ?: matcher.group(2)).trim())).orEmpty() else text
                GSON.fromJsonObject<Map<String, String>>(json).getOrNull()?.let(::putAll)
            } catch (error: Exception) {
                rethrowRuleControlFailure(error)
                rhinoContextOrNull?.coroutineContext?.get(ScriptExecutionGuard)?.checkActive?.invoke()
                rhinoContextOrNull?.coroutineContext?.ensureActive()
                environment.platform.log("执行请求头规则出错\n$error")
            }
        }
        if (keys.none { it.equals("User-Agent", true) }) environment.platform.userAgent?.let { put("User-Agent", it) }
        if (hasLoginHeader) getLoginHeaderMap()?.let(::putAll)
    }
    fun putLoginHeader(value: String) {
        if (environment.platform.storeLoginHeader(this, value)) return
        val map = GSON.fromJsonObject<Map<String, String>>(value).getOrNull()
        (map?.get("Cookie") ?: map?.get("cookie"))?.let { environment.cookie.replaceCookie(getKey(), it) }
        environment.cache.put("loginHeader_${getKey()}", value)
    }
    fun removeLoginHeader() {
        if (environment.platform.storeLoginHeader(this, null)) return
        environment.cache.delete("loginHeader_${getKey()}"); environment.cookie.removeCookie(getKey())
    }
    fun getLoginInfo(): Nothing = unsupportedRule("source login-info encryption/storage")
    fun putLoginInfo(value: String): Nothing = unsupportedRule("source login-info encryption/storage")
    fun refreshJSLib() { environment.scopes.remove(jsLib) }
    override fun ajax(url: Any): String? = connect(url.toString()).body()
    fun evalJS(js: String, bindingsConfig: ScriptBindings.() -> Unit = {}): Any? {
        environment.ensureOpen()
        val bindings = buildScriptBindings {
            it["java"] = this; it["source"] = this; it["sourceApi"] = this
            it["baseUrl"] = getKey(); it["cookie"] = environment.cookie; it["cache"] = environment.cache
            it.apply(bindingsConfig)
        }
        val context = rhinoContextOrNull?.coroutineContext
        val shared = environment.scopes.getScope(jsLib, context)
            ?: environment.scopes.getCryptoScope(this, context)
        bindings.chainTo(shared, environment.scopes.sharedHandle(this))
        return RhinoScriptEngine.eval(js, bindings, context)
    }
}
