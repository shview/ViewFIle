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

    /** 整表载入并排序；分批读取避免大库撑爆 CursorWindow，统计用深度向上聚合 */
    fun load(db: SQLiteDatabase): Int {
        dirStats.clear()
        val total = db.rawQuery("SELECT COUNT(*) FROM files", null).use { c ->
            if (c.moveToFirst()) c.getInt(0) else 0
        }
        val list = ArrayList<Entry>(total + 16)
        var lastId = -1L
        while (true) {
            val before = list.size
            db.rawQuery(
                "SELECT rowid,path,name,is_dir,size,mtime FROM files WHERE rowid>? ORDER BY rowid LIMIT 8000",
                arrayOf(lastId.toString())
            ).use { c ->
                while (c.moveToNext()) {
                    lastId = c.getLong(0)
                    val name = c.getString(2)
                    list.add(
                        Entry(c.getString(1), name, fastLower(name),
                            c.getInt(3) == 1, c.getLong(4), c.getLong(5))
                    )
                }
            }
            if (list.size == before) break
        }
        val arr = list.toArray(emptyArray<Entry>())
        Arrays.sort(arr, compareBy { it.nameLower })

        // 第一遍：直接子项计数 + 目录父链接
        val parentOfDir = HashMap<String, String>(arr.size / 4 + 16)
        for (e in arr) {
            val p = e.path.substringBeforeLast('/')
            if (p.isEmpty()) continue
            val s = dirStats.getOrPut(p) { DirStat() }
            s.direct++
            s.recCount++
            if (!e.isDir) s.recSize += e.size
            if (e.isDir) parentOfDir[e.path] = p
        }
        // 空目录也保证有记录
        for (e in arr) {
            if (e.isDir) dirStats.getOrPut(e.path) { DirStat() }
        }
        // 第二遍：按深度降序把子树统计累加给父目录（避免 深度×条目 的字符串分配）
        val withParent = parentOfDir.keys.sortedByDescending { path -> path.count { it == '/' } }
        for (d in withParent) {
            val s = dirStats[d] ?: continue
            val p = parentOfDir[d] ?: continue
            val ps = dirStats.getOrPut(p) { DirStat() }
            ps.recCount += s.recCount
            ps.recSize += s.recSize
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

    companion object {
        /** ASCII 快速小写化：String.toLowerCase 在 Android 上是慢路径，
         *  21 万级条目下差距是秒级；非 ASCII 大写不参与折叠（可接受） */
        fun fastLower(s: String): String {
            val chars = s.toCharArray()
            var changed = false
            for (i in chars.indices) {
                val c = chars[i]
                if (c in 'A'..'Z') {
                    chars[i] = c + 32
                    changed = true
                }
            }
            return if (changed) String(chars) else s
        }
    }
}
