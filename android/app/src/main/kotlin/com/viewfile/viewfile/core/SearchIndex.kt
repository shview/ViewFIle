package com.viewfile.viewfile.core

import android.database.sqlite.SQLiteDatabase
import java.util.Arrays

/**
 * 内存索引 v3：从 entry 表分批载入，利用 parent_id < id 的不变式
 * 一遍按 parent 链重建完整路径（库内不存路径）。
 * 同时维护 目录路径 → (id, mtime) 映射供增量同步对账使用。
 */
class SearchIndex {
    class Entry(
        val id: Long,
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

    // 增量同步用的目录映射（path → id / mtime）
    val dirIds = HashMap<String, Long>()
    val dirMtimes = HashMap<String, Long>()

    fun size() = entries.size

    fun statsFor(path: String): DirStat? = dirStats[path]

    /** 删除子树后修剪同步映射（dirStats 随重载重建，无需修剪） */
    fun pruneDirMaps(prefix: String) {
        val p = if (prefix.endsWith("/")) prefix else "$prefix/"
        dirIds.keys.removeIf { it == prefix || it.startsWith(p) }
        dirMtimes.keys.removeIf { it == prefix || it.startsWith(p) }
    }

    fun markDir(path: String, id: Long, mtime: Long) {
        dirIds[path] = id
        dirMtimes[path] = mtime
    }

    /** 整表载入：分批读 → parent 链重建路径 → 排序 + 统计 */
    fun load(db: SQLiteDatabase): Int {
        dirStats.clear()
        dirIds.clear()
        dirMtimes.clear()
        val total = db.rawQuery("SELECT COUNT(*) FROM entry", null).use { c ->
            if (c.moveToFirst()) c.getInt(0) else 0
        }
        val maxId = db.rawQuery("SELECT COALESCE(MAX(id),0) FROM entry", null).use { c ->
            if (c.moveToFirst()) c.getLong(0) else 0L
        }
        if (total == 0 || maxId == 0L) {
            entries = emptyArray()
            return 0
        }
        // 按 id 的稀疏数组中间结构（避免 HashMap 装箱开销）
        val n = (maxId + 1).toInt()
        val parentIds = LongArray(n)
        val types = ByteArray(n)          // 0=无 1=文件 2=目录
        val sizes = LongArray(n)
        val mtimes = LongArray(n)
        val names = arrayOfNulls<String>(n)
        var lastId = 0L
        while (true) {
            var got = 0
            db.rawQuery(
                "SELECT id,parent_id,name,type,size,mtime FROM entry WHERE id>? ORDER BY id LIMIT 8000",
                arrayOf(lastId.toString())
            ).use { c ->
                while (c.moveToNext()) {
                    lastId = c.getLong(0)
                    val idx = lastId.toInt()
                    parentIds[idx] = c.getLong(1)
                    val t = c.getInt(3)
                    types[idx] = if (t == 1) 2 else 1
                    sizes[idx] = c.getLong(4)
                    mtimes[idx] = c.getLong(5)
                    names[idx] = c.getString(2)
                    got++
                }
            }
            if (got == 0) break
        }

        val pathOf = arrayOfNulls<String>(n)
        val list = ArrayList<Entry>(total)
        // parent_id < id 恒成立：按 id 升序一遍完成路径重建
        for (idx in 1 until n) {
            if (types[idx] == 0.toByte()) continue
            val pid = parentIds[idx]
            val name = names[idx] ?: continue
            val path = if (pid == 0L) "/$name"
                else {
                    val parentPath = pathOf[pid.toInt()] ?: continue
                    if (parentPath == "/") "/$name" else "$parentPath/$name"
                }
            pathOf[idx] = path
            val isDir = types[idx] == 2.toByte()
            list.add(Entry(idx.toLong(), path, name, fastLower(name), isDir, sizes[idx], mtimes[idx]))
            if (isDir) {
                dirIds[path] = idx.toLong()
                dirMtimes[path] = mtimes[idx]
            }
        }
        val arr = list.toArray(emptyArray<Entry>())
        Arrays.sort(arr, compareBy { it.nameLower })

        // 统计：直接子项 + 深度向上聚合
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
        for (e in arr) {
            if (e.isDir) dirStats.getOrPut(e.path) { DirStat() }
        }
        val withParent = parentOfDir.keys.sortedByDescending { it.count { ch -> ch == '/' } }
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
        /** ASCII 快速小写化：String.toLowerCase 在 Android 上是慢路径 */
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
