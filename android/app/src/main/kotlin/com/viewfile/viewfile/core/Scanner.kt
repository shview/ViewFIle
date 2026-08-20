package com.viewfile.viewfile.core

import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File
import java.util.ArrayDeque

/**
 * 全量扫描器：显式栈 DFS，批量事务写入 staging 表。
 * 只读取文件元数据（readdir + stat），不读取文件内容。
 */
class Scanner(private val db: SQLiteDatabase) {
    data class Progress(val files: Int, val dirs: Int, val current: String, val elapsedMs: Long)
    data class Result(val files: Int, val dirs: Int, val elapsedMs: Long)

    fun scan(rootPath: String, onProgress: (Progress) -> Unit): Result {
        val t0 = System.currentTimeMillis()
        var files = 0
        var dirs = 0
        var sinceTick = 0L

        Db.beginRebuild(db)
        db.execSQL("PRAGMA synchronous=OFF")
        val insert = db.compileStatement(
            "INSERT OR IGNORE INTO files_staging(path,parent,name,is_dir,size,mtime) VALUES(?,?,?,?,?,?)"
        )
        val stack = ArrayDeque<File>()
        stack.push(File(rootPath))

        db.beginTransaction()
        try {
            while (stack.size > 0) {
                val dir = stack.pop()
                val children = dir.listFiles() ?: continue  // 无权限/已删除的目录直接跳过
                for (c in children) {
                    val isDir = c.isDirectory
                    insert.bindString(1, c.absolutePath)
                    insert.bindString(2, dir.absolutePath)
                    insert.bindString(3, c.name)
                    insert.bindLong(4, if (isDir) 1 else 0)
                    insert.bindLong(5, if (isDir) 0L else c.length())
                    insert.bindLong(6, c.lastModified())
                    insert.executeInsert()
                    if (isDir) {
                        dirs++
                        stack.push(c)
                    } else {
                        files++
                    }
                    if (++sinceTick >= 20000) {
                        sinceTick = 0
                        db.setTransactionSuccessful()
                        db.endTransaction()
                        db.beginTransaction()
                        onProgress(Progress(files, dirs, dir.absolutePath, System.currentTimeMillis() - t0))
                    }
                }
            }
            db.setTransactionSuccessful()
        } finally {
            try { db.endTransaction() } catch (_: IllegalStateException) {}
            db.execSQL("PRAGMA synchronous=NORMAL")
        }

        Db.finishRebuild(db)
        val elapsed = System.currentTimeMillis() - t0
        Log.i(TAG, "scan done: $files files, $dirs dirs in ${elapsed}ms")
        return Result(files, dirs, elapsed)
    }

    companion object { const val TAG = "ViewFile/Scan" }
}
