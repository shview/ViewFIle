import 'package:flutter/services.dart';

/// 原生引擎通道封装
class EngineApi {
  static const _m = MethodChannel('viewfile/engine');
  static const _scanEvents = EventChannel('viewfile/scan');

  Future<bool> hasPermission() async =>
      await _m.invokeMethod<bool>('hasPermission') ?? false;

  Future<void> requestPermission() => _m.invokeMethod('requestPermission');

  /// 检测 root（会触发系统的 root 授权框）
  Future<bool> hasRoot() async => await _m.invokeMethod<bool>('hasRoot') ?? false;

  Future<Map<dynamic, dynamic>> stats() async =>
      Map<dynamic, dynamic>.from(await _m.invokeMethod('stats'));

  Future<int> ensureIndexLoaded() async =>
      await _m.invokeMethod<int>('ensureIndexLoaded') ?? 0;

  Future<bool> needsRescan({bool rootIndex = true, bool systemIndex = false}) async =>
      await _m.invokeMethod<bool>('needsRescan', {
        'rootIndex': rootIndex,
        'systemIndex': systemIndex,
      }) ?? true;

  Future<void> startScan({bool rootIndex = true, bool systemIndex = false}) =>
      _m.invokeMethod('startScan', {
        'rootIndex': rootIndex,
        'systemIndex': systemIndex,
      });

  Future<List<Map<dynamic, dynamic>>> search(String query,
      {int limit = 200, List<String>? scopes}) async {
    final list = await _m.invokeMethod<List<dynamic>>('search', {
      'query': query,
      'limit': limit,
      if (scopes != null) 'scopes': scopes,
    });
    return list?.map((e) => Map<dynamic, dynamic>.from(e)).toList() ?? const [];
  }

  /// 已安装应用列表：{pkg, label, system}，非系统应用在前
  Future<List<Map<dynamic, dynamic>>> listApps() async {
    final list = await _m.invokeMethod<List<dynamic>>('listApps');
    return list?.map((e) => Map<dynamic, dynamic>.from(e)).toList() ?? const [];
  }

  /// 浏览目录：返回 {ok, entries} 或 {ok:false, error}
  Future<Map<String, dynamic>> listDir(String path) async =>
      Map<String, dynamic>.from(await _m.invokeMethod('listDir', {'path': path}));

  /// 打开（系统选择器）。返回 null=已发起，否则为错误信息
  Future<String?> open(List<String> paths) async =>
      await _m.invokeMethod<String>('open', {'paths': paths});

  /// 分享（单个 ACTION_SEND / 多个 ACTION_SEND_MULTIPLE）
  Future<String?> share(List<String> paths) async =>
      await _m.invokeMethod<String>('share', {'paths': paths});

  Future<Map<String, dynamic>> rename(String path, String newName) async =>
      Map<String, dynamic>.from(
          await _m.invokeMethod('rename', {'path': path, 'newName': newName}));

  Future<Map<String, dynamic>> delete(List<String> paths) async =>
      Map<String, dynamic>.from(
          await _m.invokeMethod('delete', {'paths': paths}));

  Stream<Map<dynamic, dynamic>> scanEvents() =>
      _scanEvents.receiveBroadcastStream().map((e) => Map<dynamic, dynamic>.from(e));
}
