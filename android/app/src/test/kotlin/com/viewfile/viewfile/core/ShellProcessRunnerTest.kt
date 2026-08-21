package com.viewfile.viewfile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

class ShellProcessRunnerTest {
    @Test
    fun quickNonZeroExitIsPassedThroughWithoutTimeout() {
        val process = FakeProcess.completed(
            stdout = "partial output\n",
            stderr = "expected failure\n",
            exitCode = 17
        )

        val started = System.nanoTime()
        val result = ShellProcessRunner.run(process, 2_000)

        assertEquals(17, result.code)
        assertEquals("partial output\n", result.out)
        assertEquals("expected failure\n", result.err)
        assertFalse(result.err.contains("timeout"))
        assertTrue("quick process took too long", elapsedMillis(started) < 1_500)
        assertFalse(process.destroyCalled.get())
        process.assertWorkersStopped()
    }

    @Test
    fun runTimeoutReturnsPromptlyAndDestroysProcess() {
        val process = FakeProcess.hanging()

        val started = System.nanoTime()
        val result = ShellProcessRunner.run(process, 120)

        assertEquals(-1, result.code)
        assertTrue(result.err.contains("timeout"))
        assertTrue("timeout was not bounded", elapsedMillis(started) < 1_500)
        await("destroy was not called") { process.destroyCalled.get() }
        process.assertWorkersStopped()
    }

    @Test
    fun streamCallbackFailureDestroysAndNeverCallsBackAfterReturn() {
        val process = FakeProcess.streaming(
            stdoutWriter = { out ->
                repeat(10_000) { out.write("line-$it\n".toByteArray()) }
            }
        )
        val callbacks = Collections.synchronizedList(mutableListOf<String>())

        val started = System.nanoTime()
        val result = ShellProcessRunner.runStream(process, 5_000) { line ->
            callbacks += line
            if (callbacks.size == 3) throw IllegalStateException("callback boom")
        }

        assertEquals(-1, result.code)
        assertTrue(result.err.contains("stream callback failed: callback boom"))
        assertTrue("callback failure did not return promptly", elapsedMillis(started) < 1_500)
        await("destroy was not called") { process.destroyCalled.get() }
        val countAtReturn = callbacks.size
        Thread.sleep(150)
        assertEquals("callback ran after runStream returned", countAtReturn, callbacks.size)
        assertEquals(3, countAtReturn)
        process.assertWorkersStopped()
        awaitNoNewShellThreads()
    }

    @Test
    fun largeStdoutAndStderrDrainWithoutDeadlockAndKeepLineOrder() {
        val lineCount = 4_096 // four times ShellProcessRunner's queue capacity
        val stderrText = buildString(1_200_000) {
            repeat(1_200_000) { append(('a'.code + it % 26).toChar()) }
        }
        val process = FakeProcess.streaming(
            stdoutWriter = { out ->
                repeat(lineCount) { out.write("ordered-$it\n".toByteArray()) }
            },
            stderrWriter = { err -> err.write(stderrText.toByteArray()) }
        )
        val lines = ArrayList<String>(lineCount)

        val started = System.nanoTime()
        val result = ShellProcessRunner.runStream(process, 10_000) { lines += it }

        assertEquals(0, result.code)
        assertEquals(stderrText, result.err)
        assertEquals(lineCount, lines.size)
        repeat(lineCount) { assertEquals("ordered-$it", lines[it]) }
        assertTrue("large dual-stream drain took too long", elapsedMillis(started) < 8_000)
        process.assertWorkersStopped()
        awaitNoNewShellThreads()
    }

    @Test
    fun streamTimeoutCancelsReaderBlockedByFullQueue() {
        val process = FakeProcess.streaming(
            stdoutWriter = { out ->
                repeat(100_000) { out.write("queued-$it\n".toByteArray()) }
            }
        )
        val callbackCount = AtomicInteger()

        val started = System.nanoTime()
        val result = ShellProcessRunner.runStream(process, 180) {
            callbackCount.incrementAndGet()
            Thread.sleep(4) // lets stdout reader fill the bounded 1024-event queue
        }

        assertEquals(-1, result.code)
        assertTrue(result.err.contains("timeout"))
        assertTrue("stream timeout was not bounded", elapsedMillis(started) < 1_500)
        await("destroy was not called") { process.destroyCalled.get() }
        val countAtReturn = callbackCount.get()
        Thread.sleep(150)
        assertEquals("callback ran after timed-out runStream returned", countAtReturn, callbackCount.get())
        assertTrue("test did not consume enough data to exercise a busy reader", countAtReturn > 5)
        process.assertWorkersStopped()
        awaitNoNewShellThreads()
    }

    @Test
    fun normalStreamDeliversEachLineInOrder() {
        val expected = listOf("first", "second", "", "fourth with spaces")
        val process = FakeProcess.completed(expected.joinToString("\n", postfix = "\n"), "", 0)
        val actual = mutableListOf<String>()

        val result = ShellProcessRunner.runStream(process, 2_000) { actual += it }

        assertEquals(0, result.code)
        assertEquals("", result.err)
        assertEquals(expected, actual)
        process.assertWorkersStopped()
        awaitNoNewShellThreads()
    }

    private fun await(message: String, timeoutMs: Long = 1_500, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (!condition() && System.nanoTime() < deadline) Thread.sleep(10)
        assertTrue(message, condition())
    }

    private fun awaitNoNewShellThreads() {
        await("ShellProcessRunner left a live worker thread") {
            Thread.getAllStackTraces().keys.none {
                it.isAlive && it.name in setOf(
                    "vf-shell-out", "vf-shell-err", "vf-shell-wait",
                    "vf-shell-kill", "vf-shell-close"
                )
            }
        }
    }

    private fun elapsedMillis(started: Long): Long =
        TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)

    /**
     * JVM-only process whose tiny pipes reproduce OS back-pressure. destroy() closes both ends,
     * releases waiters and therefore gives cancellation tests a deterministic escape route.
     */
    private class FakeProcess private constructor(
        private val stdoutWriter: ((OutputStream) -> Unit)?,
        private val stderrWriter: ((OutputStream) -> Unit)?,
        private val configuredExitCode: Int,
        startWriters: Boolean
    ) : Process() {
        private val stdoutIn = PipedInputStream(1_024)
        private val stdoutOut = PipedOutputStream(stdoutIn)
        private val stderrIn = PipedInputStream(1_024)
        private val stderrOut = PipedOutputStream(stderrIn)
        private val stdin = OutputStream.nullOutputStream()
        private val exited = CountDownLatch(1)
        private val writersDone = CountDownLatch(if (startWriters) 2 else 0)
        private val alive = AtomicBoolean(true)
        val destroyCalled = AtomicBoolean(false)
        private val workers = mutableListOf<Thread>()

        init {
            if (startWriters) {
                workers += writerThread("fake-stdout", stdoutOut, stdoutWriter)
                workers += writerThread("fake-stderr", stderrOut, stderrWriter)
                workers += thread(name = "fake-process-exit", isDaemon = true) {
                    writersDone.await()
                    finish()
                }
            }
        }

        private fun writerThread(
            name: String,
            output: OutputStream,
            write: ((OutputStream) -> Unit)?
        ) = thread(name = name, isDaemon = true) {
            try {
                write?.invoke(output)
            } catch (_: Throwable) {
                // Closing a full pipe is the expected cancellation signal in timeout tests.
            } finally {
                runCatching { output.close() }
                writersDone.countDown()
            }
        }

        private fun finish() {
            if (alive.compareAndSet(true, false)) exited.countDown()
        }

        override fun getOutputStream(): OutputStream = stdin
        override fun getInputStream(): InputStream = stdoutIn
        override fun getErrorStream(): InputStream = stderrIn

        override fun waitFor(): Int {
            exited.await()
            return configuredExitCode
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = exited.await(timeout, unit)

        override fun exitValue(): Int {
            if (alive.get()) throw IllegalThreadStateException("process is still running")
            return configuredExitCode
        }

        override fun destroy() {
            destroyCalled.set(true)
            closePipes()
            finish()
        }

        override fun destroyForcibly(): Process {
            destroy()
            return this
        }

        override fun isAlive(): Boolean = alive.get()

        private fun closePipes() {
            runCatching { stdoutOut.close() }
            runCatching { stderrOut.close() }
            runCatching { stdoutIn.close() }
            runCatching { stderrIn.close() }
        }

        fun assertWorkersStopped() {
            workers.forEach { it.join(1_500) }
            val live = workers.filter { it.isAlive }.map { it.name }
            if (live.isNotEmpty()) fail("fake process left live workers: $live")
        }

        companion object {
            fun completed(stdout: String, stderr: String, exitCode: Int) = streaming(
                stdoutWriter = { it.write(stdout.toByteArray()) },
                stderrWriter = { it.write(stderr.toByteArray()) },
                exitCode = exitCode
            )

            fun streaming(
                stdoutWriter: ((OutputStream) -> Unit)? = null,
                stderrWriter: ((OutputStream) -> Unit)? = null,
                exitCode: Int = 0
            ) = FakeProcess(stdoutWriter, stderrWriter, exitCode, startWriters = true)

            fun hanging() = FakeProcess(null, null, 0, startWriters = false)
        }
    }
}
