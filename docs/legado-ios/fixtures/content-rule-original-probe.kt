import com.google.gson.JsonParser
import io.legado.app.data.entities.rule.ContentRule
import io.legado.app.utils.GSON
fun main() {
    val values = listOf("null", "0", "-1", "4", "50", "75", "4.0", "4.5", "\"4\"", "\"4.0\"", "\"4.5\"", "\"bad\"", "true", "{}", "[]", "2147483648", "-2147483649")
    for (value in values) {
        val json = "{\"content\":\"body@text\",\"subContent\":\" \\r\\n e\\u0301 \\t\",\"contentBatch\":\"@js:batch()\",\"maxBatchSize\":" + value + "}"
        try {
            val rule = GSON.fromJson(json, ContentRule::class.java)
            val result = com.google.gson.JsonObject().apply {
                add("input", JsonParser.parseString(value))
                addProperty("status", "decoded")
                add("output", GSON.toJsonTree(rule))
            }
            println(result)
        } catch (failure: Exception) {
            println(com.google.gson.JsonObject().apply {
                add("input", JsonParser.parseString(value))
                addProperty("status", "rejected")
                addProperty("error", failure.javaClass.simpleName)
            })
        }
    }
}
