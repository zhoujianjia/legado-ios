package io.legado.app.model.analyzeRule

import com.script.buildScriptBindings
import com.script.rhino.RhinoScriptEngine
import com.script.rhino.runScriptWithContext
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.annotations.SerializedName
import io.legado.app.help.ConcurrentRateLimiter
import io.legado.app.data.entities.BaseSource
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.yuedu.legado.originalrule.RuleEnvironment
import io.yuedu.legado.originalrule.RuleJsExtensions
import io.yuedu.legado.originalrule.*
import io.yuedu.legado.LegadoHttpRequestPreprocessor
import io.yuedu.legado.jsonObject
import java.net.URLEncoder
import java.nio.charset.Charset
import java.util.regex.Pattern
import okhttp3.ResponseBody.Companion.toResponseBody
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/**
 * Retained URL/header/request preparation and JVM request-option subset.
 * Header initialization precedes URL scripts; URL options then override it.
 * WebView/media/server upload and Android persistence are unported; original
 * rate windows use the same explicitly authorized owner and task deadline.
 * Keeping the original FQN does not imply those capabilities are available.
 */
class AnalyzeUrl(
    private val mUrl: String,
    private val key: String? = null,
    private val page: Int? = null,
    private var baseUrl: String = "",
    private val source: BaseSource? = null,
    private val ruleData: RuleDataInterface? = null,
    private val chapter: BookChapter? = null,
    private val environment: RuleEnvironment,
    coroutineContext: CoroutineContext = EmptyCoroutineContext,
    headerMapF: Map<String, String>? = null,
    hasLoginHeader: Boolean = true,
    private val callTimeout: Long? = null,
    private val infoMap: io.legado.app.utils.InfoMap? = null,
) : RuleJsExtensions {
    private val context = coroutineContext.minusKey(ContinuationInterceptor)
    private val concurrentRateLimiter = ConcurrentRateLimiter(source)
    suspend fun getStrResponseAwait(jsStr: String? = null, sourceRegex: String? = null, useWebView: Boolean = true, isTest: Boolean = false, skipRateLimit: Boolean = false): io.yuedu.legado.StrResponse {
        if (!jsStr.isNullOrBlank() || !sourceRegex.isNullOrBlank()) unsupportedRule("original WebBook browser/webJs/sourceRegex")
        if (isTest) unsupportedRule("original AnalyzeUrl isTest timing/error probes")
        if (!skipRateLimit) concurrentRateLimiter.getConcurrentRecord()
        return environment.platform.executeUrl(this)
    }
    fun getErrStrResponse(error: Throwable): io.yuedu.legado.StrResponse {
        val request = okhttp3.Request.Builder().url(url).build()
        val raw = okhttp3.Response.Builder().request(request).code(500).message(error.message ?: "Error Response")
            .protocol(okhttp3.Protocol.HTTP_1_1).body(error.stackTraceToString().toResponseBody(null)).build()
        return io.yuedu.legado.StrResponse(raw.request.url.toString(), 500, error.stackTraceToString(), emptyMap(), raw)
    }
    var ruleUrl: String = ""
        private set
    var url: String = ""
        private set
    var urlNoQuery: String = ""
        private set
    val headerMap = LinkedHashMap<String, String>()
    private var method = "GET"
    private var body: String? = null
    private var encodedForm: String? = null
    private var encodedQuery: String? = null
    private var charset: String? = null
    private var readTimeout: Long? = null
    private var retry = 0
    private var followRedirects: Boolean? = null
    private var dnsIp: String? = null
    private var bodyJs: String? = null

    init {
        environment.ensureOpen()
        val matcher = paramPattern.matcher(baseUrl)
        if (matcher.find()) baseUrl = baseUrl.substring(0, matcher.start())
        (headerMapF ?: runScriptWithContext(context) {
            source?.getHeaderMap(hasLoginHeader && isLoginHeaderSite(mUrl))
        })?.let { defaults ->
            headerMap.putAll(defaults)
            if (defaults.containsKey("proxy")) {
                val proxy = defaults["proxy"]
                headerMap.remove("proxy")
                if (!proxy.isNullOrBlank()) unsupportedRule("source proxy configuration")
            }
        }
        ruleUrl = mUrl
        analyzeJs()
        replaceKeyPageJs()
        analyzeUrl()
    }

    private fun isLoginHeaderSite(url: String): Boolean {
        val source = source ?: return true
        val sourceDomain = NetworkUtils.getSubDomainOrNull(source.getKey()) ?: return true
        val target = url.takeIf { it.startsWith("http", true) } ?: baseUrl.takeIf(String::isNotBlank) ?: return true
        val targetDomain = NetworkUtils.getSubDomainOrNull(target) ?: return true
        return targetDomain.equals(sourceDomain, true)
    }

    private fun analyzeUrl() {
        val matcher = paramPattern.matcher(ruleUrl)
        val noOption = if (matcher.find()) ruleUrl.substring(0, matcher.start()) else ruleUrl
        url = NetworkUtils.getAbsoluteURL(baseUrl, noOption) { environment.platform.ruleDiagnostic(it) }
        NetworkUtils.getBaseUrl(url)?.let { baseUrl = it }
        if (noOption.length != ruleUrl.length) {
            val text = ruleUrl.substring(matcher.end())
            // Preserve the original strict-then-lenient Gson constructor seam.
            val parsed = GSONStrict.fromJsonObject<UrlOption>(text).getOrNull()
                ?: GSON.fromJsonObject<UrlOption>(text).getOrNull()?.also { log("链接参数 JSON 格式不规范，请改为规范格式") }
            val keys = runCatching { JsonParser.parseString(text).asJsonObject.keySet() }.getOrNull().orEmpty()
            keys.firstOrNull { it !in supportedOptionNames }?.let { unsupportedRule("URL option '$it'") }
            parsed?.let { option ->
                method = when (option.getMethod()?.uppercase()) { "POST" -> "POST"; "HEAD" -> "HEAD"; else -> "GET" }
                option.getHeaderMap()?.forEach { (name, value) -> headerMap[name.toString()] = value.toString() }
                body = option.getBody()
                charset = option.getCharset()
                retry = option.getRetry()
                readTimeout = option.getTimeout()
                followRedirects = option.getFollowRedirects()
                dnsIp = option.getDnsIp()
                bodyJs = option.getBodyJs()
                if (option.useWebView()) unsupportedRule("URL option 'webView'")
                if (option.getType() != null) unsupportedRule("URL option 'type'")
                if (option.getWebJs() != null) unsupportedRule("URL option 'webJs'")
                if (option.getServerID() != null) unsupportedRule("URL option 'serverID'")
                if ((option.getWebViewDelayTime() ?: 0) > 0) unsupportedRule("URL option 'webViewDelayTime'")
                option.getJs()?.let { script -> evalJS(script, url)?.toString()?.let { url = it } }
            }
        }
        urlNoQuery = url
        if (method == "POST") {
            body?.let { if (!it.isJson() && !(it.trim().startsWith('<') && it.trim().endsWith('>')) && headerMap["Content-Type"].isNullOrEmpty()) encodedForm = encodeParams(it, charset, false) }
        } else {
            val at = url.indexOf('?')
            if (at != -1) {
                encodedQuery = encodeParams(url.substring(at + 1), charset, true)
                urlNoQuery = url.substring(0, at)
            }
        }
    }

    internal fun prepareRequest(cookieForUrl: (String) -> String): JsonObject {
        val requestUrl = if (method == "POST") urlNoQuery else urlNoQuery + (encodedQuery?.let { "?$it" } ?: "")
        val savedCookie = cookieForUrl(requestUrl)
        val headers = LinkedHashMap(headerMap)
        if (savedCookie.isNotEmpty()) {
            val cookies = linkedMapOf<String, String>()
            listOf(savedCookie, headers["Cookie"].orEmpty()).forEach { text -> text.split(';').forEach { pair ->
                val parts = pair.split('=', limit = 2)
                if (parts.size == 2 && parts[1].isNotBlank()) cookies[parts[0].trim()] = parts[1].trim()
            } }
            headers["Cookie"] = cookies.entries.joinToString("; ") { "${it.key}=${it.value}" }
        }
        return LegadoHttpRequestPreprocessor.prepare(requestUrl, method, headers, body, charset,
            materializeBridgeHeaders = false, encodedFormOverride = encodedForm).apply {
            addProperty("originalAnalyzeUrl", true)
            addProperty("enabledCookieJar", source?.enabledCookieJar == true)
            addProperty("timeoutMs", callTimeout ?: readTimeout?.let(::derivedCallTimeoutMillis) ?: 60_000L)
            readTimeout?.let { addProperty("readTimeoutMs", it) }
            followRedirects?.let { addProperty("followRedirects", it) }
            dnsIp?.let { addProperty("dnsIp", it) }
            addProperty("retry", retry)
        }
    }

    internal fun transformResponse(text: String, contentType: String): String = when {
        Regex("(application|text)/\\w*\\+?xml.*").matches(contentType) && !text.trim().startsWith("<?xml", true) -> "<?xml version=\"1.0\"?>$text"
        bodyJs != null -> evalJS(bodyJs!!, text).toString()
        else -> text
    }

    private fun encodeParams(params: String, charset: String?, isQuery: Boolean): String {
        val checkEncoded = charset.isNullOrEmpty()
        val charset = when {
            charset.isNullOrEmpty() -> Charsets.UTF_8
            charset == "escape" -> null
            else -> charset(charset)
        }
        if (isQuery && charset != null) {
            if (NetworkUtils.encodedQuery(params)) {
                return params
            }
            return queryEncoder.encode(params, charset)
        }
        val len = params.length
        val sb = StringBuilder()
        var pos = 0
        while (pos <= len) {
            if (sb.isNotEmpty()) {
                sb.append("&")
            }
            var ampOffset = params.indexOf("&", pos)
            if (ampOffset == -1) {
                ampOffset = len
            }
            val eqOffset = params.indexOf("=", pos)
            val key: String
            val value: String?
            if (eqOffset == -1 || eqOffset > ampOffset) {
                key = params.substring(pos, ampOffset)
                value = null
            } else {
                key = params.substring(pos, eqOffset)
                value = params.substring(eqOffset + 1, ampOffset)
            }
            sb.appendEncoded(key, checkEncoded, charset)
            if (value != null) {
                sb.append("=")
                sb.appendEncoded(value, checkEncoded, charset)
            }
            pos = ampOffset + 1
        }
        return sb.toString()
    }

    private fun StringBuilder.appendEncoded(
        value: String,
        checkEncoded: Boolean,
        charset: Charset?
    ) {
        if (checkEncoded && NetworkUtils.encodedForm(value)) {
            append(value)
        } else if (charset == null) {
            append(EncoderUtils.escape(value))
        } else {
            append(URLEncoder.encode(value, charset))
        }
    }


    private fun analyzeJs() {
        var start = 0
        val jsMatcher = jsPattern.matcher(ruleUrl)
        var result = ruleUrl
        while (jsMatcher.find()) {
            if (jsMatcher.start() > start) {
                ruleUrl.substring(start, jsMatcher.start()).trim().let {
                    if (it.isNotEmpty()) result = it.replace("@result", result)
                }
            }
            result = evalJS(jsMatcher.group(2) ?: jsMatcher.group(1), result).toString()
            start = jsMatcher.end()
        }
        if (ruleUrl.length > start) {
            ruleUrl.substring(start).trim().let {
                if (it.isNotEmpty()) result = it.replace("@result", result)
            }
        }
        ruleUrl = result
    }

    private fun replaceKeyPageJs() {
        if (ruleUrl.contains("{{") && ruleUrl.contains("}}")) {
            val analyze = RuleAnalyzer(ruleUrl)
            val url = analyze.innerRule("{{", "}}") {
                val jsEval = evalJS(it) ?: ""
                when (jsEval) {
                    is String -> jsEval
                    is Double if jsEval % 1.0 == 0.0 -> String.format("%.0f", jsEval)
                    else -> jsEval.toString()
                }
            }
            if (url.isNotEmpty()) ruleUrl = url
        }
        page?.let {
            val matcher = pagePattern.matcher(ruleUrl)
            while (matcher.find()) {
                val pages = matcher.group(1)!!.split(",")
                ruleUrl = if (page < pages.size) {
                    ruleUrl.replace(matcher.group(), pages[page - 1].trim { it <= ' ' })
                } else {
                    ruleUrl.replace(matcher.group(), pages.last().trim { it <= ' ' })
                }
            }
        }
    }

    fun evalJS(jsStr: String, result: Any? = null): Any? {
        environment.ensureOpen()
        val bindings = buildScriptBindings {
            it["java"] = this
            it["baseUrl"] = baseUrl
            it["cookie"] = environment.cookie
            it["cache"] = environment.cache
            it["page"] = page
            it["key"] = key
            it["speakText"] = null
            it["speakSpeed"] = null
            it["book"] = ruleData as? Book
            it["source"] = source
            it["result"] = result
            it["infoMap"] = infoMap
        }
        val scope = environment.scopes.getScope(source?.jsLib, context)
            ?: environment.scopes.getCryptoScope(source ?: this, context)
        bindings.chainTo(scope, environment.scopes.sharedHandle(source))
        return RhinoScriptEngine.eval(jsStr, bindings, context)
    }

    fun put(key: String, value: String): String {
        environment.ensureOpen()
        chapter?.putVariable(key, value) ?: ruleData?.putVariable(key, value)
        return value
    }

    fun get(key: String): String {
        environment.ensureOpen()
        when (key) {
            "bookName" -> (ruleData as? Book)?.let { return it.name }
            "title" -> chapter?.let { return it.title }
        }
        return chapter?.getVariable(key)?.takeIf(String::isNotEmpty)
            ?: ruleData?.getVariable(key)?.takeIf(String::isNotEmpty) ?: ""
    }

    override fun getSource(): BaseSource? = source
    override fun getTag(): String? = source?.getTag()
    override fun getRuleEnvironment(): RuleEnvironment = environment
    override fun getRuleCoroutineContext(): CoroutineContext = context
    override fun ajax(url: Any): String? = connect(if (url is List<*>) url.firstOrNull().toString() else url.toString()).body()

    companion object {
        private val queryEncoder = OriginalQueryEncoder
        val supportedOptionNames = setOf("method", "charset", "headers", "body", "origin", "retry", "type", "webView", "webJs", "timeout", "followRedirects", "dnsIp", "resolveIp", "js", "bodyJs", "serverID", "webViewDelayTime")
        val jsPattern: Pattern = Pattern.compile("<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", Pattern.CASE_INSENSITIVE)
        val pagePattern: Pattern = Pattern.compile("<(.*?)>")
        val paramPattern: Pattern = Pattern.compile("\\s*,\\s*(?=\\{)")
    }

    data class UrlOption(
        private var method: String? = null,
        private var charset: String? = null,
        private var headers: Any? = null,
        private var body: Any? = null,
        /**
         * 源Url
         **/
        private var origin: String? = null,
        /**
         * 重试次数
         **/
        private var retry: Int? = null,
        /**
         * 类型
         **/
        private var type: String? = null,
        /**
         * 是否使用webView
         **/
        private var webView: Any? = null,
        /**
         * webView中执行的js
         **/
        private var webJs: String? = null,
        /**
         * 读取超时（毫秒）
         **/
        private var timeout: Any? = null,
        /**
         * 是否跟随重定向
         **/
        private var followRedirects: Any? = null,
        /**
         * 自定义的域名ip
         **/
        @SerializedName(value = "dnsIp", alternate = ["resolveIp"])
        private var dnsIp: String? = null,
        /**
         * 解析完url参数时执行的js
         * 执行结果会赋值给url
         */
        private var js: String? = null,
        /**
         * 得到访问结果后执行的js,对结果进行二次处理
         * 执行结果返回为body
         */
        private var bodyJs: String? = null,
        /**
         * 服务器id
         */
        private var serverID: Long? = null,
        /**
         * webview等待页面加载完毕的延迟时间（毫秒）
         */
        private var webViewDelayTime: Long? = null,
    ) {
        fun setMethod(value: String?) {
            method = if (value.isNullOrBlank()) null else value
        }

        fun getMethod(): String? {
            return method
        }

        fun setCharset(value: String?) {
            charset = if (value.isNullOrBlank()) null else value
        }

        fun getCharset(): String? {
            return charset
        }

        fun setOrigin(value: String?) {
            origin = if (value.isNullOrBlank()) null else value
        }

        fun getOrigin(): String? {
            return origin
        }

        fun setRetry(value: String?) {
            retry = if (value.isNullOrEmpty()) null else value.toIntOrNull()
        }

        fun getRetry(): Int {
            return retry ?: 0
        }

        fun setType(value: String?) {
            type = if (value.isNullOrBlank()) null else value
        }

        fun getType(): String? {
            return type
        }

        fun useWebView(): Boolean {
            return when (webView) {
                null, "", false, "false" -> false
                else -> true
            }
        }

        fun useWebView(boolean: Boolean) {
            webView = if (boolean) true else null
        }

        fun setHeaders(value: String?) {
            headers = if (value.isNullOrBlank()) {
                null
            } else {
                GSON.fromJsonObject<Map<String, Any>>(value).getOrNull()
            }
        }

        fun getHeaderMap(): Map<*, *>? {
            return when (val value = headers) {
                is Map<*, *> -> value
                is String -> GSON.fromJsonObject<Map<String, Any>>(value).getOrNull()
                else -> null
            }
        }

        fun setBody(value: String?) {
            body = when {
                value.isNullOrBlank() -> null
                value.isJsonObject() -> GSON.fromJsonObject<Map<String, Any>>(value).getOrNull()
                value.isJsonArray() -> GSON.fromJsonArray<Map<String, Any>>(value).getOrNull()
                else -> value
            }
        }

        fun getBody(): String? {
            return body?.let {
                it as? String ?: GSON.toJson(it)
            }
        }

        fun setWebJs(value: String?) {
            webJs = if (value.isNullOrBlank()) null else value
        }

        fun getWebJs(): String? {
            return webJs
        }

        fun setTimeout(value: String?) {
            timeout = value
        }

        fun getTimeout(): Long? {
            return parseRequestTimeoutMillis(timeout)
        }

        fun setFollowRedirects(value: String?) {
            followRedirects = value
        }

        fun getFollowRedirects(): Boolean? {
            return parseBooleanOption(followRedirects)
        }

        fun setDnsIp(value: String?) {
            dnsIp = if (value.isNullOrBlank()) null else value.trim()
        }

        fun getDnsIp(): String? {
            return dnsIp
        }

        fun setJs(value: String?) {
            js = if (value.isNullOrBlank()) null else value
        }

        fun getJs(): String? {
            return js
        }

        fun setBodyJs(value: String?) {
            bodyJs = if (value.isNullOrBlank()) null else value
        }

        fun getBodyJs(): String? {
            return bodyJs
        }

        fun setServerID(value: String?) {
            serverID = if (value.isNullOrBlank()) null else value.toLong()
        }

        fun getServerID(): Long? {
            return serverID
        }

        fun setWebViewDelayTime(value: String?) {
            webViewDelayTime = if (value.isNullOrBlank()) null else value.toLong()
        }

        fun getWebViewDelayTime(): Long? {
            return webViewDelayTime
        }
    }

    data class ConcurrentRecord(var time: Long, var accessLimit: Int, var interval: Int, var frequency: Int)

}
