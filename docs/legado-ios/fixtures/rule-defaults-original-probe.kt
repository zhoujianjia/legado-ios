import com.google.gson.JsonParser
import com.google.gson.JsonObject
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import io.legado.app.utils.GSON
import java.io.File

fun rawType(value: JsonElement?): String = when {
    value == null -> "absent"
    value.isJsonNull -> "null"
    value.isJsonPrimitive && value.asJsonPrimitive.isBoolean -> (value.asBoolean as Any).javaClass.name
    value.isJsonPrimitive && value.asJsonPrimitive.isNumber -> value.asNumber.javaClass.name
    value.isJsonPrimitive && value.asJsonPrimitive.isString -> value.asString.javaClass.name
    else -> value.javaClass.name
}

fun main(args: Array<String>) {
    val input = File(args[0]).readText(Charsets.UTF_8)
    require(!input.contains("???") && !input.contains('\uFFFD'))
    val withNulls = GSON.newBuilder().serializeNulls().create()
    for (element in JsonParser.parseString(input).asJsonArray) {
        val item = element.asJsonObject
        val model = item["model"].asString
        val field = item["field"].asString
        val getterName = item["getter"].asString
        val raw = item["rule"].asJsonObject
        val modelClass = Class.forName("io.legado.app.data.entities.rule." + model)
        val instance = GSON.fromJson(raw, modelClass)
        val getter = modelClass.getMethod(getterName)
        require(getter.parameterCount == 0 && getter.returnType == String::class.java)
        val value = getter.invoke(instance)
        require(value == null || value is String)
        val row = JsonObject().apply {
            add("model", item["model"])
            add("field", item["field"])
            add("getter", item["getter"])
            add("form", item["form"])
            addProperty("inputHasField", raw.has(field))
            addProperty("inputValueJSON", if (raw.has(field)) raw[field].toString() else "<absent>")
            addProperty("inputValueJavaClass", rawType(raw[field]))
            add("getterValue", if (value == null) JsonNull.INSTANCE else GSON.toJsonTree(value))
            addProperty("getterValueJavaClass", value?.javaClass?.name ?: "null")
            addProperty("getterReturnType", getter.returnType.name)
            add("defaultGson", GSON.toJsonTree(instance))
            add("serializeNullsGson", withNulls.toJsonTree(instance))
        }
        println(row)
    }
}
