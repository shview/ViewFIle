package com.viewfile.viewfile.core

/**
 * root 区域扫描：find -print0 + 有界批量 stat；stdout 使用批次头、NUL 路径区和
 * 不含路径的元数据区，避免任意合法文件名改变记录边界。
 * rawPrefix→displayPrefix 映射（如 /data/media/0/Android → /storage/emulated/0/Android）
 * 让 FUSE 隐藏区在索引/浏览里显示为用户熟悉的路径并自动去重。
 */
data class Area(val raw: String, val display: String, val depth: Int = 0)

internal enum class RootScanStrategy { EXEC_PLUS, BOUNDED_PIPEFAIL }

internal fun rootScanCommand(area: Area, strategy: RootScanStrategy): String {
    val depthArg = if (area.depth > 0) " -maxdepth ${area.depth}" else ""
    val root = shq(area.raw)
    val format = "'%n|%F|%s|%Y'"
    return when (strategy) {
        RootScanStrategy.EXEC_PLUS ->
            "/system/bin/find $root$depthArg -exec /system/bin/stat -c $format '{}' +"
        RootScanStrategy.BOUNDED_PIPEFAIL ->
            "set -o pipefail || exit $?; /system/bin/find $root$depthArg -print0 | " +
                "/system/bin/xargs -0 -n ${RootBinaryRecordParser.MAX_BATCH} " +
                "/system/bin/sh -c " + shq(
                    "printf 'B%s\\n' \"\$#\"; " +
                        "for p do printf '%s\\0' \"\$p\"; done; " +
                        "/system/bin/stat -c '%F|%s|%Y' \"\$@\""
                ) + " vfstat"
    }
}

internal fun shouldUseBoundedRootFallback(exitCode: Int, stderr: String): Boolean =
    exitCode == 126 || stderr.contains("Argument list too long", ignoreCase = true) ||
        stderr.contains("not supported", ignoreCase = true)

class RootScanner {
    class Count(var files: Int = 0, var dirs: Int = 0, var skipped: Int = 0)

    fun scanInto(
        writer: IndexSink,
        areas: List<Area>,   // rawRoot → displayRoot；depth>0 时限制 find 深度
        onProgress: ((area: String, files: Int, dirs: Int) -> Unit)? = null
    ): Count {
        val total = Count()
        for (area in areas) {
            val raw = area.raw
            val display = area.display
            // ColorOS toybox find 的 {} + 会越过 ARG_MAX 并以 rc=126 失败。固定批次
            // xargs 避免百万级逐文件进程；pipefail 保证 find/stat 任一失败都使整区失败。
            // stdout 的原始路径独立使用 NUL 边界，换行、竖线与引号均不会伪造记录。
            val cmd = rootScanCommand(area, RootScanStrategy.BOUNDED_PIPEFAIL)
            val areaStart = System.currentTimeMillis()
            var areaFiles = 0
            var areaDirs = 0
            var sinceTick = 0
            val parser = RootBinaryRecordParser { record ->
                if (!isWithinRawRoot(record.rawPath, raw)) {
                    throw IllegalStateException("root scan escaped area: ${record.rawPath}")
                }
                val isDir = record.type == "directory"
                val isFile = record.type.startsWith("regular")
                if (!isDir && !isFile) {
                    total.skipped++
                } else {
                    val e = Entry(record.rawPath, isDir, record.size, record.mtimeMs)
                    val displayPath = mapDisplay(e.rawPath, raw, display)
                    val name = displayPath.substringAfterLast('/')
                    val parent = displayPath.substringBeforeLast('/').ifEmpty { "/" }
                    writer.add(displayPath, parent, name, e.isDir, e.size, e.mtimeMs)
                    if (e.isDir) { total.dirs++; areaDirs++ } else { total.files++; areaFiles++ }
                    if (++sinceTick >= 50000) {
                        sinceTick = 0
                        android.util.Log.i("ViewFile/Scan",
                            "pipe $display +${areaFiles}f +${areaDirs}d ${System.currentTimeMillis() - areaStart}ms")
                    }
                    if (onProgress != null && sinceTick == 25000) {
                        onProgress(display, areaFiles, areaDirs)
                    }
                }
            }
            val res = PrivShell.runBinary(cmd) { bytes, length -> parser.accept(bytes, length) }
            if (res.ok) parser.finish()
            logScanDone(display, areaFiles, areaDirs, System.currentTimeMillis() - areaStart)
            if (!res.ok) {
                val detail = res.err.take(200).ifBlank { "rc=${res.code}" }
                // IndexBuilder 写的是独立构建库；抛出后 Engine 会 abort，不允许把
                // root 管道的部分输出当成一次成功全量扫描发布。
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
            val isFile = type.startsWith("regular")  // regular file / regular empty file
            if (!isDir && !isFile) return null       // 符号链接/socket/设备节点不入索引
            val size = line.substring(i2 + 1, i3).toLongOrNull() ?: return null
            val mtime = line.substring(i3 + 1).trim().toLongOrNull() ?: return null
            if (name.isEmpty()) return null
            return Entry(name, isDir, size, mtime * 1000)
        }

        fun mapDisplay(rawPath: String, rawRoot: String, displayRoot: String): String =
            if (rawPath == rawRoot) displayRoot
            else if (rawPath.startsWith("$rawRoot/")) displayRoot + rawPath.substring(rawRoot.length)
            else rawPath

        fun isWithinRawRoot(rawPath: String, rawRoot: String): Boolean {
            val root = rawRoot.trimEnd('/').ifEmpty { "/" }
            return rawPath == root || if (root == "/") rawPath.startsWith("/")
                else rawPath.startsWith("$root/")
        }

        /** /data/media/0/... → /storage/emulated/0/...（浏览与文件操作通用） */
        fun toDisplay(rawPath: String): String =
            mapDisplay(rawPath, RAW_MEDIA, FUSE_SDCARD)

        /** /storage/emulated/0/... → /data/media/0/...（root 操作时换真实路径） */
        fun toRaw(displayPath: String): String =
            mapDisplay(displayPath, FUSE_SDCARD, RAW_MEDIA)

        const val FUSE_SDCARD = "/storage/emulated/0"
        const val RAW_MEDIA = "/data/media/0"
    }
}
