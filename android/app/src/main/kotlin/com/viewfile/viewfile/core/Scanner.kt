package com.viewfile.viewfile.core

import android.util.Log
import java.io.File
import java.util.ArrayDeque

/**
 * FUSE/普通路径扫描器：显式栈 DFS。只读取文件元数据，不读取内容。
 */
class Scanner {
    data class Count(var files: Int = 0, var dirs: Int = 0)

    fun scanInto(
        writer: IndexWriter,
        rootPath: String,
        onProgress: ((files: Int, dirs: Int, current: String) -> Unit)? = null
    ): Count {
        val c = Count()
        var sinceTick = 0
        val stack = ArrayDeque<File>()
        stack.push(File(rootPath))
        while (stack.size > 0) {
            val dir = stack.pop()
            val children = dir.listFiles() ?: continue  // 无权限/已删除的目录直接跳过
            for (f in children) {
                val isDir = f.isDirectory
                writer.add(f.absolutePath, dir.absolutePath, f.name, isDir,
                    if (isDir) 0L else f.length(), f.lastModified())
                if (isDir) {
                    c.dirs++
                    stack.push(f)
                } else {
                    c.files++
                }
                if (onProgress != null && ++sinceTick >= 20000) {
                    sinceTick = 0
                    onProgress(c.files, c.dirs, dir.absolutePath)
                }
            }
        }
        return c
    }

    companion object { const val TAG = "ViewFile/Scan" }
}

fun logScanDone(area: String, files: Int, dirs: Int, ms: Long) {
    Log.i(Scanner.TAG, "scan[$area] done: $files files, $dirs dirs in ${ms}ms")
}
