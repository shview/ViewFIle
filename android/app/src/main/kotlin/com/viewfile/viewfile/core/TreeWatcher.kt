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
import java.util.concurrent.Executors
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
    private val lifecycleLock = Any()
    private var mediaObserver: ContentObserver? = null
    private var rootProc: Process? = null
    private var rootProcGeneration = 0L
    private var generation = 0L
    @Volatile private var running = false
    @Volatile private var rootMode = false
    private var dirtyRunnable: Runnable? = null
    @Volatile private var firstDirtyAt = 0L

    companion object {
        private const val TAG = "ViewFile/Watch"
        private const val QUIET_MS = 2000L       // 事件静默期
        private const val MAX_DELAY_MS = 10000L  // 持续变动时的最长拖延
        private const val COOLDOWN_MS = 25000L   // 监听触发同步的最小间隔（大库防同步风暴）
        private const val HELPER_STATE_PREFS = "vfwatch_helper_state"
        private const val PREF_BACKEND = "backend"
        private const val PREF_HELPER_PATH = "helper_path"

        /** 进程级单一协调器：所有 TreeWatcher 实例共用，不持有过期 Context。 */
        private val coordinatorLock = Any()
        private val coordinatorExec = Executors.newSingleThreadExecutor { r ->
            Thread(r, "vf-watch-lifecycle").apply { isDaemon = true }
        }
        private var coordinatorEpoch = 0L
        private var desiredOwner: TreeWatcher? = null
        private var helperMayExist = false
        private var helperBackend: WatcherHelperBackend? = null
        private var helperIdentityPattern: String? = null
        private var orphanPreflightState = WatcherOrphanPreflightState()

        private fun enqueueStart(
            owner: TreeWatcher,
            prepare: (Long) -> Boolean,
            action: (Long) -> Unit,
        ) {
            synchronized(coordinatorLock) {
                val transition = planGlobalWatcherStart(
                    GlobalWatcherCoordinatorState(desiredOwner, coordinatorEpoch, helperMayExist),
                    owner,
                )
                if (!prepare(transition.ticket)) return
                coordinatorEpoch = transition.state.epoch
                desiredOwner = owner
                coordinatorExec.execute { action(transition.ticket) }
            }
        }

        private fun enqueueRefresh(
            owner: TreeWatcher,
            prepare: (Long) -> Boolean,
            action: (Long) -> Unit,
        ) {
            synchronized(coordinatorLock) {
                if (desiredOwner !== owner) return
                val ticket = coordinatorEpoch + 1
                if (!prepare(ticket)) return
                coordinatorEpoch = ticket
                coordinatorExec.execute { action(ticket) }
            }
        }

        private fun enqueueStop(
            owner: TreeWatcher,
            prepare: (Long) -> Boolean,
            action: (Long, Boolean) -> Unit,
        ) {
            synchronized(coordinatorLock) {
                val transition = planGlobalWatcherStop(
                    GlobalWatcherCoordinatorState(desiredOwner, coordinatorEpoch, helperMayExist),
                    owner,
                )
                if (!prepare(transition.ticket)) return
                coordinatorEpoch = transition.state.epoch
                if (transition.ownsGlobalStop) desiredOwner = null
                coordinatorExec.execute {
                    action(transition.ticket, transition.ownsGlobalStop)
                }
            }
        }

        private fun enqueueBackground(action: () -> Unit) {
            synchronized(coordinatorLock) { coordinatorExec.execute(action) }
        }

        private fun isCurrentOwner(owner: TreeWatcher, ticket: Long): Boolean =
            synchronized(coordinatorLock) {
                desiredOwner === owner && coordinatorEpoch == ticket
            }

        private fun markHelperLaunched(
            useShizuku: Boolean,
            identityPattern: String,
        ) {
            synchronized(coordinatorLock) {
                helperMayExist = true
                helperBackend = if (useShizuku) WatcherHelperBackend.SHIZUKU
                else WatcherHelperBackend.SU
                helperIdentityPattern = identityPattern
            }
        }

        private fun claimGlobalCleanup(
            owner: TreeWatcher,
            ticket: Long,
            stopRequest: Boolean,
        ): WatcherCleanupTarget? = synchronized(coordinatorLock) {
            val allowed = mayUseGlobalWatcherPkill(
                GlobalWatcherCoordinatorState(desiredOwner, coordinatorEpoch, helperMayExist),
                owner,
                ticket,
                stopRequest,
            )
            if (!allowed) null else {
                val backend = helperBackend ?: WatcherHelperBackend.UNKNOWN
                val identity = helperIdentityPattern ?: return@synchronized null
                helperMayExist = false
                helperBackend = null
                helperIdentityPattern = null
                WatcherCleanupTarget(backend, identity)
            }
        }

        private fun restoreCleanupNeeded(target: WatcherCleanupTarget) {
            synchronized(coordinatorLock) {
                helperMayExist = true
                helperBackend = target.backend
                helperIdentityPattern = target.identityPattern
            }
        }

        private fun hasKnownHelper(): Boolean =
            synchronized(coordinatorLock) { helperMayExist }

        private fun needsOrphanPreflight(identityPattern: String): Boolean =
            synchronized(coordinatorLock) {
                needsWatcherOrphanPreflight(orphanPreflightState, identityPattern)
            }

        private fun markOrphanPreflightDone(identityPattern: String) {
            synchronized(coordinatorLock) {
                orphanPreflightState =
                    completeWatcherOrphanPreflight(orphanPreflightState, identityPattern)
            }
        }
    }

    fun start(useRoot: Boolean, useShizuku: Boolean) {
        enqueueStart(this, prepare = { ticket ->
            synchronized(lifecycleLock) {
                if (running) false else {
                    running = true
                    rootMode = useRoot || useShizuku
                    usingShizuku = useShizuku && !useRoot
                    generation = ticket
                    true
                }
            }
        }) { ticket ->
            if (useRoot || useShizuku) runRootTransition(ticket, useShizuku && !useRoot)
            else runMediaTransition(ticket)
        }
    }

    @Volatile private var usingShizuku = false
    /** 本次实例监视的目录数（0 = 空库期误启，需要被替换） */
    @Volatile var watchedDirCount = 0
        private set

    fun isRunning() = running

    /** root 辅助进程监听；全局 watch 上限只读检查，全程在 lifecycle executor。 */
    private fun runRootTransition(requestGeneration: Long, useShizuku: Boolean) {
        // generation 更新与 execute() 投递可能来自不同线程；旧任务必须在清理前就拒绝。
        if (!isDesired(requestGeneration, requireRoot = true)) return
        val bin = Engine.nativeHelperPath()
        val identityPattern = bin?.let(::nativeHelperIdentityPattern)
        if (bin == null || identityPattern == null) {
            Log.w(TAG, "missing or unsafe ViewFile helper identity; fallback to media observer")
            installMediaObserverIfCurrent(requestGeneration)
            return
        }
        val backend = if (useShizuku) WatcherHelperBackend.SHIZUKU
        else WatcherHelperBackend.SU
        if (!hasKnownHelper()) {
            val preflight = cleanupCrossProcessOrphanIfNeeded(backend)
            if (postCleanupMode(preflight) == WatcherPostCleanupMode.MEDIA_FALLBACK) {
                Log.e(TAG, "native orphan preflight failed via $backend; " +
                        "root watcher launch blocked and falling back to media observer")
                installMediaObserverIfCurrent(requestGeneration)
                return
            }
        }
        val cleanup = cleanupPublishedResources(
            requestGeneration,
            stopRequest = false,
            cleanupBackendOverride = backend,
        )
        if (postCleanupMode(cleanup) == WatcherPostCleanupMode.MEDIA_FALLBACK) {
            Log.e(TAG, "native helper cleanup uncertain; root watcher launch blocked " +
                    "and falling back to media observer")
            installMediaObserverIfCurrent(requestGeneration)
            return
        }
        if (!isDesired(requestGeneration, requireRoot = true)) return
        // 目录清单取自内存 dirIds（v3 库内无路径；载入后必然可用）
        // stdout 只回传序号；必须在启动时固定快照，不能在事件时重读可变索引。
        val dirs = ArrayList<String>(1024)
        for (path in index.directoryPaths()) dirs.add(path)
        if (dirs.size > WatcherProtocol.MAX_WATCH) {
            Log.w(TAG, "watch request exceeds native cap: requested=${dirs.size} " +
                    "cap=${WatcherProtocol.MAX_WATCH}; fallback to media observer")
            installMediaObserverIfCurrent(requestGeneration)
            return
        }
        if (!hasWatchCapacity(dirs.size, useShizuku)) {
            installMediaObserverIfCurrent(requestGeneration)
            return
        }
        if (!isDesired(requestGeneration, requireRoot = true)) return
        var startupDecision: CountDownLatch? = null
        var startupProcess: Process? = null
        try {
            if (!persistHelperPending(backend, bin)) {
                Log.e(TAG, "cannot persist native helper ownership; launch blocked")
                installMediaObserverIfCurrent(requestGeneration)
                return
            }
            val p = if (useShizuku) {
                ShizukuShell.newProcess(arrayOf(bin))
            } else {
                // nsenter 进 PID1 命名空间：同 SuShell，避免 app 视图过滤
                ProcessBuilder("su", "-c", "nsenter -t 1 -m " + shq(bin)).start()
            }
            startupProcess = p
            markHelperLaunched(useShizuku, identityPattern)
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
                    for (d in dirs) w.write(RootScanner.toRaw(d) + "\n")
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
                            val ordinal = WatcherProtocol.parseDirtyOrdinal(event, dirs.size)
                            if (ordinal == null) {
                                enqueueProtocolFailure(requestGeneration, p,
                                    "invalid event: ${event.take(80)}")
                                return@use
                            }
                            val dirtyDirectory = dirs[ordinal]
                            if (WatcherEventFilter.shouldTriggerSync(dirtyDirectory)) markDirty()
                        }
                    }
                } catch (_: Throwable) {
                    readyLatch.countDown()
                }
                if (accepted.get()) {
                    Log.w(TAG, "vfwatch exited${if (stderr.isNotBlank()) ": ${stderr.take(200)}" else ""}")
                    enqueueProtocolFailure(requestGeneration, p, "native watcher exited")
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
                cleanupProcess(p, requestGeneration,
                    allowGlobalPkill = isCurrentOwner(this, requestGeneration))
                installMediaObserverIfCurrent(requestGeneration)
                return
            }
            val committed = synchronized(lifecycleLock) {
                if (isDesiredLocked(requestGeneration, requireRoot = true) && rootProc == null) {
                    rootProc = p
                    rootProcGeneration = requestGeneration
                    watchedDirCount = handshake.installed
                    accepted.set(true)
                    true
                } else false
            }
            decisionLatch.countDown()
            if (!committed) {
                // lifecycle executor 串行：继任者尚未启动，可安全清理本次 helper。
                cleanupProcess(p, requestGeneration,
                    allowGlobalPkill = isCurrentOwner(this, requestGeneration))
                return
            }
            startupProcess = null // 所有权已转交给 rootProc
            Log.i(TAG, "root watcher ready via ${if (useShizuku) "shizuku" else "su"} " +
                    "($bin, requested=${handshake.requested}, installed=${handshake.installed})")
        } catch (t: Throwable) {
            Log.w(TAG, "start root watcher failed: ${t.message}, fallback")
            startupDecision?.countDown()
            startupProcess?.let {
                cleanupProcess(it, requestGeneration,
                    allowGlobalPkill = isCurrentOwner(this, requestGeneration))
            }
            installMediaObserverIfCurrent(requestGeneration)
        }
    }

    /** reader 只投递失败；shell 清理和 observer 注册不占用主线程。 */
    private fun enqueueProtocolFailure(
        failedGeneration: Long,
        process: Process,
        reason: String,
    ) {
        enqueueBackground {
            val current = synchronized(lifecycleLock) {
                shouldHandleWatcherFailure(running, rootProc, process) &&
                        rootProcGeneration == failedGeneration && generation == failedGeneration
            } && isCurrentOwner(this, failedGeneration)
            if (!current) {
                cleanupProcess(process, requestGeneration = failedGeneration,
                    allowGlobalPkill = false)
                return@enqueueBackground
            }
            Log.w(TAG, "$reason; stopping native watcher and falling back")
            cleanupPublishedResources(failedGeneration, stopRequest = false)
            installMediaObserverIfCurrent(failedGeneration)
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

    private fun runMediaTransition(requestGeneration: Long) {
        if (!isDesired(requestGeneration, requireRoot = false)) return
        cleanupPublishedResources(requestGeneration, stopRequest = false)
        installMediaObserverIfCurrent(requestGeneration)
    }

    private fun installMediaObserverIfCurrent(requestGeneration: Long) {
        if (!isDesired(requestGeneration, requireRoot = false)) return
        val obs = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                markDirty()
            }
        }
        context.contentResolver.registerContentObserver(
            MediaStore.Files.getContentUri("external"), true, obs)
        val committed = synchronized(lifecycleLock) {
            if (isDesiredLocked(requestGeneration, requireRoot = false) && mediaObserver == null) {
                mediaObserver = obs
                watchedDirCount = Int.MAX_VALUE
                true
            } else false
        }
        if (!committed) {
            runCatching { context.contentResolver.unregisterContentObserver(obs) }
            return
        }
        // MediaStore observer 不依赖索引中的目录清单，不需要在索引载入后替换。
        Log.i(TAG, "media store observer started")
    }

    /** 同步完成后调用：特权模式重启辅助进程以覆盖新增目录 */
    fun refreshRootProcess() {
        enqueueRefresh(this, prepare = { ticket ->
            synchronized(lifecycleLock) {
                if (!running || !rootMode) false else {
                    generation = ticket
                    true
                }
            }
        }) { ticket -> runRootTransition(ticket, usingShizuku) }
    }

    /** 短锁只摘除已发布资源；所有可阻塞清理均在 lifecycle executor 锁外。 */
    private fun cleanupPublishedResources(
        requestGeneration: Long,
        stopRequest: Boolean,
        cleanupBackendOverride: WatcherHelperBackend? = null,
    ): WatcherCleanupResult {
        val detached = synchronized(lifecycleLock) {
            val p = rootProc
            val obs = mediaObserver
            rootProc = null
            rootProcGeneration = 0L
            mediaObserver = null
            watchedDirCount = 0
            p to obs
        }
        detached.second?.let {
            runCatching { context.contentResolver.unregisterContentObserver(it) }
        }
        detached.first?.let { runCatching { it.destroy() } }
        // 新 owner 在启动前也执行一次，收敛旧 stop 只 destroy(su) 留下的孤儿 helper。
        val target = claimGlobalCleanup(this, requestGeneration, stopRequest)
            ?: return WatcherCleanupResult(required = false, succeeded = true)
        val effectiveTarget = target.copy(backend = effectiveWatcherCleanupBackend(
            target.backend,
            cleanupBackendOverride,
        ))
        val succeeded = killNativeHelpers(effectiveTarget)
        if (shouldKeepCleanupPending(
                WatcherCleanupResult(required = true, succeeded = succeeded)
            )
        ) {
            restoreCleanupNeeded(target)
            Log.e(TAG, "native helper cleanup failed via ${effectiveTarget.backend}; " +
                    "cleanup remains pending")
        } else {
            clearPersistedHelperIfMatches(target.identityPattern)
        }
        return WatcherCleanupResult(required = true, succeeded = succeeded)
    }

    private fun cleanupProcess(
        process: Process,
        requestGeneration: Long,
        allowGlobalPkill: Boolean,
        stopRequest: Boolean = false,
    ) {
        runCatching { process.destroy() }
        if (allowGlobalPkill) {
            val target = claimGlobalCleanup(this, requestGeneration, stopRequest)
            if (target != null && !killNativeHelpers(target)) {
                restoreCleanupNeeded(target)
                Log.e(TAG, "native helper cleanup failed via ${target.backend}; " +
                        "cleanup remains pending")
            } else if (target != null) {
                clearPersistedHelperIfMatches(target.identityPattern)
            }
        }
    }

    private fun killNativeHelpers(target: WatcherCleanupTarget): Boolean {
        // executor 串行保证 pkill 时继任者还未启动。
        val command = nativeHelperPkillCommand(target.identityPattern)
        val codes = requiredCleanupBackends(target.backend).map { route ->
            when (route) {
                WatcherHelperBackend.SU ->
                    runCatching { SuShell.run(command, 5000).code }
                        .getOrDefault(-1)
                WatcherHelperBackend.SHIZUKU ->
                    runCatching { ShizukuShell.run(command, 5000).code }
                        .getOrDefault(-1)
                WatcherHelperBackend.UNKNOWN -> -1 // requiredCleanupBackends never emits UNKNOWN
            }
        }
        val safe = isNativeHelperCleanupSafe(codes)
        if (!safe) Log.e(TAG, "pkill cleanup uncertain via ${target.backend}: rc=$codes")
        return safe
    }

    /** App 进程被杀后从包私有持久记录恢复 helper 身份；失败不完成 preflight。 */
    private fun cleanupCrossProcessOrphanIfNeeded(
        backend: WatcherHelperBackend,
    ): WatcherCleanupResult {
        val hasPersistedState = hasPersistedHelperState()
        val persisted = readPersistedHelper()
        if (hasPersistedState && persisted == null) {
            Log.e(TAG, "persisted native helper identity is incomplete/unsafe")
            return WatcherCleanupResult(required = true, succeeded = false)
        }
        val preflightIdentity = persisted?.identityPattern
            ?: nativeHelperPackageWideIdentityPattern()
        if (persisted == null && !needsOrphanPreflight(preflightIdentity)) {
            return WatcherCleanupResult(required = false, succeeded = true)
        }
        val target = WatcherCleanupTarget(
            backend = backend,
            identityPattern = preflightIdentity,
        )
        val succeeded = when (watcherPreflightMethod(persisted?.backend, backend)) {
            WatcherPreflightMethod.DIRECT_PKILL -> killNativeHelpers(target)
            WatcherPreflightMethod.SHIZUKU_VERIFY_THEN_PKILL -> {
                val visibility = verifyAndCleanupViaShizuku(target.identityPattern)
                Log.i(TAG, "Shizuku native orphan verification: $visibility")
                watcherCleanupFromVisibility(visibility).succeeded
            }
            WatcherPreflightMethod.FAIL_CLOSED -> false
        }
        if (succeeded) {
            persisted?.let { clearPersistedHelperIfMatches(it.identityPattern) }
            markOrphanPreflightDone(preflightIdentity)
            markOrphanPreflightDone(nativeHelperPackageWideIdentityPattern())
            Log.i(TAG, "native orphan preflight complete via $backend" +
                    (persisted?.let { " (recorded=${it.backend})" } ?: ""))
        } else {
            Log.e(TAG, "native orphan preflight remains pending via $backend" +
                    (persisted?.let { " (recorded=${it.backend})" } ?: ""))
        }
        return WatcherCleanupResult(required = true, succeeded = succeeded)
    }

    private fun verifyAndCleanupViaShizuku(
        identityPattern: String,
    ): WatcherVisibilityCleanupResult {
        fun visible(): Boolean? {
            val result = runCatching {
                ShizukuShell.run("ps -A -ww -o ARGS", 5000)
            }.getOrNull() ?: return null
            if (!result.ok) return null
            return result.out.lineSequence().any {
                nativeHelperIdentityMatches(identityPattern, it)
            }
        }
        val before = visible() ?: return WatcherVisibilityCleanupResult.UNVERIFIABLE
        if (!before) return WatcherVisibilityCleanupResult.ABSENT
        val killed = killNativeHelpers(
            WatcherCleanupTarget(WatcherHelperBackend.SHIZUKU, identityPattern))
        if (!killed) return WatcherVisibilityCleanupResult.UNVERIFIABLE
        // rc=0 alone is insufficient across uid boundaries: absence must be observable afterwards.
        return when (visible()) {
            false -> WatcherVisibilityCleanupResult.CLEARED
            else -> WatcherVisibilityCleanupResult.UNVERIFIABLE
        }
    }

    private fun helperPrefs() = context.getSharedPreferences(
        HELPER_STATE_PREFS,
        Context.MODE_PRIVATE,
    )

    private fun persistHelperPending(
        backend: WatcherHelperBackend,
        helperPath: String,
    ): Boolean = helperPrefs().edit()
        .putString(PREF_BACKEND, backend.name)
        .putString(PREF_HELPER_PATH, helperPath)
        .commit()

    private fun readPersistedHelper(): WatcherCleanupTarget? {
        val prefs = helperPrefs()
        val backend = prefs.getString(PREF_BACKEND, null)?.let {
            runCatching { WatcherHelperBackend.valueOf(it) }.getOrNull()
        } ?: return null
        val helperPath = prefs.getString(PREF_HELPER_PATH, null) ?: return null
        val identity = nativeHelperIdentityPattern(helperPath) ?: return null
        return WatcherCleanupTarget(backend, identity)
    }

    private fun hasPersistedHelperState(): Boolean {
        val prefs = helperPrefs()
        return prefs.contains(PREF_BACKEND) || prefs.contains(PREF_HELPER_PATH)
    }

    private fun clearPersistedHelperIfMatches(identityPattern: String) {
        val recorded = readPersistedHelper() ?: return
        if (recorded.identityPattern != identityPattern) return
        if (!helperPrefs().edit().clear().commit()) {
            // A stale record only causes a safe redundant preflight after restart.
            Log.w(TAG, "native helper cleanup succeeded but persisted record clear failed")
        }
    }

    private fun isDesired(requestGeneration: Long, requireRoot: Boolean): Boolean =
        isCurrentOwner(this, requestGeneration) &&
                synchronized(lifecycleLock) { isDesiredLocked(requestGeneration, requireRoot) }

    private fun isDesiredLocked(requestGeneration: Long, requireRoot: Boolean): Boolean =
        isWatcherRequestCurrent(
            WatcherDesiredState(running, generation, rootMode),
            requestGeneration,
            requireRoot,
        )

    private fun runStop(requestGeneration: Long, ownsGlobalStop: Boolean) {
        val currentStop = synchronized(lifecycleLock) {
            !running && generation == requestGeneration
        }
        if (!currentStop) return
        cleanupPublishedResources(requestGeneration, stopRequest = ownsGlobalStop)
        Log.i(TAG, "watcher stopped (generation=$requestGeneration)")
    }

    fun stop() {
        enqueueStop(this, prepare = { ticket ->
            synchronized(lifecycleLock) {
                if (!running) false else {
                    running = false
                    generation = ticket
                    dirtyRunnable?.let { handler.removeCallbacks(it) }
                    dirtyRunnable = null
                    true
                }
            }
        }) { ticket, ownsGlobalStop -> runStop(ticket, ownsGlobalStop) }
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
