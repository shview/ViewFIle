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
    private var chainCalls = 0L
    var files = 0
        private set
    var dirs = 0
        private set

    fun begin() {
        context.getDatabasePath(Db.BUILD).let { f -> if (f.exists()) f.delete() }
        db = context.openOrCreateDatabase(Db.BUILD, Context.MODE_PRIVATE, null)
        // journal_mode 返回结果行，必须走 rawQuery（A16 起 execSQL 拒绝带返回行的语句）。
        // 实测 journal=OFF 在百万级构建时触发 SQLITE_CORRUPT，WAL 稳定且构建库用完即删
        db.rawQuery("PRAGMA journal_mode=WAL", null).use { it.moveToFirst() }
        db.execSQL("PRAGMA synchronous=OFF")
        // temp_store=MEMORY 在百万级 CREATE INDEX 排序时触发 SQLITE_CORRUPT（实测），用默认文件排序
        db.execSQL("PRAGMA cache_size=-65536")
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

    private var pendingInTx = 0L

    override fun add(path: String, parent: String, name: String, isDir: Boolean, size: Long, mtime: Long) {
        if (isDir && dirIds.containsKey(path)) return  // 双扫描器重叠区去重
        val pid = dirIds[parent] ?: ensureDirChain(parent)
        // 百万级单巨型事务在部分设备上触发 SQLITE_CORRUPT：每 20 万条分批提交
        if (++pendingInTx >= 200000L) {
            pendingInTx = 0
            db.setTransactionSuccessful()
            db.endTransaction()
            db.beginTransaction()
        }
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
        // 防御：无前导斜杠的路径会让 while 循环永不终止（substringBeforeLast 无斜杠时原样返回）
        if (!path.startsWith("/")) return 0L
        chainCalls++
        if (chainCalls <= 5L || chainCalls % 20000L == 1L) {
            Log.w("ViewFile/Build", "ensureDirChain x$chainCalls last=$path dirIds=${dirIds.size}")
        }
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
        db.rawQuery("PRAGMA synchronous=NORMAL", null).use { it.moveToFirst() }
        db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).use { it.moveToFirst() }
        try {
            db.execSQL("CREATE UNIQUE INDEX idx_entry_parent_name ON entry(parent_id, name)")
        } catch (t: Throwable) {
            // 诊断：找出重复 (parent_id, name) 样本
            db.rawQuery(
                "SELECT parent_id, name, COUNT(*) c FROM entry GROUP BY parent_id, name HAVING c>1 LIMIT 5", null
            ).use { c ->
                val sb = StringBuilder()
                while (c.moveToNext()) sb.append("[pid=${c.getLong(0)} name=${c.getString(1)} x${c.getInt(2)}] ")
                Log.e("ViewFile/Build", "dup samples: $sb")
            }
            throw t
        }
        db.close()
        val indexMs = System.currentTimeMillis() - t2

        val t3 = System.currentTimeMillis()
        val main = context.getDatabasePath(Db.MAIN)
        val build = context.getDatabasePath(Db.BUILD)
        for (suffix in listOf("-wal", "-shm")) {
            val f = File(build.path + suffix)
            if (f.exists()) f.delete()
        }
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
