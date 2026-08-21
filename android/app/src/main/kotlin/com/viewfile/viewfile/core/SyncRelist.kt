package com.viewfile.viewfile.core

/**
 * 为每个待重列父目录预建 bucket；没有输出的父目录仍保留空列表，调用方因而
 * 能在命令整体成功后对空目录执行 diff，删除数据库中已经消失的旧子项。
 */
internal fun <T> groupRelistedChildren(
    parents: List<String>,
    children: List<Pair<String, T>>
): Map<String, List<T>> {
    val grouped = LinkedHashMap<String, MutableList<T>>(parents.size)
    for (parent in parents) grouped.putIfAbsent(parent, ArrayList())
    for ((parent, child) in children) grouped[parent]?.add(child)
    return grouped
}
