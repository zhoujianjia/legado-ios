package io.yuedu.legado.originalrule

/** Hutool 5.8.22 Validator.isIpv4/isIpv6 + exact RegexPool patterns (MIT).
 * Primary bytes and notices are recorded in vendor/original-rule/manifest.json.
 * No DNS lookup, address canonicalization or approximate suffix classification.
 */
internal object OriginalIpValidator {
    private val ipv4 = Regex("""^(25[0-5]|2[0-4]\d|[0-1]?\d?\d)\.(25[0-5]|2[0-4]\d|[0-1]?\d?\d)\.(25[0-5]|2[0-4]\d|[0-1]?\d?\d)\.(25[0-5]|2[0-4]\d|[0-1]?\d?\d)$""")
    private val ipv6 = Regex("""(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]+|::(ffff(:0{1,4})?:)?((25[0-5]|(2[0-4]|1?[0-9])?[0-9])\.){3}(25[0-5]|(2[0-4]|1?[0-9])?[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1?[0-9])?[0-9])\.){3}(25[0-5]|(2[0-4]|1?[0-9])?[0-9]))""")
    fun isIpv4(value: CharSequence?): Boolean = value != null && ipv4.matches(value)
    fun isIpv6(value: CharSequence?): Boolean = value != null && ipv6.matches(value)
}
