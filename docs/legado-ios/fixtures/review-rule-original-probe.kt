import com.google.gson.JsonParser
import com.google.gson.JsonObject
import io.legado.app.data.entities.rule.ReviewRule
import io.legado.app.utils.GSON
import java.io.File
fun main(args: Array<String>) {
    for (item in JsonParser.parseString(File(args[0]).readText(Charsets.UTF_8)).asJsonArray) {
        val row = item.asJsonObject
        val output = JsonObject().apply { add("id", row["id"]) }
        try {
            val rule = GSON.fromJson(row["rule"], ReviewRule::class.java)
            output.addProperty("status", "decoded")
            output.add("output", GSON.toJsonTree(rule))
        } catch (failure: Exception) {
            output.addProperty("status", "rejected")
            output.addProperty("error", failure.javaClass.simpleName)
        }
        println(output)
    }
}
