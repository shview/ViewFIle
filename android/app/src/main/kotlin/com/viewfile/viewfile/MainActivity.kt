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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var scanSink: EventChannel.EventSink? = null
    private var scanStartMs = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Engine.init(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "viewfile/engine")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(hasStoragePermission())
                    "requestPermission" -> { requestStoragePermission(); result.success(null) }
                    "hasRoot" -> result.success(Engine.refreshRoot())
                    "stats" -> result.success(Engine.stats())
                    "ensureIndexLoaded" -> Engine.loadIndexAsync { n ->
                        main.post { result.success(n) }
                    }
                    "needsRescan" -> {
                        val rootIndex = call.argument<Boolean>("rootIndex") ?: true
                        val systemIndex = call.argument<Boolean>("systemIndex") ?: false
                        result.success(Engine.needsRescan(rootIndex, systemIndex))
                    }
                    "startScan" -> {
                        val rootIndex = call.argument<Boolean>("rootIndex") ?: true
                        val systemIndex = call.argument<Boolean>("systemIndex") ?: false
                        scanStartMs = System.currentTimeMillis()
                        Engine.scanAsync(
                            rootIndex, systemIndex,
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
                        val scope = call.argument<String>("scope")
                        Engine.searchAsync(q, limit, scope) { list ->
                            main.post { result.success(list.map { it.toMap() }) }
                        }
                    }
                    "listDir" -> {
                        val path = call.argument<String>("path") ?: "/"
                        Engine.listDirAsync(path) { m ->
                            main.post { result.success(m) }
                        }
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

private fun SearchIndex.Entry.toMap() = mapOf(
    "path" to path, "name" to name, "isDir" to isDir, "size" to size, "mtime" to mtime,
)
