package com.viewfile.viewfile

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.viewfile.viewfile.core.Engine
import com.viewfile.viewfile.core.FileOps
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
                        scanStartMs = System.currentTimeMillis()
                        Engine.scanAsync(
                            rootIndex, systemIndex, deepData,
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
                                        if (err != null) mapOf("type" to "error", "error" to err)
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
                        Engine.startWatcher(rootIndex, deepData) { m ->
                            main.post {
                                scanSink?.success(mapOf("type" to "synced") + m)
                            }
                        }
                        result.success(null)
                    }
                    "stopWatcher" -> {
                        Thread {
                            Engine.stopWatcher()  // 含同步 pkill（可能秒级），不能在主线程
                            main.post { result.success(null) }
                        }.start()
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
