package com.viewfile.viewfile.core

import java.io.File

/**
 * 目录浏览：FUSE/普通路径优先（免 root 可用），root 专属路径与
 * Android/data、Android/obb 封锁区回退到 root stat 管道。
 */
object Fs {

    fun listDir(path: String): Map<String, Any?> {
        if (isFuseBlocked(path)) {
            return if (SuShell.getAvailable()) rootListing(path)
            else err("该目录受系统保护（Android 11+ 限制），需要 root 才能查看")
        }
        val f = File(path)
        if (!f.isDirectory) return err(if (f.exists()) "不是文件夹" else "目录不存在")
        if (f.canRead()) {
            val kids = f.listFiles()
            if (kids != null) return ok(kids.map { fileEntryMap(it) })
        }
        return if (SuShell.getAvailable()) rootListing(path) else err("无权限读取该目录")
    }

    /** /storage/emulated/<n>/Android/{data,obb}（FUSE 对所有应用隐藏） */
    private fun isFuseBlocked(p: String): Boolean {
        val m = Regex("^/storage/emulated/\\d+/Android/(data|obb)(/|$)").containsMatchIn(p)
        return m
    }

    private fun rootListing(displayPath: String): Map<String, Any?> {
        val raw = RootScanner.toRaw(displayPath)
        val res = SuShell.run(
            "find ${shq(raw)} -mindepth 1 -maxdepth 1 -print0 | xargs -0 stat -c '%n|%F|%s|%Y' 2>/dev/null"
        )
        if (!res.ok) return err("读取失败: ${res.err.take(120).ifBlank { "rc=${res.code}" }}")
        val entries: List<Map<String, Any?>> = res.out.lineSequence()
            .mapNotNull(RootScanner::parseStatLine)
            .map { e ->
                val dp = RootScanner.toDisplay(e.rawPath)
                mapOf<String, Any?>(
                    "path" to dp,
                    "name" to dp.substringAfterLast('/'),
                    "isDir" to e.isDir,
                    "size" to e.size,
                    "mtime" to e.mtimeMs,
                )
            }
            .sortedWith(dirsFirst)
            .toList()
        return ok(entries)
    }

    private fun fileEntryMap(f: File) = mapOf(
        "path" to f.absolutePath,
        "name" to f.name,
        "isDir" to f.isDirectory,
        "size" to if (f.isDirectory) 0L else f.length(),
        "mtime" to f.lastModified(),
    )

    private val dirsFirst = compareByDescending<Map<String, Any?>> { it["isDir"] as Boolean }
        .thenBy { (it["name"] as String).lowercase() }

    private fun ok(entries: List<Map<String, Any?>>) =
        mapOf("ok" to true, "entries" to entries)

    private fun err(msg: String) = mapOf("ok" to false, "error" to msg)
}
