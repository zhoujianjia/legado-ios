import com.google.gson.JsonParser
import com.google.gson.JsonObject
import com.google.gson.JsonElement
import io.legado.app.data.entities.rule.ReviewRule
import io.legado.app.utils.GSON
import java.io.File

fun rawValueClass(value: JsonElement): String = when {
    value.isJsonPrimitive && value.asJsonPrimitive.isBoolean -> (value.asBoolean as Any).javaClass.name
    value.isJsonPrimitive && value.asJsonPrimitive.isNumber -> value.asNumber.javaClass.name
    value.isJsonPrimitive && value.asJsonPrimitive.isString -> value.asString.javaClass.name
    else -> value.javaClass.name
}

fun main(args: Array<String>) {
    val input = File(args[0]).readText(Charsets.UTF_8)
    require(!input.contains("???"))
    for (item in JsonParser.parseString(input).asJsonArray) {
        val row = item.asJsonObject
        val value = row["rule"].asJsonObject["reviewUrl"]
        if (row["id"].asString.startsWith("unicode-")) {
            val text = value.asString
            require(!text.contains("???") && !text.contains('\uFFFD'))
            require(text.contains("\u5b50\u6b63\u6587") && text.contains("e\u0301") && text.contains("\r\n"))
        }
        val rule = GSON.fromJson(row["rule"], ReviewRule::class.java)
        val output = JsonObject().apply {
            add("id", row["id"])
            addProperty("inputValueJSON", value.toString())
            addProperty("inputValueJavaClass", rawValueClass(value))
            addProperty("outputReviewUrl", rule.reviewUrl)
            addProperty("outputReviewUrlJavaClass", rule.reviewUrl?.javaClass?.name)
            add("output", GSON.toJsonTree(rule))
        }
        println(output)
    }
}
