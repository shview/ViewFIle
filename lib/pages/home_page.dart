import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';
import '../utils/index_bootstrap.dart';
import '../utils/watcher_lifecycle.dart';
import 'apps_page.dart';
import 'settings_page.dart';
import 'tips_page.dart';

const kSdcard = '/storage/emulated/0';

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
  int _resultLimit = 200;
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
  bool _scopeAll = false; // false = 当前目录

  // 排序：name | size | time
  String _sortKey = 'name';
  bool _sortDesc = false;
  bool _showHidden = false;
  String _tier = 'NONE'; // ROOT | SHIZUKU | NONE
  int _lastScanMs = 0;
  int _loadMs = 0;
  bool _watcherDesiredForeground = true;

  // 按应用检索：{pkg, label, dirs}
  Map<String, dynamic>? _appScope;

  // 多选状态（浏览/搜索共用）
  bool _selecting = false;
  final Set<String> _selected = {};

  bool get _isSearching =>
      _searchCtl.text.trim().isNotEmpty || _appScope != null;
  List<Map<dynamic, dynamic>> get _displayList =>
      _isSearching ? _results : _dirEntries;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api.scanEvents().listen(_onScanEvent, onError: (_) {});
    _prefsReady = _loadPrefs();
    _bootstrap();
  }

  Future<void>? _prefsReady;

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _resultLimit = prefs.getInt('resultLimit') ?? 200;
      _rootIndex = prefs.getBool('rootIndex') ?? true;
      _systemIndex = prefs.getBool('systemIndex') ?? false;
      _deepData = prefs.getBool('deepDataIndex') ?? false;
      _sortKey = prefs.getString('sortKey') ?? 'name';
      _sortDesc = prefs.getBool('sortDesc') ?? false;
      _showHidden = prefs.getBool('showHidden') ?? false;
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
        _statusLine = '扫描失败: ${e['error']}';
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

  Future<void> _loadDir(String path) async {
    setState(() {
      _currentDir = path;
      _loadingDir = true;
      _dirError = null;
      _exitSelectionRaw();
    });
    final r = await _api.listDir(path);
    if (!mounted || _currentDir != path) return;
    setState(() {
      _loadingDir = false;
      if (r['ok'] == true) {
        _dirEntries = List<Map<dynamic, dynamic>>.from(
          r['entries'] ?? const [],
        );
      } else {
        _dirEntries = const [];
        _dirError = r['error'] as String?;
      }
    });
  }

  void _navigateUp() {
    if (_currentDir == kSdcard && !_root) return;
    if (_currentDir == '/') return;
    final parent = _currentDir.substringBeforeLast('/');
    _loadDir(parent.isEmpty ? '/' : parent);
  }

  // ---------- 搜索 ----------

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () => _runQuery(q));
  }

  Future<void> _runQuery(String q) async {
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
      });
      return;
    }
    List<String>? scopes;
    if (_appScope != null) {
      scopes = List<String>.from(_appScope!['dirs']);
    } else if (q.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    } else if (!_scopeAll) {
      scopes = [_currentDir];
    }
    setState(() => _searching = true);
    final r = await _api.search(q, limit: _resultLimit, scopes: scopes);
    if (mounted) {
      setState(() {
        _results = r;
        _searching = false;
      });
    }
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

  void _toggleScope() {
    setState(() => _scopeAll = !_scopeAll);
    if (_isSearching) _runQuery(_searchCtl.text);
  }

  /// 操作完成后刷新当前视图
  void _rerun() {
    if (_isSearching) {
      _runQuery(_searchCtl.text);
    } else {
      _loadDir(_currentDir);
    }
    _refreshStats();
  }

  // ---------- 多选 ----------

  void _enterSelection(String path) => setState(() {
    _selecting = true;
    _selected.add(path);
  });

  void _toggle(String path) => setState(() {
    if (!_selected.remove(path)) {
      _selected.add(path);
    }
  });

  void _exitSelection() => setState(() => _exitSelectionRaw());

  void _exitSelectionRaw() {
    _selecting = false;
    _selected.clear();
  }

  void _selectAll() => setState(() {
    _selected.addAll(_displayList.map((e) => e['path'] as String));
  });

  List<Map<dynamic, dynamic>> get _selectedItems => _displayList
      .where((e) => _selected.contains(e['path'] as String?))
      .toList(growable: false);

  bool get _allSelectedAreFiles =>
      _selectedItems.isNotEmpty &&
      _selectedItems.every((e) => e['isDir'] != true);

  // ---------- 文件操作 ----------

  Future<void> _openItem(Map<dynamic, dynamic> e) async {
    final err = await _api.open([e['path'] as String]);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
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
    _searchCtl.dispose();
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
            if (!_isSearching) _pathBar(),
            if (_searching) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _listArea()),
          ],
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
            tooltip: '分享',
            icon: const Icon(Icons.share),
            onPressed: _allSelectedAreFiles
                ? () => _sharePaths(_selected.toList())
                : null,
          ),
          IconButton(
            tooltip: '复制路径',
            icon: const Icon(Icons.content_copy),
            onPressed: () => _copyPaths(_selected.toList()),
          ),
          IconButton(
            tooltip: '删除',
            icon: Icon(
              Icons.delete,
              color: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => _confirmDelete(_selectedItems),
          ),
        ],
      );
    }
    final title = _appScope != null
        ? '应用：${_appScope!['label']}'
        : _isSearching
        ? '搜索${_scopeAll ? '（全盘）' : '（当前目录）'}'
        : _dirTitle(_currentDir);
    return AppBar(
      title: Text(title),
      actions: [
        if (_appScope != null)
          IconButton(
            tooltip: '退出应用检索',
            icon: const Icon(Icons.close),
            onPressed: _clearAppScope,
          ),
        PopupMenuButton<String>(
          tooltip: '排序',
          icon: const Icon(Icons.sort),
          onSelected: (v) {
            setState(() {
              if (v == 'desc') {
                _sortDesc = !_sortDesc;
              } else {
                _sortKey = v;
              }
            });
            _saveSort();
          },
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: 'name',
              checked: _sortKey == 'name',
              child: const Text('名称'),
            ),
            CheckedPopupMenuItem(
              value: 'size',
              checked: _sortKey == 'size',
              child: const Text('大小'),
            ),
            CheckedPopupMenuItem(
              value: 'time',
              checked: _sortKey == 'time',
              child: const Text('修改时间'),
            ),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(
              value: 'desc',
              checked: _sortDesc,
              child: const Text('降序'),
            ),
          ],
        ),
        IconButton(
          tooltip: '上一级',
          onPressed:
              (_isSearching ||
                  (_currentDir == kSdcard && !_root) ||
                  _currentDir == '/')
              ? null
              : _navigateUp,
          icon: const Icon(Icons.arrow_upward),
        ),
        IconButton(
          tooltip: '重建索引',
          onPressed: _hasPerm == true ? _rescan : null,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  String _dirTitle(String path) {
    if (path == kSdcard) return '内部存储';
    if (path == '/') return '根目录 /';
    return path.substringAfterLast('/');
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
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('系统存储权限'),
              subtitle: Text(
                _hasPerm == true ? '已授权' : '未授权',
                style: theme.textTheme.bodySmall,
              ),
              onTap: () => _api.requestPermission(),
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
              enabled: _hasPerm == true,
              onChanged: _onQueryChanged,
              decoration: InputDecoration(
                hintText: _appScope != null
                    ? '在 ${_appScope!['label']} 内搜索…'
                    : (_entries > 0
                          ? '在${_scopeAll ? '全盘' : '当前目录'}搜索…'
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
              message: _scopeAll ? '当前搜索全盘，点击改为当前目录' : '当前搜索当前目录，点击改为全盘',
              child: ActionChip(
                avatar: Icon(
                  _scopeAll ? Icons.public : Icons.subdirectory_arrow_right,
                  size: 18,
                ),
                label: Text(_scopeAll ? '全盘' : '当前目录'),
                onPressed: _toggleScope,
              ),
            ),
        ],
      ),
    );
  }

  /// 面包屑路径条（浏览模式）
  Widget _pathBar() {
    final theme = Theme.of(context);
    final crumbs = <(String, String)>[
      if (_root) ('/', '/'),
      if (_currentDir == kSdcard || _currentDir.startsWith('$kSdcard/'))
        ('内部存储', kSdcard),
    ];
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
      if (_results.isEmpty) {
        return Center(
          child: Text('无匹配结果', style: Theme.of(context).textTheme.bodySmall),
        );
      }
      final view = _sortedView();
      return ListView.builder(
        itemCount: view.length,
        itemExtent: 64,
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
      return Center(
        child: Text('空文件夹', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    final view = _sortedView();
    return ListView.builder(
      itemCount: view.length,
      itemExtent: 64,
      itemBuilder: (context, i) => _tile(view[i], browsing: true),
    );
  }

  Widget _tile(Map<dynamic, dynamic> e, {required bool browsing}) {
    final isDir = e['isDir'] == true;
    final path = e['path'] as String? ?? '';
    final name = e['name'] as String? ?? '';
    final (label, icon, color) = describe(
      name,
      isDir,
      folderColor: Theme.of(context).colorScheme.primary,
    );
    final selected = _selected.contains(path);

    return ListTile(
      dense: true,
      leading: _selecting
          ? Checkbox(value: selected, onChanged: (_) => _toggle(path))
          : Icon(icon, color: color),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: browsing
          ? Text(
              fmtDate(((e['mtime'] as num?)?.toInt() ?? 0)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _selecting
          ? null
          : isDir
          ? Text(_dirTrailing(e), style: Theme.of(context).textTheme.bodySmall)
          : Text(
              fmtSize(((e['size'] as num?)?.toInt() ?? 0)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
      selected: selected,
      onTap: () {
        if (_selecting) {
          _toggle(path);
        } else if (isDir && browsing) {
          _loadDir(path);
        } else if (isDir &&
            _appScope != null &&
            _searchCtl.text.trim().isEmpty) {
          // 应用检索默认视图：点目录入口 → 进入普通浏览
          setState(() => _appScope = null);
          _loadDir(path);
        } else {
          _showDetail(e);
        }
      },
      onLongPress: () => _enterSelection(path),
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
              Text('修改时间：${fmtDate(((e['mtime'] as num?)?.toInt() ?? 0))}'),
              const SizedBox(height: 6),
              Text('路径：$path', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              OverflowBar(
                alignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (!isDir)
                    TextButton.icon(
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('打开'),
                      onPressed: () {
                        Navigator.pop(context);
                        _openItem(e);
                      },
                    ),
                  if (!isDir)
                    TextButton.icon(
                      icon: const Icon(Icons.share),
                      label: const Text('分享'),
                      onPressed: () {
                        Navigator.pop(context);
                        _sharePaths([path]);
                      },
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.drive_file_rename_outline),
                    label: const Text('重命名'),
                    onPressed: () {
                      Navigator.pop(context);
                      _renameItem(e);
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.content_copy),
                    label: const Text('路径'),
                    onPressed: () {
                      Navigator.pop(context);
                      _copyPaths([path]);
                    },
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除'),
                    onPressed: () {
                      Navigator.pop(context);
                      _confirmDelete([e]);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
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
