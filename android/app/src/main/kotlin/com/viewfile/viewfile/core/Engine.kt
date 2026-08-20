package com.viewfile.viewfile.core

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File
import java.util.concurrent.Executors

/**
 * 引擎单例：数据库连接、内存索引、三类后台线程
 * （scan=扫描/载入，search=搜索/浏览，ops=文件写操作）。
 */
object Engine {
    enum class State { IDLE, SCANNING, READY }

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
    private val opsExec = Executors.newSingleThreadExecutor { r -> Thread(r, "vf-ops") }

    val db: SQLiteDatabase by lazy { Db.open(appContext) }

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
    }

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

    private fun scanFingerprint(rootIndex: Boolean, systemIndex: Boolean, deepData: Boolean) =
        "root=$rootIndex,sys=$systemIndex,deep=$deepData,tier=${PrivShell.tier()}"

    /** 已有索引则载入内存；返回条目数，并顺带把状态置为 READY */
    fun loadIndexAsync(cb: (Int) -> Unit) {
        scanExec.execute {
            try {
                val t0 = System.currentTimeMillis()
                val n = index.load(db)
                loadMs = System.currentTimeMillis() - t0
                if (n > 0 && state == State.IDLE) state = State.READY
                Log.i("ViewFile/Scan", "index loaded: $n entries in ${loadMs}ms")
                cb(n)
            } catch (t: Throwable) {
                Log.e("ViewFile/Scan", "loadIndex failed", t)
                cb(0)
            }
        }
    }

    /**
     * 全量重建：FUSE 扫描 /storage/emulated/0（+ 可选系统分区），
     * root 开启时追加 /data/media/0/Android（Android/data+obb 解封锁）、
     * /data/data、/data/local/tmp，统一写入 staging 后换表。
     */
    fun scanAsync(
        rootIndex: Boolean,
        systemIndex: Boolean,
        deepData: Boolean,
        onProgress: (files: Int, dirs: Int, current: String) -> Unit,
        onDone: (Result?, String?) -> Unit
    ) {
        // 前置检查（含 su 探测，最长数秒）全部后台执行，避免阻塞主线程触发 ANR
        scanExec.execute {
            if (!File("/storage/emulated/0").canRead()) {
                onDone(null, "无法读取外部存储（缺少“所有文件访问”权限）")
                return@execute
            }
            if (state == State.SCANNING) {
                onDone(null, "扫描已在进行中")
                return@execute
            }
            rootGranted = SuShell.getAvailable(refresh = true)
            ShizukuShell.getAvailable(refresh = true)
            state = State.SCANNING
            var txOpen = false
            try {
                val t0 = System.currentTimeMillis()
                // 防御：上次异常可能让连接残留事务，导致 PRAGMA 报
                // “Safety level may not be changed inside a transaction”
                if (db.inTransaction()) {
                    Log.w("ViewFile/Scan", "stale transaction detected, ending")
                    db.setTransactionSuccessful()
                    db.endTransaction()
                }
                Db.beginRebuild(db)
                val writer = IndexWriter(db)
                writer.beginTx()
                txOpen = true
                var files = 0
                var dirs = 0

                val fuseRoots = mutableListOf("/storage/emulated/0")
                if (systemIndex) fuseRoots += listOf("/system", "/vendor", "/product", "/odm")
                for (root in fuseRoots) {
                    val t1 = System.currentTimeMillis()
                    val c = Scanner().scanInto(writer, root) { f, d, cur ->
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
                    val rc = RootScanner().scanInto(writer, areas) { area, f, d ->
                        onProgress(files + f, dirs + d, area)
                    }
                    files += rc.files
                    dirs += rc.dirs
                }

                writer.finishTx()
                txOpen = false
                try {
                    Db.finishRebuild(db)
                } catch (t: Throwable) {
                    // VACUUM 等收尾失败不致命：索引本体已换表完成
                    Log.w("ViewFile/Scan", "finishRebuild tail failed: ${t.message}")
                }
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
                if (txOpen) {
                    try {
                        db.setTransactionSuccessful() // 写入不完整也先结束事务，避免连接卡死
                        db.endTransaction()
                    } catch (_: Throwable) {}
                }
                state = State.IDLE
                Log.e("ViewFile/Scan", "scan failed", t)
                onDone(null, t.message ?: t.toString())
            }
        }
    }

    fun searchAsync(query: String, limit: Int, scopes: List<String>?, cb: (List<SearchIndex.Entry>) -> Unit) {
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
            val out = try {
                state = State.SCANNING
                val areas = if (rootIndex) rootAreas(deepData) else emptyList()
                val r = SyncScanner(db).sync("/storage/emulated/0", areas)
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
        stopWatcher()
        val tier = PrivShell.tier()
        val w = TreeWatcher(appContext, db, onDirty = {
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
     * 写操作（重命名/删除）：串行执行，扫描期间拒绝；
     * 成功后自动重载内存索引，把数据库的最新状态带给 UI。
     */
    fun opAsync(
        cb: (Map<String, Any?>) -> Unit,
        body: () -> Map<String, Any?>
    ) {
        opsExec.execute {
            val out = if (state == State.SCANNING) {
                mapOf("ok" to false, "error" to "索引正在扫描，请稍后再试")
            } else {
                try {
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
