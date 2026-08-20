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

        // root 区整区刷新
        if (rootAreas.isNotEmpty()) {
            val w = IndexWriter(db, "files")
            w.beginTx()
            for ((raw, display) in rootAreas) {
                removeTree(display)
                RootScanner().scanInto(w, listOf(raw to display))
            }
            w.finishTx()
        }

        val r = Result(added, removed, updated, System.currentTimeMillis() - t0)
        Log.i("ViewFile/Sync", "sync done: +${r.added} -${r.removed} ~${r.updated} in ${r.elapsedMs}ms")
        return r
    }
}
