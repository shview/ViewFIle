package com.viewfile.viewfile.core

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

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

    /** root 辅助进程监听；全局 watch 上限只读检查，绝不由应用修改。 */
    private fun startRootProcess(useShizuku: Boolean) {
        val bin = Engine.nativeHelperPath()
        if (bin == null) {
            Log.w(TAG, "libvfwatch.so missing, fallback to media observer")
            startMediaObserver()
            return
        }
        // 目录清单取自内存 dirIds（v3 库内无路径；载入后必然可用）
        val dirs = ArrayList<String>(1024)
        for (p in index.directoryPaths()) dirs.add(RootScanner.toRaw(p))
        if (dirs.size > WatcherProtocol.MAX_WATCH) {
            Log.w(TAG, "watch request exceeds native cap: requested=${dirs.size} " +
                    "cap=${WatcherProtocol.MAX_WATCH}; fallback to media observer")
            startMediaObserver()
            return
        }
        if (!hasWatchCapacity(dirs.size, useShizuku)) {
            startMediaObserver()
            return
        }
        stopMediaObserver()
        var startupDecision: CountDownLatch? = null
        try {
            val p = if (useShizuku) {
                ShizukuShell.newProcess(arrayOf(bin))
            } else {
                // nsenter 进 PID1 命名空间：同 SuShell，避免 app 视图过滤
                ProcessBuilder("su", "-c", "nsenter -t 1 -m " + shq(bin)).start()
            }
            rootProc = p
            val ready = AtomicReference<WatcherProtocol.Ready?>(null)
            val firstLine = AtomicReference<String?>(null)
            val readyLatch = CountDownLatch(1)
            val decisionLatch = CountDownLatch(1)
            startupDecision = decisionLatch
            val accepted = AtomicBoolean(false)
            val stderr = StringBuffer()

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
            }, "vf-watch-feed").apply { isDaemon = true }.start()

            // stdout 只有这一个 reader：先完成 ready 握手，再由同一线程分发事件。
            Thread({
                try {
                    BufferedReader(InputStreamReader(p.inputStream)).use { r ->
                        val line = r.readLine()
                        firstLine.set(line)
                        ready.set(WatcherProtocol.parseReady(line))
                        readyLatch.countDown()
                        decisionLatch.await()
                        if (!accepted.get()) return@use
                        while (true) {
                            val event = r.readLine() ?: break
                            if (WatcherProtocol.isEvent(event)) markDirty()
                        }
                    }
                } catch (_: Throwable) {
                    readyLatch.countDown()
                }
                if (accepted.get()) {
                    Log.w(TAG, "vfwatch exited${if (stderr.isNotBlank()) ": ${stderr.take(200)}" else ""}")
                }
            }, "vf-watch-read").apply { isDaemon = true }.start()
            Thread({
                try {
                    p.errorStream.bufferedReader().use { r ->
                        val buf = CharArray(256)
                        while (stderr.length < 1000) {
                            val n = r.read(buf)
                            if (n < 0) break
                            stderr.append(buf, 0, minOf(n, 1000 - stderr.length))
                        }
                    }
                } catch (_: Throwable) {}
            }, "vf-watch-err").apply { isDaemon = true }.start()

            val received = try {
                readyLatch.await(WatcherProtocol.READY_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                false
            }
            val handshake = ready.get()
            val healthy = received && handshake != null && p.isAlive &&
                    WatcherProtocol.coversExpected(dirs.size, handshake)
            if (!healthy) {
                decisionLatch.countDown()
                val reason = when {
                    !received -> "ready timeout"
                    handshake == null -> "invalid ready handshake: ${firstLine.get()}"
                    !p.isAlive -> "process exited during ready handshake"
                    else -> "incomplete coverage: requested=${handshake.requested} " +
                            "installed=${handshake.installed} expected=${dirs.size}"
                }
                Log.w(TAG, "$reason; stopping native watcher and falling back")
                stopRootProcess()
                startMediaObserver()
                return
            }
            accepted.set(true)
            watchedDirCount = handshake.installed
            decisionLatch.countDown()
            Log.i(TAG, "root watcher ready via ${if (useShizuku) "shizuku" else "su"} " +
                    "($bin, requested=${handshake.requested}, installed=${handshake.installed})")
        } catch (t: Throwable) {
            Log.w(TAG, "start root watcher failed: ${t.message}, fallback")
            startupDecision?.countDown()
            stopRootProcess()
            startMediaObserver()
        }
    }

    /** 读取失败也保守回退，避免在容量未知时启动只能覆盖部分目录的 watcher。 */
    private fun hasWatchCapacity(needed: Int, useShizuku: Boolean): Boolean {
        val result = try {
            val command = "cat /proc/sys/fs/inotify/max_user_watches"
            if (useShizuku) ShizukuShell.run(command) else SuShell.run(command)
        } catch (t: Throwable) {
            Log.w(TAG, "read watch limit failed: ${t.message}; fallback to media observer")
            return false
        }
        val current = result.out.trim().toIntOrNull()
        if (!result.ok || current == null) {
            Log.w(TAG, "read watch limit failed (rc=${result.code}); fallback to media observer")
            return false
        }
        if (current < needed) {
            Log.w(TAG, "watch limit insufficient: current=$current needed=$needed; " +
                    "global setting left unchanged, fallback to media observer")
            return false
        }
        return true
    }

    private fun startMediaObserver() {
        if (mediaObserver != null) {
            watchedDirCount = Int.MAX_VALUE
            return
        }
        val obs = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                markDirty()
            }
        }
        context.contentResolver.registerContentObserver(
            MediaStore.Files.getContentUri("external"), true, obs)
        mediaObserver = obs
        // MediaStore observer 不依赖索引中的目录清单，不需要在索引载入后替换。
        watchedDirCount = Int.MAX_VALUE
        Log.i(TAG, "media store observer started (no-root mode)")
    }

    private fun stopMediaObserver() {
        mediaObserver?.let {
            runCatching { context.contentResolver.unregisterContentObserver(it) }
        }
        mediaObserver = null
    }

    /** 同步完成后调用：特权模式重启辅助进程以覆盖新增目录 */
    fun refreshRootProcess() {
        if (!running || !rootMode) return
        stopRootProcess()
        startRootProcess(usingShizuku)
    }

    private fun stopRootProcess() {
        watchedDirCount = 0
        rootProc?.let { p ->
            rootProc = null
            runCatching { p.destroy() }
        }
        // destroy 只杀到 su，vfwatch 会成为孤儿进程；按名同步清理。
        // 必须同步：异步 pkill 会与 refreshRootProcess 的新进程竞态，误杀继任者
        runCatching { SuShell.run("pkill -f libvfwatch.so", 5000) }
        runCatching { ShizukuShell.run("pkill -f libvfwatch.so", 5000) }
    }

    fun stop() {
        running = false
        stopRootProcess()
        stopMediaObserver()
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
