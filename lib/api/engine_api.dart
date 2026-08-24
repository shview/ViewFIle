import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 原生引擎通道封装
class EngineApi {
  static const _m = MethodChannel('viewfile/engine');
  static const _scanEvents = EventChannel('viewfile/scan');

  Future<bool> hasPermission() async =>
      await _m.invokeMethod<bool>('hasPermission') ?? false;

  Future<void> requestPermission() => _m.invokeMethod('requestPermission');

  /// 检测 root（会触发系统的 root 授权框）
  Future<bool> hasRoot() async =>
      await _m.invokeMethod<bool>('hasRoot') ?? false;

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

  Future<bool> needsRescan({
    bool rootIndex = true,
    bool systemIndex = false,
    bool deepData = false,
  }) async =>
      await _m.invokeMethod<bool>('needsRescan', {
        'rootIndex': rootIndex,
        'systemIndex': systemIndex,
        'deepData': deepData,
      }) ??
      true;

  Future<void> startScan({
    bool rootIndex = true,
    bool systemIndex = false,
    bool deepData = false,
    bool compactDb = false,
  }) => _m.invokeMethod('startScan', {
    'rootIndex': rootIndex,
    'systemIndex': systemIndex,
    'deepData': deepData,
    'compactDb': compactDb,
  });

  /// 打开 app 时的增量对账，返回 {ok, added, removed, updated, elapsedMs}
  Future<Map<String, dynamic>> startSync({
    bool rootIndex = true,
    bool deepData = false,
  }) async => Map<String, dynamic>.from(
    await _m.invokeMethod('startSync', {
      'rootIndex': rootIndex,
      'deepData': deepData,
    }),
  );

  /// 前台实时监听（变化→自动增量同步，结果走 scanEvents 的 synced 事件）
  Future<void> startWatcher({
    bool rootIndex = true,
    bool deepData = false,
    int lifecycleIntent = 0,
  }) => _m.invokeMethod('startWatcher', {
    'rootIndex': rootIndex,
    'deepData': deepData,
    'lifecycleIntent': lifecycleIntent,
  });

  Future<void> stopWatcher({int lifecycleIntent = 0}) =>
      _m.invokeMethod('stopWatcher', {'lifecycleIntent': lifecycleIntent});

  /// limit 默认给超大值 = 不限制，全部返回
  Future<List<Map<dynamic, dynamic>>> search(
    String query, {
    int limit = 2000000000,
    List<String>? scopes,
  }) async {
    final list = await _m.invokeMethod<List<dynamic>>('search', {
      'query': query,
      'limit': limit,
      if (scopes != null) 'scopes': scopes,
    });
    return list?.map((e) => Map<dynamic, dynamic>.from(e)).toList() ?? const [];
  }

  /// 懒加载搜索会话：只建索引命中集，返回 {id, total, elapsedMs}
  Future<Map<String, dynamic>> searchStart(
    String query, {
    List<String>? scopes,
    String sortKey = 'name',
    bool sortDesc = false,
    String? category,
    bool hideDot = false,
  }) async =>
      Map<String, dynamic>.from(await _m.invokeMethod('searchStart', {
        'query': query,
        if (scopes != null) 'scopes': scopes,
        'sortKey': sortKey,
        'sortDesc': sortDesc,
        if (category != null) 'category': category,
        'hideDot': hideDot,
      }));

  /// 取会话一页（默认 300 条）
  Future<List<Map<dynamic, dynamic>>> searchPage(
          int id, int offset, int count) async =>
      (await _m.invokeMethod<List<dynamic>>('searchPage', {
            'id': id,
            'offset': offset,
            'count': count,
          }))
          ?.map((e) => Map<dynamic, dynamic>.from(e))
          .toList() ??
      const [];

  /// 会话全量路径（供“全选”等批量操作）
  Future<List<String>> searchPaths(int id) async =>
      (await _m.invokeMethod<List<dynamic>>('searchPaths', {'id': id}))
          ?.cast<String>() ??
      const [];

  /// APK 安装（root/Shizuku 静默，无特权拉系统安装器）
  Future<Map<String, dynamic>> installApk(String path) async =>
      Map<String, dynamic>.from(
        await _m.invokeMethod('installApk', {'path': path}),
      );

  /// 哈希校验：{ok, md5, sha1, sha256, size, elapsedMs}
  Future<Map<String, dynamic>> hashFile(String path) async =>
      Map<String, dynamic>.from(
        await _m.invokeMethod('hashFile', {'path': path}),
      );

  /// VACUUM 压缩主库；pageSize 非空时切换页大小
  Future<Map<String, dynamic>> vacuum({int? pageSize}) async =>
      Map<String, dynamic>.from(
        await _m.invokeMethod('vacuum', {
          if (pageSize != null) 'pageSize': pageSize,
        }),
      );

  /// 已安装应用列表：{pkg, label, system}，非系统应用在前（不含图标，秒回）
  Future<List<Map<dynamic, dynamic>>> listApps() async {
    final list = await _m.invokeMethod<List<dynamic>>('listApps');
    return list?.map((e) => Map<dynamic, dynamic>.from(e)).toList() ?? const [];
  }

  /// 单个应用图标（懒加载，原生侧有缓存），无图标返回 null
  Future<Uint8List?> getAppIcon(String pkg) async =>
      await _m.invokeMethod('getAppIcon', {'pkg': pkg});

  /// 浏览目录：返回 {ok, entries} 或 {ok:false, error}
  Future<Map<String, dynamic>> listDir(String path) async =>
      Map<String, dynamic>.from(
        await _m.invokeMethod('listDir', {'path': path}),
      );

  /// 原生库目录（内含 libvfunrar.so 等自打包可执行）
  Future<String?> nativeDir() async =>
      await _m.invokeMethod<String>('nativeDir');

  /// 文本预览：{ok, text, truncated} 或 {ok:false, error}；root 区域走特权读取
  Future<Map<String, dynamic>> readText(String path) async =>
      Map<String, dynamic>.from(
        await _m.invokeMethod('readText', {'path': path}),
      );

  /// 打开（系统选择器）。返回 null=已发起，否则为错误信息
  Future<String?> open(List<String> paths) async =>
      await _m.invokeMethod<String>('open', {'paths': paths});

  /// 分享（单个 ACTION_SEND / 多个 ACTION_SEND_MULTIPLE）
  Future<String?> share(List<String> paths) async =>
      await _m.invokeMethod<String>('share', {'paths': paths});

  Future<Map<String, dynamic>> rename(String path, String newName) async =>
      Map<String, dynamic>.from(
        await _m.invokeMethod('rename', {'path': path, 'newName': newName}),
      );

  Future<Map<String, dynamic>> delete(List<String> paths) async =>
      Map<String, dynamic>.from(
        await _m.invokeMethod('delete', {'paths': paths}),
      );

  Future<bool> mkdir(String path) async =>
      await _m.invokeMethod<bool>('mkdir', {'path': path}) ?? false;

  /// 复制/移动到目标目录
  Future<Map<String, dynamic>> transfer(List<String> paths, String destDir,
      {required bool move}) async =>
      Map<String, dynamic>.from(await _m.invokeMethod('transfer', {
        'paths': paths,
        'destDir': destDir,
        'move': move,
      }));

  Stream<Map<dynamic, dynamic>> scanEvents() => _scanEvents
      .receiveBroadcastStream()
      .map((e) => Map<dynamic, dynamic>.from(e));
}
