import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';
import 'settings_page.dart';

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
  bool _scanning = false;
  String _statusLine = '';
  int _entries = 0;
  int _lastScanMs = 0;
  int _loadMs = 0;
  int _resultLimit = 200;

  List<Map<dynamic, dynamic>> _results = const [];
  bool _searching = false;

  // 多选状态
  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api.scanEvents().listen(_onScanEvent, onError: (_) {});
    _loadPrefs();
    _bootstrap();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _resultLimit = prefs.getInt('resultLimit') ?? 200);
  }

  Future<void> _bootstrap() async {
    final ok = await _api.hasPermission();
    setState(() => _hasPerm = ok);
    if (!ok) return;
    final n = await _api.ensureIndexLoaded();
    setState(() => _entries = n);
    if (n == 0) {
      await _api.startScan(); // 首次启动自动建索引
    } else {
      _refreshStats();
    }
  }

  Future<void> _refreshStats() async {
    final s = await _api.stats();
    setState(() {
      _entries = (s['entries'] as num?)?.toInt() ?? _entries;
      _lastScanMs = (s['lastScanMs'] as num?)?.toInt() ?? _lastScanMs;
      _loadMs = (s['loadMs'] as num?)?.toInt() ?? _loadMs;
    });
  }

  void _onScanEvent(Map<dynamic, dynamic> e) {
    final type = e['type'] as String?;
    if (type == 'progress') {
      final files = e['files'] as int? ?? 0;
      final dirs = e['dirs'] as int? ?? 0;
      final sec = ((e['elapsedMs'] as num?)?.toDouble() ?? 0) / 1000.0;
      setState(() {
        _scanning = true;
        _statusLine = '已扫描 $files 个文件 · $dirs 个文件夹 · ${sec.toStringAsFixed(1)}s';
      });
    } else if (type == 'done') {
      final files = e['files'] as int? ?? 0;
      final dirs = e['dirs'] as int? ?? 0;
      final ms = (e['elapsedMs'] as num?)?.toInt() ?? 0;
      setState(() {
        _scanning = false;
        _entries = files + dirs;
        _lastScanMs = ms;
        _loadMs = (e['loadMs'] as num?)?.toInt() ?? 0;
        _statusLine = '';
      });
      debugPrint('[ViewFile] 扫描完成: $files 文件 + $dirs 文件夹, 耗时 $ms ms');
      _rerun(); // 用当前关键词刷新结果
      _selfTest();
    } else if (type == 'error') {
      setState(() {
        _scanning = false;
        _statusLine = '扫描失败: ${e['error']}';
      });
    }
  }

  /// 端到端自检：跑几个典型查询并打日志，验证搜索链路
  Future<void> _selfTest() async {
    const queries = ['a', '.jpg', 'android', 'pdf download'];
    for (final q in queries) {
      final t0 = DateTime.now();
      final r = await _api.search(q);
      final ms = DateTime.now().difference(t0).inMilliseconds;
      debugPrint('[ViewFile] selfTest "$q" -> ${r.length} 条, 端到端 ${ms}ms');
    }
  }

  // ---------- 搜索 ----------

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () => _runQuery(q));
  }

  Future<void> _runQuery(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    final r = await _api.search(q, limit: _resultLimit);
    if (mounted) {
      setState(() {
        _results = r;
        _searching = false;
      });
    }
  }

  /// 操作完成后用当前关键词刷新结果
  void _rerun() {
    final q = _searchCtl.text;
    if (q.trim().isNotEmpty) _runQuery(q);
    _refreshStats();
  }

  // ---------- 多选 ----------

  void _enterSelection(String path) =>
      setState(() { _selecting = true; _selected.add(path); });

  void _toggle(String path) => setState(() {
        if (!_selected.remove(path)) {
          _selected.add(path);
        }
      });

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _selectAll() => setState(() {
        _selected.addAll(_results.map((e) => e['path'] as String));
      });

  List<Map<dynamic, dynamic>> get _selectedItems => _results
      .where((e) => _selected.contains(e['path'] as String?))
      .toList(growable: false);

  bool get _allSelectedAreFiles =>
      _selectedItems.isNotEmpty && _selectedItems.every((e) => e['isDir'] != true);

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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已复制 ${paths.length} 条路径')));
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await _api.rename(path, ctl.text);
    if (!mounted) return;
    if (r['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已重命名')));
      _rerun();
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重命名失败: ${r['error']}')));
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.errorContainer),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除 ${r['deleted']} 项')));
      _exitSelection();
      _rerun();
    } else {
      final failedCount = (r['failedCount'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('部分失败：已删 ${r['deleted']} 项，失败 $failedCount 项（${r['error']}）')));
      _rerun();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasPerm == false) {
      _bootstrap(); // 从系统授权页返回后重新检查
    }
  }

  Future<void> _rescan() async {
    if (_scanning) return;
    await _api.startScan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        drawer: _selecting ? null : _buildDrawer(),
        body: Column(
          children: [
            if (_hasPerm != true) _permissionCard(),
            _statusCard(),
            _searchField(),
            if (_searching) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _resultsList()),
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
          IconButton(tooltip: '全选当前结果', icon: const Icon(Icons.select_all), onPressed: _selectAll),
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
            icon: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
            onPressed: () => _confirmDelete(_selectedItems),
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('ViewFile'),
      actions: [
        IconButton(
          tooltip: '重建索引',
          onPressed: _hasPerm == true ? _rescan : null,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _buildDrawer() {
    final theme = Theme.of(context);
    final sec = _lastScanMs > 0 ? (_lastScanMs / 1000.0).toStringAsFixed(1) : '—';
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
                    Text('索引 $_entries 条 · 扫描 $sec s · 载入 $_loadMs ms',
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text('访问层级：免 root（T1）', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
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
              subtitle: Text(_hasPerm == true ? '已授权' : '未授权',
                  style: theme.textTheme.bodySmall),
              onTap: () => _api.requestPermission(),
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SettingsPage())),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'ViewFile',
                applicationVersion: '0.1.0 (M1.5)',
                applicationLegalese: 'Android 上的 Everything：即时文件搜索 + 文件管理',
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('M2 预告：root / Shizuku 全盘索引',
                  style: theme.textTheme.bodySmall),
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
              child: Text('需要“所有文件访问”权限才能建立文件索引',
                  style: TextStyle(fontSize: 14)),
            ),
            FilledButton(
              onPressed: _hasPerm == null ? null : () => _api.requestPermission(),
              child: const Text('去授权'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    final theme = Theme.of(context);
    String text;
    if (_scanning || _statusLine.isNotEmpty) {
      text = _statusLine.isEmpty ? '正在扫描…' : _statusLine;
    } else if (_entries > 0) {
      text = '索引 $_entries 条 · 输入关键词搜索';
    } else {
      text = '索引为空，点击右上角刷新按钮开始扫描';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Icon(
            _scanning ? Icons.sync : Icons.check_circle_outline,
            size: 16,
            color: _scanning ? theme.colorScheme.primary : Colors.tealAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TextField(
        controller: _searchCtl,
        enabled: _hasPerm == true,
        onChanged: _onQueryChanged,
        decoration: InputDecoration(
          hintText: _entries > 0 ? '文件名，多词空格 = AND' : '等待索引建立…',
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
    );
  }

  Widget _resultsList() {
    if (_results.isEmpty) {
      return Center(
        child: Text(
          _searchCtl.text.isEmpty ? '索引 $_entries 条 · 输入关键词开始搜索' : '无匹配结果',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemExtent: 64,
      itemBuilder: (context, i) => _tile(_results[i]),
    );
  }

  Widget _tile(Map<dynamic, dynamic> e) {
    final isDir = e['isDir'] == true;
    final path = e['path'] as String? ?? '';
    final name = e['name'] as String? ?? '';
    final parent = isDir ? path : (path.split('/')..removeLast()).join('/');
    final (label, icon, color) = describe(name, isDir);
    final selected = _selected.contains(path);

    return ListTile(
      dense: true,
      leading: _selecting
          ? Checkbox(value: selected, onChanged: (_) => _toggle(path))
          : Icon(icon, color: color),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(parent, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _selecting
          ? null
          : isDir
              ? Text('[$label]', style: Theme.of(context).textTheme.bodySmall)
              : Text(fmtSize(((e['size'] as num?)?.toInt() ?? 0)),
                  style: Theme.of(context).textTheme.bodySmall),
      selected: selected,
      onTap: () {
        if (_selecting) {
          _toggle(path);
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
    final (label, icon, color) = describe(name, isDir);
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
                      child: Text(name,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis)),
                ],
              ),
              const SizedBox(height: 12),
              Text('类型：$label${isDir ? '' : ' · ${fmtSize(((e['size'] as num?)?.toInt() ?? 0))}'}'),
              const SizedBox(height: 6),
              Text('修改时间：${fmtDate(((e['mtime'] as num?)?.toInt() ?? 0))}'),
              const SizedBox(height: 6),
              Text('路径：$path',
                  style: Theme.of(context).textTheme.bodySmall),
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
                        foregroundColor: Theme.of(context).colorScheme.error),
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
