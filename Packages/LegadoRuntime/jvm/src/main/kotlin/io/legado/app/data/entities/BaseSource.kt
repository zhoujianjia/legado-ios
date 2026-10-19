package io.legado.app.data.entities

import io.yuedu.legado.originalrule.RuleJsExtensions

/** The original source identity/core-property contract; login/UI APIs are not implemented here. */
interface BaseSource : RuleJsExtensions {
    var concurrentRate: String?
    var header: String?
    var enabledCookieJar: Boolean?
    var jsLib: String?
    override fun getTag(): String
    fun getKey(): String
    override fun getSource(): BaseSource = this
    fun put(key: String, value: String): String
    fun get(key: String): String
}
