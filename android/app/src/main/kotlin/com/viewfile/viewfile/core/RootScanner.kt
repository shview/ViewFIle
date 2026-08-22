package com.viewfile.viewfile.core

import android.util.Log

/**
 * root 区域扫描：单条 `find -print0 | xargs -0 stat` 管道流式输出
 * '路径|类型|大小|mtime秒'，runStreamFast 在调用线程直接 BufferedReader 读取
 * （跳过三线程队列中转——20 万条时队列 park/unpark 开销是分钟级）。
 * rawPrefix→displayPrefix 映射（如 /data/media/0/Android → /storage/emulated/0/Android）
 * 让 FUSE 隐藏区在索引/浏览里显示为用户熟悉的路径并自动去重。
 */
data class Area(val raw: String, val display: String, val depth: Int = 0)

class RootScanner {
    class Count(var files: Int = 0, var dirs: Int = 0, var skipped: Int = 0)

    fun scanInto(
        writer: IndexSink,
        areas: List<Area>,
        onProgress: ((area: String, files: Int, dirs: Int) -> Unit)? = null
    ): Count {
        val total = Count()
        for (area in areas) {
            val raw = area.raw
            val display = area.display
            val depthArg = if (area.depth > 0) " -maxdepth ${area.depth}" else ""
            val cmd = "find ${shq(raw)}$depthArg -print0 | xargs -0 -r stat -c '%n|%F|%s|%Y' 2>/dev/null"
            val areaStart = System.currentTimeMillis()
            var areaFiles = 0
            var areaDirs = 0
            var sinceTick = 0
            val res = SuShell.runStreamFast(cmd) { line ->
                val e = parseStatLine(line) ?: run { total.skipped++; return@runStreamFast }
                // 文件名含换行会把 stat 输出撕成碎片行：非绝对路径的一律丢弃
                if (!e.rawPath.startsWith("/")) { total.skipped++; return@runStreamFast }
                val displayPath = mapDisplay(e.rawPath, raw, display)
                val name = displayPath.substringAfterLast('/')
                val parent = displayPath.substringBeforeLast('/').ifEmpty { "/" }
                writer.add(displayPath, parent, name, e.isDir, e.size, e.mtimeMs)
                if (e.isDir) { total.dirs++; areaDirs++ } else { total.files++; areaFiles++ }
                if (++sinceTick >= 50000) {
                    sinceTick = 0
                    Log.i("ViewFile/Scan",
                        "pipe $display +${areaFiles}f +${areaDirs}d ${System.currentTimeMillis() - areaStart}ms")
                }
                if (onProgress != null && sinceTick == 25000) {
                    onProgress(display, areaFiles, areaDirs)
                }
            }
            logScanDone(display, areaFiles, areaDirs, System.currentTimeMillis() - areaStart)
            if (!res.ok) {
                val detail = res.err.take(200).ifBlank { "rc=${res.code}" }
                throw IllegalStateException("root scan $raw failed: $detail")
            }
        }
        return total
    }

    class Entry(val rawPath: String, val isDir: Boolean, val size: Long, val mtimeMs: Long)

    companion object {
        /** 从右侧解析（文件名可能含 |）：name|type|size|mtime */
        fun parseStatLine(line: String): Entry? {
            if (line.isEmpty()) return null
            val i3 = line.lastIndexOf('|')
            if (i3 < 0) return null
            val i2 = line.lastIndexOf('|', i3 - 1)
            val i1 = line.lastIndexOf('|', i2 - 1)
            if (i1 < 0 || i2 < 0) return null
            val name = line.substring(0, i1)
            val type = line.substring(i1 + 1, i2)
            val isDir = type == "directory"
            val isFile = type.startsWith("regular")
            if (!isDir && !isFile) return null
            val size = line.substring(i2 + 1, i3).toLongOrNull() ?: return null
            val mtime = line.substring(i3 + 1).trim().toLongOrNull() ?: return null
            if (name.isEmpty()) return null
            return Entry(name, isDir, size, mtime * 1000)
        }

        fun mapDisplay(rawPath: String, rawRoot: String, displayRoot: String): String =
            if (rawPath == rawRoot) displayRoot
            else if (rawPath.startsWith("$rawRoot/")) displayRoot + rawPath.substring(rawRoot.length)
            else rawPath

        /** /data/media/0/... → /storage/emulated/0/...（浏览与文件操作通用） */
        fun toDisplay(rawPath: String): String =
            mapDisplay(rawPath, RAW_MEDIA, FUSE_SDCARD)

        /** /storage/emulated/0/... → /data/media/0/...（root 操作时换真实路径） */
        fun toRaw(displayPath: String): String =
            mapDisplay(displayPath, FUSE_SDCARD, RAW_MEDIA)

        const val FUSE_SDCARD = "/storage/emulated/0"
        const val RAW_MEDIA = "/data/media/0"

        const val TAG = "ViewFile/Scan"
    }
}

fun logScanDone(area: String, files: Int, dirs: Int, ms: Long) {
    Log.i(RootScanner.TAG, "scan[$area] done: $files files, $dirs dirs in ${ms}ms")
}
