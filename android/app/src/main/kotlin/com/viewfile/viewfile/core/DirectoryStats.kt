package com.viewfile.viewfile.core

/** 纯内存目录聚合结果；与 Android/SQLite 无关，可在宿主 JVM 回归测试。 */
internal data class DirectoryAggregate(
    val direct: Int,
    val recursiveCount: Int,
    val recursiveSize: Long
)

/**
 * 先统计直接子项，再按 tin 降序把目录结果推给父目录。
 * DFS 中后代 tin 必然大于祖先，因此该顺序明确保证后代先于祖先。
 */
internal fun aggregateDirectoryStats(
    parent: IntArray,
    isDir: ByteArray,
    size: LongArray,
    tin: IntArray
): Map<Int, DirectoryAggregate> {
    require(parent.size == isDir.size && parent.size == size.size && parent.size == tin.size)
    data class MutableStat(var direct: Int = 0, var count: Int = 0, var bytes: Long = 0)

    val stats = HashMap<Int, MutableStat>()
    val dirs = ArrayList<Int>()
    for (i in parent.indices) {
        if (isDir[i].toInt() == 1) {
            dirs.add(i)
            stats.putIfAbsent(i, MutableStat()) // 空目录也有明确的零统计
        }
        val p = parent[i]
        if (p < 0) continue
        val st = stats.getOrPut(p) { MutableStat() }
        st.direct++
        st.count++
        if (isDir[i].toInt() == 0) st.bytes += size[i]
    }

    dirs.sortByDescending { tin[it] }
    for (dir in dirs) {
        val p = parent[dir]
        if (p < 0) continue
        val child = stats.getValue(dir)
        val ancestor = stats.getOrPut(p) { MutableStat() }
        ancestor.count += child.count
        ancestor.bytes += child.bytes
    }
    return stats.mapValues { (_, st) ->
        DirectoryAggregate(st.direct, st.count, st.bytes)
    }
}
