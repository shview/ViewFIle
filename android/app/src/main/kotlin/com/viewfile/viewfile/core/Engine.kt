package com.viewfile.viewfile.core

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.Environment
import java.util.concurrent.Executors

/**
 * 引擎单例：管理数据库连接、内存索引与后台线程。
 * scanExec 串行执行扫描/载入，searchExec 独立执行搜索，互不阻塞。
 */
object Engine {
    enum class State { IDLE, SCANNING, READY }

    @Volatile var state = State.IDLE
        private set
    @Volatile var lastScan: Scanner.Result? = null
        private set
    @Volatile var lastScanAt = 0L
        private set
    @Volatile var loadMs = 0L
        private set

    val index = SearchIndex()

    private lateinit var appContext: Context
    private val scanExec = Executors.newSingleThreadExecutor { r -> Thread(r, "vf-scan") }
    private val searchExec = Executors.newSingleThreadExecutor { r -> Thread(r, "vf-search") }

    val db: SQLiteDatabase by lazy { Db.open(appContext) }

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
    }

    fun externalStoragePath(): String? =
        Environment.getExternalStorageDirectory()?.takeIf { it.canRead() }?.absolutePath

    fun stats(): Map<String, Any?> = mapOf(
        "state" to state.name,
        "entries" to index.size(),
        "lastScanEntries" to lastScan?.let { it.files + it.dirs },
        "lastScanMs" to lastScan?.elapsedMs,
        "lastScanAt" to lastScanAt,
        "loadMs" to loadMs,
    )

    /** 已有索引则载入内存；返回条目数，并顺带把状态置为 READY */
    fun loadIndexAsync(cb: (Int) -> Unit) {
        scanExec.execute {
            try {
                val t0 = System.currentTimeMillis()
                val n = index.load(db)
                loadMs = System.currentTimeMillis() - t0
                if (n > 0 && state == State.IDLE) state = State.READY
                cb(n)
            } catch (t: Throwable) {
                android.util.Log.e("ViewFile/Scan", "loadIndex failed", t)
                cb(0)
            }
        }
    }

    fun scanAsync(onProgress: (Scanner.Progress) -> Unit, onDone: (Scanner.Result?, String?) -> Unit) {
        val root = externalStoragePath()
        if (root == null) {
            onDone(null, "无法读取外部存储（缺少“所有文件访问”权限）")
            return
        }
        if (state == State.SCANNING) {
            onDone(null, "扫描已在进行中")
            return
        }
        state = State.SCANNING
        scanExec.execute {
            try {
                val r = Scanner(db).scan(root, onProgress)
                val t0 = System.currentTimeMillis()
                val n = index.load(db)
                loadMs = System.currentTimeMillis() - t0
                lastScan = r
                lastScanAt = System.currentTimeMillis()
                state = State.READY
                android.util.Log.i("ViewFile/Scan", "index loaded: $n entries in ${loadMs}ms")
                onDone(r, null)
            } catch (t: Throwable) {
                state = State.IDLE
                onDone(null, t.message ?: t.toString())
            }
        }
    }

    fun searchAsync(query: String, limit: Int, cb: (List<SearchIndex.Entry>) -> Unit) {
        searchExec.execute {
            val t0 = System.nanoTime()
            val res = index.query(query, limit)
            val ms = (System.nanoTime() - t0) / 1_000_000.0
            android.util.Log.d("ViewFile/Search", "'$query' -> ${res.size} hits in ${"%.2f".format(ms)}ms")
            cb(res)
        }
    }
}
