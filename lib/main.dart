import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const ViewFileApp());

class ViewFileApp extends StatelessWidget {
  const ViewFileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ViewFile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4F8CFF),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// 原生引擎通道封装
class EngineApi {
  static const _m = MethodChannel('viewfile/engine');
  static const _scanEvents = EventChannel('viewfile/scan');

  Future<bool> hasPermission() async => await _m.invokeMethod<bool>('hasPermission') ?? false;
  Future<void> requestPermission() => _m.invokeMethod('requestPermission');
  Future<Map<dynamic, dynamic>> stats() async =>
      Map<dynamic, dynamic>.from(await _m.invokeMethod('stats'));
  Future<int> ensureIndexLoaded() async => await _m.invokeMethod<int>('ensureIndexLoaded') ?? 0;
  Future<void> startScan() => _m.invokeMethod('startScan');
  Future<List<Map<dynamic, dynamic>>> search(String query, {int limit = 200}) async {
    final list = await _m.invokeMethod<List<dynamic>>('search',
        {'query': query, 'limit': limit});
    return list?.map((e) => Map<dynamic, dynamic>.from(e)).toList() ?? const [];
  }

  Stream<Map<dynamic, dynamic>> scanEvents() =>
      _scanEvents.receiveBroadcastStream().map((e) => Map<dynamic, dynamic>.from(e));
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
  bool _scanning = false;
  String _statusLine = '';
  int _entries = 0;
  int _lastScanMs = 0;
  int _loadMs = 0;

  List<Map<dynamic, dynamic>> _results = const [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api.scanEvents().listen(_onScanEvent, onError: (_) {});
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final ok = await _api.hasPermission();
    setState(() => _hasPerm = ok);
    if (!ok) return;
    final n = await _api.ensureIndexLoaded();
    setState(() => _entries = n);
    if (n == 0) {
      // 首次启动自动建索引
      await _api.startScan();
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
      debugPrint('[ViewFile] 扫描完成: $files 文件 + $dirs 文件夹, 耗时 $ms ms, 载入 ${_loadMs}ms');
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

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      if (q.trim().isEmpty) {
        setState(() => _results = const []);
        return;
      }
      setState(() => _searching = true);
      final r = await _api.search(q);
      if (mounted) {
        setState(() {
          _results = r;
          _searching = false;
        });
      }
    });
  }

  Future<void> _rescan() async {
    if (_scanning) return;
    await _api.startScan();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置授权返回后重新检查权限
    if (state == AppLifecycleState.resumed && _hasPerm == false) {
      _bootstrap();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ViewFile'),
        actions: [
          IconButton(
            tooltip: '重建索引',
            onPressed: _hasPerm == true ? _rescan : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_hasPerm != true) _permissionCard(),
          _statusCard(),
          _searchField(),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _resultsList()),
        ],
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
      final sec = (_lastScanMs / 1000.0).toStringAsFixed(1);
      text = '索引 $_entries 条 · 上次扫描 $sec s · 内存载入 $_loadMs ms';
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
          hintText: _entries > 0 ? '输入文件名，多词空格分隔为 AND' : '等待索引建立…',
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
      itemBuilder: (context, i) {
        final e = _results[i];
        final isDir = e['isDir'] == true;
        final path = e['path'] as String? ?? '';
        final parent = isDir ? path : (path.split('/')..removeLast()).join('/');
        return ListTile(
          dense: true,
          leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file,
              color: isDir ? Colors.amber : null),
          title: Text(e['name'] as String? ?? '',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(parent, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text(_fmtSize(((e['size'] as num?)?.toInt() ?? 0)),
              style: Theme.of(context).textTheme.bodySmall),
          onTap: () => _showDetail(e),
        );
      },
    );
  }

  void _showDetail(Map<dynamic, dynamic> e) {
    final path = e['path'] as String? ?? '';
    final mtime = DateTime.fromMillisecondsSinceEpoch(
        ((e['mtime'] as num?)?.toInt() ?? 0) * 1000);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e['name'] as String? ?? '',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text('路径\n$path'),
              const SizedBox(height: 8),
              Text(
                  '类型\n${e['isDir'] == true ? '文件夹' : '文件 · ${_fmtSize(((e['size'] as num?)?.toInt() ?? 0))}'}'),
              const SizedBox(height: 8),
              Text(
                  '修改时间\n${mtime.year}-${mtime.month.toString().padLeft(2, '0')}-${mtime.day.toString().padLeft(2, '0')} ${mtime.hour.toString().padLeft(2, '0')}:${mtime.minute.toString().padLeft(2, '0')}'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: path));
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('路径已复制')));
                    },
                    child: const Text('复制路径'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
