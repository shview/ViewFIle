package com.viewfile.viewfile.core

import android.util.Log
import java.io.File
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * FUSE/普通路径扫描器：4 工作线程并行遍历（stat 走 binder，多线程可重叠等待），
 * 采集结果入队，由调用线程在单一事务内批量写入——
 * Android SQLite 的写事务绑定唯一连接，跨线程插入会等不到连接（已实测死锁）。
 * 进度按时间驱动（开局即报、其后每 400ms），UI 无需等待。
 */
class Scanner {
    data class Count(@Volatile var files: Int = 0, @Volatile var dirs: Int = 0)

    private class Rec(path: String, parent: String, name: String, isDir: Boolean, size: Long, mtime: Long)

    fun scanInto(
        writer: IndexSink,
        rootPath: String,
        skipSubtrees: Set<String> = emptySet(),
        onProgress: ((files: Int, dirs: Int, current: String) -> Unit)? = null
    ): Count {
        val count = Count()
        val files = AtomicInteger(0)
        val dirs = AtomicInteger(0)
        val lastEmit = AtomicLong(0)
        val stack = ConcurrentLinkedDeque<File>()
        val queue = ConcurrentLinkedQueue<Array<Any?>>()
        val alive = AtomicInteger(0)
        stack.push(File(rootPath))

        fun maybeProgress(current: String, force: Boolean = false) {
            if (onProgress == null) return
            val now = System.currentTimeMillis()
            val last = lastEmit.get()
            if (!force && now - last < 400) return
            if (lastEmit.compareAndSet(last, now)) {
                onProgress(files.get(), dirs.get(), current)
            }
        }

        val workers = Array(4) {
            Thread {
                try {
                    while (true) {
                        val dir = stack.pollFirst() ?: break
                        if (dir.absolutePath in skipSubtrees) continue
                        val children = dir.listFiles() ?: continue
                        for (f in children) {
                            try {
                                val isDir = f.isDirectory
                                queue.add(arrayOf(
                                    f.absolutePath, dir.absolutePath, f.name, isDir,
                                    if (isDir) 0L else f.length(), f.lastModified()))
                                if (isDir) {
                                    dirs.incrementAndGet()
                                    if (f.absolutePath !in skipSubtrees) stack.addLast(f)
                                } else {
                                    files.incrementAndGet()
                                }
                            } catch (_: Throwable) {
                                // 个别条目 stat 失败（并发删除等）：跳过
                            }
                        }
                    }
                } finally {
                    alive.decrementAndGet()
                }
            }
        }

        // 调用线程：批量落库（事务由 Engine 持有，IndexWriter 内部每 2 万条分批提交）
        maybeProgress(rootPath, force = true)
        for (w in workers) {
            alive.incrementAndGet()
            w.start()
        }
        while (alive.get() > 0 || queue.isNotEmpty()) {
            val r = queue.poll()
            if (r == null) {
                maybeProgress("…")
                Thread.sleep(4)
                continue
            }
            writer.add(r[0] as String, r[1] as String, r[2] as String,
                r[3] as Boolean, r[4] as Long, r[5] as Long)
            maybeProgress(r[2] as String)
        }
        workers.forEach { it.join(2000) }
        count.files = files.get()
        count.dirs = dirs.get()
        return count
    }

    companion object { const val TAG = "ViewFile/Scan" }
}

fun logScanDone(area: String, files: Int, dirs: Int, ms: Long) {
    Log.i(Scanner.TAG, "scan[$area] done: $files files, $dirs dirs in ${ms}ms")
}
