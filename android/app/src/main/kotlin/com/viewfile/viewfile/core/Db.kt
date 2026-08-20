package com.viewfile.viewfile.core

import android.content.Context
import android.database.sqlite.SQLiteDatabase

/**
 * 索引库。files 表是唯一事实来源；重建索引用 staging 表整体换入，
 * 任意时刻崩溃都不会留下半新半旧的索引。meta 表存扫描配置指纹，
 * 用于判断“配置变了（如开启 root）需要自动重扫”。
 */
object Db {
    private const val COLS =
        "path TEXT PRIMARY KEY, parent TEXT NOT NULL, name TEXT NOT NULL, " +
        "is_dir INTEGER NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL"

    fun open(context: Context): SQLiteDatabase {
        val db = context.openOrCreateDatabase("index.db", Context.MODE_PRIVATE, null)
        // journal_mode / wal_checkpoint 会返回结果行，A16 起必须走 rawQuery
        pragma(db, "PRAGMA journal_mode=WAL")
        db.execSQL("PRAGMA synchronous=NORMAL")
        db.execSQL("CREATE TABLE IF NOT EXISTS files($COLS)")
        db.execSQL("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        return db
    }

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

    fun beginRebuild(db: SQLiteDatabase) {
        db.execSQL("DROP TABLE IF EXISTS files_staging")
        db.execSQL("CREATE TABLE files_staging($COLS)")
    }

    fun finishRebuild(db: SQLiteDatabase) {
        db.beginTransaction()
        try {
            db.execSQL("DROP TABLE IF EXISTS files")
            db.execSQL("ALTER TABLE files_staging RENAME TO files")
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        // 插入全部完成后再建索引，避免逐行维护 B 树
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_files_name ON files(name)")
        pragma(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    }
}

/** staging 表批量写入器：事务分批提交，供 FUSE 扫描与 root 扫描共用 */
class IndexWriter(private val db: SQLiteDatabase) {
    private val insert = db.compileStatement(
        "INSERT OR IGNORE INTO files_staging(path,parent,name,is_dir,size,mtime) VALUES(?,?,?,?,?,?)"
    )
    private var pending = 0L

    fun beginTx() {
        db.execSQL("PRAGMA synchronous=OFF")
        db.beginTransaction()
    }

    fun add(path: String, parent: String, name: String, isDir: Boolean, size: Long, mtime: Long) {
        insert.bindString(1, path)
        insert.bindString(2, parent)
        insert.bindString(3, name)
        insert.bindLong(4, if (isDir) 1 else 0)
        insert.bindLong(5, size)
        insert.bindLong(6, mtime)
        insert.executeInsert()
        if (++pending >= 20000) {
            db.setTransactionSuccessful()
            db.endTransaction()
            db.beginTransaction()
            pending = 0
        }
    }

    fun finishTx() {
        try {
            db.setTransactionSuccessful()
            db.endTransaction()
        } catch (_: IllegalStateException) {}
        db.execSQL("PRAGMA synchronous=NORMAL")
    }
}
