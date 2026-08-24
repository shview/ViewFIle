import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/engine_api.dart';
import '../utils/archive_support.dart';
import '../utils/format.dart';
import '../utils/index_bootstrap.dart';
import '../utils/watcher_lifecycle.dart';
import 'apps_page.dart';
import 'image_viewer_page.dart';
import 'media_viewer_page.dart';
import 'settings_page.dart';
import 'dest_picker_page.dart';
import 'storage_analysis_page.dart';
import 'text_preview_page.dart';
import 'tips_page.dart';

const kSdcard = '/storage/emulated/0';

const _imageExts = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'dng', 'avif',
};

bool isImageName(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && _imageExts.contains(name.substring(dot + 1).toLowerCase());
}

const _videoExts = {
  'mp4', 'mkv', 'avi', 'mov', 'webm', '3gp', 'm4v', 'flv', 'ts', 'mpeg', 'mpg',
};

const _audioExts = {
  'mp3', 'flac', 'wav', 'ogg', 'm4a', 'aac', 'opus', 'amr', 'wma', 'mid',
};

bool isVideoName(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && _videoExts.contains(name.substring(dot + 1).toLowerCase());
}

bool isAudioName(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && _audioExts.contains(name.substring(dot + 1).toLowerCase());
}

const _textExts = {
  'txt', 'log', 'md', 'json', 'xml', 'csv', 'html', 'htm', 'js', 'ts', 'mjs',
  'css', 'scss', 'yml', 'yaml', 'ini', 'conf', 'cfg', 'properties', 'prop',
  'toml', 'gradle', 'sh', 'bat', 'ps1', 'py', 'rb', 'java', 'kt', 'kts',
  'c', 'h', 'cpp', 'hpp', 'cs', 'go', 'rs', 'swift', 'php', 'sql', 'svg',
  'gitignore', 'gitattributes', 'editorconfig', 'env',
};

bool isTextLikeName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  if (ext.isEmpty) return false;
  if (_textExts.contains(ext)) return true;
  // .gitignore / .env 这类“扩展名即全名”的文件
  return _textExts.contains(name.toLowerCase());
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _api = EngineApi();
  final _searchCtl = TextEditingController();
  Timer? _debounce;

  bool? _hasPerm; // null = 检查中
  bool _root = false;
  bool _scanning = false;
  String _statusLine = '';
  int _entries = 0;
  bool _rootIndex = true;
  bool _systemIndex = false;
  bool _deepData = false;

  // 浏览状态
  String _currentDir = kSdcard;
  List<Map<dynamic, dynamic>> _dirEntries = const [];
  bool _loadingDir = false;
  String? _dirError;

  // 搜索状态
  List<Map<dynamic, dynamic>> _results = const [];
  bool _searching = false;
  // 作用域：0=当前目录 1=全盘 2=当前界面（在当前显示的列表内过滤）
  int _scopeMode = 0;
  // “当前界面”模式的基底列表（浏览结果或上次搜索结果）
  List<Map<dynamic, dynamic>> _viewBase = const [];
  // 类型筛选：null=全部 image/video/audio/doc/apk/archive
  String? _category;

  // 懒加载搜索会话（普通搜索走引擎会话：总数即时、内容按需取）
  int _sessId = -1;
  int _sessTotal = 0;
  static const _pageSize = 300;
  final _pages = <int, List<Map<dynamic, dynamic>>>{};

  // 搜索历史
  final _searchFocus = FocusNode();
  List<String> _history = const [];

  // 排序：name | size | time
  String _sortKey = 'name';
  bool _sortDesc = false;
  bool _showHidden = false;
  bool _compactDb = false;
  String _tier = 'NONE'; // ROOT | SHIZUKU | NONE
  int _lastScanMs = 0;
  int _loadMs = 0;
  bool _watcherDesiredForeground = true;

  // 按应用检索：{pkg, label, dirs}
  Map<String, dynamic>? _appScope;

  // 多选状态（浏览/搜索共用）
  bool _selecting = false;
  final Set<String> _selected = {};
  String? _anchorPath; // 区间选择锚点（上次点选的项）
  StreamSubscription<Map<dynamic, dynamic>>? _scanEventsSubscription;

  bool get _isSearching =>
      _searchCtl.text.trim().isNotEmpty || _appScope != null;
  List<Map<dynamic, dynamic>> get _displayList =>
      _isSearching ? _results : _dirEntries;

  /// 普通（引擎）搜索 = 懒加载会话；“当前界面”/应用检索默认视图走本地列表
  bool get _isLazySession =>
      _isSearching && _appScope == null && _scopeMode != 2 && _sessId >= 0;
  int get _totalResults => _isLazySession ? _sessTotal : _results.length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanEventsSubscription = _api.scanEvents().listen(
      _onScanEvent,
      onError: (_) {},
    );
    _loadHistory();
    _prefsReady = _loadPrefs();
    _bootstrap();
  }

  Future<void>? _prefsReady;

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _history = prefs.getStringList('searchHistory') ?? const []);
  }

  Future<void> _recordHistory(String q) async {
    q = q.trim();
    if (q.length < 2) return;
    final prefs = await SharedPreferences.getInstance();
    final list = [..._history.where((h) => h != q), q];
    if (list.length > 20) list.removeRange(0, list.length - 20);
    await prefs.setStringList('searchHistory', list);
    if (mounted) setState(() => _history = list);
  }

  Future<void> _removeHistory(int i) async {
    final list = [..._history]..removeAt(i);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('searchHistory', list);
    if (mounted) setState(() => _history = list);
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('searchHistory', const []);
    if (mounted) setState(() => _history = const []);
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _rootIndex = prefs.getBool('rootIndex') ?? true;
      _systemIndex = prefs.getBool('systemIndex') ?? false;
      _deepData = prefs.getBool('deepDataIndex') ?? false;
      _sortKey = prefs.getString('sortKey') ?? 'name';
      _sortDesc = prefs.getBool('sortDesc') ?? false;
      _showHidden = prefs.getBool('showHidden') ?? false;
      _compactDb = prefs.getBool('compactDb') ?? false;
    });
    if (_rootIndex) {
      final r = await _api.hasRoot();
      if (mounted) setState(() => _root = r);
    }
  }

  Future<void> _saveSort() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('sortKey', _sortKey);
    await p.setBool('sortDesc', _sortDesc);
  }

  Future<void> _bootstrap() async {
    await _prefsReady; // 必须先拿到真实配置，否则深度开关等会被漏检（走同步收敛的错路）
    final ok = await _api.hasPermission();
    setState(() => _hasPerm = ok);
    if (!ok) return;
    final n = await _api.ensureIndexLoaded(); // 先载入索引（目录统计依赖它）
    final loadDisposition = classifyIndexLoad(n);
    if (loadDisposition == IndexLoadDisposition.rebuildCompact) {
      // 原生已清掉超预算/损坏的库；持久关闭深度索引后只尝试一次精简重建，
      // 避免下次启动继续用原配置重建并再次触发同一保护。
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('deepDataIndex', false);
      if (!mounted) return;
      setState(() {
        _deepData = false;
        _entries = 0;
        _statusLine = '索引无法载入或超出内存预算，正在以精简模式重建…';
      });
      _loadDir(_currentDir);
      await _api.startScan(
        rootIndex: _rootIndex,
        systemIndex: _systemIndex,
        deepData: false,
        compactDb: _compactDb,
      );
      _ensureWatcher();
      return;
    }
    if (!mounted) return;
    setState(() => _entries = n);
    _loadDir(_currentDir);
    if (loadDisposition == IndexLoadDisposition.rebuildConfigured) {
      await _api.startScan(
        rootIndex: _rootIndex,
        systemIndex: _systemIndex,
        deepData: _deepData,
        compactDb: _compactDb,
      );
    } else if (await _api.needsRescan(
      rootIndex: _rootIndex,
      systemIndex: _systemIndex,
      deepData: _deepData,
    )) {
      // 配置变化（如 root 授权状态变化）→ 自动重扫
      await _api.startScan(
        rootIndex: _rootIndex,
        systemIndex: _systemIndex,
        deepData: _deepData,
        compactDb: _compactDb,
      );
    } else {
      _refreshStats();
      _autoSync();
    }
    _ensureWatcher();
  }

  /// 打开 app 时的静默增量对账
  Future<void> _autoSync() async {
    final r = await _api.startSync(rootIndex: _rootIndex, deepData: _deepData);
    if (!mounted || r['ok'] != true) return;
    final a = (r['added'] as num?)?.toInt() ?? 0;
    final rm = (r['removed'] as num?)?.toInt() ?? 0;
    final up = (r['updated'] as num?)?.toInt() ?? 0;
    final ms = (r['elapsedMs'] as num?)?.toInt() ?? 0;
    debugPrint('[ViewFile] 增量同步: +$a -$rm ~$up, ${ms}ms');
    if (a + rm > 0) {
      _refreshStats();
      _rerun();
    }
  }

  Future<void> _refreshStats() async {
    final s = await _api.stats();
    setState(() {
      _entries = (s['entries'] as num?)?.toInt() ?? _entries;
      _lastScanMs = (s['lastScanMs'] as num?)?.toInt() ?? _lastScanMs;
      _loadMs = (s['loadMs'] as num?)?.toInt() ?? _loadMs;
      _root = s['root'] == true;
      _tier = (s['tier'] as String?) ?? 'NONE';
    });
  }

  // ---------- 扫描事件 ----------

  void _onScanEvent(Map<dynamic, dynamic> e) {
    final type = e['type'] as String?;
    if (type == 'progress') {
      final files = e['files'] as int? ?? 0;
      final dirs = e['dirs'] as int? ?? 0;
      final sec = ((e['elapsedMs'] as num?)?.toDouble() ?? 0) / 1000.0;
      setState(() {
        _scanning = true;
        _statusLine = '索引中：$files 文件 · $dirs 文件夹 · ${sec.toStringAsFixed(1)}s';
      });
    } else if (type == 'done') {
      setState(() {
        _scanning = false;
        _entries = (e['files'] as int? ?? 0) + (e['dirs'] as int? ?? 0);
        _statusLine = '';
      });
      _refreshStats();
      _rerun();
      _ensureWatcher(); // 全量重建后目录集合变化，重启监听
    } else if (type == 'synced') {
      // 前台监听触发的自动增量同步
      final a = (e['added'] as num?)?.toInt() ?? 0;
      final rm = (e['removed'] as num?)?.toInt() ?? 0;
      final ms = (e['elapsedMs'] as num?)?.toInt() ?? 0;
      if (a + rm > 0) {
        debugPrint('[ViewFile] 前台自动同步: +$a -$rm, ${ms}ms');
        _refreshStats();
        _rerun();
      }
    } else if (type == 'error') {
      setState(() {
        _scanning = false;
        final retained = e['oldIndexRetained'] == true;
        final deep = e['deepRequested'] == true
            ? '；深度索引未生效，${retained ? '仍保留旧索引' : '旧索引状态需复核'}'
            : '；新索引未发布，${retained ? '仍保留旧索引' : '旧索引状态需复核'}';
        _statusLine = '扫描失败: ${e['error']}$deep';
      });
    }
  }

  // 去重由引擎侧健康检查负责（避免空库期误启后无法替换）
  void _ensureWatcher() {
    if (_hasPerm != true || !_watcherDesiredForeground) return;
    _api.startWatcher(
      rootIndex: _rootIndex,
      deepData: _deepData,
      lifecycleIntent: watcherLifecycleIntents.next(),
    );
  }

  void _maybeStopWatcher() {
    _api.stopWatcher(lifecycleIntent: watcherLifecycleIntents.next());
  }

  // ---------- 浏览 ----------

  Future<void> _loadDir(String path, {bool seamless = false}) async {
    // 无缝模式（增量同步触发）：同路径重载时保留旧列表显示，不闪加载圈、不清多选
    final keepDisplay = seamless && path == _currentDir && _dirEntries.isNotEmpty;
    setState(() {
      _currentDir = path;
      if (!keepDisplay) _loadingDir = true;
      _dirError = null;
      if (!seamless) _exitSelectionRaw();
    });
    // 压缩包虚拟路径：Dart 侧列目录
    if (VFArchives.isVirtual(path)) {
      final (zipPath, inner) = VFArchives.splitVirtual(path);
      final entries = await VFArchives.listDir(zipPath, inner);
      if (!mounted || _currentDir != path) return;
      setState(() {
        _loadingDir = false;
        _dirEntries = entries;
        _viewBase = entries;
        if (entries.isEmpty && !keepDisplay) {
          _dirError = '无法读取压缩包（损坏、加密或不支持）';
        }
      });
      return;
    }
    final r = await _api.listDir(path);
    if (!mounted || _currentDir != path) return;
    setState(() {
      _loadingDir = false;
      if (r['ok'] == true) {
        _dirEntries = List<Map<dynamic, dynamic>>.from(
          r['entries'] ?? const [],
        );
        _viewBase = _dirEntries;
      } else {
        _dirEntries = const [];
        _dirError = r['error'] as String?;
      }
    });
  }

  void _navigateUp() {
    if (VFArchives.isVirtual(_currentDir)) {
      final (zipPath, inner) = VFArchives.splitVirtual(_currentDir);
      if (inner.contains('/')) {
        _loadDir('$zipPath!/${inner.substring(0, inner.lastIndexOf('/'))}');
      } else {
        // 已在 zip 根：回到压缩包所在目录
        final parent = zipPath.substringBeforeLast('/');
        _loadDir(parent.isEmpty ? '/' : parent);
      }
      return;
    }
    if (_currentDir == kSdcard && !_root) return;
    if (_currentDir == '/') return;
    final parent = _currentDir.substringBeforeLast('/');
    _loadDir(parent.isEmpty ? '/' : parent);
  }

  /// 点击顶栏/路径条输入路径直接跳转
  Future<void> _showPathInput() async {
    if (_isSearching || _appScope != null) return;
    final ctl = TextEditingController(text: _currentDir);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('转到路径'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '如 /storage/emulated/0/Download',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('转到')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final p = ctl.text.trim();
    if (p.isEmpty) return;
    _searchCtl.clear();
    setState(() {
      _appScope = null;
      _results = const [];
    });
    _loadDir(p);
  }

  // ---------- 搜索 ----------

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () => _runQuery(q));
  }

  int _querySeq = 0; // 搜索请求序号：防响应乱序（旧查询后到覆盖新结果）
  bool _sessionRebuilding = false; // 会话失效重建退避

  Future<void> _runQuery(String q, {bool seamless = false}) async {
    // 应用检索默认视图：显示该应用的几个根目录入口（可点进去浏览）
    if (_appScope != null && q.trim().isEmpty) {
      final dirs = List<String>.from(_appScope!['dirs']);
      setState(() {
        _results = dirs
            .map(
              (d) => <dynamic, dynamic>{
                'path': d,
                'name': _appDirLabel(d),
                'isDir': true,
                'size': 0,
                'mtime': 0,
              },
            )
            .toList();
        _searching = false;
        _viewBase = _results;
        _sessId = -1;
        _sessTotal = 0;
        _pages.clear();
      });
      return;
    }
    if (_appScope == null && q.trim().isEmpty) {
      setState(() {
        _results = const [];
        _sessId = -1;
        _sessTotal = 0;
        _pages.clear();
      });
      return;
    }
    final localFilter = _appScope == null &&
        // “当前界面” 或 压缩包虚拟层级内（引擎目录表无虚拟路径，
        // 传给引擎会退化为全盘搜索）都在本地列表内过滤
        (_scopeMode == 2 || (_scopeMode == 0 && VFArchives.isVirtual(_currentDir)));
    if (localFilter) {
      final needle = q.trim().toLowerCase();
      setState(() {
        _results = _viewBase
            .where((e) =>
                ((e['name'] as String?) ?? '').toLowerCase().contains(needle))
            .where((e) => _category == null || _matchCategory(e, _category!))
            .where((e) =>
                _showHidden ||
                !((e['name'] as String? ?? '').startsWith('.')))
            .toList()
          ..sort(_clientSort);
        _searching = false;
        _sessId = -1;
        _pages.clear();
      });
      return;
    }
    // 普通搜索：引擎懒加载会话（总数即时，内容按页取）
    List<String>? scopes;
    if (_appScope != null) {
      scopes = List<String>.from(_appScope!['dirs']);
    } else if (_scopeMode == 0) {
      scopes = [_currentDir];
    }
    final seq = ++_querySeq;
    // seamless（增量同步触发）：不闪进度条、不清旧页——旧结果保持显示，
    // 新会话就位后静默重拉已缓存的页，到货原地替换
    if (!seamless) setState(() => _searching = true);
    final r = await _api.searchStart(
      q,
      scopes: scopes,
      sortKey: _sortKey,
      sortDesc: _sortDesc,
      category: _category,
      hideDot: !_showHidden,
    );
    // 乱序防护：await 期间又发起了新查询，本响应作废
    if (!mounted || seq != _querySeq) return;
    final newId = (r['id'] as num?)?.toInt() ?? -1;
    final newTotal = (r['total'] as num?)?.toInt() ?? 0;
    if (seamless && _pages.isNotEmpty && newTotal > 0) {
      setState(() {
        _sessId = newId;
        _sessTotal = newTotal;
        _searching = false;
      });
      // 后台静默刷新已展示的页（含滑窗外的缓存页）
      for (final p in _pages.keys.toList()) {
        _refreshPage(p);
      }
      return;
    }
    setState(() {
      _sessId = newId;
      _sessTotal = newTotal;
      _searching = false;
      _results = const [];
      // 新会话已就位，此时清旧页：itemBuilder 将用新 id 拉页
      _pages.clear();
    });
  }

  final _refreshingPages = <int>{};

  /// 静默刷新一页：旧内容留在屏上，新数据到货后原地替换（无骨架屏）
  Future<void> _refreshPage(int page) async {
    if (_refreshingPages.contains(page)) return;
    _refreshingPages.add(page);
    final id = _sessId;
    try {
      final rows = await _api.searchPage(id, page * _pageSize, _pageSize);
      if (!mounted || _sessId != id || rows.isEmpty) return;
      setState(() => _pages[page] = rows);
    } finally {
      _refreshingPages.remove(page);
    }
  }

  /// 本地列表排序（“当前界面”/zip 内过滤结果用）
  int _clientSort(Map<dynamic, dynamic> a, Map<dynamic, dynamic> b) {
    int sizeOf(Map<dynamic, dynamic> e) => e['isDir'] == true
        ? ((e['dirSize'] as num?)?.toInt() ?? 0)
        : ((e['size'] as num?)?.toInt() ?? 0);
    int c;
    switch (_sortKey) {
      case 'size':
        c = sizeOf(a).compareTo(sizeOf(b));
      case 'time':
        c = ((a['mtime'] as num?)?.toInt() ?? 0)
            .compareTo((b['mtime'] as num?)?.toInt() ?? 0);
      default:
        c = ((a['name'] as String? ?? '').toLowerCase())
            .compareTo((b['name'] as String? ?? '').toLowerCase());
    }
    return _sortDesc ? -c : c;
  }

  static bool _matchCategory(Map<dynamic, dynamic> e, String cat) {
    final name = (e['name'] as String?) ?? '';
    bool extIn(Set<String> set) {
      final dot = name.lastIndexOf('.');
      return dot > 0 && set.contains(name.substring(dot + 1).toLowerCase());
    }
    switch (cat) {
      case 'image':
        return extIn(_imageExts);
      case 'video':
        return extIn(_videoExts);
      case 'audio':
        return extIn(_audioExts);
      case 'apk':
        return extIn({'apk', 'xapk', 'apks'});
      case 'archive':
        return extIn({'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'});
      case 'doc':
        return extIn({
          'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md',
          'epub', 'mobi', 'csv', 'json', 'xml', 'html', 'htm',
        });
      default:
        return true;
    }
  }

  /// 懒加载：取一页（300 条），带并发保护
  Future<void> _fetchPage(int page) async {
    if (_pages.containsKey(page)) return;
    _pages[page] = const []; // 占位防重入
    final id = _sessId;
    final rows = await _api.searchPage(id, page * _pageSize, _pageSize);
    if (!mounted) return;
    if (_sessId != id) {
      // 会话已更换（新查询/索引重建）：清掉占位符，让下一次构建用新 id 自愈
      _pages.remove(page);
      return;
    }
    if (rows.isEmpty && page * _pageSize < _sessTotal) {
      // 有效会话的页永不为空：说明索引重建后会话被失效（防内存钉扎）→ 重建搜索
      _pages.remove(page);
      if (_sessionRebuilding) return; // 防重建风暴
      _sessionRebuilding = true;
      await _runQuery(_searchCtl.text, seamless: true);
      _sessionRebuilding = false;
      return;
    }
    setState(() => _pages[page] = rows);
    // 页缓存上限：滑窗保留最近 48 页（~1.4 万行），更早的淘汰
    while (_pages.length > 48) {
      _pages.remove(_pages.keys.first);
    }
  }

  /// 懒加载行（未加载返回 null）
  Map<dynamic, dynamic>? _lazyRowAt(int i) {
    if (i >= _sessTotal) return null;
    final page = i ~/ _pageSize;
    final rows = _pages[page];
    if (rows == null) {
      _fetchPage(page);
      return null;
    }
    final idx = i - page * _pageSize;
    return idx < rows.length && rows.isNotEmpty ? rows[idx] : null;
  }

  /// 当前已加载的可见行（懒加载模式：按会话顺序拼接各页）
  List<Map<dynamic, dynamic>> _loadedView() {
    if (!_isLazySession) return _sortedView();
    final out = <Map<dynamic, dynamic>>[];
    for (var i = 0; i < _sessTotal; i++) {
      final row = _lazyRowAt(i);
      if (row == null) break;
      out.add(row);
    }
    return out;
  }

  static String _appDirLabel(String dir) {
    if (dir.contains('/Android/data/')) return 'Android/data';
    if (dir.contains('/Android/obb/')) return 'Android/obb';
    if (dir.startsWith('/data/data/')) return 'data/data（应用私有）';
    return dir.substringAfterLast('/');
  }

  void _clearAppScope() {
    setState(() => _appScope = null);
    if (_searchCtl.text.trim().isEmpty) {
      setState(() => _results = const []);
    } else {
      _runQuery(_searchCtl.text);
    }
  }

  String get _scopeLabel =>
      switch (_scopeMode) { 1 => '全盘', 2 => '当前界面', _ => '当前目录' };

  void _toggleScope() {
    setState(() => _scopeMode = (_scopeMode + 1) % 3);
    if (_scopeMode == 2) {
      // 进入“当前界面”：以当前显示的列表为过滤基底
      if (_isSearching && _results.isNotEmpty) {
        _viewBase = _results;
      }
    }
    if (_isSearching) _runQuery(_searchCtl.text);
  }

  /// 操作完成后刷新当前视图（seamless：文件操作后的自动刷新也不闪屏）
  void _rerun({bool seamless = true}) {
    if (_isSearching) {
      _runQuery(_searchCtl.text, seamless: seamless);
    } else {
      _loadDir(_currentDir, seamless: seamless);
    }
    _refreshStats();
  }

  // ---------- 多选 ----------

  void _enterSelection(String path) => setState(() {
        _selecting = true;
        _selected.add(path);
        _anchorPath = path;
      });

  void _toggle(String path) => setState(() {
        if (!_selected.remove(path)) {
          _selected.add(path);
        }
        _anchorPath = path; // 点选也更新锚点，供后续长按区间选
      });

  /// 长按已处于多选时：选中锚点到当前项之间的所有项（已加载范围内）
  void _rangeSelectTo(String path) {
    final paths = _loadedView().map((e) => e['path'] as String).toList();
    final a = paths.indexOf(_anchorPath ?? path);
    final b = paths.indexOf(path);
    if (a < 0 || b < 0) return;
    final lo = a < b ? a : b, hi = a < b ? b : a;
    setState(() => _selected.addAll(paths.sublist(lo, hi + 1)));
  }

  void _exitSelection() => setState(() => _exitSelectionRaw());

  void _exitSelectionRaw() {
    _selecting = false;
    _selected.clear();
    _anchorPath = null;
  }

  void _selectAll() {
    if (_isLazySession && _sessTotal > 2000) {
      // 大结果集：从引擎取全量路径（纯字符串，比整页数据轻得多）
      final id = _sessId;
      _api.searchPaths(id).then((paths) {
        if (!mounted || _sessId != id) return;
        setState(() => _selected.addAll(paths));
      });
      return;
    }
    setState(() {
      _selected.addAll(_loadedView().map((e) => e['path'] as String));
    });
  }

  void _selectNone() => setState(() => _selected.clear());

  void _invertSelection() => setState(() {
        final next = _loadedView()
            .where((e) => !_selected.contains(e['path']))
            .map((e) => e['path'] as String)
            .toSet();
        _selected
          ..clear()
          ..addAll(next);
      });

  List<Map<dynamic, dynamic>> get _selectedItems => _loadedView()
      .where((e) => _selected.contains(e['path'] as String?))
      .toList(growable: false);

  bool get _allSelectedAreFiles =>
      _selectedItems.isNotEmpty &&
      _selectedItems.every((e) => e['isDir'] != true);

  // ---------- 文件操作 ----------

  Future<void> _openItem(Map<dynamic, dynamic> e) async {
    final path = e['path'] as String;
    List<String> toOpen = [path];
    if (VFArchives.isVirtual(path)) {
      final extracted = await VFArchives.extractFile(path);
      if (extracted == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('无法从压缩包提取该文件')));
        }
        return;
      }
      toOpen = [extracted];
    }
    final err = await _api.open(toOpen);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  /// APK 安装（root/Shizuku 静默；无特权拉起系统安装器）
  Future<void> _installApk(Map<dynamic, dynamic> e) async {
    final path = e['path'] as String;
    var real = path;
    if (VFArchives.isVirtual(path)) {
      final extracted = await VFArchives.extractFile(path);
      if (extracted == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('无法从压缩包提取该 APK')));
        }
        return;
      }
      real = extracted;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('正在安装…')));
    final r = await _api.installApk(real);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r['ok'] == true
          ? '已发起安装（${r['mode'] == 'ROOT' ? 'root 静默' : r['mode'] == 'SHIZUKU' ? 'Shizuku 静默' : '系统安装器'}）'
          : '安装失败：${r['error']}'),
      duration: const Duration(seconds: 3),
    ));
  }

  /// 哈希校验对话框（带进度百分比）
  Future<void> _showHash(Map<dynamic, dynamic> e) async {
    final path = e['path'] as String;
    final name = e['name'] as String? ?? '';
    final progress = ValueNotifier<double?>(null); // null = 未开始
    final tTap = DateTime.now();
    final progressSub = _api.scanEvents().listen((ev) {
      if (ev['type'] == 'hashProgress') {
        final total = (ev['total'] as num?)?.toDouble() ?? 0;
        final done = (ev['done'] as num?)?.toDouble() ?? 0;
        if (total > 0) progress.value = done / total;
      }
    });
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (context, pct, _) => AlertDialog(
          title: const Text('校验中…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: pct,
                minHeight: 6,
              ),
              const SizedBox(height: 10),
              Text(
                pct == null
                    ? '准备中…'
                    : '已读取 ${(pct * 100).toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
    var real = path;
    if (VFArchives.isVirtual(path)) {
      real = await VFArchives.extractFile(path) ?? '';
    }
    final r = real.isEmpty
        ? <String, dynamic>{'ok': false, 'error': '无法从压缩包提取'}
        : await _api.hashFile(real);
    final totalFelt = DateTime.now().difference(tTap).inMilliseconds;
    await progressSub.cancel();
    if (!mounted) return;
    Navigator.pop(context); // 关闭进度框
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('校验 · $name', style: const TextStyle(fontSize: 16)),
        content: SelectionArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (r['ok'] == true) ...[
                for (final k in const ['md5', 'sha1', 'sha256'])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${k.toUpperCase()}',
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700)),
                        Text(r[k] as String? ?? '—',
                            style: const TextStyle(
                                fontSize: 12, fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                Text(
                  '读取 ${r['elapsedMs']} ms · 总计 $totalFelt ms'
                  '${totalFelt - ((r['elapsedMs'] as num?)?.toInt() ?? 0) > 200 ? '（含排队/解压 ${totalFelt - ((r['elapsedMs'] as num?)?.toInt() ?? 0)} ms）' : ''}',
                  style: const TextStyle(fontSize: 11),
                ),
              ] else
                Text('校验失败：${r['error']}'),
            ],
          ),
        ),
        actions: [
          if (r['ok'] == true)
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(
                    text: 'MD5: ${r['md5']}\nSHA1: ${r['sha1']}\nSHA256: ${r['sha256']}'));
                Navigator.pop(context);
              },
              child: const Text('复制全部'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 预览文本文件（压缩包内文件先解压）
  Future<void> _previewText(Map<dynamic, dynamic> e) async {
    var path = e['path'] as String;
    if (VFArchives.isVirtual(path)) {
      final extracted = await VFArchives.extractFile(path);
      if (extracted == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('无法从压缩包提取该文件')));
        }
        return;
      }
      path = extracted;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TextPreviewPage(path: path)),
    );
  }

  /// 查看图片：列表内左右滑动切换；压缩包内图片先解压再看
  Future<void> _viewImage(Map<dynamic, dynamic> e) async {
    final path = e['path'] as String;
    List<String> images;
    var idx = 0;
    if (VFArchives.isVirtual(path)) {
      final extracted = await VFArchives.extractFile(path);
      if (extracted == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('无法从压缩包提取该图片')));
        }
        return;
      }
      images = [extracted];
    } else {
      images = [
        for (final x in _loadedView())
          if (x['isDir'] != true && isImageName(x['name'] as String? ?? ''))
            x['path'] as String,
      ];
      idx = images.indexOf(path);
      if (idx < 0) {
        images = [path];
        idx = 0;
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerPage(paths: images, initialIndex: idx),
      ),
    );
  }

  /// 内置播放器打开视频/音频；压缩包内先解压；失败回退系统打开
  Future<void> _openMedia(Map<dynamic, dynamic> e) async {
    var path = e['path'] as String;
    if (VFArchives.isVirtual(path)) {
      final extracted = await VFArchives.extractFile(path);
      if (extracted == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('无法从压缩包提取该文件')));
        }
        return;
      }
      path = extracted;
    }
    if (!mounted) return;
    final r = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewerPage(
          path: path,
          onExternal: null,
        ),
      ),
    );
    if (r == 'external') _openItem(e);
  }

  Future<void> _sharePaths(List<String> paths) async {
    final err = await _api.share(paths);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _copyPaths(List<String> paths) async {
    await Clipboard.setData(ClipboardData(text: paths.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已复制 ${paths.length} 条路径')));
    }
  }

  Future<void> _renameItem(Map<dynamic, dynamic> e) async {
    final path = e['path'] as String;
    final oldName = e['name'] as String? ?? '';
    final ctl = TextEditingController(text: oldName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await _api.rename(path, ctl.text);
    if (!mounted) return;
    if (r['ok'] == true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已重命名')));
      _rerun();
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重命名失败: ${r['error']}')));
    }
  }

  // ---------- 复制/移动 ----------

  Future<void> _transferSelected({required bool move}) async {
    final items = _selectedItems;
    if (items.isEmpty) return;
    final dest = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => DestPickerPage(
          title: move ? '移动到...' : '复制到...',
          initialDir: _currentDir,
        ),
      ),
    );
    if (dest == null || !mounted) return;
    final paths = items.map((e) => e['path'] as String).toList();
    // 进度提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${move ? '移动' : '复制'} ${items.length} 项到 $dest ...'),
        duration: const Duration(seconds: 2),
      ));
    }
    final r = await _api.transfer(paths, dest, move: move);
    if (!mounted) return;
    if (r['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("已${move ? '移动' : '复制'} ${r['succeeded']} 项到 $dest")));
      _exitSelection();
      _rerun();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("部分失败：${r['succeeded']} 成功，${r['failedCount']} 失败")));
      _rerun();
    }
  }

  Future<void> _confirmDelete(List<Map<dynamic, dynamic>> items) async {
    if (items.isEmpty) return;
    final fileCount = items.where((e) => e['isDir'] != true).length;
    final dirCount = items.length - fileCount;
    final names = items.take(5).map((e) => e['name']).join('、');
    final more = items.length > 5 ? ' 等 ${items.length} 项' : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除？'),
        content: Text(
          '将删除 $fileCount 个文件、$dirCount 个文件夹：\n$names$more\n\n'
          '此操作不可恢复，也不会进入回收站。',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await _api.delete(items.map((e) => e['path'] as String).toList());
    if (!mounted) return;
    if (r['ok'] == true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已删除 ${r['deleted']} 项')));
      _exitSelection();
      _rerun();
    } else {
      final failedCount = (r['failedCount'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '部分失败：已删 ${r['deleted']} 项，失败 $failedCount 项（${r['error']}）',
          ),
        ),
      );
      _rerun();
    }
  }

  Future<void> _rescan() async {
    if (_scanning) return;
    // 二次确认：全量重建耗时与库规模成正比
    final lastSec = _lastScanMs > 0
        ? '（上次约 ${(_lastScanMs / 1000).toStringAsFixed(0)} 秒）'
        : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重建索引？'),
        content: Text(
          '将放弃现有索引并全量重扫$lastSec，'
          '期间搜索结果不更新、文件操作暂不可用。\n当前索引 $_entries 条。',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_rootIndex) {
      final r = await _api.hasRoot(); // 刷新 root 状态（可能刚授权）
      setState(() => _root = r);
    }
    // 立即进入扫描态：进度条与计数马上可见，不等首个进度事件
    setState(() {
      _scanning = true;
      _statusLine = '正在启动扫描…';
    });
    await _api.startScan(
      rootIndex: _rootIndex,
      systemIndex: _systemIndex,
      deepData: _deepData,
      compactDb: _compactDb,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _watcherDesiredForeground = true;
      if (_hasPerm == false) {
        _bootstrap(); // 从系统授权页返回后重新检查
      }
      _ensureWatcher(); // 前台实时监听
    } else if (state == AppLifecycleState.paused) {
      _watcherDesiredForeground = false;
      _maybeStopWatcher(); // 退出前台即停，不耗电
    }
  }

  @override
  void dispose() {
    // Widget replacement is not an app-background transition. A retiring page
    // must not stop a watcher just started by its successor; paused owns stop.
    _watcherDesiredForeground = false;
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _scanEventsSubscription?.cancel();
    _scanEventsSubscription = null;
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop:
          !_selecting &&
          _appScope == null &&
          !(_currentDir != kSdcard && !_isSearching),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _exitSelection();
        } else if (_appScope != null) {
          _clearAppScope();
        } else {
          _navigateUp();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        drawer: _selecting ? null : _buildDrawer(),
        body: Column(
          children: [
            if (_hasPerm != true) _permissionCard(),
            if (_scanning || _statusLine.isNotEmpty) _statusCard(),
            _searchField(),
            if (_showHistoryPanel()) _historyPanel(),
            if (_isSearching && _appScope == null) _categoryChips(),
            if (!_isSearching) _pathBar(),
            if (_isSearching && _totalResults > 0) _resultCountBar(),
            if (_searching) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _listArea()),
            if (_selecting) _selectBottomBar(),
          ],
        ),
      ),
    );
  }

  bool _showHistoryPanel() {
    if (_appScope != null || _history.isEmpty) return false;
    if (!_searchFocus.hasFocus) return false;
    final q = _searchCtl.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return _history.any((h) => h.toLowerCase().startsWith(q) && h.toLowerCase() != q);
  }

  List<String> get _historySuggestions {
    final q = _searchCtl.text.trim().toLowerCase();
    if (q.isEmpty) return _history.take(8).toList();
    return _history
        .where((h) => h.toLowerCase().startsWith(q) && h.toLowerCase() != q)
        .take(6)
        .toList();
  }

  Widget _historyPanel() {
    final theme = Theme.of(context);
    final sugg = _historySuggestions;
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final h in sugg)
            InkWell(
              onTap: () {
                _searchCtl.text = h;
                _onQueryChanged(h);
                _searchFocus.unfocus();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                child: Row(
                  children: [
                    Icon(Icons.history, size: 16, color: theme.colorScheme.outline),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(h,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall),
                    ),
                    if (_searchCtl.text.trim().isEmpty)
                      InkWell(
                        onTap: () => _removeHistory(_history.indexOf(h)),
                        child: Icon(Icons.close,
                            size: 16, color: theme.colorScheme.outline),
                      ),
                  ],
                ),
              ),
            ),
          if (_searchCtl.text.trim().isEmpty && _history.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text('搜索历史',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline)),
                  ),
                  TextButton(
                    onPressed: _clearHistory,
                    child: const Text('清空', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static const _categories = <(String?, String, IconData)>[
    (null, '全部', Icons.all_inclusive),
    ('image', '图片', Icons.image),
    ('video', '视频', Icons.movie),
    ('audio', '音频', Icons.audiotrack),
    ('doc', '文档', Icons.description),
    ('apk', 'APK', Icons.android),
    ('archive', '压缩包', Icons.folder_zip),
  ];

  Widget _categoryChips() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final (cat, label, icon) in _categories)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                avatar: Icon(icon,
                    size: 15,
                    color: _category == cat
                        ? null
                        : Theme.of(context).colorScheme.outline),
                label: Text(label),
                selected: _category == cat,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  setState(() => _category = cat);
                  if (_isSearching) _runQuery(_searchCtl.text);
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 多选底部操作栏（图标+文字块，横向可滚动）
  Widget _selectBottomBar() {
    final theme = Theme.of(context);
    Widget action(IconData icon, String label, VoidCallback onTap,
        {bool enabled = true, Color? color}) {
      final c =
          color ?? (enabled ? theme.colorScheme.onSurface : theme.disabledColor);
      return SizedBox(
        width: 76,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: c, size: 22),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 11, color: c), maxLines: 1),
            ],
          ),
        ),
      );
    }

    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        child: SizedBox(
          height: 64,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              action(Icons.share, '分享',
                  () => _sharePaths(_selected.toList()),
                  enabled: _allSelectedAreFiles),
              action(Icons.content_copy, '复制路径',
                  () => _copyPaths(_selected.toList())),
              action(Icons.file_copy_outlined, '复制到',
                  () => _transferSelected(move: false)),
              action(Icons.drive_file_move_outlined, '移动到',
                  () => _transferSelected(move: true)),
              action(Icons.delete, '删除', () => _confirmDelete(_selectedItems),
                  color: theme.colorScheme.error),
            ],
          ),
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelection,
        ),
        title: Text('已选 ${_selected.length} 项'),
        actions: [
          IconButton(
            tooltip: '全选当前列表',
            icon: const Icon(Icons.select_all),
            onPressed: _selectAll,
          ),
          IconButton(
            tooltip: '全不选',
            icon: const Icon(Icons.deselect),
            onPressed: _selectNone,
          ),
          IconButton(
            tooltip: '反选',
            icon: const Icon(Icons.flip),
            onPressed: _invertSelection,
          ),
        ],
      );
    }
    final title = _appScope != null
        ? '应用：${_appScope!['label']}'
        : _isSearching
        ? '搜索（$_scopeLabel）'
        : _dirTitle(_currentDir);
    return AppBar(
      // 浏览模式点标题 → 输入路径直接跳转
      title: GestureDetector(
        onTap: _isSearching || _appScope != null ? null : _showPathInput,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
            if (!_isSearching && _appScope == null) ...[
              const SizedBox(width: 4),
              Icon(Icons.edit, size: 13, color: Theme.of(context).hintColor),
            ],
          ],
        ),
      ),
      actions: [
        if (_appScope != null)
          IconButton(
            tooltip: '退出应用检索',
            icon: const Icon(Icons.close),
            onPressed: _clearAppScope,
          ),
        IconButton(
          tooltip: '排序与显示',
          icon: const Icon(Icons.sort),
          onPressed: _showSortPanel,
        ),
        IconButton(
          tooltip: '上一级',
          onPressed:
              (_isSearching ||
                      (_currentDir == kSdcard && !_root && !VFArchives.isVirtual(_currentDir)) ||
                      _currentDir == '/')
                  ? null
                  : _navigateUp,
          icon: const Icon(Icons.arrow_upward),
        ),
      ],
    );
  }

  String _dirTitle(String path) {
    if (path == kSdcard) return '内部存储';
    if (path == '/') return '根目录 /';
    return path.substringAfterLast('/');
  }

  /// 排序/升降序/显示隐藏文件 面板
  Future<void> _showSortPanel() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, sheetSetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text('排序方式',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary)),
              ),
              _sortOption(sheetSetState, 'name', '名称', Icons.sort_by_alpha),
              _sortOption(sheetSetState, 'size', '大小', Icons.data_usage),
              _sortOption(
                  sheetSetState, 'time', '修改时间', Icons.schedule),
              const Divider(height: 1, indent: 20, endIndent: 20),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text('顺序',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary)),
              ),
              _orderOption(sheetSetState, false, '升序（A → Z / 小 → 大）',
                  Icons.north),
              _orderOption(sheetSetState, true, '降序（Z → A / 大 → 小）',
                  Icons.south),
              const Divider(height: 1, indent: 20, endIndent: 20),
              SwitchListTile(
                secondary: const Icon(Icons.visibility_off_outlined),
                title: const Text('显示隐藏文件'),
                subtitle: const Text('以 . 开头的文件与文件夹'),
                value: _showHidden,
                onChanged: (v) {
                  sheetSetState(() {});
                  setState(() => _showHidden = v);
                  _saveShowHidden(v);
                  // 搜索结果按引擎 hideDot 过滤，开关后需重建会话
                  if (_isSearching) _runQuery(_searchCtl.text);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sortOption(StateSetter sheetSetState, String key, String label,
      IconData icon) {
    final selected = _sortKey == key;
    return ListTile(
      leading: Icon(icon,
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline),
      title: Text(label,
          style: TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
      trailing: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
      onTap: () {
        sheetSetState(() {});
        setState(() => _sortKey = key);
        _saveSort();
        if (_isLazySession) _runQuery(_searchCtl.text);
      },
    );
  }

  Widget _orderOption(
      StateSetter sheetSetState, bool desc, String label, IconData icon) {
    final selected = _sortDesc == desc;
    return ListTile(
      dense: true,
      leading: Icon(icon,
          size: 20,
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      trailing: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
      onTap: () {
        sheetSetState(() {});
        setState(() => _sortDesc = desc);
        _saveSort();
        if (_isLazySession) _runQuery(_searchCtl.text);
      },
    );
  }

  Future<void> _saveShowHidden(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('showHidden', v);
  }

  Widget _buildDrawer() {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ViewFile', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 6),
                    Text('索引 $_entries 条', style: theme.textTheme.bodySmall),
                    if (_lastScanMs > 0)
                      Text(
                        '扫描 ${(_lastScanMs / 1000.0).toStringAsFixed(1)} s · 载入 $_loadMs ms',
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      '访问层级：${switch (_tier) {
                        'ROOT' => 'root（T3）',
                        'SHIZUKU' => 'Shizuku（T2）',
                        _ => '免 root（T1）',
                      }}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('内部存储'),
              subtitle: Text(kSdcard, style: theme.textTheme.bodySmall),
              onTap: () {
                Navigator.pop(context);
                _searchCtl.clear();
                setState(() => _results = const []);
                _loadDir(kSdcard);
              },
            ),
            if (_root)
              ListTile(
                leading: const Icon(Icons.memory),
                title: const Text('根目录 /'),
                subtitle: Text('root 模式', style: theme.textTheme.bodySmall),
                onTap: () {
                  Navigator.pop(context);
                  _searchCtl.clear();
                  setState(() => _results = const []);
                  _loadDir('/');
                },
              ),
            ListTile(
              leading: const Icon(Icons.apps),
              title: const Text('按应用检索'),
              subtitle: Text(
                '搜某应用的 /data/data 与 Android/data',
                style: theme.textTheme.bodySmall,
              ),
              onTap: () async {
                Navigator.pop(context);
                final picked = await Navigator.push<Map<String, dynamic>>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AppsPage(rootAvailable: _root),
                  ),
                );
                if (picked != null && mounted) {
                  setState(() => _appScope = picked);
                  _runQuery(_searchCtl.text);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('重建索引'),
              onTap: () {
                Navigator.pop(context);
                _rescan();
              },
            ),
            ListTile(
              leading: const Icon(Icons.analytics_outlined),
              title: const Text('空间分析'),
              subtitle: Text('按大小可视化', style: theme.textTheme.bodySmall),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => StorageAnalysisPage(
                            initialPath: _currentDir)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              onTap: () async {
                Navigator.pop(context);
                final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                );
                if (changed == true) {
                  await _loadPrefs();
                  if (mounted &&
                      await _api.needsRescan(
                        rootIndex: _rootIndex,
                        systemIndex: _systemIndex,
                        deepData: _deepData,
                      )) {
                    _rescan();
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.tips_and_updates_outlined),
              title: const Text('使用提示与已知限制'),
              subtitle: Text(
                '访问分层 · 实时性边界 · 操作风险',
                style: theme.textTheme.bodySmall,
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TipsPage()),
                );
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'ViewFile',
                applicationVersion: '0.2.0 (M2)',
                applicationLegalese: 'Android 上的 Everything：即时文件搜索 + 文件管理',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.folder_open),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '需要“所有文件访问”权限才能建立文件索引',
                style: TextStyle(fontSize: 14),
              ),
            ),
            FilledButton(
              onPressed: _hasPerm == null
                  ? null
                  : () => _api.requestPermission(),
              child: const Text('去授权'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Icon(
            Icons.sync,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusLine.isEmpty ? '正在扫描…' : _statusLine,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtl,
              focusNode: _searchFocus,
              enabled: _hasPerm == true,
              onChanged: (v) {
                setState(() {}); // 刷新历史建议面板
                _onQueryChanged(v);
              },
              onSubmitted: (v) {
                _recordHistory(v);
                _searchFocus.unfocus();
                _runQuery(v);
              },
              decoration: InputDecoration(
                hintText: _appScope != null
                    ? '在 ${_appScope!['label']} 内搜索…'
                    : (_entries > 0
                          ? '在$_scopeLabel搜索…'
                          : '等待索引建立…'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtl.clear();
                          _onQueryChanged('');
                        },
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 应用检索时不放芯片（AppBar 标题已显示应用名），保持搜索框全长
          if (_appScope == null)
            Tooltip(
              message: '当前作用域：$_scopeLabel，点击切换（当前目录 → 全盘 → 当前界面）',
              child: ActionChip(
                avatar: Icon(
                  switch (_scopeMode) {
                    1 => Icons.public,
                    2 => Icons.filter_alt,
                    _ => Icons.subdirectory_arrow_right,
                  },
                  size: 18,
                ),
                label: Text(_scopeLabel),
                onPressed: _toggleScope,
              ),
            ),
        ],
      ),
    );
  }

  /// 搜索结果计数条
  Widget _resultCountBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '共 ${_totalResults} 条',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      ),
    );
  }

  /// 面包屑路径条（浏览模式，含压缩包虚拟层级）
  Widget _pathBar() {
    final theme = Theme.of(context);
    final crumbs = <(String, String)>[];

    if (VFArchives.isVirtual(_currentDir)) {
      final (zipPath, inner) = VFArchives.splitVirtual(_currentDir);
      final zipParent = zipPath.substringBeforeLast('/');
      crumbs.add(('..', zipParent.isEmpty ? '/' : zipParent));
      crumbs.add((zipPath.substringAfterLast('/'), '$zipPath!/'));
      var acc = '';
      for (final seg in inner.split('/')) {
        if (seg.isEmpty) continue;
        acc = acc.isEmpty ? seg : '$acc/$seg';
        crumbs.add((seg, '$zipPath!/$acc'));
      }
    } else {
      if (_root) crumbs.add(('/', '/'));
      if (_currentDir == kSdcard || _currentDir.startsWith('$kSdcard/')) {
        crumbs.add(('内部存储', kSdcard));
      }
      if (!_currentDir.startsWith(kSdcard)) {
        // root 区域路径：/data/data/... 等
        var acc = '';
        for (final seg in _currentDir.split('/')) {
          if (seg.isEmpty) continue;
          acc = '$acc/$seg';
          crumbs.add((seg, acc));
        }
      } else {
        var acc = kSdcard;
        for (final seg in _currentDir.substring(kSdcard.length).split('/')) {
          if (seg.isEmpty) continue;
          acc = '$acc/$seg';
          crumbs.add((seg, acc));
        }
      }
    }
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (var i = 0; i < crumbs.length; i++)
            Row(
              children: [
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    crumbs[i].$1,
                    style: i == crumbs.length - 1
                        ? TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          )
                        : null,
                  ),
                  onPressed: () => _loadDir(crumbs[i].$2),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 当前视图的排序副本（浏览模式文件夹置顶；搜索结果纯按所选键；隐藏文件过滤）
  List<Map<dynamic, dynamic>> _sortedView() {
    final list = _displayList
        .where(
          (e) => _showHidden || !((e['name'] as String? ?? '').startsWith('.')),
        )
        .toList();
    int sizeOf(Map<dynamic, dynamic> e) => e['isDir'] == true
        ? ((e['dirSize'] as num?)?.toInt() ?? 0)
        : ((e['size'] as num?)?.toInt() ?? 0);
    int cmp(Map<dynamic, dynamic> a, Map<dynamic, dynamic> b) {
      switch (_sortKey) {
        case 'size':
          return sizeOf(a).compareTo(sizeOf(b));
        case 'time':
          return (((a['mtime'] as num?)?.toInt() ?? 0)).compareTo(
            ((b['mtime'] as num?)?.toInt() ?? 0),
          );
        default:
          return ((a['name'] as String? ?? '').toLowerCase()).compareTo(
            (b['name'] as String? ?? '').toLowerCase(),
          );
      }
    }

    final searching = _isSearching;
    list.sort((a, b) {
      if (!searching) {
        final ad = a['isDir'] == true, bd = b['isDir'] == true;
        if (ad != bd) return ad ? -1 : 1;
      }
      final c = cmp(a, b);
      return _sortDesc ? -c : c;
    });
    return list;
  }

  static String _dirTrailing(Map<dynamic, dynamic> e) {
    final n = (e['dirCount'] as num?)?.toInt();
    final s = (e['dirSize'] as num?)?.toInt();
    if (n == null || s == null) return '[文件夹]';
    return '$n 项 · ${fmtSize(s)}';
  }

  Widget _listArea() {
    if (_isSearching) {
      // 懒加载会话：总数即时，滚动按需取页
      if (_isLazySession) {
        if (_sessTotal == 0) {
          return Center(
            child: Text('无匹配结果', style: Theme.of(context).textTheme.bodySmall),
          );
        }
        return ListView.builder(
          itemCount: _sessTotal,
          itemExtent: 60,
          itemBuilder: (context, i) {
            final row = _lazyRowAt(i);
            if (row == null) return _skeletonTile();
            return _tile(row, browsing: false);
          },
        );
      }
      if (_results.isEmpty) {
        return Center(
          child: Text('无匹配结果', style: Theme.of(context).textTheme.bodySmall),
        );
      }
      final view = _sortedView();
      return ListView.builder(
        itemCount: view.length,
        itemExtent: 60,
        itemBuilder: (context, i) => _tile(view[i], browsing: false),
      );
    }
    // 浏览模式
    if (_loadingDir) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_dirError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_dirError!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => _loadDir(_currentDir),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_dirEntries.isEmpty) {
      // 扫描进行中 ≠ 空文件夹：明确告知构建中，别误导
      if (_scanning || _entries == 0) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 12),
              Text('正在构建索引…',
                  style: Theme.of(context).textTheme.bodySmall),
              Text('当前目录内容即刻可用，索引完成后搜索生效',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11)),
            ],
          ),
        );
      }
      return Center(
        child: Text('空文件夹', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    final view = _sortedView();
    return ListView.builder(
      itemCount: view.length,
      itemExtent: 60,
      itemBuilder: (context, i) => _tile(view[i], browsing: true),
    );
  }

  /// 懒加载占位行
  Widget _skeletonTile() {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: Container(
        width: 24, height: 24,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          shape: BoxShape.circle,
        ),
      ),
      title: Container(
        height: 12,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      subtitle: Container(
        height: 8,
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }

  /// 收起键盘并让搜索框失焦（跳转子页/打开面板前调用，
  /// 否则返回时焦点自动还给搜索框、键盘会再次弹起）
  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  Widget _tile(Map<dynamic, dynamic> e, {required bool browsing}) {
    final theme = Theme.of(context);
    final isDir = e['isDir'] == true;
    final path = e['path'] as String? ?? '';
    final name = e['name'] as String? ?? '';
    final (label, icon, color) = describe(
      name,
      isDir,
      folderColor: theme.colorScheme.primary,
    );
    final selected = _selected.contains(path);
    final compactPath = TextStyle(
      fontSize: 11,
      height: 1.15,
      color: theme.colorScheme.outline,
    );
    // 缩略图（非多选、图片、无特权路径读不了时报错兜底成图标）
    final thumb = !_selecting && !isDir && isImageName(name);

    return ListTile(
      dense: true,
      // selected 时 ListTile 只认 selectedTileColor（tileColor 被忽略）
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.25),
      leading: thumb
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 42,
                height: 42,
                child: Image.file(
                  File(path),
                  cacheWidth: 128,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Icon(icon, color: color),
                ),
              ),
            )
          // 与缩略图同尺寸的图标盒：避免两种行高导致文本基线错位
          : SizedBox(
              width: 42,
              height: 42,
              child: Center(child: Icon(icon, color: color)),
            ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: browsing
          ? Text(
              fmtDate(((e['mtime'] as num?)?.toInt() ?? 0)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: compactPath,
            )
          : Text(path, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: compactPath),
      trailing: _selecting
          ? null
          : isDir
          ? Text(_dirTrailing(e), style: theme.textTheme.bodySmall)
          : Text(
              fmtSize(((e['size'] as num?)?.toInt() ?? 0)),
              style: theme.textTheme.bodySmall,
            ),
      selected: selected,
      onTap: () {
        if (_selecting) {
          _toggle(path);
        } else if (isDir && browsing) {
          _unfocus();
          _loadDir(path);
        } else if (isDir &&
            _appScope != null &&
            _searchCtl.text.trim().isEmpty) {
          // 应用检索默认视图：点目录入口 → 进入普通浏览
          _unfocus();
          setState(() => _appScope = null);
          _loadDir(path);
        } else if (!isDir &&
            browsing &&
            VFArchives.isBrowsableArchive(name)) {
          // 浏览模式点 zip/rar：进入压缩包虚拟层级
          _unfocus();
          _loadDir('$path!/');
        } else if (!isDir && isImageName(name)) {
          _recordHistory(_searchCtl.text);
          _unfocus();
          _viewImage(e);
        } else if (!isDir && (isVideoName(name) || isAudioName(name))) {
          _recordHistory(_searchCtl.text);
          _unfocus();
          _openMedia(e);
        } else if (!isDir && isTextLikeName(name)) {
          _recordHistory(_searchCtl.text);
          _unfocus();
          _previewText(e);
        } else {
          _unfocus();
          _showDetail(e);
        }
      },
      onLongPress: () =>
          _selecting ? _rangeSelectTo(path) : _enterSelection(path),
    );
  }

  void _showDetail(Map<dynamic, dynamic> e) {
    final isDir = e['isDir'] == true;
    final path = e['path'] as String? ?? '';
    final name = e['name'] as String? ?? '';
    final (label, icon, color) = describe(
      name,
      isDir,
      folderColor: Theme.of(context).colorScheme.primary,
    );
    final dirCount = (e['dirCount'] as num?)?.toInt();
    final dirSize = (e['dirSize'] as num?)?.toInt();
    final isImage = !isDir && isImageName(name);
    final isZip = !isDir && VFArchives.isBrowsableArchive(name);
    final isMedia = !isDir && (isVideoName(name) || isAudioName(name));
    final isApk = !isDir &&
        const {'apk', 'xapk', 'apks'}
            .contains(name.substring(name.lastIndexOf('.') + 1).toLowerCase());
    final isText = !isDir && isTextLikeName(name);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      name,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 文本均可长按选中复制
              SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '类型：$label${isDir ? '' : ' · ${fmtSize(((e['size'] as num?)?.toInt() ?? 0))}'}',
                    ),
                    if (isDir) ...[
                      const SizedBox(height: 6),
                      Text(
                        '子项：${dirCount != null ? '$dirCount 项' : '—'}'
                        ' · 总大小：${dirSize != null ? fmtSize(dirSize) : '—'}',
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                        '修改时间：${fmtDate(((e['mtime'] as num?)?.toInt() ?? 0))}'),
                    const SizedBox(height: 6),
                    Text('路径：$path',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 操作块：整块可点
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (isDir)
                    _detailAction(
                      Icons.subdirectory_arrow_right,
                      '进入文件夹',
                      () {
                        Navigator.pop(context);
                        _searchCtl.clear();
                        setState(() {
                          _appScope = null;
                          _results = const [];
                        });
                        _loadDir(path);
                      },
                    ),
                  if (isZip)
                    _detailAction(
                      Icons.folder_zip,
                      '浏览压缩包',
                      () {
                        Navigator.pop(context);
                        _searchCtl.clear();
                        setState(() {
                          _appScope = null;
                          _results = const [];
                        });
                        _loadDir('$path!/');
                      },
                    ),
                  if (!isDir && isImage)
                    _detailAction(
                      Icons.image,
                      '查看',
                      () {
                        Navigator.pop(context);
                        _viewImage(e);
                      },
                    ),
                  if (!isDir && isText)
                    _detailAction(
                      Icons.description,
                      '预览',
                      () {
                        Navigator.pop(context);
                        _previewText(e);
                      },
                    ),
                  if (isMedia)
                    _detailAction(
                      Icons.play_circle,
                      '播放',
                      () {
                        Navigator.pop(context);
                        _openMedia(e);
                      },
                    ),
                  if (isApk)
                    _detailAction(
                      Icons.install_mobile,
                      '安装',
                      () {
                        Navigator.pop(context);
                        _installApk(e);
                      },
                    ),
                  if (!isDir)
                    _detailAction(
                      Icons.fingerprint,
                      '校验',
                      () {
                        Navigator.pop(context);
                        _showHash(e);
                      },
                    ),
                  if (!isDir && !isImage)
                    _detailAction(
                      Icons.open_in_new,
                      '打开',
                      () {
                        Navigator.pop(context);
                        _openItem(e);
                      },
                    ),
                  if (!isDir)
                    _detailAction(
                      Icons.share,
                      '分享',
                      () {
                        Navigator.pop(context);
                        _sharePaths([path]);
                      },
                    ),
                  _detailAction(
                    Icons.drive_file_rename_outline,
                    '重命名',
                    () {
                      Navigator.pop(context);
                      _renameItem(e);
                    },
                  ),
                  _detailAction(
                    Icons.content_copy,
                    '复制路径',
                    () {
                      Navigator.pop(context);
                      _copyPaths([path]);
                    },
                  ),
                  _detailAction(
                    Icons.delete_outline,
                    '删除',
                    () {
                      Navigator.pop(context);
                      _confirmDelete([e]);
                    },
                    color: Theme.of(context).colorScheme.error,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 详情面板的块状操作按钮（整个色块都是点击区）
  Widget _detailAction(IconData icon, String label, VoidCallback onTap,
      {Color? color}) {
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        foregroundColor: color,
        backgroundColor: color?.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

extension _StrX on String {
  String substringBeforeLast(String sep) {
    final i = lastIndexOf(sep);
    return i <= 0 ? '' : substring(0, i);
  }

  String substringAfterLast(String sep) {
    final i = lastIndexOf(sep);
    return i < 0 ? this : substring(i + 1);
  }
}
