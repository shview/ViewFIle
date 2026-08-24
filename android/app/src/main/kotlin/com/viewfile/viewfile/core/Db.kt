package com.viewfile.viewfile.core

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

/**
 * 索引库 v3：entry(id, parent_id, name, type, size, mtime)。
 * 路径不再落库（v2 重复存 path+parent 是库体积的主因，135 万条要 600MB+），
 * 显示路径由内存层按 parent 链反推。UNIQUE(parent_id,name) 天然覆盖
 * “按目录取子项”查询，不另建索引；名称搜索全在内存。
 *
 * 全量重建在独立的 index-new.db 进行（journal=OFF、无二级索引写入、
 * 完成后建索引并原子 rename 顶替 index.db），主库不再出现巨型 WAL。
 */
object Db {
    private const val TAG = "ViewFile/Db"
    const val MAIN = "index.db"
    const val BUILD = "index-new.db"
    private const val SCHEMA = "v3-parentid"

    private const val ENTRY_SQL =
        "CREATE TABLE entry(" +
                "id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL, name TEXT NOT NULL," +
                "type INTEGER NOT NULL, size INTEGER NOT NULL DEFAULT 0," +
                "mtime INTEGER NOT NULL DEFAULT 0)"

    fun openDb(context: Context, name: String = MAIN): SQLiteDatabase {
        val db = context.openOrCreateDatabase(name, Context.MODE_PRIVATE, null)
        if (name == MAIN) {
            pragma(db, "PRAGMA journal_mode=WAL")
            db.execSQL("PRAGMA synchronous=NORMAL")
            migrate(db)
        }
        return db
    }

    /** 主库文件总大小（db+wal+shm），供压缩估算 */
    fun sizeBytes(context: Context): Long {
        val main = context.getDatabasePath(MAIN)
        var total = 0L
        for (suffix in listOf("", "-wal", "-shm")) {
            val f = File(main.path + suffix)
            if (f.exists()) total += f.length()
        }
        return total
    }

    /** VACUUM 压缩；pageSize 非空时切换页大小（VACUUM 时重写全库生效） */
    fun vacuum(context: Context, pageSize: Int?): Map<String, Any?> {
        return try {
            val db = openDb(context)
            val t0 = System.currentTimeMillis()
            if (pageSize != null) db.execSQL("PRAGMA page_size=$pageSize")
            db.execSQL("VACUUM")
            db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).use { it.moveToFirst() }
            mapOf(
                "ok" to true,
                "elapsedMs" to (System.currentTimeMillis() - t0),
                "bytes" to sizeBytes(context),
            )
        } catch (t: Throwable) {
            mapOf("ok" to false, "error" to (t.message ?: t.toString()))
        }
    }

    private fun migrate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        if (getMeta(db, "schema") == SCHEMA) {
            db.execSQL("CREATE TABLE IF NOT EXISTS entry(" + entryCols() + ")")
            db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS idx_entry_parent_name ON entry(parent_id, name)")
            return
        }
        Log.i(TAG, "schema upgrade -> $SCHEMA (index will be rebuilt)")
        db.beginTransaction()
        try {
            db.execSQL("DROP TABLE IF EXISTS files")
            db.execSQL("DROP TABLE IF EXISTS files_staging")
            db.execSQL("DROP TABLE IF EXISTS entry")
            db.execSQL("DELETE FROM meta")
            db.execSQL(ENTRY_SQL)
            db.execSQL("CREATE UNIQUE INDEX idx_entry_parent_name ON entry(parent_id, name)")
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        setMeta(db, "schema", SCHEMA)
        pragma(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private fun entryCols() =
        "id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL, name TEXT NOT NULL," +
                "type INTEGER NOT NULL, size INTEGER NOT NULL DEFAULT 0," +
                "mtime INTEGER NOT NULL DEFAULT 0"

    private fun pragma(db: SQLiteDatabase, sql: String) {
        db.rawQuery(sql, null).use { it.moveToFirst() }
    }

    fun getMeta(db: SQLiteDatabase, key: String): String? =
        db.rawQuery("SELECT v FROM meta WHERE k=?", arrayOf(key)).use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    fun setMeta(db: SQLiteDatabase, key: String, value: String) {
        db.execSQL("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)", arrayOf(key, value))
    }

    /** 索引超内存预算/损坏时的自愈：废弃索引，下次自动按当前配置重建 */
    fun resetForRebuild(db: SQLiteDatabase) {
        try {
            db.execSQL("DROP TABLE IF EXISTS entry")
            db.execSQL("CREATE TABLE entry(" + entryCols() + ")")
            db.execSQL("CREATE UNIQUE INDEX idx_entry_parent_name ON entry(parent_id, name)")
            db.execSQL("DELETE FROM meta WHERE k='scan_cfg'")
            pragma(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        } catch (t: Throwable) {
            Log.w(TAG, "reset failed: ${t.message}")
        }
    }

    /** 删除某目录的整棵子树（含自身），返回删除条数 */
    fun deleteSubtree(db: SQLiteDatabase, id: Long): Int {
        val c = db.rawQuery(
            "WITH RECURSIVE del(id) AS (SELECT ? UNION ALL " +
                    "SELECT e.id FROM entry e JOIN del ON e.parent_id = del.id) " +
                    "SELECT COUNT(*) FROM entry WHERE id IN (SELECT id FROM del)",
            arrayOf(id.toString())
        )
        val n = if (c.moveToFirst()) c.getInt(0) else 0
        c.close()
        db.execSQL(
            "DELETE FROM entry WHERE id IN (WITH RECURSIVE del(id) AS (SELECT ? UNION ALL " +
                    "SELECT e.id FROM entry e JOIN del ON e.parent_id = del.id) SELECT id FROM del)",
            arrayOf(id.toString())
        )
        return n
    }
}

/** 扫描器统一输出接口：全量构建（IndexBuilder）与未来的增量写入共用 */
interface IndexSink {
    fun add(path: String, parent: String, name: String, isDir: Boolean, size: Long, mtime: Long)
}
