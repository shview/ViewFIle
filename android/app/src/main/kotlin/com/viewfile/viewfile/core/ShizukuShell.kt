package com.viewfile.viewfile.core

import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException


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
            // IRemoteProcess 只有阻塞 waitFor()：放入 daemon waiter，由调用线程
            // 对 FutureTask 做 timed get。FutureTask 原子裁定截止点，不需要在
            // alive()/destroy() 与退出之间竞态判断；任意 exit code 按时完成均 true。
            if (timeout <= 0) return !rp.alive()
            val task = FutureTask<Int> { rp.waitFor() }
            Thread(task, "vf-shizuku-wait").apply { isDaemon = true }.start()
            return try {
                task.get(timeout, unit)
                true
            } catch (_: TimeoutException) {
                false // 上层先返回 timeout，再由异步清理线程 best-effort destroy
            } catch (e: ExecutionException) {
                throw (e.cause ?: e)
            }
        }
    }

    fun newProcess(cmd: Array<String>): Process {
        val s = svc() ?: throw IllegalStateException("Shizuku 服务不可用")
        return RemoteProcess(s.newProcess(cmd, null, null))
    }

    fun run(cmd: String, timeoutMs: Long = 15000): SuShell.Result {
        return try {
            ShellProcessRunner.run(newProcess(arrayOf("sh", "-c", cmd)), timeoutMs)
        } catch (t: Throwable) {
            SuShell.Result(-1, "", t.message ?: t.toString())
        }
    }

    fun runStream(cmd: String, timeoutMs: Long = 600000, onLine: (String) -> Unit): SuShell.Result {
        return try {
            ShellProcessRunner.runStream(
                newProcess(arrayOf("sh", "-c", cmd)), timeoutMs, onLine)
        } catch (t: Throwable) {
            SuShell.Result(-1, "", t.message ?: t.toString())
        }
    }

    fun runBinary(cmd: String, timeoutMs: Long = 600000,
                  onChunk: (ByteArray, Int) -> Unit): SuShell.Result = try {
        ShellProcessRunner.runBinary(newProcess(arrayOf("sh", "-c", cmd)), timeoutMs, onChunk)
    } catch (t: Throwable) {
        SuShell.Result(-1, "", t.message ?: t.toString())
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

    fun runBinary(cmd: String, timeoutMs: Long = 600000,
                  onChunk: (ByteArray, Int) -> Unit): SuShell.Result = when (tier()) {
        Tier.ROOT -> SuShell.runBinary(cmd, timeoutMs, onChunk)
        Tier.SHIZUKU -> ShizukuShell.runBinary(cmd, timeoutMs, onChunk)
        Tier.NONE -> SuShell.Result(-1, "", "无可用特权后端（root / Shizuku）")
    }
}
