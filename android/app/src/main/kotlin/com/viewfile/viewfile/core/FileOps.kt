package com.viewfile.viewfile.core

import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.util.ArrayDeque

/**
 * 文件操作：打开/分享（只读，走 FileProvider）；
 * 重命名/删除（写操作，调用方必须已经过 UI 二次确认）。
 * 所有 DB 同步都用 substr 前缀精确匹配（避免 LIKE 通配符歧义与误删兄弟目录）。
 */
object FileOps {
    private const val TAG = "ViewFile/Ops"

    // ---------- 只读操作 ----------

    fun open(context: Context, path: String): String? {
        val f = File(path)
        if (!f.isFile) return "无法打开（不是常规文件）"
        return try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uriFor(context, f), mimeOf(f))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "选择打开方式"))
            null
        } catch (t: Throwable) {
            "没有应用可以打开它：${t.message}"
        }
    }

    fun share(context: Context, paths: List<String>): String? {
        val files = paths.map(::File).filter { it.isFile }
        if (files.isEmpty()) return "没有可分享的文件"
        return try {
            val uris = ArrayList<Uri>(files.map { uriFor(context, it) })
            val intent = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    type = mimeOf(files[0])
                    putExtra(Intent.EXTRA_STREAM, uris[0])
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = "*/*"
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                }
            }
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            context.startActivity(Intent.createChooser(intent, "分享"))
            null
        } catch (t: Throwable) {
            "分享失败：${t.message}"
        }
    }

    // ---------- 写操作（需 UI 确认） ----------

    /** 返回 null=成功，否则为错误信息 */
    fun rename(db: SQLiteDatabase, path: String, newName: String): String? {
        val old = File(path)
        val clean = newName.trim()
        if (clean.isEmpty() || clean.contains('/')) return "文件名不合法"
        if (!old.exists()) return "文件不存在（可能已被移动）"
        if (old.name == clean) return null
        val target = File(old.parentFile, clean)
        if (target.exists()) return "已存在同名项目"
        if (!old.renameTo(target)) return "重命名失败（存储权限或跨区限制）"

        val oldPath = old.absolutePath
        val newPath = target.absolutePath
        val oldSlash = "$oldPath/"
        val len = oldSlash.length
        db.beginTransaction()
        try {
            // 后代路径
            db.execSQL(
                "UPDATE files SET path=?||substr(path,?) WHERE substr(path,1,?)=?",
                arrayOf<Any>(newPath, len, len, oldSlash)
            )
            // 后代的父目录
            db.execSQL(
                "UPDATE files SET parent=?||substr(parent,?) WHERE substr(parent,1,?)=?",
                arrayOf<Any>(newPath, len, len, oldSlash)
            )
            // 自身
            db.execSQL(
                "UPDATE files SET path=?, name=? WHERE path=?",
                arrayOf(newPath, clean, oldPath)
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        Log.i(TAG, "renamed $oldPath -> $newPath")
        return null
    }

    /** 返回 (成功数, 失败路径列表) */
    fun delete(db: SQLiteDatabase, paths: List<String>): Pair<Int, List<String>> {
        var deleted = 0
        val failed = mutableListOf<String>()
        for (p in paths) {
            val f = File(p)
            if (!f.exists()) {
                removeRows(db, p)  // 文件已不在，清掉索引即可
                continue
            }
            if (deleteRecursively(f)) {
                deleted++
                removeRows(db, p)
            } else {
                failed.add(p)
            }
        }
        Log.i(TAG, "delete: ok=$deleted failed=${failed.size}")
        return deleted to failed
    }

    private fun deleteRecursively(root: File): Boolean {
        // 先收全部后代（深前浅后），再从叶子往上删
        val stack = ArrayDeque<File>()
        val ordered = ArrayDeque<File>()
        stack.push(root)
        while (stack.isNotEmpty()) {
            val d = stack.pop()
            ordered.push(d)
            d.listFiles()?.let { stack.addAll(it) }
        }
        var ok = true
        for (f in ordered) {
            if (!f.delete() && f.exists()) ok = false
        }
        return ok
    }

    private fun removeRows(db: SQLiteDatabase, path: String) {
        val slash = "$path/"
        db.execSQL(
            "DELETE FROM files WHERE path=? OR substr(path,1,?)=?",
            arrayOf<Any>(path, slash.length, slash)
        )
    }

    // ---------- 工具 ----------

    private fun uriFor(context: Context, f: File): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", f)

    fun mimeOf(f: File): String {
        val ext = f.extension.lowercase()
        val mapped = android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(ext)
        return when {
            mapped != null -> mapped
            ext == "apk" || ext == "xapk" || ext == "apks" -> "application/vnd.android.package-archive"
            ext == "zip" -> "application/zip"
            ext == "txt" || ext == "log" || ext == "md" -> "text/plain"
            else -> "application/octet-stream"
        }
    }
}
