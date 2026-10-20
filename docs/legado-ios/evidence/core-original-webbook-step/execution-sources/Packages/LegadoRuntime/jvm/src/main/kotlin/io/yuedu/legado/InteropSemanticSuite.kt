package io.yuedu.legado

import com.google.gson.JsonParser
import com.script.ScriptBindings
import com.script.rhino.RhinoScriptEngine
import com.script.rhino.rhinoContextOrNull
import io.yuedu.legado.interop.InteropFixture
import kotlinx.coroutines.CancellationException

/** Runs on the JVM with the locked engine and unchanged Java collection/array wrappers. */
object InteropSemanticSuite {
    const val CASE_SET_VERSION = "legado-interop-v1"
    const val EXPECTED_CASE_COUNT = 28

    private data class Case(val name: String, val expected: String, val script: String)

    private val cases = listOf(
        Case("list.indexed-read-and-null", """[true,3,"first",true,"last",false]""", """
            var values = fixture.newList();
            return [values instanceof Packages.java.util.List, values.size(), String(values[0]),
                values[1] === null, String(values[2]), Array.isArray(values)];
        """),
        Case("list.indexed-write-updates-java", """["changed","changed",4,"append"]""", """
            var values = fixture.newList(); values[0] = 'changed'; values.add('append');
            return [String(values[0]), String(fixture.readListItem(values, 0)), values.size(), String(values[3])];
        """),
        Case("list.remove-selects-index-overload", """["first",2,true,"last"]""", """
            var values = fixture.newList(); var removed = values.remove(0);
            return [String(removed), values.size(), values[0] === null, String(values[1])];
        """),
        Case("list.java-iterator-preserves-null", """["first",null,"last"]""", """
            var iterator = fixture.newList().iterator(); var values = [];
            while (iterator.hasNext()) { var item = iterator.next(); values.push(item === null ? null : String(item)); }
            return values;
        """),
        Case("map.key-access-distinguishes-missing-and-null", """["book",7,true,true,false,"undefined"]""", """
            var values = fixture.newMap();
            return [String(values.title), Number(values['count']), values.nil === null,
                values.containsKey('nil'), values.containsKey('missing'), typeof values.missing];
        """),
        Case("map.property-write-updates-java-types", """[42,"java.lang.Double","written",true]""", """
            var values = fixture.newMap(); values['count'] = 42; values.put('extra', 'written');
            return [Number(fixture.readMapItem(values, 'count')),
                String(fixture.typeOfObject(fixture.readMapItem(values, 'count'))),
                String(values.extra), values.containsKey('extra')];
        """),
        Case("string.java-wrapper-and-utf16-methods", """["object",true,6,20070,"\u4e66\ud83d\udcda","A\u4e66\ud83d\udcda\u0000Z"]""", """
            var text = fixture.javaString();
            return [typeof text, text instanceof Packages.java.lang.String, text.length(), text.charAt(1),
                String(text.substring(1, 4)), String(text)];
        """),
        Case("string.utf8-produces-signed-java-bytes", """[3,-28,-71,-90,"number","\u4e66"]""", """
            var bytes = fixture.utf8Bytes();
            return [bytes.length, bytes[0], bytes[1], bytes[2], typeof bytes[0], String(fixture.decodeUtf8(bytes))];
        """),
        Case("byte-array.signed-boundaries-and-unsigned-mask", """[4,0,127,-128,-1,128,255,"[B"]""", """
            var bytes = fixture.signedBytes();
            return [bytes.length, bytes[0], bytes[1], bytes[2], bytes[3], bytes[2] & 255, bytes[3] & 255,
                String(fixture.typeOfObject(bytes))];
        """),
        Case("byte-array.base64-roundtrip-keeps-signed-values", """["AH+A/w==",4,127,-128,-1,"[B"]""", """
            var bytes = fixture.signedBytes();
            var encoded = Packages.java.util.Base64.getEncoder().encodeToString(bytes);
            var decoded = Packages.java.util.Base64.getDecoder().decode(encoded);
            return [String(encoded), decoded.length, decoded[1], decoded[2], decoded[3], String(fixture.typeOfObject(decoded))];
        """),
        Case("byte-array.js-array-converts-to-byte-array", """["[B",4,-128,-1,0,127,-2]""", """
            var bytes = fixture.echoBytes([-128, -1, 0, 127]);
            return [String(fixture.typeOfObject(bytes)), bytes.length, bytes[0], bytes[1], bytes[2], bytes[3], fixture.sumBytes(bytes)];
        """),
        Case("array.java-string-array-is-fixed-java-type", """[false,3,"first",true,"third","[Ljava.lang.String;"]""", """
            var values = fixture.stringArray();
            return [Array.isArray(values), values.length, String(values[0]), values[1] === null,
                String(values[2]), String(fixture.typeOfObject(values))];
        """),
        Case("array.indexed-write-updates-original-array", """["written","written",true,3]""", """
            var values = fixture.stringArray(); values[0] = 'written'; values[1] = null;
            return [String(values[0]), String(fixture.stringArrayFirst(values)), values[1] === null, values.length];
        """),
        Case("array.js-arrays-convert-to-declared-java-types", """["[I",3,6,"[Ljava.lang.String;",true,"beta"]""", """
            var ints = fixture.echoInts([1, 2, 3]); var strings = fixture.echoStrings(['alpha', null, 'beta']);
            return [String(fixture.typeOfObject(ints)), ints.length, ints[0] + ints[1] + ints[2],
                String(fixture.typeOfObject(strings)), strings[1] === null, String(strings[2])];
        """),
        Case("null.java-null-remains-distinct-from-void", """[true,true,true,"object",true,"undefined"]""", """
            return [fixture.nullObject() === null, fixture.nullString() === null, fixture.nullBytes() === null,
                typeof fixture.nullObject(), fixture.returnVoid() === undefined, typeof fixture.returnVoid()];
        """),
        Case("parameters.primitive-int-long-boolean-char-conversion", """[7,"2147483648",true,"char:20070"]""", """
            return [fixture.acceptInt(7.9), String(fixture.acceptLong(2147483648)),
                fixture.acceptBoolean(true), String(fixture.acceptChar('\u4e66'))];
        """),
        Case("parameters.object-keeps-java-boxed-types", """["java.lang.String","java.lang.Double","java.lang.Boolean","null","java.lang.String","undefined"]""", """
            return [String(fixture.typeOfObject('text')), String(fixture.typeOfObject(3.5)),
                String(fixture.typeOfObject(true)), String(fixture.typeOfObject(null)),
                String(fixture.typeOfObject(undefined)), String(fixture['choose(java.lang.String)'](undefined)).substring(7)];
        """),
        // The locked fork reports null as ambiguous between String and Object (also
        // reproduced with its default WrapFactory). Preserve that compatibility edge;
        // sources must use an explicit signature when passing null to these overloads.
        Case("overload.automatic-js-primitive-and-java-object-selection", """["String:text","double:7.5","boolean:true","Object:java.util.ArrayList",true,"InternalError","String:<null>","Object:null"]""", """
            var ambiguous = false; var errorName = '';
            try { fixture.choose(null); } catch (error) { ambiguous = true; errorName = String(error.name); }
            return [String(fixture.choose('text')), String(fixture.choose(7.5)), String(fixture.choose(true)),
                String(fixture.choose(fixture.newList())), ambiguous, errorName,
                String(fixture['choose(java.lang.String)'](null)), String(fixture['choose(java.lang.Object)'](null))];
        """),
        Case("overload.js-number-prefers-double", """["double:7.0","double:7.5"]""", """
            return [String(fixture.chooseNumber(7)), String(fixture.chooseNumber(7.5))];
        """),
        Case("overload.explicit-signatures-select-exact-java-target", """["int:7","double:7.0","Object:java.lang.String"]""", """
            return [String(fixture['chooseNumber(int)'](7)), String(fixture['chooseNumber(double)'](7)),
                String(fixture['choose(java.lang.Object)']('text'))];
        """),
        Case("overload.arity-selection-and-missing-arity-error", """["one:a","two:a:b",true]""", """
            var caught = false; try { fixture.combine(); } catch (error) { caught = true; }
            return [String(fixture.combine('a')), String(fixture.combine('a', 'b')), caught];
        """),
        Case("exception.instance-java-exception-remains-catchable", """[true,true,"java.lang.IllegalStateException"]""", """
            try { fixture.fail(); return [false]; }
            catch (error) { return [String(error).indexOf('interop-instance-failure') >= 0,
                error.javaException instanceof Packages.java.lang.IllegalStateException,
                String(fixture.typeOfObject(error.javaException))]; }
        """),
        Case("exception.nested-list-map-and-array-keep-catchable-wrappers", """[true,true,true]""", """
            var results = [];
            try { fixture.childrenList()[0].fail(); results.push(false); }
            catch (error) { results.push(String(error).indexOf('interop-child-failure') >= 0); }
            try { fixture.childrenMap().child.fail(); results.push(false); }
            catch (error) { results.push(String(error).indexOf('interop-child-failure') >= 0); }
            try { fixture.childrenArray()[0].fail(); results.push(false); }
            catch (error) { results.push(String(error).indexOf('interop-child-failure') >= 0); }
            return results;
        """),
        Case("exception.static-java-exception-remains-catchable", """[true,true,"java.lang.IllegalArgumentException"]""", """
            try { Packages.io.yuedu.legado.interop.InteropFixture.staticFail(); return [false]; }
            catch (error) { return [String(error).indexOf('interop-static-failure') >= 0,
                error.javaException instanceof Packages.java.lang.IllegalArgumentException,
                String(fixture.typeOfObject(error.javaException))]; }
        """),
        Case("method.detached-method-restores-original-java-receiver", """["String:text",3,"one:value"]""", """
            var choose = fixture.choose; var list = fixture.newList; var combine = fixture.combine;
            return [String(choose('text')), list().size(), String(combine('value'))];
        """),
        Case("parameters.invalid-numeric-and-null-primitive-are-catchable", """[true,true,true]""", """
            var invalid = false; var primitiveNull = false;
            try { fixture.echoInts(['not-a-number']); } catch (error) { invalid = true; }
            try { fixture.acceptInt(null); } catch (error) { primitiveNull = true; }
            return [invalid, primitiveNull, fixture.echoInts(null) === null];
        """),
        Case("number.boxed-long-string-preserves-beyond-js-safe-integer", """["object","java.lang.Long","9007199254740993",9007199254740992,"9007199254740991"]""", """
            var value = fixture.boxedLong();
            return [typeof value, String(fixture.typeOfObject(value)), String(value), Number(value),
                String(fixture.acceptLong(9007199254740991))];
        """),
        Case("byte-array.out-of-range-js-values-are-rejected", """[true,true]""", """
            var high = false; var low = false;
            try { fixture.echoBytes([128]); } catch (error) { high = true; }
            try { fixture.echoBytes([-129]); } catch (error) { low = true; }
            return [high, low];
        """)
    )

    @JvmStatic fun run(): Map<String, Any?> = runWithEvaluator { script, scope -> RhinoScriptEngine.eval(script, scope) }

    internal fun runWithEvaluator(evaluate: (String, ScriptBindings) -> Any?): Map<String, Any?> {
        check(cases.size == EXPECTED_CASE_COUNT && cases.map { it.name }.toSet().size == EXPECTED_CASE_COUNT) {
            "Interop matrix must contain exactly $EXPECTED_CASE_COUNT unique cases"
        }
        val tests = cases.map { case ->
            rhinoContextOrNull?.ensureActive()
            val expected = canonical(case.expected)
            try {
                val scope = RhinoScriptEngine.getRuntimeScope(ScriptBindings())
                scope["fixture"] = InteropFixture()
                val value = evaluate("JSON.stringify((function(){\n${case.script}\n})())", scope)
                check(value is String) { "Case did not produce a JSON string (${value?.javaClass?.name ?: "null"})" }
                val actual = canonical(value)
                linkedMapOf<String, Any?>("name" to case.name, "passed" to (actual == expected),
                    "actual" to actual, "expected" to expected)
            } catch (error: Throwable) {
                if (error is CancellationException || error is VirtualMachineError) throw error
                rhinoContextOrNull?.ensureActive()
                val detail = linkedMapOf("type" to error.javaClass.name,
                    "message" to (error.message ?: error.toString()), "stackTrace" to error.stackTraceToString())
                linkedMapOf<String, Any?>("name" to case.name, "passed" to false,
                    "actual" to gson.toJson(mapOf("exception" to detail)), "expected" to expected, "error" to detail)
            }
        }
        val passedCount = tests.count { it["passed"] == true }
        return linkedMapOf<String, Any?>(
            "suite" to "InteropSemanticSuite", "caseSetVersion" to CASE_SET_VERSION,
            "passed" to (passedCount == EXPECTED_CASE_COUNT), "passedCount" to passedCount,
            "failed" to (EXPECTED_CASE_COUNT - passedCount), "total" to EXPECTED_CASE_COUNT,
            "tests" to tests
        ).apply {
            if (passedCount == 0) put("error", mapOf("code" to "INTEROP_SUITE_ALL_FAILED",
                "message" to "Every Java interop case failed; this runtime is rejected"))
        }
    }

    private fun canonical(json: String): String = gson.toJson(JsonParser.parseString(json))
}
