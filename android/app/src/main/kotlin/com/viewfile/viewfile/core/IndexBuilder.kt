package com.viewfile.viewfile.core

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

/**
 * 全量重建器：写入独立的 index-new.db（journal=OFF、synchronous=OFF、
 * 单一事务、全程无二级索引），完成后建 UNIQUE 索引并原子 rename 顶替主库。
 *
 * id 规则：目录先于其子项插入（find 与并行扫描均保证），因此 parent_id < id
 * 恒成立——内存层据此一遍即可按 parent 链重建完整路径。
 * 根链（/、/storage、/data…）按需补建，mtime 记 0。
 */
class IndexBuilder(private val context: Context) : IndexSink {
    private lateinit var db: SQLiteDatabase
    private val insert = lazy {
        db.compileStatement("INSERT OR IGNORE INTO entry(parent_id,name,type,size,mtime) VALUES(?,?,?,?,?)")
    }
    private val dirIds = HashMap<String, Long>(1 shl 16)
    var files = 0
        private set
    var dirs = 0
        private set

    fun begin() {
        context.getDatabasePath(Db.BUILD).let { f -> if (f.exists()) f.delete() }
        db = context.openOrCreateDatabase(Db.BUILD, Context.MODE_PRIVATE, null)
        // journal_mode 返回结果行，必须走 rawQuery（A16 起 execSQL 拒绝带返回行的语句）
        db.rawQuery("PRAGMA journal_mode=OFF", null).use { it.moveToFirst() }
        db.execSQL("PRAGMA synchronous=OFF")
        db.execSQL("PRAGMA temp_store=MEMORY")
        db.execSQL(
            "CREATE TABLE entry(" +
                    "id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL, name TEXT NOT NULL," +
                    "type INTEGER NOT NULL, size INTEGER NOT NULL DEFAULT 0," +
                    "mtime INTEGER NOT NULL DEFAULT 0)"
        )
        // meta 必须就位：否则顶替后主库迁移逻辑会把新库误判为旧结构而清空
        db.execSQL("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        db.execSQL("INSERT OR REPLACE INTO meta(k,v) VALUES('schema','v3-parentid')")
        db.beginTransaction()
    }

    override fun add(path: String, parent: String, name: String, isDir: Boolean, size: Long, mtime: Long) {
        if (isDir && dirIds.containsKey(path)) return  // 双扫描器重叠区去重
        val pid = dirIds[parent] ?: ensureDirChain(parent)
        val st = insert.value
        st.bindLong(1, pid)
        st.bindString(2, name)
        st.bindLong(3, if (isDir) 1 else 0)
        st.bindLong(4, size)
        st.bindLong(5, mtime)
        val id = st.executeInsert()
        if (isDir) {
            dirIds[path] = id
            dirs++
        } else {
            files++
        }
    }

    /** 路径链上缺失的祖先目录逐级补建（如首次遇到 /data/data 时补 / 与 /data） */
    private fun ensureDirChain(path: String): Long {
        if (path == "" || path == ".") return 0L
        // 自根向下补建
        val segs = ArrayList<String>()
        var p = path
        while (p != "/" && p.isNotEmpty()) {
            segs.add(0, p.substringAfterLast('/'))
            p = p.substringBeforeLast('/')
            if (p.isEmpty()) p = "/"
        }
        var pid = 0L
        var cur = ""
        for (seg in segs) {
            cur = if (cur == "/" || cur.isEmpty()) "/$seg" else "$cur/$seg"
            val known = dirIds[cur]
            if (known != null) {
                pid = known
                continue
            }
            val st = insert.value
            st.bindLong(1, pid)
            st.bindString(2, seg)
            st.bindLong(3, 1)
            st.bindLong(4, 0L)
            st.bindLong(5, 0L)
            val id = st.executeInsert()
            dirIds[cur] = id
            dirs++
            pid = id
        }
        return pid
    }

    class Stats(val files: Int, val dirs: Int, val commitMs: Long, val indexMs: Long, val swapMs: Long)

    /** 扫描失败时丢弃构建库 */
    fun abandon() {
        try { db.close() } catch (_: Throwable) {}
        context.getDatabasePath(Db.BUILD).let { if (it.exists()) it.delete() }
    }

    /** 提交事务→建索引→原子替换主库。onSwapped(null) 时 Engine 应关闭旧连接。 */
    fun finishAndSwap(onSwapped: (SQLiteDatabase?) -> Unit): Stats {
        val t1 = System.currentTimeMillis()
        db.setTransactionSuccessful()
        db.endTransaction()
        val commitMs = System.currentTimeMillis() - t1

        val t2 = System.currentTimeMillis()
        db.execSQL("CREATE UNIQUE INDEX idx_entry_parent_name ON entry(parent_id, name)")
        db.close()
        val indexMs = System.currentTimeMillis() - t2

        val t3 = System.currentTimeMillis()
        val main = context.getDatabasePath(Db.MAIN)
        val build = context.getDatabasePath(Db.BUILD)
        // 清掉主库及 WAL/SHM 残留后原子改名顶替
        onSwapped(null)  // 先让 Engine 关闭旧连接（旧 inode 由系统回收）
        for (suffix in listOf("", "-wal", "-shm", "-journal")) {
            val f = File(main.path + suffix)
            if (f.exists()) f.delete()
        }
        if (!build.renameTo(main)) {
            throw IllegalStateException("index swap failed")
        }
        val fresh = Db.openDb(context)
        onSwapped(fresh)
        val swapMs = System.currentTimeMillis() - t3
        Log.i("ViewFile/Build",
            "build: $files files + $dirs dirs, commit ${commitMs}ms, index ${indexMs}ms, swap ${swapMs}ms")
        return Stats(files, dirs, commitMs, indexMs, swapMs)
    }
}
