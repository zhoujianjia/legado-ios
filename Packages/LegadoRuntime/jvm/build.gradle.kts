import java.util.zip.ZipFile
import java.security.MessageDigest
import groovy.json.JsonOutput
import org.gradle.api.artifacts.result.ResolvedDependencyResult

plugins {
    kotlin("jvm") version "2.4.20"
    `java-library`
}

group = "io.yuedu"
version = "0.1.0-prototype"

repositories {
    maven { url = uri("../vendor/maven"); content { includeModule("org.htmlunit", "htmlunit-core-js") } }
    mavenCentral()
}

kotlin { jvmToolchain(21) }
dependencies {
    api("org.htmlunit:htmlunit-core-js:5.3.0-legado.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    implementation("com.squareup.okio:okio-jvm:3.9.1")
    implementation("com.google.code.gson:gson:2.13.2")
    implementation("org.jsoup:jsoup:1.23.2")
    implementation("com.jayway.jsonpath:json-path:3.0.0")
    implementation("cn.wanghaomiao:JsoupXpath:2.5.3")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains:annotations:26.0.2")
    // These are confined to opt-in diagnostic payloads. Normal runtimeClasspath
    // keeps its existing Okio version and has no OkHttp client dependency.
    testImplementation("com.squareup.okhttp3:okhttp-jvm:5.4.0")
    testImplementation("com.squareup.okio:okio-jvm:3.17.0")
}

tasks.test { useJUnit(); maxHeapSize = "512m" }

// The first device gate opts in explicitly; ordinary app payloads never ship JUnit.
val includeEngineTests = providers.gradleProperty("includeEngineTests")
    .map(String::toBooleanStrict).getOrElse(false)
val payloadDependencies = if (includeEngineTests) configurations.testRuntimeClasspath else configurations.runtimeClasspath

// JNI classpath consists of this JAR plus the unmodified dependency JARs.
tasks.register<Copy>("runtimeBundle") {
    dependsOn(tasks.jar)
    from(tasks.jar)
    from(configurations.runtimeClasspath)
    into(layout.buildDirectory.dir("runtime/lib"))
    duplicatesStrategy = DuplicatesStrategy.FAIL
}

val mergedServices = layout.buildDirectory.dir("merged-services")
val mergeServices by tasks.registering {
    inputs.files(payloadDependencies)
    outputs.dir(mergedServices)
    doLast {
        val output = mergedServices.get().asFile
        check(output.canonicalFile.toPath().startsWith(layout.buildDirectory.get().asFile.canonicalFile.toPath()))
        output.deleteRecursively()
        val services = linkedMapOf<String, LinkedHashSet<String>>()
        payloadDependencies.get().files.forEach { dependency ->
            ZipFile(dependency).use { archive ->
                archive.entries().asSequence().filter {
                    !it.isDirectory && it.name.startsWith("META-INF/services/")
                }.forEach { entry ->
                    archive.getInputStream(entry).bufferedReader().useLines { lines ->
                        services.getOrPut(entry.name) { linkedSetOf() }.addAll(lines.filter { it.isNotBlank() }.toList())
                    }
                }
            }
        }
        services.forEach { (path, lines) ->
            output.resolve(path).apply { parentFile.mkdirs(); writeText(lines.joinToString("\n", postfix = "\n")) }
        }
    }
}

val runtimeJar by tasks.registering(Jar::class) {
    dependsOn(tasks.classes, mergeServices)
    archiveFileName.set("legado-runtime.jar")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    inputs.property("includeEngineTests", includeEngineTests)
    from(sourceSets.main.get().output)
    if (includeEngineTests) {
        dependsOn(tasks.testClasses)
        from(sourceSets.test.get().output)
    }
    payloadDependencies.get().files.forEach { dependency ->
        from(zipTree(dependency)) {
            exclude("META-INF/services/**", "META-INF/*.SF", "META-INF/*.RSA", "META-INF/*.DSA",
                "module-info.class", "META-INF/versions/**/module-info.class")
        }
    }
    from(mergedServices)
    from("../vendor/LICENSE") { into("META-INF/licenses/legado") }
    from("../vendor/licenses") { into("META-INF/licenses") }
    from("../vendor/manifest.json") { into("META-INF/legado-provenance") }
    if (includeEngineTests) {
        // These are third-party test-runtime notices, not user-archive provenance.
        val junit = payloadDependencies.get().files.single { it.name == "junit-4.13.2.jar" }
        val hamcrest = payloadDependencies.get().files.single { it.name == "hamcrest-core-1.3.jar" }
        from(zipTree(junit)) {
            include("LICENSE-junit.txt")
            into("META-INF/licenses/engine-suite")
            rename { "junit-4.13.2-LICENSE.txt" }
        }
        from(zipTree(hamcrest)) {
            include("LICENSE.txt")
            into("META-INF/licenses/engine-suite")
            rename { "hamcrest-core-1.3-LICENSE.txt" }
        }
        from("../vendor/probe/licenses") { into("META-INF/licenses/http-wire-probe") }
        from(files("../vendor/probe/manifest.json", "../vendor/probe/resolved-dependencies.json")) {
            into("META-INF/legado-provenance/http-wire-probe")
        }
    }
    manifest.attributes["Implementation-Version"] = project.version
    manifest.attributes["Legado-Engine-Version"] = "5.3.0-legado.4"
    manifest.attributes["Legado-Engine-Tests"] = includeEngineTests.toString()
}

// Reproducible evidence for the opt-in probe, including the unchanged normal
// graph. No local paths, credentials or Gradle cache locations enter this file.
tasks.register("probeDependencyEvidence") {
    doLast {
        fun graph(configuration: Configuration): Map<String, Any> {
            val artifacts = configuration.incoming.artifacts.artifacts.map { artifact ->
                val bytes = artifact.file.readBytes()
                mapOf("component" to artifact.id.componentIdentifier.displayName,
                    "file" to artifact.file.name, "bytes" to bytes.size,
                    "sha256" to MessageDigest.getInstance("SHA-256").digest(bytes)
                        .joinToString("") { "%02x".format(it.toInt() and 255) })
            }.sortedBy { it["component"].toString() }
            val edges = configuration.incoming.resolutionResult.allDependencies
                .filterIsInstance<ResolvedDependencyResult>().map {
                    mapOf("from" to it.from.id.displayName, "requested" to it.requested.displayName,
                        "selected" to it.selected.id.displayName)
                }.sortedBy { it["from"] + "/" + it["requested"] }
            return mapOf("artifacts" to artifacts, "edges" to edges)
        }
        val evidence = mapOf("schemaVersion" to 1,
            "normalRuntimeClasspath" to graph(configurations.runtimeClasspath.get()),
            "diagnosticTestRuntimeClasspath" to graph(configurations.testRuntimeClasspath.get()))
        layout.buildDirectory.file("reports/http-wire/resolved-dependencies.json").get().asFile.apply {
            parentFile.mkdirs(); writeText(JsonOutput.prettyPrint(JsonOutput.toJson(evidence)) + "\n")
        }
    }
}

tasks.register<JavaExec>("runtimeSmoke") {
    dependsOn(runtimeJar)
    javaLauncher.set(javaToolchains.launcherFor { languageVersion.set(JavaLanguageVersion.of(21)) })
    classpath = files(runtimeJar.flatMap { it.archiveFile })
    mainClass.set(layout.projectDirectory.file("src/smoke/java/LegadoPayloadSmoke.java").asFile.absolutePath)
    jvmArgs("-Xint", "-Xmx128m")
}

tasks.register<JavaExec>("runtimeSuiteSmoke") {
    dependsOn(runtimeJar)
    javaLauncher.set(javaToolchains.launcherFor { languageVersion.set(JavaLanguageVersion.of(21)) })
    classpath = files(runtimeJar.flatMap { it.archiveFile })
    mainClass.set(layout.projectDirectory.file("src/smoke/java/LegadoSemanticSuiteSmoke.java").asFile.absolutePath)
    args(if (includeEngineTests) "present" else "absent")
    jvmArgs("-Xint", "-Xmx128m")
}

tasks.register<JavaExec>("runtimeWireSmoke") {
    dependsOn(runtimeJar)
    javaLauncher.set(javaToolchains.launcherFor { languageVersion.set(JavaLanguageVersion.of(21)) })
    classpath = files(runtimeJar.flatMap { it.archiveFile })
    mainClass.set(layout.projectDirectory.file("src/smoke/java/LegadoHttpWireSmoke.java").asFile.absolutePath)
    args(if (includeEngineTests) "present" else "absent")
    jvmArgs("-Xint", "-Xmx128m")
}
