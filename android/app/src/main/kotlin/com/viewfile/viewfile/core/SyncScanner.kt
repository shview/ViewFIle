package com.viewfile.viewfile.core

import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

/**
 * 增量同步 v3：按 (parent_id, name) 语义对账。
 * - FUSE 区：递归走完整 File 目录树，mtime 未变仅跳过当前层对账；
 * - root 区：find -type d 只 stat 目录，变化目录批量重列直接子项；
 * - 删除用递归 CTE 整树删除；路径 → id 依赖内存 dirIds（载入时构建）。
 */
class SyncScanner(
    private val db: SQLiteDatabase,
    private val index: SearchIndex
) {
    data class AreaResult(
        val area: String,
        val added: Int,
        val removed: Int,
        val updated: Int,
        val dirAddedRemoved: Int,
        val deferredDirs: Int,
        val processingOk: Boolean,
        val massDeleteGuarded: Boolean,
        val elapsedMs: Long,
        val ok: Boolean,
    )

    class Result(
        val added: Int,
        val removed: Int,
        val updated: Int,
        val elapsedMs: Long,
        val dirAddedRemoved: Int,
        val fuseElapsedMs: Long,
        val fuseOk: Boolean,
        val rootAreas: List<AreaResult>,
    ) {
        val directoryChanged: Boolean get() = directorySetChanged(dirAddedRemoved)
        val rootDeferredDirs: Int get() = rootAreas.sumOf { it.deferredDirs }
        val canAutoContinueRoot: Boolean get() = shouldAutoContinueRoot(rootAreas.map {
            RootContinuationState(it.deferredDirs, it.processingOk)
        })
    }

    /** 引擎侧扫描请求探针：同步各阶段检查，true 则中止本轮（Engine.scanAsync 置位） */
    @Volatile
    var scanRequestedBridge: (() -> Boolean)? = null

    private class Child(val name: String, val isDir: Boolean, val size: Long, val mtime: Long)
    private data class RootAreaOutcome(
        val processingOk: Boolean,
        val deferredDirs: Int,
        val massDeleteGuarded: Boolean = false,
    ) {
        val complete: Boolean get() = processingOk && deferredDirs == 0
    }

    private var added = 0
    private var removed = 0
    private var updated = 0
    private var dirAddedRemoved = 0
    private var fuseElapsedMs = 0L
    private var fuseOk = false
    private val areaResults = ArrayList<AreaResult>()

    companion object {
        private const val MAX_RELIST_PER_SYNC = 2000
        /** 内部控制流：同步让位给扫描请求（不视为错误） */
        private val SCAN_YIELD = RuntimeException("__scan_yield__")
    }

    fun sync(fuseRoot: String, rootAreas: List<Area>, skipSubtrees: Set<String> = emptySet()): Result {
        val t0 = System.currentTimeMillis()
        added = 0; removed = 0; updated = 0; dirAddedRemoved = 0
        fuseElapsedMs = 0L; fuseOk = false; areaResults.clear()
        if (scanRequestedBridge?.invoke() == true) return abortedResult(t0)
        val fuseStart = System.currentTimeMillis()
        try {
            fuseOk = syncDirFuse(File(fuseRoot), skipSubtrees)
        } catch (t: Throwable) {
            Log.w("ViewFile/Sync", "fuse walk failed: ${t.message}")
        } finally {
            fuseElapsedMs = System.currentTimeMillis() - fuseStart
            Log.i("ViewFile/Sync", "fuse ${if (fuseOk) "ok" else "failed"} in ${fuseElapsedMs}ms")
        }
        for (area in rootAreas) {
            if (scanRequestedBridge?.invoke() == true) return abortedResult(t0)
            val areaStart = System.currentTimeMillis()
            val a0 = added; val r0 = removed; val u0 = updated; val d0 = dirAddedRemoved
            var outcome = RootAreaOutcome(processingOk = false, deferredDirs = 0)
            try {
                outcome = syncRootArea(area)
            } catch (t: Throwable) {
                if (t === SCAN_YIELD) return abortedResult(t0)
                Log.w("ViewFile/Sync", "root area ${area.display} failed: ${t.message}")
            }
            val areaResult = AreaResult(
                area.display, added - a0, removed - r0, updated - u0,
                dirAddedRemoved - d0, outcome.deferredDirs, outcome.processingOk,
                outcome.massDeleteGuarded,
                System.currentTimeMillis() - areaStart, outcome.complete)
            areaResults.add(areaResult)
            Log.i("ViewFile/Sync", "root area ${area.display} " +
                    "${if (areaResult.ok) "ok" else if (outcome.processingOk) "deferred" else "failed"}: " +
                    "+${areaResult.added} -${areaResult.removed} ~${areaResult.updated}, " +
                    "dirs=${areaResult.dirAddedRemoved}, deferred=${areaResult.deferredDirs} " +
                    "guarded=${areaResult.massDeleteGuarded} " +
                    "in ${areaResult.elapsedMs}ms")
        }
        val r = result(t0)
        Log.i("ViewFile/Sync", "sync done: +${r.added} -${r.removed} ~${r.updated}, " +
                "dirs=${r.dirAddedRemoved} in ${r.elapsedMs}ms")
        return r
    }

    // ---------- FUSE 区 ----------

    private fun syncDirFuse(
        dir: File,
        skipSubtrees: Set<String>,
        forceRelist: Boolean = false,
    ): Boolean {
        val path = dir.absolutePath
        if (path in skipSubtrees) return true // 由 root 管道覆盖，计划内跳过不是失败
        val listed = dir.listFiles()
        if (!fuseListingAvailable(listed)) return false
        val children = listed!!
        val stored = index.dirMtime(path)
        val cur = dir.lastModified()
        var newDirs: Set<String> = emptySet()
        if (shouldDiffFuseDirectory(stored, cur, forceRelist)) {
            val pid = index.dirId(path) ?: return false // 对账链不完整
            newDirs = diffChildren(path, pid, children.map {
                Child(it.name, it.isDirectory,
                    if (it.isDirectory) 0L else it.length(), it.lastModified())
            })
            // diffChildren 抛异常时不会到达此处，旧 mtime（新行为 0）保留供下轮重试。
            if (shouldCommitFuseMtime(FuseMtimeStage.DIFF_SUCCEEDED)) {
                commitDirMtime(path, cur)
            }
        }
        // Android/FUSE 不保证深层变化会更新所有祖先 mtime。即使当前层无需 diff，
        // 也必须下钻一次，才能到达真正变化的父目录。children 已在本层只读取一次。
        var complete = true
        for (c in children) {
            if (c.isDirectory) {
                // diffChildren 已记录新目录的当前 mtime；若不强制首轮重列，递归会
                // 立即命中“mtime 未变”剪枝，从而永久漏掉目录中已有的内容。
                val childComplete = syncDirFuse(c, skipSubtrees, c.absolutePath in newDirs)
                complete = combineFuseTraversalResult(complete, childComplete)
            }
        }
        return complete
    }

    // ---------- root 区 ----------

    private fun inArea(p: String, area: String) = p == area || p.startsWith("$area/")

    private fun abortedResult(t0: Long): Result {
        Log.i("ViewFile/Sync", "sync yielded to scan request")
        return result(t0)
    }

    private fun result(t0: Long) = Result(
        added, removed, updated, System.currentTimeMillis() - t0,
        dirAddedRemoved, fuseElapsedMs, fuseOk, areaResults.toList())

    private fun syncRootArea(area: Area): RootAreaOutcome {
        val display = area.display
        val depthArg = if (area.depth > 0) " -maxdepth ${area.depth}" else ""
        val actual = HashMap<String, Long>()
        val res = PrivShell.runStream(
            "find ${shq(area.raw)}$depthArg -type d " +
                    "-exec stat -c '%n|%Y' '{}' + 2>/dev/null"
        ) { line ->
            val i = line.lastIndexOf('|')
            if (i <= 0) return@runStream
            val mtime = (line.substring(i + 1).trim().toLongOrNull() ?: return@runStream) * 1000
            actual[RootScanner.toDisplay(line.substring(0, i))] = mtime
        }
        // 管道失败（rc≠0）：结果不可信，本区整体跳过——既不删也不重列。
        // 曾因部分失败误删 15.5 万条（find 部分输出被当成"目录已消失"）
        if (!res.ok) {
            Log.w("ViewFile/Sync", "area $display dir-stat rc=${res.code}, skip area")
            return RootAreaOutcome(processingOk = false, deferredDirs = 0)
        }

        // 库里有、实际没有 → 整树删除。
        // 大规模删除守卫：超过已知量 1/5 或绝对值 2000 视为管道异常（部分输出），
        // 本轮不删，留给全量重建收敛
        val toDelete = ArrayList<String>()
        var knownInArea = 0
        for (p in index.directoryPaths()) {
            if (!inArea(p, display)) continue
            knownInArea++
            if (!actual.containsKey(p)) toDelete.add(p)
        }
        var massDeleteGuarded = false
        if (shouldGuardRootMassDelete(toDelete.size, knownInArea)) {
            Log.w("ViewFile/Sync",
                "area $display: suspect mass delete ${toDelete.size}/$knownInArea, skip deletions")
            toDelete.clear()
            massDeleteGuarded = true
        }
        for (p in toDelete) {
            val id = index.dirId(p) ?: continue
            deleteDirectorySubtree(id)
            index.pruneDirMaps(p)
        }

        // 先计划再写 mtime：pending 目录只补行/父链，保留旧 mtime（新行为 0）。
        // 否则超过单轮上限或 chunk 失败的目录下轮会被误判为无变化。
        val sortedActual = actual.entries.sortedWith(
            compareBy<Map.Entry<String, Long>> { it.key.length }.thenBy { it.key })
        val changedDirs = sortedActual.filter { index.dirMtime(it.key) != it.value }
            .map { it.key }
        val plan = planRootRelists(changedDirs, display, area.depth, MAX_RELIST_PER_SYNC)
        for ((p, m) in sortedActual) {
            val disposition = plan.disposition(p)
            val commitNow = disposition == null || shouldCommitRootMtime(disposition, false)
            if (commitNow) ensureDir(p, m) else ensureDir(p, 0, update = false)
        }
        if (plan.deferred.isNotEmpty()) {
            Log.i("ViewFile/Sync", "area $display: changed=${changedDirs.size}, " +
                    "this run=${plan.selected.size}, deferred=${plan.deferred.size}")
        }
        var allRelistsOk = true
        for (chunk in plan.selected.chunked(300)) {
            if (scanRequestedBridge?.invoke() == true) throw SCAN_YIELD
            // 每个 find 自己批量 stat，并用 && 串联：任一目录重列失败都会成为
            // 整体非零 rc，本 chunk 全部丢弃，不采用部分输出。
            val finds = chunk.joinToString(" && ") {
                "find ${shq(RootScanner.toRaw(it))} -mindepth 1 -maxdepth 1 " +
                        "-exec stat -c '%n|%F|%s|%Y' '{}' +"
            }
            val r = PrivShell.run("($finds) 2>/dev/null")
            if (!r.ok) {
                allRelistsOk = false
                continue
            }
            val parsedChildren = ArrayList<Pair<String, Child>>()
            r.out.lineSequence().forEach { line ->
                val e = RootScanner.parseStatLine(line) ?: return@forEach
                val dp = RootScanner.toDisplay(e.rawPath)
                val parent = dp.substringBeforeLast('/').ifEmpty { "/" }
                parsedChildren.add(parent to
                        Child(dp.substringAfterLast('/'), e.isDir, e.size, e.mtimeMs))
            }
            // chunk 成功后每个请求父目录都参与 diff；无输出即空目录，必须清掉旧子项。
            val byParent = groupRelistedChildren(chunk, parsedChildren)
            var chunkComplete = true
            for ((parent, kids) in byParent) {
                val pid = index.dirId(parent)
                if (pid == null) {
                    chunkComplete = false
                    break
                }
                diffChildren(parent, pid, kids)
            }
            if (!chunkComplete) {
                allRelistsOk = false
                continue
            }
            // 只有 shell 和整个 chunk 的 diff 都成功才提交 mtime。
            if (shouldCommitRootMtime(RootMtimeDisposition.SELECTED, chunkComplete)) {
                for (parent in chunk) commitDirMtime(parent, actual.getValue(parent))
            }
        }
        return RootAreaOutcome(
            processingOk = allRelistsOk && !massDeleteGuarded,
            deferredDirs = plan.deferred.size,
            massDeleteGuarded = massDeleteGuarded,
        )
    }

    /**
     * 保证目录行存在；[update]=true 时目标目录 mtime 变化则更新。
     * 补祖先（update=false）绝不写 mtime——否则会把祖先的真实 mtime 清零，
     * 造成“永远变化”的死循环（v3 初版线上 bug）。
     */
    private fun ensureDir(path: String, mtime: Long, update: Boolean = true): Long {
        val known = index.dirId(path)
        if (known != null) {
            if (update && index.dirMtime(path) != mtime) {
                db.execSQL("UPDATE entry SET mtime=? WHERE id=?",
                    arrayOf(mtime.toString(), known.toString()))
                index.markDir(path, known, mtime)
            }
            return known
        }
        if (path == "/" || path.isEmpty()) return 0L
        val parent = path.substringBeforeLast('/').ifEmpty { "/" }
        val pid = if (parent == path) 0L else ensureDir(parent, 0, update = false)
        // 先查 DB (parent_id, name) 防平行链：ensureDir 的内存映射 miss 不代表库里没有
        val name = path.substringAfterLast('/')
        val existing = db.rawQuery(
            "SELECT id,mtime FROM entry WHERE parent_id=? AND name=? AND type=1",
            arrayOf(pid.toString(), name)).use { c ->
                if (c.moveToFirst()) c.getLong(0) to c.getLong(1) else -1L to 0L
            }
        if (existing.first != -1L) {
            val indexedMtime = if (update) {
                if (existing.second != mtime) {
                    db.execSQL("UPDATE entry SET mtime=? WHERE id=?",
                        arrayOf(mtime.toString(), existing.first.toString()))
                }
                mtime
            } else existing.second
            index.markDir(path, existing.first, indexedMtime)
            return existing.first
        }
        val inserted = insertEntry(pid, name, true, 0, mtime)
        if (inserted.id == -1L) return -1L
        index.markDir(path, inserted.id, mtime)
        if (inserted.inserted) {
            added++
            dirAddedRemoved++
        }
        return inserted.id
    }

    private fun commitDirMtime(path: String, mtime: Long) {
        val id = index.dirId(path) ?: return
        if (index.dirMtime(path) == mtime) return
        db.execSQL("UPDATE entry SET mtime=? WHERE id=?",
            arrayOf(mtime.toString(), id.toString()))
        index.markDir(path, id, mtime)
    }

    // ---------- 公共 ----------

    /** 对账直接子项，并返回本轮新插入的目录路径（调用方须对它们做首次下钻）。 */
    private fun diffChildren(parentPath: String, pid: Long, kids: List<Child>): Set<String> {
        val newDirs = HashSet<String>()
        val dbChildren = HashMap<String, Pair<Long, Boolean>>() // name -> (id, isDir)
        db.rawQuery("SELECT name,id,type FROM entry WHERE parent_id=?", arrayOf(pid.toString()))
            .use { c ->
                while (c.moveToNext()) dbChildren[c.getString(0)] = c.getLong(1) to (c.getInt(2) == 1)
            }
        val kidNames = HashSet<String>(kids.size)
        for (k in kids) {
            kidNames.add(k.name)
            val known = dbChildren[k.name]
            if (known == null) {
                val storedMtime = if (k.isDir) 0L else k.mtime
                val inserted = insertEntry(pid, k.name, k.isDir, k.size, storedMtime)
                if (inserted.id != -1L) {
                    if (k.isDir) {
                        val childPath = "$parentPath/${k.name}"
                        index.markDir(childPath, inserted.id, 0L)
                        newDirs.add(childPath)
                    }
                    if (inserted.inserted) {
                        added++
                        if (k.isDir) dirAddedRemoved++
                    }
                }
            } else if (known.second != k.isDir) {
                // 同名节点在文件/目录之间变更也会改变 watch 集合。
                val childPath = "$parentPath/${k.name}"
                if (known.second) {
                    deleteDirectorySubtree(known.first)
                    index.pruneDirMaps(childPath)
                } else {
                    db.execSQL("DELETE FROM entry WHERE id=?", arrayOf(known.first.toString()))
                    removed++
                }
                val storedMtime = if (k.isDir) 0L else k.mtime
                val inserted = insertEntry(pid, k.name, k.isDir, k.size, storedMtime)
                if (inserted.id != -1L && inserted.inserted) {
                    added++
                    if (k.isDir) {
                        index.markDir(childPath, inserted.id, 0L)
                        newDirs.add(childPath)
                        dirAddedRemoved++
                    }
                }
            } else if (!k.isDir) {
                db.execSQL("UPDATE entry SET size=?,mtime=? WHERE id=?",
                    arrayOf(k.size.toString(), k.mtime.toString(), known.first.toString()))
                updated++
            }
        }
        for ((name, meta) in dbChildren) {
            if (kidNames.contains(name)) continue
            if (meta.second) {
                deleteDirectorySubtree(meta.first)
                index.pruneDirMaps("$parentPath/$name")
            } else {
                db.execSQL("DELETE FROM entry WHERE id=?", arrayOf(meta.first.toString()))
                removed++
            }
        }
        return newDirs
    }

    private data class InsertResult(val id: Long, val inserted: Boolean)

    private fun insertEntry(
        pid: Long, name: String, isDir: Boolean, size: Long, mtime: Long
    ): InsertResult {
        val st = db.compileStatement(
            "INSERT OR IGNORE INTO entry(parent_id,name,type,size,mtime) VALUES(?,?,?,?,?)")
        st.bindLong(1, pid)
        st.bindString(2, name)
        st.bindLong(3, if (isDir) 1 else 0)
        st.bindLong(4, size)
        st.bindLong(5, mtime)
        val id = st.executeInsert()
        if (id == -1L) {
            // 已存在（罕见路径交叠）：查回现有 id
            val existing = db.rawQuery("SELECT id FROM entry WHERE parent_id=? AND name=?",
                arrayOf(pid.toString(), name)).use {
                    c -> if (c.moveToFirst()) c.getLong(0) else -1L
                }
            return InsertResult(existing, false)
        }
        return InsertResult(id, true)
    }

    /** 在删除前统计子树中的目录数，不把文件数误当成 watcher 变化。 */
    private fun deleteDirectorySubtree(id: Long) {
        val counts = db.rawQuery(
            "WITH RECURSIVE sub(id,type) AS (" +
                    "SELECT id,type FROM entry WHERE id=? UNION ALL " +
                    "SELECT e.id,e.type FROM entry e JOIN sub s ON e.parent_id=s.id) " +
                    "SELECT COUNT(*),COALESCE(SUM(CASE WHEN type=1 THEN 1 ELSE 0 END),0) FROM sub",
            arrayOf(id.toString())
        ).use { c ->
            if (c.moveToFirst()) c.getInt(0) to c.getInt(1) else 0 to 0
        }
        if (counts.first == 0) return
        removed += Db.deleteSubtree(db, id)
        dirAddedRemoved += counts.second
    }
}
