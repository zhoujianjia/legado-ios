package io.yuedu.legado

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.nio.file.FileAlreadyExistsException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** File/schema/privacy guards only; native socket cancellation needs Simulator evidence. */
class RuntimeTaskTraceTest {
    private fun withPath(body: (java.nio.file.Path) -> Unit) {
        val root = Files.createTempDirectory("legado-task-trace-")
        try {
            val current = Files.createDirectory(root.resolve("current"))
            body(current.resolve("runtime-events.jsonl"))
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun redactsArbitraryTaskStringsAndKeepsOnlyFixedSchema() = withPath { path ->
        val id = UUID.randomUUID().toString()
        TaskTraceWriter.open(path).use { writer ->
            writer.event(TaskTraceStage.CANCEL_LOOKUP, "https://private.invalid/?token=SECRET", found = false)
            writer.event(TaskTraceStage.HTTP_CANCEL_AFTER, id.uppercase(), jobCancelled = true,
                timedOut = false, deadlineEpochMs = 1234, callId = 42, callCancelled = true, completed = true)
        }
        val text = Files.readString(path)
        assertFalse(text.contains("SECRET")); assertFalse(text.contains("private.invalid"))
        val events = text.lineSequence().filter(String::isNotBlank).map(::parseObject).toList()
        assertEquals("redacted", events[0]["taskId"].asString)
        assertEquals(id, events[1]["taskId"].asString)
        assertEquals("http.cancel.after", events[1]["stage"].asString)
        assertTrue(events[1]["completed"].asBoolean)
        val allowed = setOf("schemaVersion", "sequence", "epochMs", "elapsedNs", "stage", "taskId", "javaThreadId",
            "jobCancelled", "timedOut", "deadlineEpochMs", "callId", "found", "callCancelled", "completed")
        assertTrue(events.all { allowed.containsAll(it.keySet()) })
        assertEquals(listOf(0, 1), events.map { it["sequence"].asInt })
    }

    @Test fun eventAndByteLimitsNeverLeavePartialJsonLines() = withPath { path ->
        TaskTraceWriter.open(path, eventLimit = 2).use { writer ->
            repeat(20) { writer.event(TaskTraceStage.CANCEL_LOOKUP, "redact", found = false) }
        }
        assertEquals(2, Files.readAllLines(path).size)
        Files.delete(path)
        TaskTraceWriter.open(path, byteLimit = 300).use { writer ->
            repeat(20) { writer.event(TaskTraceStage.CANCEL_LOOKUP, "redact", found = false) }
        }
        assertTrue(Files.size(path) <= 300)
        assertTrue(Files.size(path) > 0)
        assertTrue(Files.readString(path).endsWith("\n"))
        val stages = Files.readAllLines(path).map { parseObject(it)["stage"].asString }
        assertTrue(stages.all { it in setOf("cancel.lookup", "trace.limit") })
        assertEquals("trace.limit", stages.last())
    }

    @Test fun concurrentCancelAndReadEventsKeepWholeOrderedLines() = withPath { path ->
        val workers = Executors.newFixedThreadPool(2)
        try {
            TaskTraceWriter.open(path, eventLimit = 64).use { writer ->
                val futures = (1..2).map {
                    workers.submit { repeat(64) { writer.event(TaskTraceStage.CANCEL_LOOKUP, "redacted", found = true) } }
                }
                futures.forEach { it.get(5, TimeUnit.SECONDS) }
            }
        } finally {
            workers.shutdownNow()
            check(workers.awaitTermination(2, TimeUnit.SECONDS))
        }
        val events = Files.readAllLines(path).map(::parseObject)
        assertEquals(64, events.size)
        assertEquals((0 until 64).toList(), events.map { it["sequence"].asInt })
        assertTrue(Files.size(path) <= TaskTraceWriter.MAX_BYTES)
    }

    @Test fun refusesExistingFilesAndUnapprovedNamesOrDirectories() = withPath { path ->
        TaskTraceWriter.open(path).close()
        assertThrows(FileAlreadyExistsException::class.java) { TaskTraceWriter.open(path) }
        assertThrows(IllegalArgumentException::class.java) { TaskTraceWriter.open(path.resolveSibling("private.jsonl")) }
        assertThrows(IllegalArgumentException::class.java) { TaskTraceWriter.open(path.parent.parent.resolve("runtime-events.jsonl")) }
    }
}
