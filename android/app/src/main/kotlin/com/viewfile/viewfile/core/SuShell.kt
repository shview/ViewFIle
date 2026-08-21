package com.viewfile.viewfile.core

import android.util.Log
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * 统一消费本地或 Shizuku Process：stdout/stderr 始终由独立 daemon 线程读取，
 * 调用线程只做 timed wait，因此大输出不会在 waitFor 前塞满管道造成假死。
 */
internal object ShellProcessRunner {
    private const val DRAIN_WAIT_MS = 2000L
    private const val TIMEOUT_DRAIN_WAIT_MS = 100L

    private sealed interface StreamEvent {
        class Line(val value: String) : StreamEvent
        class Failure(val error: Throwable) : StreamEvent
        data object Eof : StreamEvent
    }

    fun run(p: Process, timeoutMs: Long): SuShell.Result = execute(p, timeoutMs)

    fun runStream(p: Process, timeoutMs: Long, onLine: (String) -> Unit): SuShell.Result =
        executeStream(p, timeoutMs, onLine)

    private fun execute(p: Process, timeoutMs: Long): SuShell.Result {
        val out = StringBuffer()
        val err = StringBuffer()
        val readFailure = AtomicReference<Throwable?>(null)

        val stdoutThread = Thread({
            try {
                p.inputStream.bufferedReader().use { reader ->
                    val buf = CharArray(8192)
                    while (true) {
                        val n = reader.read(buf)
                        if (n < 0) break
                        out.append(buf, 0, n)
                    }
                }
            } catch (t: Throwable) {
                readFailure.compareAndSet(null, t)
            }
        }, "vf-shell-out")
        val stderrThread = Thread({
            try {
                p.errorStream.bufferedReader().use { reader ->
                    val buf = CharArray(4096)
                    while (true) {
                        val n = reader.read(buf)
                        if (n < 0) break
                        err.append(buf, 0, n)
                    }
                }
            } catch (t: Throwable) {
                readFailure.compareAndSet(null, t)
            }
        }, "vf-shell-err")
        stdoutThread.isDaemon = true
        stderrThread.isDaemon = true
        stdoutThread.start()
        stderrThread.start()

        val finished = try {
            p.waitFor(timeoutMs.coerceAtLeast(0), TimeUnit.MILLISECONDS)
        } catch (t: Throwable) {
            destroyAsync(p)
            return SuShell.Result(-1, out.toString(), t.message ?: t.toString())
        }
        if (!finished) {
            destroyAsync(p)
            stdoutThread.join(TIMEOUT_DRAIN_WAIT_MS)
            stderrThread.join(TIMEOUT_DRAIN_WAIT_MS)
            return SuShell.Result(-1, out.toString(), appendError(err.toString(), "timeout"))
        }

        val drainDeadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(DRAIN_WAIT_MS)
        joinUntil(stdoutThread, drainDeadline)
        joinUntil(stderrThread, drainDeadline)
        val drainTimedOut = stdoutThread.isAlive || stderrThread.isAlive
        if (drainTimedOut) {
            closeStreamsAsync(p)
        }

        val code = try {
            p.exitValue()
        } catch (t: Throwable) {
            return SuShell.Result(-1, out.toString(), appendError(err.toString(), t.message ?: t.toString()))
        }
        val failure = readFailure.get()
        val extra = when {
            failure != null -> "stream read failed: ${failure.message ?: failure.javaClass.simpleName}"
            drainTimedOut -> "stream drain timeout"
            else -> null
        }
        // 流读取失败会使成功输出不完整：code=0 时转为失败；真实非零码始终原样透传。
        val resultCode = if (code == 0 && extra != null) -1 else code
        return SuShell.Result(resultCode, out.toString(), appendError(err.toString(), extra))
    }

    /**
     * reader 线程只负责入队；回调由当前调用线程按队列顺序执行。这样回调抛出后
     * 可以立即退出消费循环并异步终止进程，函数返回后绝不会再有线程调用回调。
     */
    private fun executeStream(
        p: Process,
        timeoutMs: Long,
        onLine: (String) -> Unit
    ): SuShell.Result {
        val queue = ArrayBlockingQueue<StreamEvent>(1024)
        val err = StringBuffer()
        val stderrFailure = AtomicReference<Throwable?>(null)
        val cancelled = AtomicBoolean(false)
        val processDone = CountDownLatch(1)
        val deadline = System.nanoTime() +
                TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(0))

        fun offerEvent(event: StreamEvent): Boolean {
            while (!cancelled.get()) {
                try {
                    if (queue.offer(event, 100, TimeUnit.MILLISECONDS)) return true
                } catch (_: InterruptedException) {
                    return false
                }
            }
            return false
        }

        val stdoutThread = Thread({
            try {
                p.inputStream.bufferedReader().use { reader ->
                    while (!cancelled.get()) {
                        val line = reader.readLine() ?: break
                        if (!offerEvent(StreamEvent.Line(line))) break
                    }
                }
                if (!cancelled.get()) offerEvent(StreamEvent.Eof)
            } catch (t: Throwable) {
                if (!cancelled.get()) offerEvent(StreamEvent.Failure(t))
            }
        }, "vf-shell-out")
        val stderrThread = Thread({
            try {
                p.errorStream.bufferedReader().use { reader ->
                    val buf = CharArray(4096)
                    while (true) {
                        val n = reader.read(buf)
                        if (n < 0) break
                        err.append(buf, 0, n)
                    }
                }
            } catch (t: Throwable) {
                stderrFailure.compareAndSet(null, t)
            }
        }, "vf-shell-err")
        val waiter = Thread({
            try {
                p.waitFor()
            } finally {
                processDone.countDown()
            }
        }, "vf-shell-wait")
        stdoutThread.isDaemon = true
        stderrThread.isDaemon = true
        waiter.isDaemon = true
        stdoutThread.start()
        stderrThread.start()
        waiter.start()

        fun abortStream(extra: String): SuShell.Result {
            cancelled.set(true)
            stdoutThread.interrupt() // 立即解除 offer 等待；close/destroy 解除 readLine
            stderrThread.interrupt()
            waiter.interrupt()
            destroyAsync(p)
            val joinDeadline = System.nanoTime() +
                    TimeUnit.MILLISECONDS.toNanos(TIMEOUT_DRAIN_WAIT_MS)
            joinUntil(stdoutThread, joinDeadline)
            joinUntil(stderrThread, joinDeadline)
            return SuShell.Result(-1, "", appendError(err.toString(), extra))
        }

        var stdoutDone = false
        while (!stdoutDone || processDone.count != 0L) {
            val left = deadline - System.nanoTime()
            if (left <= 0) {
                return abortStream("timeout")
            }
            val event = try {
                queue.poll(minOf(left, TimeUnit.MILLISECONDS.toNanos(100)), TimeUnit.NANOSECONDS)
            } catch (t: InterruptedException) {
                Thread.currentThread().interrupt()
                return abortStream("interrupted")
            }
            when (event) {
                is StreamEvent.Line -> try {
                    onLine(event.value)
                } catch (t: Throwable) {
                    return abortStream(
                        "stream callback failed: ${t.message ?: t.javaClass.simpleName}")
                }
                is StreamEvent.Failure -> {
                    return abortStream(
                        "stream read failed: ${event.error.message ?: event.error.javaClass.simpleName}")
                }
                StreamEvent.Eof -> stdoutDone = true
                null -> Unit
            }
        }

        val drainDeadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(DRAIN_WAIT_MS)
        joinUntil(stderrThread, drainDeadline)
        val code = try {
            p.exitValue()
        } catch (t: Throwable) {
            return SuShell.Result(-1, "", appendError(err.toString(), t.message ?: t.toString()))
        }
        val failure = stderrFailure.get()
        val extra = when {
            failure != null -> "stream read failed: ${failure.message ?: failure.javaClass.simpleName}"
            stderrThread.isAlive -> "stream drain timeout"
            else -> null
        }
        if (stderrThread.isAlive) closeStreamsAsync(p)
        val resultCode = if (code == 0 && extra != null) -1 else code
        return SuShell.Result(resultCode, "", appendError(err.toString(), extra))
    }

    private fun joinUntil(thread: Thread, deadlineNanos: Long) {
        val left = deadlineNanos - System.nanoTime()
        if (left <= 0) return
        val millis = TimeUnit.NANOSECONDS.toMillis(left).coerceAtLeast(1)
        thread.join(millis)
    }

    private fun destroyAsync(p: Process) {
        Thread({
            runCatching { p.destroy() }
            runCatching { if (p.isAlive) p.destroyForcibly() }
            runCatching { p.inputStream.close() }
            runCatching { p.errorStream.close() }
            runCatching { p.outputStream.close() }
        }, "vf-shell-kill").apply { isDaemon = true }.start()
    }

    private fun closeStreamsAsync(p: Process) {
        Thread({
            runCatching { p.inputStream.close() }
            runCatching { p.errorStream.close() }
            runCatching { p.outputStream.close() }
        }, "vf-shell-close").apply { isDaemon = true }.start()
    }

    private fun appendError(current: String, extra: String?): String = when {
        extra.isNullOrEmpty() -> current
        current.isEmpty() -> extra
        else -> "$current\n$extra"
    }
}

/**
 * 轻量 su 封装：每次 `su -c <cmd>` 新起进程（约 30–80ms 开销），
 * 浏览/文件操作足够；扫描用 runStream 流式读取避免输出堆积。
 * 兼容 Magisk / KernelSU / APatch。
 */
object SuShell {
    private const val TAG = "ViewFile/Su"
    private val cached = AtomicBoolean(false)
    @Volatile
    private var checked = false

    class Result(val code: Int, val out: String, val err: String) {
        val ok get() = code == 0
    }

    /** 首次调用 su 时系统会弹 root 授权框（需用户在手机上允许） */
    fun getAvailable(refresh: Boolean = false): Boolean {
        if (refresh) { checked = false }
        if (checked) return cached.get()
        val ok = try {
            val p = ProcessBuilder("su", "-c", "id").start()
            val r = ShellProcessRunner.run(p, 5000)
            r.ok && r.out.contains("uid=0")
        } catch (t: Throwable) {
            Log.w(TAG, "su check failed: ${t.message}")
            false
        }
        cached.set(ok)
        checked = true
        Log.i(TAG, "su available = $ok")
        return ok
    }

    /**
     * su 命令包装：进入 PID1 的挂载命名空间再执行。
     * Magisk su 默认继承调用方（app）的命名空间，部分 ROM（实测 ColorOS 15）
     * 在 app 命名空间里对 /data/data 是过滤视图——su 也只能看到自己与 GMS，
     * 扫描与浏览都会缺失。nsenter 后视图与 adb shell 一致。
     */
    private fun suArgs(cmd: String): Array<String> =
        // "--" 必须：否则 toybox nsenter 会把 sh 的 -c 当成自己的选项
        arrayOf("su", "-c", "nsenter -t 1 -m -- /system/bin/sh -c " + shq(cmd))

    /** 常规执行（输出量小的命令） */
    fun run(cmd: String, timeoutMs: Long = 15000): Result {
        return try {
            ShellProcessRunner.run(ProcessBuilder(*suArgs(cmd)).start(), timeoutMs)
        } catch (t: Throwable) {
            Result(-1, "", t.message ?: t.toString())
        }
    }

    /**
     * 流式执行（扫描用）：逐行回调 stdout，不等全部输出。
     */
    fun runStream(cmd: String, timeoutMs: Long = 600000, onLine: (String) -> Unit): Result {
        return try {
            ShellProcessRunner.runStream(ProcessBuilder(*suArgs(cmd)).start(), timeoutMs, onLine)
        } catch (t: Throwable) {
            Result(-1, "", t.message ?: t.toString())
        }
    }
}

/** shell 单引号安全包裹 */
fun shq(s: String): String = "'" + s.replace("'", "'\\''") + "'"
