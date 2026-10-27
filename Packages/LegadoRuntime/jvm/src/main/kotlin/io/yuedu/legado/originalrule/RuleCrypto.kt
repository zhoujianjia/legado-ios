package io.yuedu.legado.originalrule

import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** The retained four-String JsEncodeUtils AES decoder, backed by the JDK provider. */
internal object RuleCrypto {
    fun decryptAes(value: String, key: String, transformation: String, iv: String): ByteArray {
        val algorithm = transformation.substringBefore('/')
        require(algorithm.equals("AES", ignoreCase = true)) { "The AES decoder requires an AES transformation" }
        val cipher = Cipher.getInstance(transformation)
        // Original String overloads encode the key and IV as UTF-8, regardless of their appearance.
        val secret = SecretKeySpec(key.toByteArray(Charsets.UTF_8), algorithm)
        if (iv.isEmpty()) cipher.init(Cipher.DECRYPT_MODE, secret)
        else cipher.init(Cipher.DECRYPT_MODE, secret, IvParameterSpec(iv.toByteArray(Charsets.UTF_8)))
        // Do not turn provider/key/padding failures into an empty URL.
        return cipher.doFinal(decodeCiphertext(value))
    }

    private fun decodeCiphertext(value: String): ByteArray {
        // Hutool SecureUtil.decode tests the original input for Hex before attempting Base64.
        if (value.isNotEmpty() && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) {
            val hex = if (value.length % 2 == 0) value else "0$value"
            return ByteArray(hex.length / 2) { index ->
                ((hex[index * 2].digitToInt(16) shl 4) or hex[index * 2 + 1].digitToInt(16)).toByte()
            }
        }
        return RuleBase64.decodeBytes(value.toByteArray(Charsets.UTF_8))
    }
}
