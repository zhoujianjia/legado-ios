package io.yuedu.legado

import java.io.Closeable
import java.nio.ByteBuffer
import java.nio.channels.SeekableByteChannel
import java.nio.file.Files
import java.nio.file.FileSystems
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions
import java.util.Locale

/** Explicit embedding diagnostic, never enabled/configured by a book source. */
internal object RuntimeTaskTrace {
    // Initialized with the facade, before a source script can change properties.
    private val writer = System.getProperty("io.yuedu.legado.taskTrace")?.let { value ->
        try { TaskTraceWriter.open(Path.of(value)) }
        catch (_: Exception) { System.err.println("LEGADO_TASK_TRACE_OPEN_FAILED"); null }
    }

    fun event(stage: TaskTraceStage, task: RuntimeTask, callId: Int? = null,
              found: Boolean? = null, callCancelled: Boolean? = null, completed: Boolean? = null) {
        writer?.event(stage, task.id, task.job.isCancelled, task.timedOut.get(), task.deadlineEpochMs,
            callId, found, callCancelled, completed)
    }

    fun lookup(taskId: String, found: Boolean) {
        writer?.event(TaskTraceStage.CANCEL_LOOKUP, taskId, found = found)
    }
}

internal enum class TaskTraceStage(val wire: String) {
    EXECUTE_REGISTERED("execute.registered"),
    EXECUTE_FINISHED("execute.finished"),
    CANCEL_LOOKUP("cancel.lookup"),
    JOB_CANCEL_BEFORE("job.cancel.before"),
    JOB_CANCEL_AFTER("job.cancel.after"),
    DEADLINE_FIRED("deadline.fired"),
    DEADLINE_CANCEL_AFTER("deadline.cancel.after"),
    HTTP_REGISTERED("http.registered"),
    HTTP_EXECUTE_BEFORE("http.execute.before"),
    HTTP_HEADERS("http.headers"),
    HTTP_BODY_BEFORE("http.body.before"),
    HTTP_BODY_AFTER("http.body.after"),
    HTTP_CANCEL_BEFORE("http.cancel.before"),
    HTTP_CANCEL_AFTER("http.cancel.after"),
    HTTP_FINISHED("http.finished"),
    TRACE_LIMIT("trace.limit")
}

/** One bounded, CREATE_NEW file. The only text values are fixed stages and UUIDs.
 * Trace failure is explicit in captured VM stderr and never changes task semantics.
 * This adds no watchdog, socket manipulation, cancellation handler or timeout.
 */
internal class TaskTraceWriter private constructor(
    private val output: SeekableByteChannel,
    private val eventLimit: Int,
    private val byteLimit: Int,
) : Closeable {
    private var events = 0
    private var bytes = 0
    private var failed = false
    private val started = System.nanoTime()

    @Synchronized
    fun event(stage: TaskTraceStage, taskId: String, jobCancelled: Boolean? = null,
              timedOut: Boolean? = null, deadlineEpochMs: Long? = null, callId: Int? = null,
              found: Boolean? = null, callCancelled: Boolean? = null, completed: Boolean? = null) {
        if (failed) return
        // Reserve one slot and 128 bytes for an in-file terminal marker: Java
        // System.err does not necessarily pass through JNI's VM vfprintf hook.
        if (events >= eventLimit - 1) { limitReached(); return }
        val event = jsonObject("schemaVersion" to 1, "sequence" to events,
            "epochMs" to System.currentTimeMillis(), "elapsedNs" to System.nanoTime() - started,
            "stage" to stage.wire, "taskId" to safeTaskId(taskId),
            "javaThreadId" to Thread.currentThread().threadId())
        jobCancelled?.let { event.addProperty("jobCancelled", it) }
        timedOut?.let { event.addProperty("timedOut", it) }
        deadlineEpochMs?.let { event.addProperty("deadlineEpochMs", it) }
        callId?.let { event.addProperty("callId", it) }
        found?.let { event.addProperty("found", it) }
        callCancelled?.let { event.addProperty("callCancelled", it) }
        completed?.let { event.addProperty("completed", it) }
        val line = (event.toString() + "\n").toByteArray(Charsets.UTF_8)
        if (line.size > byteLimit - bytes - 128) { limitReached(); return }
        append(line)
    }

    private fun limitReached() {
        val line = (jsonObject("schemaVersion" to 1, "sequence" to events,
            "stage" to TaskTraceStage.TRACE_LIMIT.wire, "taskId" to "redacted").toString() + "\n").toByteArray(Charsets.UTF_8)
        if (events < eventLimit && line.size <= byteLimit - bytes) append(line)
        failed = true
        System.err.println("LEGADO_TASK_TRACE_LIMIT")
    }

    private fun append(line: ByteArray) {
        try {
            val buffer = ByteBuffer.wrap(line)
            while (buffer.hasRemaining()) check(output.write(buffer) > 0)
            bytes += line.size
            events++
        } catch (_: Exception) {
            failed = true
            System.err.println("LEGADO_TASK_TRACE_WRITE_FAILED")
        }
    }

    @Synchronized override fun close() { output.close() }

    companion object {
        const val MAX_BYTES = 64 * 1024
        const val MAX_EVENTS = 256
        private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        internal fun safeTaskId(value: String): String =
            if (uuid.matches(value)) value.lowercase(Locale.ROOT) else "redacted"

        internal fun open(path: Path, eventLimit: Int = MAX_EVENTS, byteLimit: Int = MAX_BYTES): TaskTraceWriter {
            require(eventLimit in 1..MAX_EVENTS && byteLimit in 1..MAX_BYTES)
            val absolute = path.toAbsolutePath().normalize()
            require(absolute.fileName.toString() == "runtime-events.jsonl")
            require(absolute.parent.fileName.toString() == "current" && Files.isDirectory(absolute.parent, LinkOption.NOFOLLOW_LINKS))
            require(!Files.isSymbolicLink(absolute.parent)) { "Trace attempt must not be linked" }
            val attributes = if (FileSystems.getDefault().supportedFileAttributeViews().contains("posix"))
                arrayOf(PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))) else emptyArray()
            val output = Files.newByteChannel(absolute, setOf(StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE), *attributes)
            return TaskTraceWriter(output, eventLimit, byteLimit)
        }
    }
}
