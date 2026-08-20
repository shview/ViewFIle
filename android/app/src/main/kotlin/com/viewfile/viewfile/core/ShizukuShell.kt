package com.viewfile.viewfile.core

import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit


/**
 * Shizuku 后端：通过 binder 调用服务端 newProcess，
 * 以 shell uid（ADB 方式启动）或 root（root 方式启动）执行命令。
 * shell uid 拥有 media_rw 组，可读 /data/media/0 与 /data/local/tmp，
 * 但不能读其他应用的 /data/data——该区域仍需真正的 root。
 */
object ShizukuShell {
    private const val TAG = "ViewFile/Shizuku"
    private const val REQ_CODE = 4242

    @Volatile private var checked = false
    @Volatile private var granted = false

    private fun svc(): IShizukuService? = try {
        if (Shizuku.pingBinder()) {
            Shizuku.getBinder()?.let { IShizukuService.Stub.asInterface(it) }
        } else null
    } catch (_: Throwable) {
        null
    }

    fun getAvailable(refresh: Boolean = false): Boolean {
        if (refresh) checked = false
        if (checked) return granted
        granted = try {
            Shizuku.pingBinder() &&
                    svc() != null &&
                    Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (t: Throwable) {
            Log.w(TAG, "check failed: ${t.message}")
            false
        }
        checked = true
        Log.i(TAG, "shizuku available = $granted")
        return granted
    }

    fun requestPermission(): Boolean {
        return try {
            if (!Shizuku.pingBinder()) return false
            when (Shizuku.checkSelfPermission()) {
                PackageManager.PERMISSION_GRANTED -> true
                PackageManager.PERMISSION_DENIED -> {
                    Shizuku.requestPermission(REQ_CODE)
                    false
                }
                else -> false
            }
        } catch (t: Throwable) {
            Log.w(TAG, "request failed: ${t.message}")
            false
        }
    }

    fun isBinderAlive(): Boolean = try {
        Shizuku.pingBinder()
    } catch (_: Throwable) {
        false
    }

    /** 把远端进程包装成 java.lang.Process 供现有读取逻辑复用 */
    private class RemoteProcess(val rp: moe.shizuku.server.IRemoteProcess) : Process() {
        override fun getOutputStream() = FileOutputStream(rp.outputStream.fileDescriptor)
        override fun getInputStream() = FileInputStream(rp.inputStream.fileDescriptor)
        override fun getErrorStream(): java.io.InputStream =
            rp.errorStream?.let { FileInputStream(it.fileDescriptor) }
                ?: java.io.InputStream.nullInputStream()
        override fun waitFor(): Int = rp.waitFor()
        override fun exitValue(): Int = rp.exitValue()
        override fun destroy() {
            runCatching { rp.destroy() }
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            // 读流到 EOF 通常即进程结束；此处用阻塞 waitFor + 看门狗 destroy 兜底
            val killer = Thread({
                try {
                    Thread.sleep(unit.toMillis(timeout))
                    if (rp.alive()) destroy()
                } catch (_: InterruptedException) {}
            })
            killer.isDaemon = true
            killer.start()
            return try {
                rp.waitFor() == 0
            } finally {
                killer.interrupt()
            }
        }
    }

    fun newProcess(cmd: Array<String>): Process {
        val s = svc() ?: throw IllegalStateException("Shizuku 服务不可用")
        return RemoteProcess(s.newProcess(cmd, null, null))
    }

    fun run(cmd: String, timeoutMs: Long = 15000): SuShell.Result {
        return try {
            val p = newProcess(arrayOf("sh", "-c", cmd))
            val errThread = Thread { p.errorStream.bufferedReader().use { it.readText() } }
            errThread.isDaemon = true
            errThread.start()
            val out = p.inputStream.bufferedReader().use { it.readText() }
            val finished = p.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                p.destroyForcibly()
                SuShell.Result(-1, out, "timeout")
            } else {
                SuShell.Result(p.exitValue(), out, "")
            }
        } catch (t: Throwable) {
            SuShell.Result(-1, "", t.message ?: t.toString())
        }
    }

    fun runStream(cmd: String, timeoutMs: Long = 600000, onLine: (String) -> Unit): SuShell.Result {
        return try {
            val p = newProcess(arrayOf("sh", "-c", cmd))
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
                SuShell.Result(-1, "", "timeout")
            } else {
                SuShell.Result(p.exitValue(), "", errBuilder.toString())
            }
        } catch (t: Throwable) {
            SuShell.Result(-1, "", t.message ?: t.toString())
        }
    }
}

/** 特权命令统一入口：优先 root，其次 Shizuku，最后无特权 */
object PrivShell {
    enum class Tier { ROOT, SHIZUKU, NONE }

    fun tier(refresh: Boolean = false): Tier = when {
        SuShell.getAvailable(refresh) -> Tier.ROOT
        ShizukuShell.getAvailable(refresh) -> Tier.SHIZUKU
        else -> Tier.NONE
    }

    /** /data/data 等只有真 root 能碰；Android/data 原始路径与 tmp 对 shell 也开放 */
    fun needsRealRoot(path: String): Boolean {
        if (path == "/data/media" || path.startsWith("/data/media/")) return false
        if (path == "/data/local/tmp" || path.startsWith("/data/local/tmp/")) return false
        if (path.startsWith("/data/")) return true
        return false
    }

    fun run(cmd: String, timeoutMs: Long = 15000): SuShell.Result = when (tier()) {
        Tier.ROOT -> SuShell.run(cmd, timeoutMs)
        Tier.SHIZUKU -> ShizukuShell.run(cmd, timeoutMs)
        Tier.NONE -> SuShell.Result(-1, "", "无可用特权后端（root / Shizuku）")
    }

    fun runStream(cmd: String, timeoutMs: Long = 600000, onLine: (String) -> Unit): SuShell.Result =
        when (tier()) {
            Tier.ROOT -> SuShell.runStream(cmd, timeoutMs, onLine)
            Tier.SHIZUKU -> ShizukuShell.runStream(cmd, timeoutMs, onLine)
            Tier.NONE -> SuShell.Result(-1, "", "无可用特权后端（root / Shizuku）")
        }
}
