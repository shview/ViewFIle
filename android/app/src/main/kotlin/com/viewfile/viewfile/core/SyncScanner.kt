package com.viewfile.viewfile.core

import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

/**
 * 增量同步（打开 app 时对账，无常驻）：
 * - FUSE 区按目录 mtime 对比，只重扫 mtime 变化的子树——目录 mtime
 *   在任何直接子项增删时会更新，因此未变化的目录可安全跳过；
 *   同名文件的内容修改不会反映（文件名索引的场景可接受，全量重建可修正）。
 * - root 区（Android/data、/data/data 等）体量小刷新快，直接整区删除重扫。
 */
class SyncScanner(private val db: SQLiteDatabase) {
    class Result(val added: Int, val removed: Int, val updated: Int, val elapsedMs: Long)

    companion object {
        private const val MAX_RELIST_PER_SYNC = 2000
    }

    fun sync(fuseRoot: String, rootAreas: List<Pair<String, String>>): Result {
        val t0 = System.currentTimeMillis()
        var added = 0
        var removed = 0
        var updated = 0

        val dirMtimes = HashMap<String, Long>()
        db.rawQuery("SELECT path,mtime FROM files WHERE is_dir=1", null).use { c ->
            while (c.moveToNext()) dirMtimes[c.getString(0)] = c.getLong(1)
        }

        val ins = db.compileStatement(
            "INSERT OR IGNORE INTO files(path,parent,name,is_dir,size,mtime) VALUES(?,?,?,?,?,?)")
        val upd = db.compileStatement("UPDATE files SET size=?,mtime=? WHERE path=?")
        val del = db.compileStatement("DELETE FROM files WHERE path=? OR substr(path,1,?)=?")

        fun removeTree(path: String) {
            val slash = "$path/"
            del.bindString(1, path)
            del.bindLong(2, slash.length.toLong())
            del.bindString(3, slash)
            del.executeUpdateDelete()
        }

        fun syncDir(dirPath: String) {
            val stored = dirMtimes[dirPath]
            val dir = File(dirPath)
            val cur = dir.lastModified()
            if (stored != null && stored == cur) return  // 子树未变，跳过
            val children = dir.listFiles() ?: run {
                if (stored != null && !dir.exists()) {
                    removeTree(dirPath)
                    removed++
                }
                return
            }
            val dbChildren = HashMap<String, Boolean>()
            db.rawQuery("SELECT path,is_dir FROM files WHERE parent=?", arrayOf(dirPath)).use { c ->
                while (c.moveToNext()) dbChildren[c.getString(0)] = c.getInt(1) == 1
            }
            db.beginTransaction()
            try {
                val nowPaths = HashSet<String>()
                for (ch in children) {
                    val p = ch.absolutePath
                    nowPaths.add(p)
                    val isDir = ch.isDirectory
                    if (!dbChildren.containsKey(p)) {
                        ins.bindString(1, p)
                        ins.bindString(2, dirPath)
                        ins.bindString(3, ch.name)
                        ins.bindLong(4, if (isDir) 1 else 0)
                        ins.bindLong(5, if (isDir) 0L else ch.length())
                        ins.bindLong(6, ch.lastModified())
                        ins.executeInsert()
                        added++
                    } else if (!isDir) {
                        upd.bindLong(1, ch.length())
                        upd.bindLong(2, ch.lastModified())
                        upd.bindString(3, p)
                        upd.executeUpdateDelete()
                        updated++
                    }
                }
                for ((p, _) in dbChildren) {
                    if (!nowPaths.contains(p)) {
                        removeTree(p)
                        removed++
                    }
                }
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
            for (ch in children) {
                if (ch.isDirectory) syncDir(ch.absolutePath)
            }
        }

        syncDir(fuseRoot)

        // root 区增量：只 stat 目录（数量远小于文件），mtime 变化的目录才重列子项
        for (area in rootAreas) {
            val (a, rm, u) = syncRootArea(area)
            added += a
            removed += rm
            updated += u
        }

        val r = Result(added, removed, updated, System.currentTimeMillis() - t0)
        Log.i("ViewFile/Sync", "sync done: +${r.added} -${r.removed} ~${r.updated} in ${r.elapsedMs}ms")
        return r
    }

    /**
     * root 区域的 mtime 对账：
     * 1) find -type d + stat 拿全部目录的当前 mtime（只碰目录，大区也不再全量重扫）
     * 2) 与库中不符/新增的目录 → 重新列出其直接子项并 diff
     * 3) 库里有、实际没有的目录 → 整树删除
     */
    private fun syncRootArea(area: Pair<String, String>): Triple<Int, Int, Int> {
        val (raw, display) = area
        var added = 0
        var removed = 0
        var updated = 0

        val dirMtimes = HashMap<String, Long>()
        val dSlash = "$display/"
        db.rawQuery(
            "SELECT path,mtime FROM files WHERE is_dir=1 AND (path=? OR substr(path,1,?)=?)",
            arrayOf(display, dSlash.length.toString(), dSlash)
        ).use { c ->
            while (c.moveToNext()) dirMtimes[c.getString(0)] = c.getLong(1)
        }

        val actual = HashMap<String, Long>(dirMtimes.size + 64)
        val dirRes = PrivShell.runStream(
            "find ${shq(raw)} -type d -print0 | xargs -0 -r stat -c '%n|%Y' 2>/dev/null"
        ) { line ->
            val i = line.lastIndexOf('|')
            if (i <= 0) return@runStream
            // %Y 是秒，库里统一存毫秒
            val mtime = (line.substring(i + 1).trim().toLongOrNull() ?: return@runStream) * 1000
            actual[RootScanner.toDisplay(line.substring(0, i))] = mtime
        }
        if (!dirRes.ok && dirRes.code == -1) {
            Log.w("ViewFile/Sync", "root area dir stat failed: ${dirRes.err.take(80)}")
            return Triple(0, 0, 0)
        }

        // 库中有但实际消失的目录 → 删除子树
        for (d in dirMtimes.keys) {
            if (!actual.containsKey(d)) {
                removeTree(d)
                removed++
            }
        }

        // mtime 变化或新增的目录 → 批量重列直接子项（合并 su 调用，避免逐目录起进程）
        // 单次上限：大 churn 下单次同步有界，剩余下次同步继续收敛
        val changedAll = actual.filter { dirMtimes[it.key] != it.value }.keys.toList()
        val changed = changedAll.take(MAX_RELIST_PER_SYNC)
        if (changedAll.size > changed.size) {
            Log.i("ViewFile/Sync", "area $display: changed=${changedAll.size}, " +
                    "this run=${changed.size} (rest converges next sync)")
        }
        db.beginTransaction()
        try {
            // 区域根自身保证存在
            db.execSQL(
                "INSERT OR IGNORE INTO files(path,parent,name,is_dir,size,mtime) VALUES(?,?,?,1,0,?)",
                arrayOf(display, display.substringBeforeLast('/').ifEmpty { "/" },
                    display.substringAfterLast('/'), (actual[display] ?: 0L).toString())
            )
            db.setTransactionSuccessful()
        } finally {
            try { db.endTransaction() } catch (_: IllegalStateException) {}
        }
        for (chunk in changed.chunked(300)) {
            val finds = chunk.joinToString(" ") {
                "find ${shq(RootScanner.toRaw(it))} -mindepth 1 -maxdepth 1 -print0;"
            }
            val res = PrivShell.run("($finds) | xargs -0 -r stat -c '%n|%F|%s|%Y' 2>/dev/null")
            if (!res.ok) continue
            val byParent = HashMap<String, HashMap<String, Triple<Boolean, Long, Long>>>()
            res.out.lineSequence().forEach { line ->
                val e = RootScanner.parseStatLine(line) ?: return@forEach
                val dp = RootScanner.toDisplay(e.rawPath)
                byParent.getOrPut(dp.substringBeforeLast('/').ifEmpty { "/" }) { HashMap() }[dp] =
                    Triple(e.isDir, e.size, e.mtimeMs)
            }
            db.beginTransaction()
            try {
                for ((parent, kids) in byParent) {
                    val cnt = diffChildren(parent, kids)
                    added += cnt.first
                    removed += cnt.second
                    updated += cnt.third
                }
                db.setTransactionSuccessful()
            } finally {
                try { db.endTransaction() } catch (_: IllegalStateException) {}
            }
        }
        return Triple(added, removed, updated)
    }

    /** 与库中某目录的直接子项 diff，返回 (新增, 删除, 更新) */
    private fun diffChildren(
        parent: String,
        nowKids: Map<String, Triple<Boolean, Long, Long>>
    ): Triple<Int, Int, Int> {
        var added = 0
        var removed = 0
        var updated = 0
        val dbChildren = HashMap<String, Boolean>()
        db.rawQuery("SELECT path,is_dir FROM files WHERE parent=?", arrayOf(parent)).use { c ->
            while (c.moveToNext()) dbChildren[c.getString(0)] = c.getInt(1) == 1
        }
        for ((p, v) in nowKids) {
            val known = dbChildren.containsKey(p)
            if (!known) {
                insertRow(p, parent, v.first, v.second, v.third)
                added++
            } else if (!v.first) {
                updateRow(p, v.second, v.third)
                updated++
            }
        }
        for (p in dbChildren.keys) {
            if (!nowKids.containsKey(p)) {
                removeTree(p)
                removed++
            }
        }
        return Triple(added, removed, updated)
    }


    private fun removeTree(path: String) {
        val slash = "$path/"
        db.execSQL(
            "DELETE FROM files WHERE path=? OR substr(path,1,?)=?",
            arrayOf(path, slash.length.toString(), slash)
        )
    }

    private fun insertRow(path: String, parent: String, isDir: Boolean, size: Long, mtime: Long) {
        db.execSQL(
            "INSERT OR IGNORE INTO files(path,parent,name,is_dir,size,mtime) VALUES(?,?,?,?,?,?)",
            arrayOf(path, parent, path.substringAfterLast('/'),
                (if (isDir) 1 else 0).toString(), size.toString(), mtime.toString())
        )
    }

    private fun updateRow(path: String, size: Long, mtime: Long) {
        db.execSQL("UPDATE files SET size=?,mtime=? WHERE path=?",
            arrayOf(size.toString(), mtime.toString(), path))
    }
}
