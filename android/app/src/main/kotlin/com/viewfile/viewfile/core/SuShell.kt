package com.viewfile.viewfile.core

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

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
            val finished = p.waitFor(5, TimeUnit.SECONDS)
            val out = p.inputStream.bufferedReader().use { it.readText() }
            p.errorStream.bufferedReader().use { it.readText() }
            p.destroy()
            finished && out.contains("uid=0")
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
            val p = ProcessBuilder(*suArgs(cmd)).start()
            val errThread = Thread { p.errorStream.bufferedReader().use { it.readText() } }
            errThread.isDaemon = true
            errThread.start()
            val out = p.inputStream.bufferedReader().use { it.readText() }
            val finished = p.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                p.destroyForcibly()
                Result(-1, out, "timeout")
            } else {
                Result(p.exitValue(), out, "")
            }
        } catch (t: Throwable) {
            Result(-1, "", t.message ?: t.toString())
        }
    }

    /**
     * 流式执行（扫描用）：逐行回调 stdout，不等全部输出。
     */
    fun runStream(cmd: String, timeoutMs: Long = 600000, onLine: (String) -> Unit): Result {
        return try {
            val p = ProcessBuilder(*suArgs(cmd)).start()
            val errBuilder = StringBuilder()
            val errThread = Thread {
                p.errorStream.bufferedReader().forEachLine { errBuilder.appendLine(it) }
            }
            errThread.isDaemon = true
            errThread.start()
            BufferedReader(InputStreamReader(p.inputStream)).use { r ->
                while (true) {
                    val line = r.readLine() ?: break
                    onLine(line)
                }
            }
            val finished = p.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                p.destroyForcibly()
                Result(-1, "", "timeout")
            } else {
                Result(p.exitValue(), "", errBuilder.toString())
            }
        } catch (t: Throwable) {
            Result(-1, "", t.message ?: t.toString())
        }
    }
}

/** shell 单引号安全包裹 */
fun shq(s: String): String = "'" + s.replace("'", "'\\''") + "'"
