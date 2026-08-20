package com.viewfile.viewfile.core

import java.io.File

/**
 * 目录浏览：FUSE/普通路径优先（免 root 可用），root 专属路径与
 * Android/data、Android/obb 封锁区回退到 root stat 管道。
 */
object Fs {

    fun listDir(path: String): Map<String, Any?> {
        val tier = PrivShell.tier()
        if (isFuseBlocked(path)) {
            return if (tier != PrivShell.Tier.NONE) rootListing(path)
            else err("该目录受系统保护（Android 11+ 限制），需要 root 或 Shizuku 才能查看")
        }
        val f = File(path)
        if (!f.isDirectory) return err(if (f.exists()) "不是文件夹" else "目录不存在")
        if (f.canRead()) {
            val kids = f.listFiles()
            if (kids != null) return ok(kids.map { fileEntryMap(it) })
        }
        if (PrivShell.needsRealRoot(path) && tier != PrivShell.Tier.ROOT) {
            return err("该目录只有真正的 root 才能读取（Shizuku 的 shell 身份不够）")
        }
        return if (tier != PrivShell.Tier.NONE) rootListing(path) else err("无权限读取该目录")
    }

    /** FUSE 会隐藏内容的区域：Android 本身（data 子目录被藏）与 Android/{data,obb} */
    private fun isFuseBlocked(p: String): Boolean {
        return Regex("^/storage/emulated/\\d+/Android(/(data|obb))?(/|$)").containsMatchIn(p)
    }

    private fun rootListing(displayPath: String): Map<String, Any?> {
        val raw = RootScanner.toRaw(displayPath)
        // -r：空目录时 xargs 不执行 stat（否则报 rc=123）
        val res = PrivShell.run(
            "find ${shq(raw)} -mindepth 1 -maxdepth 1 -print0 | xargs -0 -r stat -c '%n|%F|%s|%Y' 2>/dev/null"
        )
        if (!res.ok) return err("读取失败: ${res.err.take(120).ifBlank { "rc=${res.code}" }}")
        val entries: List<Map<String, Any?>> = res.out.lineSequence()
            .mapNotNull(RootScanner::parseStatLine)
            .map { e ->
                val dp = RootScanner.toDisplay(e.rawPath)
                buildMap<String, Any?> {
                    put("path", dp)
                    put("name", dp.substringAfterLast('/'))
                    put("isDir", e.isDir)
                    put("size", e.size)
                    put("mtime", e.mtimeMs)
                    if (e.isDir) Engine.index.statsFor(dp)?.let {
                        put("dirCount", it.direct)
                        put("dirSize", it.recSize)
                    }
                }
            }
            .sortedWith(dirsFirst)
            .toList()
        return ok(entries)
    }

    private fun fileEntryMap(f: File): Map<String, Any?> = buildMap {
        put("path", f.absolutePath)
        put("name", f.name)
        put("isDir", f.isDirectory)
        put("size", if (f.isDirectory) 0L else f.length())
        put("mtime", f.lastModified())
        if (f.isDirectory) Engine.index.statsFor(f.absolutePath)?.let {
            put("dirCount", it.direct)
            put("dirSize", it.recSize)
        }
    }

    private val dirsFirst = compareByDescending<Map<String, Any?>> { it["isDir"] as Boolean }
        .thenBy { (it["name"] as String).lowercase() }

    private fun ok(entries: List<Map<String, Any?>>) =
        mapOf("ok" to true, "entries" to entries)

    private fun err(msg: String) = mapOf("ok" to false, "error" to msg)
}
