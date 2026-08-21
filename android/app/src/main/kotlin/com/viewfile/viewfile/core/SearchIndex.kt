package com.viewfile.viewfile.core

import android.database.sqlite.SQLiteDatabase
import android.util.Log

/**
 * 内存索引 v4（SoA，紧凑结构）：以“名字池 + 平行数组”取代逐条目对象模型，
 * 135 万条内存从 ~630MB 降到 ~180MB 量级。
 *
 * - namePool: 全部条目名的 UTF-8 拼接（保留原大小写），匹配用折叠字节比较
 * - tin/tout: DFS 欧拉区间——“是否在目录 X 子树下”为 O(1) 区间判断
 * - sortIdx: 按名（不分大小写）排序的密集下标排列，查询按序取前 N
 * - 路径不驻留：结果与目录映射按需沿 parent 链重建
 */
class SearchIndex {
    /** 命中投影：密集下标，属性经访问器读取 */
    class Hit(val idx: Int)

    /** 目录统计：直接子项数 / 递归条数 / 递归总大小 */
    class DirStat(var direct: Int = 0, var recCount: Int = 0, var recSize: Long = 0)

    private class SoA(val n: Int) {
        var nameOff = IntArray(n + 1)   // 载入期原始偏移；去重后变为唯一名偏移
        var nameRef = IntArray(0)       // 去重后：条目 → 唯一名下标
        val parentId = IntArray(n)      // 密集父下标；根 = -1
        val isDir = ByteArray(n)
        val size = LongArray(n)
        val mtime = LongArray(n)
        val entryId = LongArray(n)      // 数据库 id
        val tin = IntArray(n)
        val tout = IntArray(n)
        var namePool: ByteArray = ByteArray(n * 24)  // 按需扩容
        var poolPos = 0
        var sortIdx: IntArray? = null
    }

    @Volatile
    private var soa: SoA? = null
    private val dirStats = HashMap<String, DirStat>()
    private val denseStats = HashMap<Int, DirStat>()   // 密集下标 → 统计（目录）

    // 同步与范围查询映射
    val dirIds = HashMap<String, Long>()       // path → dbId
    val dirMtimes = HashMap<String, Long>()    // path → mtime
    private val dirDenseIdx = HashMap<Long, Int>()  // dbId → 密集下标（仅目录）

    fun size() = soa?.n ?: 0

    fun statsFor(path: String): DirStat? {
        val id = dirIds[path] ?: return null
        val idx = dirDenseIdx[id] ?: return null
        return denseStats[idx]
    }

    fun pruneDirMaps(prefix: String) {
        val p = if (prefix.endsWith("/")) prefix else "$prefix/"
        dirIds.keys.removeIf { it == prefix || it.startsWith(p) }
        dirMtimes.keys.removeIf { it == prefix || it.startsWith(p) }
    }

    fun markDir(path: String, id: Long, mtime: Long) {
        dirIds[path] = id
        dirMtimes[path] = mtime
        // dense 下标未知（同步新建目录）：置 -1，下次载入补齐
        if (!dirDenseIdx.containsKey(id)) dirDenseIdx[id] = -1
    }

    // ---------- 结果访问器 ----------

    fun nameOf(h: Hit): String {
        val s = soa ?: return ""
        val r = s.nameRef[h.idx]
        val a = s.nameOff[r]
        return String(s.namePool, a, s.nameOff[r + 1] - a, Charsets.UTF_8)
    }

    fun isDirOf(h: Hit): Boolean = soa!!.isDir[h.idx].toInt() == 1
    fun sizeOf(h: Hit): Long = soa!!.size[h.idx]
    fun mtimeOf(h: Hit): Long = soa!!.mtime[h.idx]
    fun idOf(h: Hit): Long = soa!!.entryId[h.idx]

    /** 沿 parent 链重建完整显示路径 */
    fun pathOf(h: Hit): String {
        val s = soa ?: return ""
        return pathOfIdx(s, h.idx)
    }

    private fun pathOfIdx(s: SoA, idx: Int): String {
        val parts = ArrayList<String>(16)
        var i = idx
        var guard = 0
        while (i >= 0 && guard++ < 256) {
            val r = s.nameRef[i]
            val a = s.nameOff[r]
            parts.add(String(s.namePool, a, s.nameOff[r + 1] - a, Charsets.UTF_8))
            i = s.parentId[i]
        }
        parts.reverse()
        return "/" + parts.joinToString("/")
    }

    // ---------- 载入 ----------

    fun load(db: SQLiteDatabase): Int {
        val t0 = System.currentTimeMillis()
        dirStats.clear()
        dirIds.clear()
        dirMtimes.clear()
        dirDenseIdx.clear()
        denseStats.clear()

        val total = db.rawQuery("SELECT COUNT(*) FROM entry", null).use { c ->
            if (c.moveToFirst()) c.getInt(0) else 0
        }
        val maxId = db.rawQuery("SELECT COALESCE(MAX(id),0) FROM entry", null).use { c ->
            if (c.moveToFirst()) c.getLong(0) else 0L
        }
        if (total == 0 || maxId == 0L) {
            soa = null
            return 0
        }
        val s = SoA(total)
        val idxOfId = IntArray(maxId.toInt() + 1) { -1 }

        var dense = 0
        var lastId = 0L
        val nb = ByteArray(512)
        while (true) {
            var got = 0
            db.rawQuery(
                "SELECT id,parent_id,name,type,size,mtime FROM entry WHERE id>? ORDER BY id LIMIT 16000",
                arrayOf(lastId.toString())
            ).use { c ->
                while (c.moveToNext()) {
                    lastId = c.getLong(0)
                    val name = c.getString(2)
                    val need = name.toByteArray(Charsets.UTF_8)
                    if (s.poolPos + need.size > s.namePool.size) {
                        val grown = ByteArray(maxOf(s.poolPos + need.size, s.namePool.size * 3 / 2))
                        System.arraycopy(s.namePool, 0, grown, 0, s.poolPos)
                        s.namePool = grown
                    }
                    System.arraycopy(need, 0, s.namePool, s.poolPos, need.size)
                    s.nameOff[dense] = s.poolPos
                    s.poolPos += need.size
                    s.parentId[dense] = c.getLong(1).toInt()   // 第三步解析为密集下标
                    s.isDir[dense] = if (c.getInt(3) == 1) 1 else 0
                    s.size[dense] = c.getLong(4)
                    s.mtime[dense] = c.getLong(5)
                    s.entryId[dense] = lastId
                    idxOfId[lastId.toInt()] = dense
                    dense++
                    got++
                }
            }
            if (got == 0) break
        }
        s.nameOff[dense] = s.poolPos
        for (i in 0 until dense) {
            val pid = s.parentId[i].toLong()
            s.parentId[i] = if (pid == 0L) -1 else idxOfId[pid.toInt()]
        }

        // DFS 欧拉区间（递归深度=树深，几十级，安全）
        val childCount = IntArray(dense)
        for (i in 0 until dense) {
            val p = s.parentId[i]
            if (p >= 0) childCount[p]++
        }
        val childFill = IntArray(dense)
        val children = ArrayList<IntArray>(dense)
        for (i in 0 until dense) children.add(IntArray(childCount[i]))
        for (i in 0 until dense) {
            val p = s.parentId[i]
            if (p >= 0) children[p][childFill[p]++] = i
        }
        var timer = 0
        fun dfs(u: Int) {
            s.tin[u] = timer++
            for (k in children[u].indices) dfs(children[u][k])
            s.tout[u] = timer
        }
        for (i in 0 until dense) if (s.parentId[i] == -1) dfs(i)
        soa = s

        // 排序 + 池去重必须先于目录映射：pathOfIdx 依赖去重后的 nameRef/nameOff
        // （曾因顺序颠倒，目录映射读到 IntArray(0) 的 nameRef → length=0; index=0）
        // 免装箱 IntArray 三路快排（按名、折叠大小写）；装箱排序在 5M 时瞬时 +80MB
        val order = IntArray(dense) { it }
        poolSort(s, order, 0, dense - 1)

        // 名字池去重：排序后同名相邻 → 唯一名池 + 引用数组（cache/.log 等重复名占大头）
        val uniq = ByteArray(s.poolPos)
        val uniqOff = IntArray(dense + 1)
        val nameRef = IntArray(dense)
        var uc = 0
        var upos = 0
        var i0 = 0
        while (i0 < dense) {
            val head = order[i0]
            val a = s.nameOff[head]
            val b = s.nameOff[head + 1]
            System.arraycopy(s.namePool, a, uniq, upos, b - a)
            uniqOff[uc] = upos
            upos += b - a
            var j = i0
            while (j < dense && cmpNameExact(s, order[j], head)) {
                nameRef[order[j]] = uc
                j++
            }
            uc++
            i0 = j
        }
        uniqOff[uc] = upos
        val uniqBytes = upos
        s.namePool = uniq.copyOf(upos)
        s.nameOff = uniqOff.copyOf(uc + 1)
        s.nameRef = nameRef
        s.sortIdx = order

        // 目录映射 + 统计（密集空间聚合，只有目录需要路径字符串）
        for (i in 0 until dense) {
            if (s.isDir[i].toInt() != 1) continue
            val path = pathOfIdx(s, i)
            dirIds[path] = s.entryId[i]
            dirMtimes[path] = s.mtime[i]
            dirDenseIdx[s.entryId[i]] = i
        }
        for (i in 0 until dense) {
            val p = s.parentId[i]
            if (p < 0) continue
            val st = denseStats.getOrPut(p) { DirStat() }
            st.direct++
            st.recCount++
            if (s.isDir[i].toInt() == 0) st.recSize += s.size[i]
        }
        // 子树向上聚合：按 tout 降序处理目录（父在全部子之后）
        val dirIdxs = ArrayList<Int>(dirDenseIdx.size)
        for (i in 0 until dense) if (s.isDir[i].toInt() == 1) dirIdxs.add(i)
        dirIdxs.sortByDescending { s.tout[it] }
        for (di in dirIdxs) {
            val st = denseStats[di] ?: continue
            val p = s.parentId[di]
            if (p < 0) continue
            val ps = denseStats.getOrPut(p) { DirStat() }
            ps.recCount += st.recCount
            ps.recSize += st.recSize
        }

        Log.i("ViewFile/Scan",
            "SoA built: $dense entries, ${uc} uniq names, pool ${(uniqBytes shr 10)}KB, " +
                    "${System.currentTimeMillis() - t0}ms")
        return dense
    }

    // ---------- 查询 ----------

    /**
     * 多关键词 AND 折叠子串匹配；scopes 非空时用欧拉区间 O(1) 过滤。
     * 空关键词 + scopes = 列出范围内条目；按 sortIdx 序取前 limit。
     */
    fun query(raw: String, limit: Int, scopes: List<String>? = null): List<Hit> {
        val s = soa ?: return emptyList()
        val n = s.n
        if (n == 0) return emptyList()

        val intervals = scopes?.mapNotNull { path ->
            val id = dirIds[path] ?: return@mapNotNull null
            val idx = dirDenseIdx[id] ?: return@mapNotNull null
            if (idx < 0) null else intArrayOf(s.tin[idx], s.tout[idx])
        }
        val hasScope = !intervals.isNullOrEmpty()

        val q = raw.trim().lowercase()
        val tokens = q.split(' ', '\t').filter { it.isNotEmpty() }
            .map { it.toByteArray(Charsets.UTF_8) }
        val out = ArrayList<Hit>(minOf(limit, 256))

        fun nameContainsFold(i: Int, tok: ByteArray): Boolean {
            val r = s.nameRef[i]
            val a = s.nameOff[r]
            val b = s.nameOff[r + 1]
            val tlen = tok.size
            if (tlen > b - a) return false
            outer@ for (start in a..b - tlen) {
                for (k in 0 until tlen) {
                    var c1 = s.namePool[start + k].toInt() and 0xFF
                    val c2 = tok[k].toInt() and 0xFF
                    if (c1 in 0x41..0x5A) c1 += 32
                    if (c1 != c2) continue@outer
                }
                return true
            }
            return false
        }

        fun inScope(i: Int) = !hasScope || run {
            val t = s.tin[i]
            intervals!!.any { t >= it[0] && t < it[1] }
        }

        val order = s.sortIdx
        val seq: IntIterator = if (order != null) {
            object : IntIterator() {
                var p = 0
                override fun hasNext() = p < order.size
                override fun nextInt() = order[p++]
            }
        } else {
            object : IntIterator() {
                var p = 0
                override fun hasNext() = p < n
                override fun nextInt() = p++
            }
        }

        if (q.isEmpty()) {
            if (!hasScope) return emptyList()
            while (seq.hasNext()) {
                val i = seq.nextInt()
                if (inScope(i)) {
                    out.add(Hit(i))
                    if (out.size >= limit) break
                }
            }
            return out
        }
        while (seq.hasNext()) {
            val i = seq.nextInt()
            if (hasScope && !inScope(i)) continue
            var hit = true
            for (tok in tokens) {
                if (!nameContainsFold(i, tok)) { hit = false; break }
            }
            if (hit) {
                out.add(Hit(i))
                if (out.size >= limit) break
            }
        }
        return out
    }

    /** 精确逐字节比较（去重用——大小写敏感，Tencent ≠ tencent） */
    private fun cmpNameExact(s: SoA, x: Int, y: Int): Boolean {
        val ax = s.nameOff[x + 1] - s.nameOff[x]
        val ay = s.nameOff[y + 1] - s.nameOff[y]
        if (ax != ay) return false
        var i = s.nameOff[x]
        var j = s.nameOff[y]
        val end = i + ax
        while (i < end) {
            if (s.namePool[i] != s.namePool[j]) return false
            i++; j++
        }
        return true
    }

    /** 折叠字节序比较 name(x) vs name(y) */
    private fun cmpName(s: SoA, x: Int, y: Int): Int {
        val pool = s.namePool
        var a = s.nameOff[x]; var b = s.nameOff[y]
        val ax = s.nameOff[x + 1]; val bx = s.nameOff[y + 1]
        while (a < ax && b < bx) {
            var c1 = pool[a].toInt() and 0xFF
            var c2 = pool[b].toInt() and 0xFF
            if (c1 in 0x41..0x5A) c1 += 32
            if (c2 in 0x41..0x5A) c2 += 32
            if (c1 != c2) return c1 - c2
            a++; b++
        }
        return (ax - a) - (bx - b)
    }

    /** 三路快排（重复名多，三路划分显著减少比较） */
    private fun poolSort(s: SoA, arr: IntArray, loIn: Int, hiIn: Int) {
        val stack = IntArray(4096)
        var sp = 0
        stack[sp++] = loIn; stack[sp++] = hiIn
        while (sp > 0) {
            val hi = stack[--sp]
            val lo = stack[--sp]
            if (lo >= hi) continue
            if (hi - lo < 24) {
                for (i in lo + 1..hi) {
                    val v = arr[i]; var j = i - 1
                    while (j >= lo && cmpName(s, arr[j], v) > 0) { arr[j + 1] = arr[j]; j-- }
                    arr[j + 1] = v
                }
                continue
            }
            val pivot = arr[lo + (hi - lo) / 2]
            var lt = lo; var i = lo; var gt = hi
            while (i <= gt) {
                val c = cmpName(s, arr[i], pivot)
                if (c < 0) { val t = arr[lt]; arr[lt] = arr[i]; arr[i] = t; lt++; i++ }
                else if (c > 0) { val t = arr[gt]; arr[gt] = arr[i]; arr[i] = t; gt-- }
                else i++
            }
            if (lt - lo > hi - gt) {
                stack[sp++] = lo; stack[sp++] = lt - 1
                stack[sp++] = gt + 1; stack[sp++] = hi
            } else {
                stack[sp++] = gt + 1; stack[sp++] = hi
                stack[sp++] = lo; stack[sp++] = lt - 1
            }
        }
    }
}
