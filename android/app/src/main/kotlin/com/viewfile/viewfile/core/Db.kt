package com.viewfile.viewfile.core

import android.content.Context
import android.database.sqlite.SQLiteDatabase

/**
 * 索引库。files 表是唯一事实来源；重建索引用 staging 表整体换入，
 * 任意时刻崩溃都不会留下半新半旧的索引。
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
        return db
    }

    private fun pragma(db: SQLiteDatabase, sql: String) {
        db.rawQuery(sql, null).use { it.moveToFirst() }
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
