package io.yuedu.legado

/** Test-only pure method bodies from locked original CookieStore.kt:73-80,
 * 118-148 and CookieManager.kt:96-107. Android DB/browser calls are fixture ports.
 * Original archive SHA256 724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd.
 */
internal object OriginalCookieTextOracle {
    private val semicolonRegex = ";".toRegex()
    private val equalsRegex = "=".toRegex()

    fun mergeCookieValues(oldCookie: String, cookie: String): String {
        if (oldCookie.isEmpty()) {
            return cookie
        }
        val cookieMap = cookieToMap(oldCookie)
        cookieMap.putAll(cookieToMap(cookie))
        return mapToCookie(cookieMap).orEmpty()
    }

    fun cookieToMap(cookie: String): MutableMap<String, String> {
        val cookieMap = mutableMapOf<String, String>()
        if (cookie.isBlank()) {
            return cookieMap
        }
        val pairArray = cookie.split(semicolonRegex).dropLastWhile { it.isEmpty() }.toTypedArray()
        for (pair in pairArray) {
            val pairs = pair.split(equalsRegex, 2).dropLastWhile { it.isEmpty() }.toTypedArray()
            if (pairs.size <= 1) {
                continue
            }
            val key = pairs[0].trim { it <= ' ' }
            val value = pairs[1]
            if (value.isNotBlank() || value.trim { it <= ' ' } == "null") {
                cookieMap[key] = value.trim { it <= ' ' }
            }
        }
        return cookieMap
    }

    fun mapToCookie(cookieMap: Map<String, String>?): String? {
        if (cookieMap.isNullOrEmpty()) {
            return null
        }
        val builder = StringBuilder()
        cookieMap.keys.forEachIndexed { index, key ->
            if (index > 0) builder.append("; ")
            builder.append(key).append("=").append(cookieMap[key])
        }
        return builder.toString()
    }

    fun mergeCookies(vararg cookies: String?): String? {
        val cookieMap = cookies.filterNotNull().map {
            cookieToMap(it)
        }.reduce { acc, cookieMap ->
            acc.apply { putAll(cookieMap) }
        }
        return mapToCookie(cookieMap)
    }
}
