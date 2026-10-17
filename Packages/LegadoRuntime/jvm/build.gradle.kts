import java.util.zip.ZipFile

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
}

tasks.test { useJUnit(); maxHeapSize = "512m" }

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
    inputs.files(configurations.runtimeClasspath)
    outputs.dir(mergedServices)
    doLast {
        val output = mergedServices.get().asFile
        output.deleteRecursively()
        val services = linkedMapOf<String, LinkedHashSet<String>>()
        configurations.runtimeClasspath.get().files.forEach { dependency ->
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
    from(sourceSets.main.get().output)
    configurations.runtimeClasspath.get().files.forEach { dependency ->
        from(zipTree(dependency)) {
            exclude("META-INF/services/**", "META-INF/*.SF", "META-INF/*.RSA", "META-INF/*.DSA",
                "module-info.class", "META-INF/versions/**/module-info.class")
        }
    }
    from(mergedServices)
    from("../vendor/LICENSE") { into("META-INF/licenses/legado") }
    from("../vendor/licenses") { into("META-INF/licenses") }
    from("../vendor/manifest.json") { into("META-INF/legado-provenance") }
    manifest.attributes["Implementation-Version"] = project.version
    manifest.attributes["Legado-Engine-Version"] = "5.3.0-legado.4"
}

tasks.register<JavaExec>("runtimeSmoke") {
    dependsOn(runtimeJar)
    javaLauncher.set(javaToolchains.launcherFor { languageVersion.set(JavaLanguageVersion.of(21)) })
    classpath = files(runtimeJar.flatMap { it.archiveFile })
    mainClass.set(layout.projectDirectory.file("src/smoke/java/LegadoPayloadSmoke.java").asFile.absolutePath)
    jvmArgs("-Xint", "-Xmx128m")
}
