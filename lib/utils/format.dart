import 'package:flutter/material.dart';

String fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String fmtDate(int msSinceEpoch) {
  if (msSinceEpoch <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(msSinceEpoch);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// 按扩展名给出人类可读类型 + 图标 + 颜色
(String, IconData, Color?) describe(String name, bool isDir) {
  if (isDir) return ('文件夹', Icons.folder, Colors.amber);
  final dot = name.lastIndexOf('.');
  final ext = dot >= 0 && dot < name.length - 1
      ? name.substring(dot + 1).toLowerCase()
      : '';
  if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'heic', 'heif', 'avif'}.contains(ext)) {
    return ('图片', Icons.image, Colors.deepPurpleAccent);
  }
  if (const {'mp4', 'mkv', 'avi', 'mov', 'webm', '3gp', 'flv', 'ts', 'm4v'}.contains(ext)) {
    return ('视频', Icons.movie, Colors.orangeAccent);
  }
  if (const {'mp3', 'flac', 'wav', 'ogg', 'm4a', 'aac', 'opus', 'amr'}.contains(ext)) {
    return ('音频', Icons.audiotrack, Colors.greenAccent);
  }
  if (const {'apk', 'xapk', 'apks'}.contains(ext)) {
    return ('安装包', Icons.android, Colors.tealAccent);
  }
  if (const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'lz4', 'zst'}.contains(ext)) {
    return ('压缩包', Icons.folder_zip, Colors.brown);
  }
  if (const {'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'pdf', 'csv'}.contains(ext)) {
    return ('文档', Icons.description, Colors.blueAccent);
  }
  if (const {'txt', 'log', 'md', 'json', 'xml', 'html', 'htm', 'yaml', 'yml', 'ini', 'conf', 'sh'}.contains(ext)) {
    return ('文本', Icons.article, Colors.lightBlueAccent);
  }
  if (const {'iso', 'img'}.contains(ext)) {
    return ('镜像', Icons.album, Colors.blueGrey);
  }
  return ('文件', Icons.insert_drive_file, null);
}
