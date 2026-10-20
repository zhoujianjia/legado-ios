package io.yuedu.legado

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import io.legado.app.data.entities.rule.RowUi
import io.yuedu.legado.originalrule.GSON
import java.util.UUID

/** Locked SourceLoginDialog269-307/651-658 and ArrayListExtensions.indexOf.
 * Name slots and physical children deliberately differ for unrendered rows.
 * This is one invocation's plan, never a persistent UI/credential owner. */
internal class OriginalLoginUIReuse(
    val rows: List<RowUi>, private val values: MutableMap<String, String>, input: JsonObject?
) {
    data class Child(val id: String, var rowIndex: Int, val row: RowUi, val state: JsonObject)
    val names = arrayListOf<String>()
    val children = arrayListOf<Child>()
    val created = arrayListOf<Child>()
    private val slots = arrayOfNulls<Child>(rows.size)
    var workingMapChanged = false
        private set
    private val types = setOf("text", "password", "select", "button", "toggle")

    init {
        if (input != null) read(input)
        requireRepresentableLoginUIKeys(values.keys + rows.map { it.name } + names + children.map { it.row.name })
        for ((index, row) in rows.withIndex()) {
            var insertIndex = -1
            if (input != null) {
                val oldIndex = if (index >= names.size) -2
                    else (index until names.size).firstOrNull { names[it] == row.name } ?: -1
                if (oldIndex == index) {
                    children.getOrNull(oldIndex)?.let { child ->
                        child.rowIndex = index; slots[index] = child
                    }
                    if (slots[index] != null) continue
                } else if (oldIndex >= 0) {
                    children.getOrNull(oldIndex)?.let { child ->
                        children.removeAt(oldIndex); names.removeAt(oldIndex)
                        requireInsert(index, children.size)
                        children.add(index, child); names.add(index, row.name)
                        child.rowIndex = index; slots[index] = child
                    }
                    if (slots[index] != null) continue
                }
                if (oldIndex == -2) names.add(row.name)
                else { names.add(index, row.name); insertIndex = index }
            } else names.add(row.name)

            if (row.type !in types) continue
            val id = if (input == null) "original-row-$index" else "control-${UUID.randomUUID()}"
            val state = newState(id, row)
            val child = Child(id, index, row, state)
            if (insertIndex == -1) children.add(child)
            else { requireInsert(insertIndex, children.size); children.add(insertIndex, child) }
            created.add(child); slots[index] = child
        }
        if (input != null) {
            if (children.size > rows.size) children.subList(rows.size, children.size).clear()
            if (names.size > rows.size) names.subList(rows.size, names.size).clear()
        }
    }

    private fun requireInsert(index: Int, count: Int) {
        if (index !in 0..count)
            throw RuntimeFailure("INVALID_RESULT", "Original delta layout has an invalid physical insertion")
    }
    private fun chars(row: RowUi): List<String> = row.chars?.filterNotNull()
        ?: if (row.type == "select") listOf("chars", "is null") else listOf("chars is null")
    private fun newState(id: String, row: RowUi): JsonObject {
        val selected = if (row.type == "select" || row.type == "toggle") {
            val previous = values[row.name]
            val value = if (previous.isNullOrEmpty()) {
                workingMapChanged = true
                row.default ?: chars(row).firstOrNull()
                    ?: throw RuntimeFailure("INVALID_RESULT", "Login UI selection has no value")
            } else previous
            values[row.name] = value
            value
        } else values[row.name] ?: row.default ?: ""
        val options = if (row.type == "select") chars(row) else emptyList()
        val index = if (options.isEmpty()) null else options.indexOf(selected).coerceIn(0, options.lastIndex)
        val displayed = when (row.type) {
            "button" -> ""
            "select" -> index?.let { options[it] }.orEmpty()
            else -> selected
        }
        return jsonObject("id" to id, "value" to displayed, "label" to row.name,
            "selectedIndex" to index, "cycleValue" to selected.takeIf { row.type == "toggle" },
            "cycleLabel" to row.name.takeIf { row.type == "toggle" },
            "listenerMapIsCurrent" to true, "forceSuffix" to false, "displayTextOverride" to null)
    }

    /** getLoginData uses the newly assigned raw row and actual View id/class.
     * A failed Android edit binding makes label evalUiJsResult null before JS. */
    fun labelValues(): Map<String, String>? {
        val result = values.toMutableMap()
        val assigned = hashMapOf<Int, Child>()
        children.forEach { child -> assigned.putIfAbsent(child.rowIndex, child) }
        for ((index, row) in rows.withIndex()) if (row.type == "text" || row.type == "password") {
            val child = assigned[index] ?: return null
            if (child.row.type != "text" && child.row.type != "password") return null
            result[row.name] = child.state["value"].asString
        }
        return result
    }
    fun labels(): List<String> = rows.indices.map { index ->
        slots[index]?.state?.get("label")?.asString ?: rows[index].name
    }
    fun slot(index: Int): Child? = slots[index]
    fun layout(): JsonObject = jsonObject("names" to names, "children" to JsonArray().apply {
        children.forEach { child -> add(jsonObject("id" to child.id, "rowIndex" to child.rowIndex,
            "row" to GSON.toJsonTree(child.row))) }
    })
    fun states(): JsonArray = JsonArray().apply { children.forEach { add(it.state.deepCopy()) } }

    private fun read(input: JsonObject) {
        require(input.keySet() == setOf("layout", "controls")) { "Invalid original login reuse snapshot" }
        val layout = input["layout"]?.takeIf { it.isJsonObject }?.asJsonObject
            ?: throw IllegalArgumentException("Missing original login layout")
        require(layout.keySet() == setOf("names", "children")) { "Invalid original login layout" }
        val oldNames = layout["names"]?.takeIf { it.isJsonArray }?.asJsonArray
            ?: throw IllegalArgumentException("Missing original login name slots")
        require(oldNames.size() <= 4096 && oldNames.all { it.isJsonPrimitive && it.asJsonPrimitive.isString }) { "Invalid original login name slots" }
        names.addAll(oldNames.map { it.asString })
        val controls = input["controls"]?.takeIf { it.isJsonArray }?.asJsonArray
            ?: throw IllegalArgumentException("Missing original login controls")
        val oldChildren = layout["children"]?.takeIf { it.isJsonArray }?.asJsonArray
            ?: throw IllegalArgumentException("Missing original login children")
        require(oldChildren.size() <= 4096 && oldChildren.size() <= names.size && controls.size() == oldChildren.size()) { "Invalid original login control count" }
        val states = linkedMapOf<String, JsonObject>()
        for (element in controls) {
            require(element.isJsonObject) { "Invalid original login control" }
            val state = element.asJsonObject
            require(state.keySet().all { it in setOf("id", "value", "label", "selectedIndex", "cycleValue", "cycleLabel", "listenerMapIsCurrent", "forceSuffix", "displayTextOverride") }) { "Unknown original login control field" }
            val id = string(state, "id")
            require(id.matches(Regex("[A-Za-z0-9._:-]{1,128}")) && !states.containsKey(id)) { "Invalid original login control identity" }
            string(state, "value"); string(state, "label")
            for (key in listOf("cycleValue", "cycleLabel", "displayTextOverride"))
                state[key]?.takeUnless { it.isJsonNull }?.let { require(it.isJsonPrimitive && it.asJsonPrimitive.isString) { "Invalid original login control text" } }
            for (key in listOf("listenerMapIsCurrent", "forceSuffix"))
                require(state[key]?.let { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean } == true) { "Invalid original login control flag" }
            state["selectedIndex"]?.takeUnless { it.isJsonNull }?.let {
                require(validIndex(it)) { "Invalid original login selection" }
            }
            states[id] = state.deepCopy()
        }
        val ids = hashSetOf<String>()
        for (element in oldChildren) {
            require(element.isJsonObject) { "Invalid original login child" }
            val child = element.asJsonObject
            require(child.keySet() == setOf("id", "rowIndex", "row")) { "Invalid original login child fields" }
            val id = string(child, "id")
            require(ids.add(id) && states.containsKey(id)) { "Unknown original login child identity" }
            val index = child["rowIndex"]
            require(index != null && validIndex(index)) { "Invalid assigned login View id" }
            val row = child["row"]?.takeIf { it.isJsonObject }?.let { GSON.fromJson(it, RowUi::class.java) }
                ?: throw IllegalArgumentException("Missing captured original login row")
            require(row.type in types) { "Unrendered original login row cannot own a View" }
            children.add(Child(id, index.asInt, row, states.getValue(id)))
        }
    }
    private fun string(value: JsonObject, name: String): String {
        val field = value[name]
        require(field != null && field.isJsonPrimitive && field.asJsonPrimitive.isString) { "Missing original login control text" }
        return field.asString
    }
    private fun validIndex(value: com.google.gson.JsonElement): Boolean {
        if (!value.isJsonPrimitive || !value.asJsonPrimitive.isNumber) return false
        val number = value.asBigDecimal
        return number.stripTrailingZeros().scale() <= 0 && number >= java.math.BigDecimal.ZERO
            && number <= java.math.BigDecimal.valueOf(4095)
    }
}
