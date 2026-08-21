package com.viewfile.viewfile.core

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * 引擎单例：数据库连接、内存索引、两类后台线程。
 * scanExec 串行承载扫描/载入/同步/换库/文件写，searchExec 只读已发布快照。
 */
object Engine {
    enum class State { IDLE, SCANNING, SYNCING, READY }

    @Volatile var state = State.IDLE
        private set
    @Volatile var lastScan: Result? = null
        private set
    @Volatile var lastScanAt = 0L
        private set
    @Volatile var loadMs = 0L
        private set
    @Volatile var rootGranted = false
        private set

    class Result(val files: Int, val dirs: Int, val elapsedMs: Long, val withRoot: Boolean)

    val index = SearchIndex()

    private lateinit var appContext: Context
    private val scanExec = Executors.newSingleThreadExecutor { r -> Thread(r, "vf-scan") }
    private val searchExec = Executors.newSingleThreadExecutor { r -> Thread(r, "vf-search") }

    // 主库连接：全量重建原子替换后重开；全部 DB mutation 仅在 scanExec 执行。
    @Volatile
    var db: SQLiteDatabase = SQLiteDatabase.create(null) // 占位，init 时替换
        private set

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        db = Db.openDb(appContext)
    }

    /** APK 中以 lib*.so 名称打包、实际作为可执行 helper 使用的原生程序。 */
    fun nativeHelperPath(): String? = appContext.applicationInfo.nativeLibraryDir
        ?.let { dir -> File(dir, "libvfwatch.so") }
        ?.takeIf { it.exists() }?.absolutePath

    fun refreshRoot(): Boolean {
        rootGranted = SuShell.getAvailable(refresh = true)
        return rootGranted
    }

    /** root 探测可能耗时（授权框/超时），异步执行避免主线程 ANR */
    fun refreshRootAsync(cb: (Boolean) -> Unit) {
        Thread({ cb(refreshRoot()) }, "vf-root-check").start()
    }

    fun stats(): Map<String, Any?> = mapOf(
        "state" to state.name,
        "entries" to index.size(),
        "lastScanEntries" to lastScan?.let { it.files + it.dirs },
        "lastScanMs" to lastScan?.elapsedMs,
        "lastScanAt" to lastScanAt,
        "loadMs" to loadMs,
        "root" to rootGranted,
        "shizuku" to ShizukuShell.getAvailable(),
        "tier" to PrivShell.tier().name,
    )

    /** 配置指纹是否与上次扫描一致（root 开关变化时提示重扫）；排队后台执行避免与载入争抢连接 */
    fun needsRescanAsync(rootIndex: Boolean, systemIndex: Boolean, deepData: Boolean, cb: (Boolean) -> Unit) {
        scanExec.execute { cb(needsRescan(rootIndex, systemIndex, deepData)) }
    }

    fun needsRescan(rootIndex: Boolean, systemIndex: Boolean, deepData: Boolean): Boolean {
        val cur = Db.getMeta(db, "scan_cfg") ?: return true
        return cur != scanFingerprint(rootIndex, systemIndex, deepData)
    }

    /** FUSE 走查需跳过的子树（由 root 管道提供完整视图） */
    private fun fuseSkip(rootIndex: Boolean, areas: List<Area>): Set<String> =
        if (rootIndex && areas.any { it.display == "/storage/emulated/0/Android" })
            setOf("/storage/emulated/0/Android") else emptySet()

    private fun scanFingerprint(rootIndex: Boolean, systemIndex: Boolean, deepData: Boolean) =
        "root=$rootIndex,sys=$systemIndex,deep=$deepData,tier=${PrivShell.tier()}"

    /**
     * 已有索引则载入内存；返回条目数，-1 = 库超内存预算已自愈重置（调用方
     * 应以精简模式重建）。每条目堆占用约 400B，按 largeMemoryClass 估算预算。
     */
    fun loadIndexAsync(cb: (Int) -> Unit) {
        scanExec.execute {
            try {
                val count = db.rawQuery("SELECT COUNT(*) FROM entry", null).use { c ->
                    if (c.moveToFirst()) c.getInt(0) else 0
                }
                val am = appContext
                    .getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                // SoA 实测 ~133B/条（含映射与开销）：512MB 堆可容 ~310 万条；
                // 更大规模需目录映射树解析化（backlog）或更大堆设备
                val budget = am.largeMemoryClass * 6200
                if (count > budget) {
                    Log.w("ViewFile/Scan",
                        "index $count over budget $budget (heap ${am.largeMemoryClass}MB), auto reset")
                    Db.resetForRebuild(db)
                    cb(-1)
                    return@execute
                }
                val t0 = System.currentTimeMillis()
                val n = index.load(db)
                loadMs = System.currentTimeMillis() - t0
                if (n > 0 && state == State.IDLE) state = State.READY
                Log.i("ViewFile/Scan", "index loaded: $n entries in ${loadMs}ms")
                cb(n)
            } catch (t: Throwable) {
                Log.e("ViewFile/Scan", "loadIndex failed (${t.javaClass.simpleName}), auto reset", t)
                Db.resetForRebuild(db)
                cb(-1)
            }
        }
    }

    /**
     * 全量重建（v3）：并行 FUSE 扫描 + root 管道 → IndexBuilder 写独立
     * index-new.db（journal=OFF 单事务）→ 建索引 → 原子 rename 顶替主库。
     */
    fun scanAsync(
        rootIndex: Boolean,
        systemIndex: Boolean,
        deepData: Boolean,
        onProgress: (files: Int, dirs: Int, current: String) -> Unit,
        onDone: (Result?, String?) -> Unit
    ) {
        // 前置检查（含 su 探测，最长数秒）全部后台执行，避免阻塞主线程触发 ANR。
        // scanRequested 让排队中的同步立即让位（单线程队列里同步可能占住几十秒）
        pendingScanRequests.incrementAndGet()
        scanExec.execute {
            if (!File("/storage/emulated/0").canRead()) {
                pendingScanRequests.decrementAndGet()
                onDone(null, "无法读取外部存储（缺少“所有文件访问”权限）")
                return@execute
            }
            if (state == State.SCANNING) {
                pendingScanRequests.decrementAndGet()
                onDone(null, "扫描已在进行中")
                return@execute
            }
            rootGranted = SuShell.getAvailable(refresh = true)
            ShizukuShell.getAvailable(refresh = true)
            state = State.SCANNING
            val builder = IndexBuilder(appContext)
            try {
                val t0 = System.currentTimeMillis()
                builder.begin()
                var files = 0
                var dirs = 0

                val fuseRoots = mutableListOf("/storage/emulated/0")
                if (systemIndex) fuseRoots += listOf("/system", "/vendor", "/product", "/odm")
                // Android 子树改由 root 管道覆盖（FUSE 视图残缺且会重复入库）
                val skip = fuseSkip(rootIndex, rootAreas(deepData))
                for (root in fuseRoots) {
                    val t1 = System.currentTimeMillis()
                    val c = Scanner().scanInto(builder, root, skip) { f, d, cur ->
                        onProgress(files + f, dirs + d, cur)
                    }
                    files += c.files
                    dirs += c.dirs
                    logScanDone(root, c.files, c.dirs, System.currentTimeMillis() - t1)
                }

                var withRoot = false
                // root 区域按特权层级决定：ROOT 全量，SHIZUKU 仅 Android 区+tmp
                val areas = rootAreas(deepData)
                if (rootIndex && areas.isNotEmpty()) {
                    withRoot = true
                    val rc = RootScanner().scanInto(builder, areas) { area, f, d ->
                        onProgress(files + f, dirs + d, area)
                    }
                    files += rc.files
                    dirs += rc.dirs
                }

                val st = builder.finishAndSwap { fresh ->
                    if (fresh != null) {
                        db = fresh
                    } else {
                        try { db.close() } catch (_: Throwable) {}
                    }
                }
                files = st.files
                dirs = st.dirs
                Db.setMeta(db, "scan_cfg", scanFingerprint(rootIndex, systemIndex, deepData))

                val t2 = System.currentTimeMillis()
                val n = index.load(db)
                loadMs = System.currentTimeMillis() - t2
                val r = Result(files, dirs, System.currentTimeMillis() - t0, withRoot)
                lastScan = r
                lastScanAt = System.currentTimeMillis()
                state = State.READY
                Log.i("ViewFile/Scan", "rebuild done: $files files, $dirs dirs, " +
                        "index $n loaded in ${loadMs}ms, root=$withRoot")
                onDone(r, null)
            } catch (t: Throwable) {
                try { builder.abandon() } catch (_: Throwable) {}
                state = State.IDLE
                Log.e("ViewFile/Scan", "scan failed", t)
                onDone(null, t.message ?: t.toString())
            } finally {
                pendingScanRequests.decrementAndGet()
            }
        }
    }

    /** 同步在各阶段检查；计数避免多个排队扫描中前一个完成后错误清掉后一个请求。 */
    private val pendingScanRequests = AtomicInteger(0)
    val scanRequested: Boolean get() = pendingScanRequests.get() > 0

    fun searchAsync(query: String, limit: Int, scopes: List<String>?, cb: (List<SearchIndex.Hit>) -> Unit) {
        searchExec.execute {
            val t0 = System.nanoTime()
            val res = index.query(query, limit, scopes)
            val ms = (System.nanoTime() - t0) / 1_000_000.0
            val scopeText = if (scopes.isNullOrEmpty()) "ALL" else scopes.joinToString(";")
            Log.d("ViewFile/Search",
                "'$query' scopes=$scopeText -> ${res.size} hits in ${"%.2f".format(ms)}ms")
            cb(res)
        }
    }

    fun listDirAsync(path: String, cb: (Map<String, Any?>) -> Unit) {
        searchExec.execute { cb(Fs.listDir(path)) }
    }

    /**
     * root 扫描区域。/data/data 默认只索引两层（应用目录+一级子目录）：
     * 深层是微信等应用的海量小文件（实测一台机 112 万条），全量索引
     * 内存 700MB/库 600MB+，得不偿失；浏览与按应用概览不受影响。
     */
    private fun rootAreas(deepData: Boolean): List<Area> = when (PrivShell.tier()) {
        PrivShell.Tier.ROOT -> listOf(
            Area("/data/media/0/Android", "/storage/emulated/0/Android"),
            Area("/data/data", "/data/data", depth = if (deepData) 0 else 2),
            Area("/data/local/tmp", "/data/local/tmp"),
        )
        // Shizuku 的 shell 身份可读 Android/data 原始路径与 tmp，不能读 /data/data
        PrivShell.Tier.SHIZUKU -> listOf(
            Area("/data/media/0/Android", "/storage/emulated/0/Android"),
            Area("/data/local/tmp", "/data/local/tmp"),
        )
        PrivShell.Tier.NONE -> emptyList()
    }

    /** 打开 app 时的增量对账：目录 mtime 比对 + root 区刷新，完成后重载内存索引 */
    fun syncAsync(rootIndex: Boolean, deepData: Boolean, cb: (Map<String, Any?>) -> Unit) {
        if (state == State.SCANNING) {
            cb(mapOf("ok" to false, "error" to "扫描进行中"))
            return
        }
        scanExec.execute {
            // 排队期间来了扫描请求：直接让位（同步随时可重跑，扫描等不起）
            if (scanRequested) {
                cb(mapOf("ok" to false, "error" to "扫描请求优先"))
                return@execute
            }
            val out = try {
                state = State.SYNCING
                val areas = if (rootIndex) rootAreas(deepData) else emptyList()
                val skip = fuseSkip(rootIndex, areas)
                val scanner = SyncScanner(db, index)
                scanner.scanRequestedBridge = { scanRequested }
                val r = scanner.sync("/storage/emulated/0", areas, skip)
                state = State.READY
                // 无变化不重载索引（大库重载是秒级开销）
                val changed = r.added + r.removed + r.updated
                if (changed > 0) {
                    val t0 = System.currentTimeMillis()
                    index.load(db)
                    loadMs = System.currentTimeMillis() - t0
                }
                mapOf(
                    "ok" to true,
                    "added" to r.added, "removed" to r.removed, "updated" to r.updated,
                    "elapsedMs" to r.elapsedMs, "entries" to index.size(),
                )
            } catch (t: Throwable) {
                state = State.IDLE
                Log.e("ViewFile/Sync", "sync failed", t)
                mapOf("ok" to false, "error" to (t.message ?: t.toString()))
            }
            cb(out)
        }
    }

    private var watcher: TreeWatcher? = null

    /** 前台实时监听：变化触发增量对账，结果通过 onSynced 回调 */
    fun startWatcher(rootIndex: Boolean, deepData: Boolean, onSynced: (Map<String, Any?>) -> Unit) {
        // 健康检查在引擎侧：已运行且目录映射非空则不重启（空库期误启的 0 目录实例会被替换）
        watcher?.let { w ->
            if (w.isRunning() && w.watchedDirCount > 0) return
        }
        stopWatcher()
        val tier = PrivShell.tier()
        val w = TreeWatcher(appContext, index, onDirty = {
            syncAsync(rootIndex, deepData) { m ->
                if (m["ok"] == true) {
                    onSynced(m)
                    // 目录集合可能变化（新建目录）：重启特权辅助进程以覆盖
                    watcher?.refreshRootProcess()
                }
            }
        })
        w.start(tier == PrivShell.Tier.ROOT && rootIndex,
                tier == PrivShell.Tier.SHIZUKU && rootIndex)
        watcher = w
    }

    fun stopWatcher() {
        watcher?.stop()
        watcher = null
    }

    fun isWatching(): Boolean = watcher?.isRunning() == true

    /**
     * 写操作（重命名/删除）：与扫描/载入/同步/换库共用 scanExec；
     * 状态在任务真正执行时检查，避免排队期间状态变化造成竞态。
     * 成功后自动重载内存索引，把数据库的最新状态带给 UI。
     */
    fun opAsync(
        cb: (Map<String, Any?>) -> Unit,
        body: () -> Map<String, Any?>
    ) {
        scanExec.execute {
            val out = when {
                // 同步可能刚为 scanAsync 让位；若本操作排在扫描请求之前，也必须
                // 继续让位，不能在换库前插入一次 DB mutation。
                scanRequested -> mapOf("ok" to false, "error" to "扫描请求优先，请稍后再试")
                state == State.SCANNING || state == State.SYNCING ->
                    mapOf("ok" to false, "error" to "索引正在扫描或同步，请稍后再试")
                else -> try {
                    body()
                } catch (t: Throwable) {
                    mapOf("ok" to false, "error" to (t.message ?: t.toString()))
                }
            }
            if (out["ok"] == true) {
                try {
                    val t0 = System.currentTimeMillis()
                    index.load(db)
                    loadMs = System.currentTimeMillis() - t0
                } catch (t: Throwable) {
                    Log.w("ViewFile/Ops", "index reload after op failed", t)
                }
            }
            cb(out)
        }
    }
}
