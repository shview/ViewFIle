package com.viewfile.viewfile

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.viewfile.viewfile.core.Engine
import com.viewfile.viewfile.core.FileOps
import com.viewfile.viewfile.core.Fs
import com.viewfile.viewfile.core.SearchIndex
import com.viewfile.viewfile.core.ShizukuShell
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var scanSink: EventChannel.EventSink? = null
    private var scanStartMs = 0L
    private val appIconCache = HashMap<String, ByteArray>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 必须先初始化 Engine；以下 channel handler 及其异步任务才允许访问 Engine.db。
        Engine.init(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "viewfile/engine")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(hasStoragePermission())
                    "requestPermission" -> { requestStoragePermission(); result.success(null) }
                    "hasRoot" -> Engine.refreshRootAsync { ok ->
                        main.post { result.success(ok) }
                    }
                    "hasShizuku" -> {
                        Thread {
                            val ok = ShizukuShell.getAvailable(refresh = true)
                            main.post { result.success(ok) }
                        }.start()
                    }
                    "shizukuBinderAlive" -> result.success(ShizukuShell.isBinderAlive())
                    "requestShizuku" -> {
                        result.success(ShizukuShell.requestPermission())
                    }
                    "stats" -> result.success(Engine.stats())
                    "ensureIndexLoaded" -> Engine.loadIndexAsync { n ->
                        main.post { result.success(n) }
                    }
                    "needsRescan" -> {
                        val rootIndex = call.argument<Boolean>("rootIndex") ?: true
                        val systemIndex = call.argument<Boolean>("systemIndex") ?: false
                        val deepData = call.argument<Boolean>("deepData") ?: false
                        Engine.needsRescanAsync(rootIndex, systemIndex, deepData) { need ->
                            main.post { result.success(need) }
                        }
                    }
                    "startScan" -> {
                        val rootIndex = call.argument<Boolean>("rootIndex") ?: true
                        val systemIndex = call.argument<Boolean>("systemIndex") ?: false
                        val deepData = call.argument<Boolean>("deepData") ?: false
                        val compactDb = call.argument<Boolean>("compactDb") ?: false
                        scanStartMs = System.currentTimeMillis()
                        Engine.scanAsync(
                            rootIndex, systemIndex, deepData, compactDb,
                            onProgress = { files, dirs, current ->
                                main.post {
                                    scanSink?.success(mapOf(
                                        "type" to "progress",
                                        "files" to files, "dirs" to dirs,
                                        "current" to current,
                                        "elapsedMs" to System.currentTimeMillis() - scanStartMs,
                                    ))
                                }
                            },
                            onDone = { r, err ->
                                main.post {
                                    scanSink?.success(
                                        if (err != null) mapOf(
                                            "type" to "error",
                                            "error" to err,
                                            "newIndexPublished" to false,
                                            "oldIndexRetained" to Engine.lastScanFailureRetainedOldIndex,
                                            "deepRequested" to deepData,
                                            "deepApplied" to false,
                                        )
                                        else mapOf(
                                            "type" to "done",
                                            "files" to r!!.files, "dirs" to r.dirs,
                                            "elapsedMs" to r.elapsedMs,
                                            "loadMs" to Engine.loadMs,
                                            "withRoot" to r.withRoot,
                                        )
                                    )
                                }
                            }
                        )
                        result.success(null)
                    }
                    "search" -> {
                        val q = call.argument<String>("query") ?: ""
                        val limit = call.argument<Int>("limit") ?: 200
                        val scopes = call.argument<List<String>>("scopes")
                            ?: call.argument<String>("scope")?.let { listOf(it) }
                        Engine.searchAsync(q, limit, scopes) { list ->
                            main.post { result.success(list.map { it.toMap() }) }
                        }
                    }
                    "listApps" -> {
                        Thread {
                            val t0 = System.currentTimeMillis()
                            val pm = packageManager
                            val apps = pm.getInstalledApplications(0)
                                .mapNotNull { ai ->
                                    try {
                                        val isSystem = (ai.flags and
                                                android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                                        mapOf<String, Any?>(
                                            "pkg" to ai.packageName,
                                            "label" to ai.loadLabel(pm).toString(),
                                            "system" to isSystem,
                                        )
                                    } catch (t: Throwable) {
                                        null
                                    }
                                }
                                .sortedWith(
                                    compareBy<Map<String, Any?>> { it["system"] as Boolean }
                                        .thenBy { (it["label"] as String).lowercase() }
                                )
                            android.util.Log.i("ViewFile/Apps",
                                "listApps: ${apps.size} in ${System.currentTimeMillis() - t0}ms")
                            main.post { result.success(apps) }
                        }.start()
                    }
                    "getAppIcon" -> {
                        val pkg = call.argument<String>("pkg") ?: ""
                        Thread {
                            val bytes = synchronized(appIconCache) { appIconCache[pkg] }
                                ?: try {
                                    drawableToPng(packageManager.getApplicationIcon(pkg), 96)
                                        .also { synchronized(appIconCache) { appIconCache[pkg] = it } }
                                } catch (t: Throwable) {
                                    null
                                }
                            main.post { result.success(bytes) }
                        }.start()
                    }
                    "listDir" -> {
                        val path = call.argument<String>("path") ?: "/"
                        Engine.listDirAsync(path) { m ->
                            main.post { result.success(m) }
                        }
                    }
                    "readText" -> {
                        val path = call.argument<String>("path") ?: ""
                        Engine.ioAsync({ m -> main.post { result.success(m) } }) {
                            Fs.readText(path)
                        }
                    }
                    "nativeDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "searchStart" -> {
                        val q = call.argument<String>("query") ?: ""
                        val scopes = call.argument<List<String>>("scopes")
                        val sortKey = call.argument<String>("sortKey") ?: "name"
                        val sortDesc = call.argument<Boolean>("sortDesc") ?: false
                        val category = call.argument<String>("category")
                        val hideDot = call.argument<Boolean>("hideDot") ?: false
                        val caseSensitive = call.argument<Boolean>("caseSensitive") ?: false
                        Engine.searchStartAsync(q, scopes, sortKey, sortDesc, category, hideDot, caseSensitive) { id, total, ms ->
                            main.post {
                                result.success(mapOf("id" to id, "total" to total, "elapsedMs" to ms))
                            }
                        }
                    }
                    "searchPage" -> {
                        val id = call.argument<Int>("id") ?: -1
                        val offset = call.argument<Int>("offset") ?: 0
                        val count = call.argument<Int>("count") ?: 300
                        Engine.searchPageAsync(id, offset, count) { list ->
                            main.post { result.success(list.map { it.toMap() }) }
                        }
                    }
                    "searchPaths" -> {
                        val id = call.argument<Int>("id") ?: -1
                        Engine.searchPathsAsync(id) { paths ->
                            main.post { result.success(paths ?: emptyList<String>()) }
                        }
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        Engine.opAsync({ m -> main.post { result.success(m) } }) {
                            FileOps.installApk(this@MainActivity, path)
                        }
                    }
                    "hashFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        val tInvoke = System.currentTimeMillis()
                        Engine.ioAsync({ m ->
                            main.post {
                                Log.i("ViewFile/Ops",
                                    "hash total=${System.currentTimeMillis() - tInvoke}ms op=${m["elapsedMs"]}ms")
                                result.success(m)
                            }
                        }) {
                            FileOps.hashFile(path) { done, total ->
                                main.post {
                                    scanSink?.success(mapOf(
                                        "type" to "hashProgress",
                                        "done" to done,
                                        "total" to total,
                                    ))
                                }
                            }
                        }
                    }
                    "hashHead" -> {
                        val path = call.argument<String>("path") ?: ""
                        Engine.ioAsync({ m -> main.post { result.success(m) } }) {
                            FileOps.hashHead(path)
                        }
                    }
                    "vacuum" -> {
                        val pageSize = call.argument<Int>("pageSize")
                        Engine.vacuumAsync(pageSize) { m ->
                            main.post { result.success(m) }
                        }
                    }
                    "startSync" -> {
                        val rootIndex = call.argument<Boolean>("rootIndex") ?: true
                        val deepData = call.argument<Boolean>("deepData") ?: false
                        Engine.syncAsync(rootIndex, deepData) { m ->
                            main.post { result.success(m) }
                        }
                    }
                    "startWatcher" -> {
                        val rootIndex = call.argument<Boolean>("rootIndex") ?: true
                        val deepData = call.argument<Boolean>("deepData") ?: false
                        val intent = call.argument<Number>("lifecycleIntent")?.toLong() ?: 0L
                        Engine.startWatcher(rootIndex, deepData, intent) { m ->
                            main.post {
                                scanSink?.success(mapOf("type" to "synced") + m)
                            }
                        }
                        result.success(null)
                    }
                    "stopWatcher" -> {
                        // stop 只做短状态更新并把清理投递到 watcher 后台协调器。
                        // 与同一 MethodChannel 上后续的 start 保持调用顺序，避免 pause/resume 丢监听。
                        val intent = call.argument<Number>("lifecycleIntent")?.toLong() ?: 0L
                        Engine.stopWatcher(intent)
                        result.success(null)
                    }
                    "open" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        result.success(if (paths.size == 1) FileOps.open(this, paths[0]) else "一次只能打开一个文件")
                    }
                    "share" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        result.success(FileOps.share(this, paths))
                    }
                    "rename" -> {
                        val path = call.argument<String>("path") ?: ""
                        val newName = call.argument<String>("newName") ?: ""
                        Engine.opAsync({ m -> main.post { result.success(m) } }) {
                            val err = FileOps.rename(Engine.db, path, newName)
                            if (err == null) mapOf("ok" to true) else mapOf("ok" to false, "error" to err)
                        }
                    }
                    "delete" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        Engine.opAsync({ m -> main.post { result.success(m) } }) {
                            val (ok, failed) = FileOps.delete(Engine.db, paths)
                            mapOf(
                                "ok" to failed.isEmpty(),
                                "deleted" to ok,
                                "failedCount" to failed.size,
                                "failed" to failed.take(5),
                                "error" to if (failed.isEmpty()) null
                                    else "部分项目删除失败（可能被占用或无权限）",
                            )
                        }
                    }
                    "mkdir" -> {
                        val path = call.argument<String>("path") ?: ""
                        Engine.ioAsync({ m -> main.post { result.success(m["ok"]) } }) {
                            val ok = try {
                                java.io.File(path).mkdirs()
                            } catch (_: Throwable) {
                                false
                            }
                            mapOf("ok" to ok)
                        }
                    }
                    "transfer" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        val destDir = call.argument<String>("destDir") ?: ""
                        val move = call.argument<Boolean>("move") ?: false
                        Engine.opAsync({ m -> main.post { result.success(m) } }) {
                            val (ok, failed) = FileOps.transfer(Engine.db, paths, destDir, move)
                            mapOf(
                                "ok" to failed.isEmpty(),
                                "succeeded" to ok,
                                "failedCount" to failed.size,
                                "failed" to failed.take(5),
                                "error" to if (failed.isEmpty()) null
                                    else "部分项目${if (move) "移动" else "复制"}失败",
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "viewfile/scan")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) { scanSink = events }
                override fun onCancel(args: Any?) { scanSink = null }
            })
    }

    private fun hasStoragePermission(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED

    private fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= 30) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName")
                )
            )
        } else {
            requestPermissions(arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE), 1)
        }
    }
}

private fun SearchIndex.Hit.toMap(): Map<String, Any?> {
    val ix = Engine.index
    val path = ix.pathOf(this)
    val name = ix.nameOf(this)
    val isDir = ix.isDirOf(this)
    val size = ix.sizeOf(this)
    val mtime = ix.mtimeOf(this)
    val st = if (isDir) ix.statsFor(path) else null
    return buildMap {
        put("path", path)
        put("name", name)
        put("isDir", isDir)
        put("size", size)
        put("mtime", mtime)
        if (st != null) {
            put("dirCount", st.direct)
            put("dirSize", st.recSize)
        }
    }
}

private fun drawableToPng(d: android.graphics.drawable.Drawable, sizePx: Int): ByteArray {
    val bmp = if (d is android.graphics.drawable.BitmapDrawable && d.bitmap != null) {
        android.graphics.Bitmap.createScaledBitmap(d.bitmap, sizePx, sizePx, true)
    } else {
        val b = android.graphics.Bitmap.createBitmap(sizePx, sizePx, android.graphics.Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(b)
        d.setBounds(0, 0, sizePx, sizePx)
        d.draw(c)
        b
    }
    val out = java.io.ByteArrayOutputStream()
    bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 90, out)
    return out.toByteArray()
}
