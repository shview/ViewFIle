package com.viewfile.viewfile.core

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter

/**
 * 前台实时监听（“无常驻”设计的一部分：只在 app 可见期间存在）。
 * 事件只作为“触发信号”，静默 2s 后由 Engine 跑增量对账拿到精确结果。
 *
 * - root 模式：su 拉起原生 vfwatch 进程，以 root 对索引全部目录
 *   （含 /data/media/0、/data/data 原始路径）挂 inotify；
 *   app 自身 uid 无法读这些路径，进程内 FileObserver 不可行（已实测）。
 * - 免 root 模式：监听 MediaStore 变化（FUSE 层不允许应用挂 inotify）。
 */
class TreeWatcher(
    private val context: Context,
    private val index: SearchIndex,
    private val onDirty: () -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private var mediaObserver: ContentObserver? = null
    private var rootProc: Process? = null
    @Volatile private var running = false
    @Volatile private var rootMode = false
    private var dirtyRunnable: Runnable? = null
    @Volatile private var firstDirtyAt = 0L

    companion object {
        private const val TAG = "ViewFile/Watch"
        private const val QUIET_MS = 2000L       // 事件静默期
        private const val MAX_DELAY_MS = 10000L  // 持续变动时的最长拖延
        private const val COOLDOWN_MS = 25000L   // 监听触发同步的最小间隔（大库防同步风暴）
    }

    fun start(useRoot: Boolean, useShizuku: Boolean) {
        if (running) return
        running = true
        rootMode = useRoot || useShizuku
        usingShizuku = useShizuku && !useRoot
        if (rootMode) startRootProcess(usingShizuku) else startMediaObserver()
    }

    @Volatile private var usingShizuku = false
    /** 本次实例监视的目录数（0 = 空库期误启，需要被替换） */
    @Volatile var watchedDirCount = 0
        private set

    fun isRunning() = running

    private fun binaryPath(): String? =
        context.applicationInfo.nativeLibraryDir
            ?.let { dir -> File(dir, "libvfwatch.so") }
            ?.takeIf { it.exists() }?.absolutePath

    /** root 辅助进程监听；仅当默认 watch 上限不足时才临时调大并在停止时恢复 */
    private fun startRootProcess(useShizuku: Boolean) {
        val bin = binaryPath()
        if (bin == null) {
            Log.w(TAG, "libvfwatch.so missing, fallback to media observer")
            startMediaObserver()
            return
        }
        // 目录清单取自内存 dirIds（v3 库内无路径；载入后必然可用）
        val dirs = ArrayList<String>(1024)
        for (p in index.dirIds.keys) dirs.add(RootScanner.toRaw(p))
        if (!useShizuku) ensureWatchLimit(dirs.size)
        try {
            val p = if (useShizuku) {
                ShizukuShell.newProcess(arrayOf(bin))
            } else {
                // nsenter 进 PID1 命名空间：同 SuShell，避免 app 视图过滤
                ProcessBuilder("su", "-c", "nsenter -t 1 -m " + shq(bin)).start()
            }
            rootProc = p
            // 喂目录清单（原始路径）
            Thread({
                try {
                    val w = BufferedWriter(OutputStreamWriter(p.outputStream))
                    for (d in dirs) w.write(d + "\n")
                    w.write(".\n")
                    w.flush()
                    w.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "feed dirs failed: ${t.message}")
                }
            }, "vf-watch-feed").start()
            // 读事件信号：任何一行 = 有变化；stderr 一并捕获用于诊断
            Thread({
                try {
                    BufferedReader(InputStreamReader(p.inputStream)).use { r ->
                        while (r.readLine() != null) markDirty()
                    }
                } catch (_: Throwable) {}
                val err = try {
                    p.errorStream.bufferedReader().use { it.readText().take(200) }
                } catch (_: Throwable) { "" }
                Log.w(TAG, "vfwatch exited${if (err.isNotBlank()) ": $err" else ""}")
            }, "vf-watch-read").start()
            watchedDirCount = if (rootMode) dirs.size else Int.MAX_VALUE
            Log.i(TAG, "root watcher started via ${if (useShizuku) "shizuku" else "su"} ($bin, ${dirs.size} dirs)")
        } catch (t: Throwable) {
            Log.w(TAG, "start root watcher failed: ${t.message}, fallback")
            startMediaObserver()
        }
    }

    /** 仅当现有上限不足以覆盖 needed 时才调大；记录原值供恢复 */
    private fun ensureWatchLimit(needed: Int) {
        try {
            val cur = SuShell.run("cat /proc/sys/fs/inotify/max_user_watches").out.trim()
            val curVal = cur.toIntOrNull() ?: return
            if (curVal >= needed) return  // 默认上限够用：不做任何系统改动
            if (savedWatchLimit == null) savedWatchLimit = cur
            SuShell.run("echo ${needed * 2} > /proc/sys/fs/inotify/max_user_watches")
            Log.i(TAG, "watch limit raised $cur -> ${needed * 2} (will restore on stop)")
        } catch (t: Throwable) {
            Log.w(TAG, "ensureWatchLimit failed: ${t.message}")
        }
    }

    private var savedWatchLimit: String? = null

    private fun restoreWatchLimit() {
        savedWatchLimit?.let { orig ->
            savedWatchLimit = null
            Thread({
                runCatching {
                    SuShell.run("echo $orig > /proc/sys/fs/inotify/max_user_watches")
                    Log.i(TAG, "watch limit restored to $orig")
                }
            }, "vf-watch-restore").start()
        }
    }

    private fun startMediaObserver() {
        val obs = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                markDirty()
            }
        }
        context.contentResolver.registerContentObserver(
            MediaStore.Files.getContentUri("external"), true, obs)
        mediaObserver = obs
        Log.i(TAG, "media store observer started (no-root mode)")
    }

    /** 同步完成后调用：特权模式重启辅助进程以覆盖新增目录 */
    fun refreshRootProcess() {
        if (!running || !rootMode) return
        stopRootProcess()
        startRootProcess(usingShizuku)
    }

    private fun stopRootProcess() {
        rootProc?.let { p ->
            rootProc = null
            runCatching { p.destroy() }
        }
        // destroy 只杀到 su，vfwatch 会成为孤儿进程；按名同步清理。
        // 必须同步：异步 pkill 会与 refreshRootProcess 的新进程竞态，误杀继任者
        runCatching { SuShell.run("pkill -f libvfwatch.so", 5000) }
        runCatching { ShizukuShell.run("pkill -f libvfwatch.so", 5000) }
        restoreWatchLimit()
    }

    fun stop() {
        running = false
        stopRootProcess()
        mediaObserver?.let { context.contentResolver.unregisterContentObserver(it) }
        mediaObserver = null
        dirtyRunnable?.let { handler.removeCallbacks(it) }
        dirtyRunnable = null
        Log.i(TAG, "watcher stopped")
    }

    @Volatile private var lastDispatchAt = 0L

    private fun markDirty() {
        if (!running) return
        if (firstDirtyAt == 0L) firstDirtyAt = System.currentTimeMillis()
        val existing = dirtyRunnable
        if (existing == null) {
            val nr = object : Runnable {
                override fun run() {
                    val sinceSync = System.currentTimeMillis() - lastDispatchAt
                    if (sinceSync < COOLDOWN_MS) {
                        // 同步冷却中：顺延到冷却结束再试（保持单一待处理任务）
                        handler.postDelayed(this, COOLDOWN_MS - sinceSync)
                        return
                    }
                    dirtyRunnable = null
                    firstDirtyAt = 0L
                    if (running) {
                        lastDispatchAt = System.currentTimeMillis()
                        onDirty()
                    }
                }
            }
            dirtyRunnable = nr
            handler.postDelayed(nr, QUIET_MS)
        } else if (System.currentTimeMillis() - firstDirtyAt >= MAX_DELAY_MS + COOLDOWN_MS) {
            handler.removeCallbacks(existing)
            dirtyRunnable = null
            firstDirtyAt = 0L
            if (running) {
                lastDispatchAt = System.currentTimeMillis()
                onDirty()
            }
        }
    }
}
