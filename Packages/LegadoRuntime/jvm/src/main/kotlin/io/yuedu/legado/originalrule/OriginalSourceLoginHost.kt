package io.yuedu.legado.originalrule

import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.yuedu.legado.StrResponse

/** Finite SourceLoginJsExtensions/RssJsExtensions contract. Parsing, HTTP, source
 * state and checked nonawait GET presentation borrow the same environment/task.
 * Unported browser/clipboard capabilities fail explicitly, never via JSC. */
class OriginalSourceLoginHost(private val source: BookSource) : RuleJsExtensions, AutoCloseable {
    private val analysisDelegate = lazy { AnalyzeRule(source = source) }
    private val analyzeRule get() = analysisDelegate.value
    override fun getSource() = source
    override fun getTag() = source.getTag()
    override fun getRuleEnvironment() = source.getRuleEnvironment()
    override fun getRuleCoroutineContext() = source.getRuleCoroutineContext()
    override fun ajax(url: Any): String? = getRuleEnvironment().platform.ajax(
        if (url is List<*>) url.firstOrNull().toString() else url.toString(), getRuleCoroutineContext(), this, null)
    fun put(key: String, value: String): String = source.put(key, value)
    fun get(key: String): String = source.get(key)
    @JvmOverloads fun setContent(content: Any?, baseUrl: String? = null): AnalyzeRule = analyzeRule.setContent(content, baseUrl)
    fun setBaseUrl(baseUrl: String?): AnalyzeRule = analyzeRule.setBaseUrl(baseUrl)
    fun setRedirectUrl(url: String) = analyzeRule.setRedirectUrl(url)
    @JvmOverloads fun getStringList(rule: String?, content: Any? = null, isUrl: Boolean = false) = analyzeRule.getStringList(rule, content, isUrl)
    @JvmOverloads fun getString(rule: String?, content: Any? = null, isUrl: Boolean = false) = analyzeRule.getString(rule, content, isUrl)
    fun getString(rule: String?, unescape: Boolean) = analyzeRule.getString(rule, unescape)
    fun getElement(rule: String) = analyzeRule.getElement(rule)
    fun getElements(rule: String) = analyzeRule.getElements(rule)
    @JvmOverloads fun startBrowser(url: String, title: String, html: String? = null) {
        // Explicit local HTML installs WebJsExtensions in the locked Activity;
        // a plain WK page must not silently pretend to provide that host.
        if (html != null) unsupportedRule("original local HTML WebJS browser")
        getRuleEnvironment().platform.startLoginBrowser(source, url, title)
    }
    @JvmOverloads fun startBrowserAwait(url: String, title: String, refetchAfterSuccess: Boolean = true, html: String? = null): StrResponse = unsupportedRule("form login awaited browser navigation")
    @JvmOverloads fun showBrowser(url: String, html: String? = null, preloadJs: String? = null, config: String? = null): Nothing = unsupportedRule("form login browser presentation")
    fun upLoginData(data: Map<String, Any?>?) = getRuleEnvironment().platform.updateLoginUI(source, data)
    @JvmOverloads fun reLoginView(deltaUp: Boolean = false) = getRuleEnvironment().platform.renderLoginUI(source, deltaUp)
    fun refreshExplore() = getRuleEnvironment().platform.renderLoginUI(source, false)
    fun copyText(text: String): Nothing = unsupportedRule("form login clipboard")
    fun toast(message: Any?): Nothing = unsupportedRule("form login toast presentation")
    fun longToast(message: Any?): Nothing = unsupportedRule("form login toast presentation")
    override fun close() { if (analysisDelegate.isInitialized()) analysisDelegate.value.close() }
}
