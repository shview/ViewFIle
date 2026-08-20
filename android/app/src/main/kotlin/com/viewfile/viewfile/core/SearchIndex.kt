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

    /** 目录统计：直接子项数 / 递归条数 / 递归总大小 */
    class DirStat(var direct: Int = 0, var recCount: Int = 0, var recSize: Long = 0)

    @Volatile
    private var entries: Array<Entry> = emptyArray()
    private val dirStats = HashMap<String, DirStat>()

    fun size() = entries.size

    fun statsFor(path: String): DirStat? = dirStats[path]

    /** 整表载入并排序；同时按祖先链累计目录统计 */
    fun load(db: SQLiteDatabase): Int {
        dirStats.clear()
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
        // 每条目向全部祖先累计递归统计（深度×条目，均摊 O(1) 层级成本）
        for (e in arr) {
            var i = e.path.lastIndexOf('/')
            while (i > 0) {
                val anc = e.path.substring(0, i)
                val s = dirStats.getOrPut(anc) { DirStat() }
                s.recCount++
                if (!e.isDir) s.recSize += e.size
                i = e.path.lastIndexOf('/', i - 1)
            }
        }
        // 直接子项数单独一遍；同时确保每个目录都有统计记录（空目录 = 0）
        for (e in arr) {
            if (e.isDir) dirStats.getOrPut(e.path) { DirStat() }
            val p = e.path.substringBeforeLast('/')
            if (p.isNotEmpty()) {
                dirStats.getOrPut(p) { DirStat() }.direct++
            }
        }
        entries = arr
        return arr.size
    }

    /**
     * 多关键词 AND 子串匹配；scopes 非空时限定路径前缀（任一命中）。
     * 空关键词 + scopes = 直接列出该范围内的条目（应用内浏览）。
     */
    fun query(raw: String, limit: Int, scopes: List<String>? = null): List<Entry> {
        val prefixes = scopes?.filter { it.isNotEmpty() }?.takeIf { it.isNotEmpty() }
        val q = raw.trim().lowercase()
        if (entries.isEmpty()) return emptyList()
        val inScope = { e: Entry ->
            prefixes == null || prefixes.any { e.path == it || e.path.startsWith("$it/") }
        }
        if (q.isEmpty()) {
            if (prefixes == null) return emptyList()
            val out = ArrayList<Entry>(minOf(limit, 256))
            for (e in entries) {
                if (inScope(e)) {
                    out.add(e)
                    if (out.size >= limit) break
                }
            }
            return out
        }
        val tokens = q.split(' ', '\t').filter { it.isNotEmpty() }
        val out = ArrayList<Entry>(minOf(limit, 256))
        for (e in entries) {
            if (!inScope(e)) continue
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
