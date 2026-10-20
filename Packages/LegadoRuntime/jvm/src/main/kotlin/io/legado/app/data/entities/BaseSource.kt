package io.legado.app.data.entities

import io.yuedu.legado.originalrule.RuleJsExtensions

/** Finite original source identity/core-property contract; interactive login/UI remain outside this ABI. */
interface BaseSource : RuleJsExtensions {
    var concurrentRate: String?
    var header: String?
    var enabledCookieJar: Boolean?
    var jsLib: String?
    var loginUrl: String?
    var loginUi: String?
    override fun getTag(): String
    fun getKey(): String
    override fun getSource(): BaseSource = this
    fun put(key: String, value: String): String
    fun get(key: String): String
    fun getHeaderMap(hasLoginHeader: Boolean = false): Map<String, String>
}
