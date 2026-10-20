package io.yuedu.legado

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.script.rhino.runScriptWithContext
import java.beans.Introspector
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Modifier
import kotlinx.coroutines.CancellationException

/** Diagnostic-only entry point: the unchanged upstream suite is optional payload content. */
internal object EngineSemanticSuite {
    private const val SUITE_CLASS = "io.legado.app.JsEngineCapabilitiesTest"
    private const val EXPECTED_TEST_COUNT = 25

    @Synchronized fun run(task: RuntimeTask): JsonObject {
        task.job.ensureActiveForRuntime()
        val testClass = try {
            Class.forName("org.junit.Test")
            Class.forName("org.junit.Assert")
            Class.forName(SUITE_CLASS)
        } catch (error: ClassNotFoundException) {
            throw RuntimeFailure("SEMANTIC_SUITE_NOT_PACKAGED",
                "Engine tests are absent; build the diagnostic payload with -PincludeEngineTests=true (${error.message})")
        } catch (error: LinkageError) {
            throw RuntimeFailure("SEMANTIC_SUITE_NOT_PACKAGED", "Engine suite dependency is unavailable: $error")
        }
        val methods = testClass.declaredMethods.filter { method ->
            method.declaredAnnotations.any { it.annotationClass.java.name == "org.junit.Test" }
        }.sortedBy { it.name }
        if (methods.size != EXPECTED_TEST_COUNT || methods.any {
                !Modifier.isPublic(it.modifiers) || Modifier.isStatic(it.modifiers) || it.parameterCount != 0
            }) {
            throw RuntimeFailure("SEMANTIC_SUITE_INVALID",
                "Expected exactly $EXPECTED_TEST_COUNT public instance @Test methods with no parameters; found ${methods.size}")
        }
        val tests = JsonArray()
        var passed = 0
        runScriptWithContext(task.job) {
            methods.forEach { method ->
                task.job.ensureActiveForRuntime()
                val result = jsonObject("name" to method.name)
                try {
                    // JUnit 4 creates a new test instance for each method; preserve that behavior.
                    method.invoke(testClass.getDeclaredConstructor().newInstance())
                    result.addProperty("passed", true)
                    passed++
                } catch (error: Throwable) {
                    val cause = unwrapInvocation(error)
                    if (cause is CancellationException) throw cause
                    task.job.ensureActiveForRuntime()
                    if (cause is VirtualMachineError) throw cause
                    result.addProperty("passed", false)
                    result.add("error", errorReport(cause))
                }
                tests.add(result)
            }
        }
        task.job.ensureActiveForRuntime()
        return jsonObject(
            "suite" to "JsEngineCapabilitiesTest", "total" to methods.size,
            "passed" to passed, "failed" to (methods.size - passed), "skipped" to 0,
            "tests" to tests, "javaBeans" to probeJavaBeans(),
            "javaVersion" to System.getProperty("java.version"),
            "vmVersion" to System.getProperty("java.vm.version"),
            "vmName" to System.getProperty("java.vm.name")
        )
    }

    private fun probeJavaBeans(): JsonObject = try {
        val bean = BeanProbe()
        val property = Introspector.getBeanInfo(BeanProbe::class.java).propertyDescriptors
            .single { it.name == "value" }
        val read = requireNotNull(property.readMethod) { "Introspector did not discover getValue" }
        val write = requireNotNull(property.writeMethod) { "Introspector did not discover setValue" }
        check(read.name == "getValue" && write.name == "setValue") { "Unexpected bean accessor names" }
        write.invoke(bean, "beans-书-ok")
        check(read.invoke(bean) == "beans-书-ok") { "Bean setter/getter round trip failed" }
        jsonObject("passed" to true, "propertyName" to property.name,
            "readMethod" to read.name, "writeMethod" to write.name)
    } catch (error: Throwable) {
        if (error is VirtualMachineError) throw error
        jsonObject("passed" to false, "error" to errorReport(unwrapInvocation(error)))
    }

    class BeanProbe { var value: String = "initial" }

    private fun unwrapInvocation(error: Throwable): Throwable =
        if (error is InvocationTargetException) error.targetException else error

    private fun errorReport(error: Throwable): JsonObject = jsonObject(
        "type" to error.javaClass.name, "message" to (error.message ?: error.toString()),
        "stackTrace" to error.stackTraceToString()
    )
}
