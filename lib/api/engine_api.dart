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

  /// 检测 Shizuku（已授权返回 true；binder 活着但未授权返回 false）
  Future<bool> hasShizuku() async =>
      await _m.invokeMethod<bool>('hasShizuku') ?? false;

  /// Shizuku 服务是否在运行（用于区分“未启动”和“未授权”）
  Future<bool> shizukuBinderAlive() async =>
      await _m.invokeMethod<bool>('shizukuBinderAlive') ?? false;

  /// 发起 Shizuku 授权（弹出系统框），返回是否已处于授权状态
  Future<bool> requestShizuku() async =>
      await _m.invokeMethod<bool>('requestShizuku') ?? false;

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

  /// 打开 app 时的增量对账，返回 {ok, added, removed, updated, elapsedMs}
  Future<Map<String, dynamic>> startSync({bool rootIndex = true}) async =>
      Map<String, dynamic>.from(
          await _m.invokeMethod('startSync', {'rootIndex': rootIndex}));

  /// 前台实时监听（变化→自动增量同步，结果走 scanEvents 的 synced 事件）
  Future<void> startWatcher({bool rootIndex = true}) =>
      _m.invokeMethod('startWatcher', {'rootIndex': rootIndex});

  Future<void> stopWatcher() => _m.invokeMethod('stopWatcher');

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
