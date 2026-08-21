package com.viewfile.viewfile.core

import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.ArrayDeque

/**
 * 文件操作：打开/分享（只读，走 FileProvider）；
 * 重命名/删除（写操作，调用方必须已经过 UI 二次确认）。
 * 所有 DB 同步都用 substr 前缀精确匹配（避免 LIKE 通配符歧义与误删兄弟目录）。
 */
object FileOps {
    private const val TAG = "ViewFile/Ops"

    // ---------- 只读操作 ----------

    fun open(context: Context, path: String): String? {
        val f = File(path)
        if (!f.isFile) return "无法打开（不是常规文件）"
        if (!f.canRead()) {
            return "该文件位于系统保护区域（如 Android/data），暂不支持直接打开；" +
                    "可先在浏览中复制到可见区域"
        }
        return try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uriFor(context, f), mimeOf(f))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "选择打开方式"))
            null
        } catch (t: Throwable) {
            "没有应用可以打开它：${t.message}"
        }
    }

    fun share(context: Context, paths: List<String>): String? {
        val files = paths.map(::File).filter { it.isFile && it.canRead() }
        if (files.size < paths.size) {
            return "部分文件位于系统保护区域，暂不支持分享"
        }
        if (files.isEmpty()) return "没有可分享的文件"
        return try {
            val uris = ArrayList<Uri>(files.map { uriFor(context, it) })
            val intent = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    type = mimeOf(files[0])
                    putExtra(Intent.EXTRA_STREAM, uris[0])
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = "*/*"
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                }
            }
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            context.startActivity(Intent.createChooser(intent, "分享"))
            null
        } catch (t: Throwable) {
            "分享失败：${t.message}"
        }
    }

    // ---------- 写操作（需 UI 确认） ----------

    /** 返回 null=成功，否则为错误信息。应用 UID 失败时可安全回退特权 helper。 */
    fun rename(db: SQLiteDatabase, path: String, newName: String): String? {
        val old = File(path)
        val clean = newName.trim()
        if (clean.isEmpty() || clean.contains('/')) return "文件名不合法"
        val tier = PrivShell.tier()
        val oldVisible = existsNoFollow(old)
        if (!oldVisible && tier == PrivShell.Tier.NONE) {
            return "文件不存在（可能已被移动）"
        }
        if (old.name == clean) return null
        val target = File(old.parentFile, clean)
        if (existsNoFollow(target)) return "已存在同名项目"

        val helper = Engine.nativeHelperPath()
            ?: return "重命名失败（原生安全重命名组件缺失）"

        // 普通可见路径也必须使用内核原子 RENAME_NOREPLACE。ProcessBuilder 传参数
        // 数组，不经过 shell，路径中的空格、引号和元字符不会被重新解释。
        var renamed = false
        var canRetryPrivileged = !oldVisible
        if (oldVisible) {
            val direct = try {
                ShellProcessRunner.run(
                    ProcessBuilder(*NativeRenameProtocol.arguments(
                        helper, old.absolutePath, target.absolutePath
                    ).toTypedArray()).start(),
                    15000
                )
            } catch (t: Throwable) {
                SuShell.Result(-1, "", t.message ?: t.toString())
            }
            when (NativeRenameProtocol.decideDirectResult(
                direct.code, existsNoFollow(old)
            )) {
                NativeRenameProtocol.DirectDecision.SUCCESS -> renamed = true
                NativeRenameProtocol.DirectDecision.CONFLICT -> return "已存在同名项目"
                NativeRenameProtocol.DirectDecision.RETRY_PRIVILEGED ->
                    canRetryPrivileged = true
                NativeRenameProtocol.DirectDecision.UNCERTAIN ->
                    return "重命名结果不确定（源路径已变化，请刷新后确认）"
            }
        }
        if (!renamed && canRetryPrivileged && tier != PrivShell.Tier.NONE) {
            val rawOld = RootScanner.toRaw(old.absolutePath)
            val rawNew = RootScanner.toRaw(target.absolutePath)
            if (PrivShell.needsRealRoot(rawOld) && tier != PrivShell.Tier.ROOT) {
                return "该位置只有真正的 root 才能修改（Shizuku 不够）"
            }
            // Android 8-10 toybox mv 没有可靠的 -T；调用随 APK 打包的 native
            // helper，以 renameat2(RENAME_NOREPLACE) 在内核中原子完成冲突判定。
            val r = PrivShell.run(NativeRenameProtocol.command(helper, rawOld, rawNew))
            if (!r.ok) return NativeRenameProtocol.errorMessage(r.code)
            renamed = r.ok
        }
        if (!renamed) return "重命名失败（存储权限或跨区限制）"

        // v3 结构：重命名只改一行 name（后代经 parent_id 链天然正确）
        val id = rowId(db, old.absolutePath)
        if (id != null) {
            db.execSQL("UPDATE entry SET name=? WHERE id=?", arrayOf(clean, id.toString()))
        }
        Log.i(TAG, "renamed ${old.absolutePath} -> ${target.absolutePath}")
        return null
    }

    private fun existsNoFollow(file: File): Boolean =
        Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)

    /** 返回 (成功数, 失败路径列表)。FUSE 失败时回退 root rm */
    fun delete(db: SQLiteDatabase, paths: List<String>): Pair<Int, List<String>> {
        var deleted = 0
        val failed = mutableListOf<String>()
        for (p in paths) {
            if (deleteOne(db, p)) deleted++ else failed.add(p)
        }
        Log.i(TAG, "delete: ok=$deleted failed=${failed.size}")
        return deleted to failed
    }

    private fun deleteOne(db: SQLiteDatabase, p: String): Boolean {
        val f = File(p)
        if (f.exists()) {
            if (deleteRecursively(f)) {
                removeRows(db, p)
                return true
            }
        } else if (PrivShell.tier() == PrivShell.Tier.NONE) {
            removeRows(db, p)  // 文件已不在且无特权后端，清掉索引即可
            return true
        }
        if (PrivShell.tier() != PrivShell.Tier.NONE) {
            val raw = RootScanner.toRaw(p)
            if (PrivShell.needsRealRoot(raw) && PrivShell.tier() != PrivShell.Tier.ROOT) {
                return false  // 只有真 root 能删的位置
            }
            if (PrivShell.run("rm -rf ${shq(raw)}").ok && !File(raw).exists()) {
                removeRows(db, p)
                return true
            }
        }
        return false
    }

    private fun deleteRecursively(root: File): Boolean {
        // 先收全部后代（深前浅后），再从叶子往上删
        val stack = ArrayDeque<File>()
        val ordered = ArrayDeque<File>()
        stack.push(root)
        while (stack.isNotEmpty()) {
            val d = stack.pop()
            ordered.push(d)
            d.listFiles()?.let { stack.addAll(it) }
        }
        var ok = true
        for (f in ordered) {
            if (!f.delete() && f.exists()) ok = false
        }
        return ok
    }

    private fun removeRows(db: SQLiteDatabase, path: String) {
        val id = rowId(db, path) ?: return
        val isDir = Engine.index.containsDir(path)
        if (isDir) {
            Db.deleteSubtree(db, id)
            Engine.index.pruneDirMaps(path)
        } else {
            db.execSQL("DELETE FROM entry WHERE id=?", arrayOf(id.toString()))
        }
    }

    /** 由路径解析 entry.id：目录走内存 dirIds，文件按 (parent_id,name) 查 */
    private fun rowId(db: SQLiteDatabase, path: String): Long? {
        Engine.index.dirId(path)?.let { return it }
        val parent = path.substringBeforeLast('/').ifEmpty { "/" }
        val pid = Engine.index.dirId(parent) ?: return null
        return db.rawQuery(
            "SELECT id FROM entry WHERE parent_id=? AND name=?",
            arrayOf(pid.toString(), path.substringAfterLast('/'))
        ).use { c -> if (c.moveToFirst()) c.getLong(0) else null }
    }

    // ---------- 工具 ----------

    private fun uriFor(context: Context, f: File): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", f)

    fun mimeOf(f: File): String {
        val ext = f.extension.lowercase()
        val mapped = android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(ext)
        return when {
            mapped != null -> mapped
            ext == "apk" || ext == "xapk" || ext == "apks" -> "application/vnd.android.package-archive"
            ext == "zip" -> "application/zip"
            ext == "txt" || ext == "log" || ext == "md" -> "text/plain"
            else -> "application/octet-stream"
        }
    }
}
