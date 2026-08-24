import 'dart:io' as io;

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 压缩包虚拟路径支持：`/real/path/to.zip!/inner/sub`
/// zip 走 Dart archive 包（中央目录缓存）；rar 走自打包的 vfunrar NDK 二进制。
/// 打开/查看时才解压单个文件到缓存目录。
class VFArchives {
  VFArchives._();

  static const _maxCache = 3;
  // zipPath -> (name, size, mtime) 扁平条目（仅文件）
  static final _cache = <String, List<(String, int, int)>>{};

  static String? _nativeDir;
  static const _m = MethodChannel('viewfile/engine');

  static bool isVirtual(String path) => path.contains('!/');

  static bool isRarPath(String p) => p.toLowerCase().endsWith('.rar');

  /// 浏览模式可进入的压缩包（zip + rar）
  static bool isBrowsableArchive(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.zip') || n.endsWith('.rar');
  }

  static (String, String) splitVirtual(String path) {
    final i = path.indexOf('!/');
    return (path.substring(0, i), path.substring(i + 2));
  }

  /// rar 条目：vfunrar list 输出行 F|size|mtime|name / D|0|0|name
  static Future<List<(String, int, int)>?> _listRar(String rarPath) async {
    final dir = _nativeDir ??= await _m.invokeMethod<String>('nativeDir');
    if (dir == null) return null;
    final r = await io.Process.run('$dir/libvfunrar.so', ['list', rarPath])
        .timeout(const Duration(seconds: 30), onTimeout: () {
      return io.ProcessResult(1, 1, '', 'timeout');
    });
    final out = (r.stdout as String).trim();
    if (r.exitCode != 0 || out.isEmpty) return null;
    final entries = <(String, int, int)>[];
    for (final line in out.split('\n')) {
      final parts = line.split('|');
      if (parts.length < 4 || parts[0] != 'F') continue;
      final size = int.tryParse(parts[1]) ?? 0;
      final mtime = int.tryParse(parts[2]) ?? 0;
      entries.add((parts.sublist(3).join('|'), size, mtime));
    }
    return entries;
  }

  static Future<List<(String, int, int)>?> _entries(String zipPath) async {
    final hit = _cache.remove(zipPath);
    if (hit != null) {
      _cache[zipPath] = hit; // LRU 触碰
      return hit;
    }
    final list = isRarPath(zipPath)
        ? await _listRar(zipPath)
        : await _entriesZip(zipPath);
    if (list == null) return null;
    _cache[zipPath] = list;
    while (_cache.length > _maxCache) {
      _cache.remove(_cache.keys.first);
    }
    return list;
  }

  static Future<List<(String, int, int)>?> _entriesZip(String zipPath) async {
    final arc = await _openAsync(zipPath);
    if (arc == null) return null;
    return [
      for (final f in arc.files)
        if (f.isFile && !f.name.endsWith('/')) (f.name, f.size, f.lastModTime),
    ];
  }

  // decodeStream 是同步 IO，zip 大时可能卡帧，先用 Future.microtask 让出当前帧
  static Future<Archive?> _openAsync(String zipPath) async {
    try {
      return await Future.microtask(
          () => ZipDecoder().decodeStream(InputFileStream(zipPath)));
    } catch (_) {
      return null;
    }
  }

  /// 列出压缩包内某目录的直接子项，形状与引擎 listDir 条目一致
  static Future<List<Map<dynamic, dynamic>>> listDir(
      String zipPath, String inner) async {
    final entries = await _entries(zipPath);
    if (entries == null) return const [];
    final prefix = inner.isEmpty || inner == '/'
        ? ''
        : (inner.endsWith('/') ? inner : '$inner/');
    final dirs = <String>{};
    final files = <Map<dynamic, dynamic>>[];
    for (final (name, size, mtime) in entries) {
      if (name.isEmpty || !name.startsWith(prefix)) continue;
      final rest = name.substring(prefix.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash < 0) {
        files.add({
          'path': '$zipPath!/$prefix$rest',
          'name': rest,
          'isDir': false,
          'size': size,
          'mtime': mtime,
        });
      } else if (slash > 0) {
        dirs.add(rest.substring(0, slash));
      }
    }
    return [
      for (final d in dirs)
        {
          'path': '$zipPath!/$prefix$d',
          'name': d,
          'isDir': true,
          'size': 0,
          'mtime': 0,
        },
      ...files,
    ];
  }

  /// 解压单个文件到应用缓存目录，返回真实路径；失败返回 null
  static Future<String?> extractFile(String virtualPath) async {
    final (zipPath, inner) = splitVirtual(virtualPath);
    if (isRarPath(zipPath)) return _extractRar(zipPath, inner);
    try {
      final arc = await _openAsync(zipPath);
      if (arc == null) return null;
      for (final f in arc.files) {
        if (f.isFile && f.name == inner) {
          return await _writeTemp(zipPath, inner, f.content);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _extractRar(String rarPath, String inner) async {
    final dir = _nativeDir ??= await _m.invokeMethod<String>('nativeDir');
    if (dir == null) return null;
    final tmp = await getTemporaryDirectory();
    final outDir = io.Directory('${tmp.path}/viewfile_zip');
    await outDir.create(recursive: true);
    final safe = inner.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final dest = '${outDir.path}/${rarPath.hashCode}_$safe';
    final r = await io.Process.run(
        '$dir/libvfunrar.so', ['extract', rarPath, inner, dest])
        .timeout(const Duration(seconds: 120), onTimeout: () {
      return io.ProcessResult(1, 1, '', 'timeout');
    });
    return r.exitCode == 0 ? dest : null;
  }

  static Future<String> _writeTemp(
      String zipPath, String inner, List<int> bytes) async {
    final tmp = await getTemporaryDirectory();
    final dir = io.Directory('${tmp.path}/viewfile_zip');
    await dir.create(recursive: true);
    final safe = inner.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final out = io.File('${dir.path}/${zipPath.hashCode}_$safe');
    await out.writeAsBytes(bytes, flush: true);
    return out.path;
  }
}
