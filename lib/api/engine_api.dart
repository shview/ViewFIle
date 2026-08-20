import 'package:flutter/services.dart';

/// 原生引擎通道封装
class EngineApi {
  static const _m = MethodChannel('viewfile/engine');
  static const _scanEvents = EventChannel('viewfile/scan');

  Future<bool> hasPermission() async =>
      await _m.invokeMethod<bool>('hasPermission') ?? false;

  Future<void> requestPermission() => _m.invokeMethod('requestPermission');

  Future<Map<dynamic, dynamic>> stats() async =>
      Map<dynamic, dynamic>.from(await _m.invokeMethod('stats'));

  Future<int> ensureIndexLoaded() async =>
      await _m.invokeMethod<int>('ensureIndexLoaded') ?? 0;

  Future<void> startScan() => _m.invokeMethod('startScan');

  Future<List<Map<dynamic, dynamic>>> search(String query,
      {int limit = 200}) async {
    final list = await _m.invokeMethod<List<dynamic>>('search',
        {'query': query, 'limit': limit});
    return list?.map((e) => Map<dynamic, dynamic>.from(e)).toList() ?? const [];
  }

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
