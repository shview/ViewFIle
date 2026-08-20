package com.viewfile.viewfile.core

import android.database.sqlite.SQLiteDatabase
import java.util.Arrays

/**
 * 内存索引：启动后从 SQLite 整表载入，按文件名小写排序。
 * 查询 = 多关键词 AND 子串匹配（Everything 默认语义），
 * 顺序扫描已排序数组，结果天然有序。载入与查询可并发（数组整体替换）。
 */
class SearchIndex {
    class Entry(
        val path: String,
        val name: String,
        val nameLower: String,
        val isDir: Boolean,
        val size: Long,
        val mtime: Long
    )

    @Volatile
    private var entries: Array<Entry> = emptyArray()

    fun size() = entries.size

    /** 整表载入并排序，返回条目数 */
    fun load(db: SQLiteDatabase): Int {
        val list = ArrayList<Entry>(128 * 1024)
        db.rawQuery("SELECT path,name,is_dir,size,mtime FROM files", null).use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1)
                list.add(
                    Entry(c.getString(0), name, name.lowercase(),
                        c.getInt(2) == 1, c.getLong(3), c.getLong(4))
                )
            }
        }
        val arr = list.toArray(emptyArray<Entry>())
        Arrays.sort(arr, compareBy { it.nameLower })
        entries = arr
        return arr.size
    }

    fun query(raw: String, limit: Int, scope: String? = null): List<Entry> {
        val q = raw.trim().lowercase()
        if (q.isEmpty() || entries.isEmpty()) return emptyList()
        val scopePrefix = scope?.takeIf { it.isNotEmpty() }
        val tokens = q.split(' ', '\t').filter { it.isNotEmpty() }
        val out = ArrayList<Entry>(minOf(limit, 256))
        for (e in entries) {
            if (scopePrefix != null && !e.path.startsWith(scopePrefix)) continue
            var hit = true
            for (t in tokens) {
                if (!e.nameLower.contains(t)) { hit = false; break }
            }
            if (hit) {
                out.add(e)
                if (out.size >= limit) break
            }
        }
        return out
    }
}
