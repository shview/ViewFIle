import 'dart:async';
import 'dart:io' show File, FileMode;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/engine_api.dart';
import '../utils/archive_support.dart';
import '../utils/format.dart';
import 'dest_picker_page.dart';
import 'image_viewer_page.dart';
import 'media_viewer_page.dart';
import 'text_preview_page.dart';

const _kSdcard = '/storage/emulated/0';

const _imageExts = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'dng', 'avif',
};
const _videoExts = {
  'mp4', 'mkv', 'avi', 'mov', 'webm', '3gp', 'm4v', 'flv', 'ts', 'mpeg', 'mpg',
};
const _audioExts = {
  'mp3', 'flac', 'wav', 'ogg', 'm4a', 'aac', 'opus', 'amr', 'wma', 'mid',
};
const _textExts = {
  'txt', 'log', 'md', 'json', 'xml', 'csv', 'html', 'htm', 'js', 'ts', 'mjs',
  'css', 'scss', 'yml', 'yaml', 'ini', 'conf', 'cfg', 'properties', 'prop',
  'toml', 'gradle', 'sh', 'bat', 'ps1', 'py', 'rb', 'java', 'kt', 'kts',
  'c', 'h', 'cpp', 'hpp', 'cs', 'go', 'rs', 'swift', 'php', 'sql', 'svg',
};

bool _extIn(String name, Set<String> set) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && set.contains(name.substring(dot + 1).toLowerCase());
}

/// 搜索专页：复杂配置（范围/大小写/类型/大小/时间可视化）+ 懒加载结果
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    this.initialDir = _kSdcard,
    this.initialQuery = '',
    this.appScope,
    this.onBrowse,
  });

  final String initialDir;
  final String initialQuery;
  /// 按应用检索：{pkg, label, dirs}
  final Map<String, dynamic>? appScope;
  /// 请求主页浏览某路径（目录 / 压缩包虚拟路径）
  final void Function(String path)? onBrowse;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _api = EngineApi();
  final _q = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  // 配置（持久化）
  int _scopeMode = 1; // 0=当前目录 1=全盘 2=当前界面
  bool _caseSensitive = false;
  String? _category;
  final _sizeMin = TextEditingController();
  final _sizeMax = TextEditingController();
  String? _dateMode; // today/yesterday/thisweek/thismonth/thisyear
  final _dateFrom = TextEditingController(); // yyyy-MM-dd
  final _dateTo = TextEditingController();
  bool _showHidden = false;
  bool _cfgExpanded = false;
  int _pathLines = 3; // 路径显示行数：1/2/3，0=自适应完整展开

  String _sortKey = 'name';
  bool _sortDesc = false;

  String _scopeDir = _kSdcard;

  // 结果（懒加载会话）
  int _sessId = -1;
  int _sessTotal = 0;
  static const _pageSize = 300;
  final _pages = <int, List<Map<dynamic, dynamic>>>{};
  int _querySeq = 0;
  bool _sessionRebuilding = false;
  bool _searching = false;
  List<Map<dynamic, dynamic>> _localResults = const []; // scope2 / appScope 入口
  List<Map<dynamic, dynamic>> _viewBase = const [];
  List<String> _history = const [];

  // 多选
  bool _selecting = false;
  final Set<String> _selected = {};
  String? _anchorPath;
  bool _exporting = false;
  int _exportDone = 0;

  bool get _hasQuery => _q.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _q.text = widget.initialQuery;
    _scopeDir = widget.initialDir;
    _loadPrefs();
    _loadHistory();
    if (_hasQuery) {
      _runQuery();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _focus.dispose();
    _sizeMin.dispose();
    _sizeMax.dispose();
    _dateFrom.dispose();
    _dateTo.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _scopeMode = p.getInt('searchScope') ??
          (widget.appScope != null ? 0 : 1);
      _caseSensitive = p.getBool('searchCase') ?? false;
      final cat = p.getString('searchCategory');
      _category = (cat == null || cat.isEmpty) ? null : cat;
      _sizeMin.text = p.getString('searchSizeMin') ?? '';
      _sizeMax.text = p.getString('searchSizeMax') ?? '';
      final d = p.getString('searchDateMode');
      _dateMode = (d == null || d.isEmpty) ? null : d;
      _dateFrom.text = p.getString('searchDateFrom') ?? '';
      _dateTo.text = p.getString('searchDateTo') ?? '';
      _showHidden = p.getBool('showHidden') ?? false;
      _pathLines = p.getInt('pathLines') ?? 3;
      _sortKey = p.getString('sortKey') ?? 'name';
      _sortDesc = p.getBool('sortDesc') ?? false;
    });
    if (_hasQuery) _runQuery();
  }

  Future<void> _saveCfg() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('searchScope', _scopeMode);
    await p.setBool('searchCase', _caseSensitive);
    await p.setString('searchCategory', _category ?? '');
    await p.setString('searchSizeMin', _sizeMin.text);
    await p.setString('searchSizeMax', _sizeMax.text);
    await p.setString('searchDateMode', _dateMode ?? '');
    await p.setString('searchDateFrom', _dateFrom.text);
    await p.setString('searchDateTo', _dateTo.text);
  }

  Future<void> _loadHistory() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _history = p.getStringList('searchHistory') ?? const []);
    }
  }

  Future<void> _recordHistory() async {
    final q = _q.text.trim();
    if (q.length < 2) return;
    final p = await SharedPreferences.getInstance();
    final list = [..._history.where((h) => h != q), q];
    if (list.length > 20) list.removeRange(0, list.length - 20);
    await p.setStringList('searchHistory', list);
    if (mounted) setState(() => _history = list);
  }

  // ---------- 查询 ----------

  String get _builtQuery {
    final parts = <String>[_q.text.trim()];
    final min = double.tryParse(_sizeMin.text.trim());
    final max = double.tryParse(_sizeMax.text.trim());
    if (min != null && min > 0) parts.add('>=${min.toStringAsFixed(0)}mb');
    if (max != null && max > 0) parts.add('<=${max.toStringAsFixed(0)}mb');
    if (_dateMode != null) parts.add(_dateMode!);
    final dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    final from = _dateFrom.text.trim();
    final to = _dateTo.text.trim();
    if (dateRe.hasMatch(from)) parts.add('>$from');
    if (dateRe.hasMatch(to)) parts.add('<=$to');
    return parts.where((s) => s.isNotEmpty).join(' ');
  }

  void _onQueryChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _runQuery);
  }

  Future<void> _runQuery() async {
    // 按应用检索的空查询：显示入口目录
    if (widget.appScope != null && !_hasQuery &&
        _sizeMin.text.isEmpty &&
        _sizeMax.text.isEmpty &&
        _dateMode == null) {
      final dirs = List<String>.from(widget.appScope!['dirs']);
      setState(() {
        _localResults = dirs
            .map((d) => <dynamic, dynamic>{
                  'path': d,
                  'name': d.contains('/Android/data/')
                      ? 'Android/data'
                      : d.contains('/Android/obb/')
                          ? 'Android/obb'
                          : d.substring(d.lastIndexOf('/') + 1),
                  'isDir': true,
                  'size': 0,
                  'mtime': 0,
                })
            .toList();
        _viewBase = _localResults;
        _sessId = -1;
        _pages.clear();
      });
      return;
    }
    if (!_hasQuery) {
      setState(() {
        _localResults = const [];
        _sessId = -1;
        _sessTotal = 0;
        _pages.clear();
      });
      return;
    }
    // 当前界面：在基底内本地过滤
    if (widget.appScope == null && _scopeMode == 2) {
      final needle = _q.text.trim().toLowerCase();
      setState(() {
        _localResults = _viewBase
            .where((e) => _matchLocal(e, needle))
            .toList();
        _sessId = -1;
        _pages.clear();
      });
      return;
    }
    List<String>? scopes;
    if (widget.appScope != null) {
      scopes = List<String>.from(widget.appScope!['dirs']);
    } else if (_scopeMode == 0) {
      scopes = [_scopeDir];
    }
    final seq = ++_querySeq;
    setState(() => _searching = true);
    final r = await _api.searchStart(
      _builtQuery,
      scopes: scopes,
      sortKey: _sortKey,
      sortDesc: _sortDesc,
      category: _category,
      hideDot: !_showHidden,
      caseSensitive: _caseSensitive,
    );
    if (!mounted || seq != _querySeq) return;
    setState(() {
      _sessId = (r['id'] as num?)?.toInt() ?? -1;
      _sessTotal = (r['total'] as num?)?.toInt() ?? 0;
      _searching = false;
      _localResults = const [];
      _pages.clear();
    });
  }

  bool _matchLocal(Map e, String needle) {
    final name = (e['name'] as String? ?? '');
    final hit = _caseSensitive
        ? name.contains(needle)
        : name.toLowerCase().contains(needle);
    if (!hit) return false;
    if (!_showHidden && name.startsWith('.')) return false;
    if (_category != null && !_matchCategoryLocal(e)) return false;
    return true;
  }

  bool _matchCategoryLocal(Map e) {
    final name = (e['name'] as String? ?? '');
    switch (_category) {
      case 'image':
        return _extIn(name, _imageExts);
      case 'video':
        return _extIn(name, _videoExts);
      case 'audio':
        return _extIn(name, _audioExts);
      case 'doc':
        return _extIn(name, _textExts) ||
            _extIn(name, const {'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'epub', 'mobi'});
      case 'apk':
        return _extIn(name, const {'apk', 'xapk', 'apks'});
      case 'archive':
        return _extIn(name, const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'});
      default:
        return true;
    }
  }

  Map<dynamic, dynamic>? _lazyRowAt(int i) {
    if (i >= _sessTotal) return null;
    final page = i ~/ _pageSize;
    final rows = _pages[page];
    if (rows == null) {
      _fetchPage(page);
      return null;
    }
    final idx = i - page * _pageSize;
    return idx < rows.length ? rows[idx] : null;
  }

  Future<void> _fetchPage(int page) async {
    if (_pages.containsKey(page)) return;
    _pages[page] = const [];
    final id = _sessId;
    final rows = await _api.searchPage(id, page * _pageSize, _pageSize);
    if (!mounted) return;
    if (_sessId != id) {
      _pages.remove(page);
      return;
    }
    if (rows.isEmpty && page * _pageSize < _sessTotal) {
      _pages.remove(page);
      if (_sessionRebuilding) return;
      _sessionRebuilding = true;
      await _runQuery();
      _sessionRebuilding = false;
      return;
    }
    setState(() => _pages[page] = rows);
    while (_pages.length > 48) {
      _pages.remove(_pages.keys.first);
    }
  }

  // ---------- 多选 ----------

  List<Map<dynamic, dynamic>> _loadedView() {
    if (_sessId >= 0) {
      final out = <Map<dynamic, dynamic>>[];
      for (var i = 0; i < _sessTotal; i++) {
        final row = _lazyRowAt(i);
        if (row == null) break;
        out.add(row);
      }
      return out;
    }
    return _localResults;
  }

  void _enterSelection(String path) => setState(() {
        _selecting = true;
        _selected.add(path);
        _anchorPath = path;
      });

  void _toggleSel(String path) => setState(() {
        if (!_selected.remove(path)) _selected.add(path);
        _anchorPath = path;
      });

  void _rangeSelTo(String path) {
    final paths = _loadedView().map((e) => e['path'] as String).toList();
    final a = paths.indexOf(_anchorPath ?? path);
    final b = paths.indexOf(path);
    if (a < 0 || b < 0) return;
    final lo = a < b ? a : b, hi = a < b ? b : a;
    setState(() => _selected.addAll(paths.sublist(lo, hi + 1)));
  }

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
        _anchorPath = null;
      });

  void _selectAll() {
    if (_sessId >= 0 && _sessTotal > 2000) {
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

  bool get _allSelAreFiles =>
      _selectedItems.isNotEmpty &&
      _selectedItems.every((e) => e['isDir'] != true);

  Future<void> _shareSel() async {
    final err = await _api.share(_selected.toList());
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _copySelPaths() async {
    await Clipboard.setData(ClipboardData(text: _selected.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已复制路径'), duration: Duration(seconds: 1)));
    }
  }

  Future<void> _transferSel({required bool move}) async {
    final dest = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => DestPickerPage(
          title: move ? '移动到...' : '复制到...',
          initialDir: _scopeDir,
        ),
      ),
    );
    if (dest == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          Text('${move ? '移动' : '复制'} ${_selected.length} 项到 $dest ...'),
      duration: const Duration(seconds: 2),
    ));
    final r = await _api.transfer(_selected.toList(), dest, move: move);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: r['ok'] == true
          ? Text("已${move ? '移动' : '复制'} ${r['succeeded']} 项")
          : Text("部分失败：${r['succeeded']} 成功，${r['failedCount']} 失败"),
    ));
    if (r['ok'] == true) {
      _exitSelection();
      if (_hasQuery) _runQuery();
    }
  }

  Future<void> _deleteSel() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除？'),
        content: Text('选中的 $n 项将被删除，不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await _api.delete(_selected.toList());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(r['ok'] == true ? '已删除 $n 项' : '部分失败：${r['error']}')));
    _exitSelection();
    if (_hasQuery) _runQuery();
  }

  // ---------- CSV 导出 ----------

  /// 全量结果导出到 Download/viewfile_export_*.csv（UTF-8 BOM，Excel 兼容）
  Future<void> _exportCsv() async {
    if (_exporting) return;
    if (_sessId < 0 && _localResults.isEmpty) return;
    setState(() {
      _exporting = true;
      _exportDone = 0;
    });
    try {
      final now = DateTime.now();
      final name =
          'viewfile_export_${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.csv';
      final f = File('/storage/emulated/0/Download/$name');
      final sink = f.openWrite(mode: FileMode.write);
      sink.write('\ufeff名称,路径,类型,大小(字节),修改时间\r\n');
      String esc(Object? v) {
        final s = v?.toString() ?? '';
        if (s.contains(',') || s.contains('"') || s.contains('\n')) {
          return '"${s.replaceAll('"', '""')}"';
        }
        return s;
      }
      void row(Map e) {
        sink.write('${esc(e['name'])},${esc(e['path'])},'
            '${e['isDir'] == true ? '文件夹' : '文件'},'
            '${esc(e['size'] ?? 0)},'
            '${esc(fmtDate(((e['mtime'] as num?)?.toInt() ?? 0)))}\r\n');
      }
      if (_sessId >= 0) {
        var offset = 0;
        while (offset < _sessTotal) {
          final page = await _api.searchPage(_sessId, offset, 500);
          if (page.isEmpty) break;
          for (final e in page) {
            row(e);
          }
          offset += page.length;
          if (mounted) setState(() => _exportDone = offset);
        }
      } else {
        for (final e in _localResults) {
          row(e);
        }
        if (mounted) setState(() => _exportDone = _localResults.length);
      }
      await sink.flush();
      await sink.close();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已导出 $_exportDone 条到 Download/$name'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (t) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$t')));
      }
    }
    if (mounted) setState(() => _exporting = false);
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  // ---------- 打开 ----------

  Future<void> _openEntry(Map<dynamic, dynamic> e) async {
    _recordHistory();
    _focus.unfocus();
    final path = e['path'] as String;
    final name = e['name'] as String? ?? '';
    final isDir = e['isDir'] == true;
    if (isDir) {
      Navigator.pop(context);
      widget.onBrowse?.call(path);
      return;
    }
    if (VFArchives.isBrowsableArchive(name) && !VFArchives.isVirtual(path)) {
      Navigator.pop(context);
      widget.onBrowse?.call('$path!/');
      return;
    }
    if (_extIn(name, _imageExts)) {
      var p = path;
      if (VFArchives.isVirtual(p)) {
        p = await VFArchives.extractFile(p) ?? '';
      }
      if (!mounted || p.isEmpty) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ImageViewerPage(paths: [p])));
      return;
    }
    if (_extIn(name, _videoExts) || _extIn(name, _audioExts)) {
      var p = path;
      if (VFArchives.isVirtual(p)) {
        p = await VFArchives.extractFile(p) ?? '';
      }
      if (!mounted || p.isEmpty) return;
      final r = await Navigator.push<String>(
          context, MaterialPageRoute(builder: (_) => MediaViewerPage(path: p)));
      if (r == 'external') _api.open([path]);
      return;
    }
    if (_extIn(name, _textExts)) {
      var p = path;
      if (VFArchives.isVirtual(p)) {
        p = await VFArchives.extractFile(p) ?? '';
      }
      if (!mounted || p.isEmpty) return;
      await Navigator.push(
          context, MaterialPageRoute(builder: (_) => TextPreviewPage(path: p)));
      return;
    }
    // 其他类型：解压（若在压缩包内）后交给系统打开
    var p = path;
    if (VFArchives.isVirtual(p)) {
      p = await VFArchives.extractFile(p) ?? '';
      if (p.isEmpty) return;
    }
    final err = await _api.open([p]);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }

  void _scopeTo(String dir) {
    setState(() {
      _scopeMode = 0;
      _scopeDir = dir;
    });
    _saveCfg();
    if (_hasQuery) _runQuery();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已限定在 ${dir.substring(dir.lastIndexOf('/') + 1)} 内搜索'),
      duration: const Duration(seconds: 1),
    ));
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: Scaffold(
        appBar: _selecting ? _buildSelectBar(theme) : _buildSearchBar(theme),
        body: Column(
          children: [
            if (!_selecting && _cfgExpanded) _buildCfgPanel(theme),
            if (!_selecting && _showHistory()) _buildHistory(theme),
            if (_exporting)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: _sessTotal > 0
                          ? (_exportDone / _sessTotal).clamp(0.0, 1.0)
                          : null,
                      minHeight: 3,
                    ),
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('导出中… $_exportDone 条',
                          style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              )
            else if (!_selecting && _hasQuery)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '共 $_totalShown 条',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              ),
            if (_searching && !_selecting)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _buildList(theme)),
            if (_selecting) _buildBottomBar(theme),
          ],
        ),
      ),
    );
  }

  AppBar _buildSearchBar(ThemeData theme) {
    return AppBar(
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: TextField(
          controller: _q,
          focusNode: _focus,
          autofocus: widget.initialQuery.isEmpty,
          enabled: !_selecting,
          onChanged: (v) {
            setState(() {});
            _onQueryChanged(v);
          },
          onSubmitted: (v) {
            _recordHistory();
            _focus.unfocus();
            _runQuery();
          },
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: widget.appScope != null
                ? '在 ${widget.appScope!['label']} 内搜索…'
                : '搜索文件名，支持语法（>10mb today）…',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _q.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _q.clear();
                      setState(() {});
                      _runQuery();
                    },
                  ),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 14),
        ),
      ),
      actions: [
        IconButton(
          tooltip: '导出 CSV 到 Download',
          icon: _exporting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.ios_share),
          onPressed: _exporting ? null : _exportCsv,
        ),
        IconButton(
          tooltip: '排序',
          icon: const Icon(Icons.sort),
          onPressed: _pickSort,
        ),
        IconButton(
          tooltip: _cfgExpanded ? '收起筛选' : '展开筛选',
          icon: Icon(_cfgExpanded ? Icons.expand_less : Icons.tune),
          onPressed: () => setState(() => _cfgExpanded = !_cfgExpanded),
        ),
      ],
    );
  }

  AppBar _buildSelectBar(ThemeData theme) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelection,
      ),
      title: Text('已选 ${_selected.length} 项'),
      actions: [
        IconButton(
            tooltip: '全选', icon: const Icon(Icons.select_all), onPressed: _selectAll),
        IconButton(
            tooltip: '全不选',
            icon: const Icon(Icons.deselect),
            onPressed: _selectNone),
        IconButton(
            tooltip: '反选', icon: const Icon(Icons.flip), onPressed: _invertSelection),
      ],
    );
  }

  Widget _buildBottomBar(ThemeData theme) {
    Widget action(IconData icon, String label, VoidCallback onTap,
        {bool enabled = true, Color? color}) {
      final c = color ??
          (enabled ? theme.colorScheme.onSurface : theme.disabledColor);
      return Expanded(
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
          child: Row(
            children: [
              action(Icons.share, '分享', _shareSel, enabled: _allSelAreFiles),
              action(Icons.content_copy, '复制路径', _copySelPaths),
              action(Icons.file_copy_outlined, '复制到',
                  () => _transferSel(move: false)),
              action(Icons.drive_file_move_outlined, '移动到',
                  () => _transferSel(move: true)),
              action(Icons.delete, '删除', _deleteSel,
                  color: theme.colorScheme.error),
            ],
          ),
        ),
      ),
    );
  }

  int get _totalShown =>
      _sessId >= 0 ? _sessTotal : _localResults.length;

  double? get _itemExtent => switch (_pathLines) {
        1 => 60.0,
        2 => 74.0,
        3 => 88.0,
        _ => null, // 自适应：完整展开，块高不一
      };

  Future<void> _pickSort() async {
    final v = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('排序'),
        children: [
          for (final (k, label) in const [
            ('name', '名称'),
            ('size', '大小'),
            ('time', '修改时间'),
          ])
            RadioListTile<String>(
              value: k,
              groupValue: _sortKey,
              title: Text(label),
              dense: true,
              onChanged: (v) => Navigator.pop(context, v),
            ),
          RadioListTile<String>(
            value: 'desc',
            groupValue: _sortDesc ? 'desc' : 'asc',
            title: Text(_sortDesc ? '当前：降序' : '当前：升序'),
            subtitle: const Text('点击切换升降序'),
            dense: true,
            onChanged: (v) => Navigator.pop(context, 'desc'),
          ),
        ],
      ),
    );
    if (v == null) return;
    setState(() {
      if (v == 'desc') {
        _sortDesc = !_sortDesc;
      } else {
        _sortKey = v;
      }
    });
    final p = await SharedPreferences.getInstance();
    await p.setString('sortKey', _sortKey);
    await p.setBool('sortDesc', _sortDesc);
    if (_hasQuery && _sessId >= 0) _runQuery();
  }

  Widget _buildCfgPanel(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.appScope == null)
              Row(
                children: [
                  Text('范围', style: theme.textTheme.labelSmall),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('当前目录')),
                        ButtonSegment(value: 1, label: Text('全盘')),
                        ButtonSegment(value: 2, label: Text('当前界面')),
                      ],
                      selected: {_scopeMode},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                          visualDensity: VisualDensity.compact),
                      onSelectionChanged: (s) {
                        if (s.first == 2 &&
                            _viewBase.isEmpty &&
                            _sessTotal > 0) {
                          // 进入“当前界面”：以当前结果为基底
                          _viewBase = [
                            for (var i = 0; i < _sessTotal; i++)
                              if (_lazyRowAt(i) != null) _lazyRowAt(i)!,
                          ];
                        }
                        setState(() => _scopeMode = s.first);
                        _saveCfg();
                        if (_hasQuery) _runQuery();
                      },
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            // 类型
            SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final (cat, label) in const [
                    (null, '全部'),
                    ('image', '图片'),
                    ('video', '视频'),
                    ('audio', '音频'),
                    ('doc', '文档'),
                    ('apk', 'APK'),
                    ('archive', '压缩包'),
                  ])
                    FilterChip(
                      label: Text(label, style: const TextStyle(fontSize: 11)),
                      selected: _category == cat,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        setState(() => _category = cat);
                        _saveCfg();
                        if (_hasQuery) _runQuery();
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 大小（独立一行，防时间输入挤溢出）
            Row(
              children: [
                SizedBox(
                  width: 42,
                  child: Text('大小', style: theme.textTheme.labelSmall),
                ),
                SizedBox(
                  width: 76,
                  child: TextField(
                    controller: _sizeMin,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        isDense: true, hintText: '最小'),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) => _onQueryChanged(''),
                  ),
                ),
                const Text(' — '),
                SizedBox(
                  width: 76,
                  child: TextField(
                    controller: _sizeMax,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        isDense: true, hintText: '最大'),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) => _onQueryChanged(''),
                  ),
                ),
                const SizedBox(width: 6),
                Text('MB', style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 6),
            // 修改时间起止（独立一行，Expanded 自适应）
            Row(
              children: [
                SizedBox(
                  width: 42,
                  child: Text('时间', style: theme.textTheme.labelSmall),
                ),
                Expanded(
                  child: TextField(
                    controller: _dateFrom,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                        isDense: true, hintText: '起 2024-01-01'),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) {
                      setState(() => _dateMode = null); // 自定义时清快捷
                      _saveCfg();
                      _onQueryChanged('');
                    },
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text('—'),
                ),
                Expanded(
                  child: TextField(
                    controller: _dateTo,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                        isDense: true, hintText: '止 2025-12-31'),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) {
                      setState(() => _dateMode = null);
                      _saveCfg();
                      _onQueryChanged('');
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final (m, label) in const [
                    (null, '不限'),
                    ('today', '今天'),
                    ('yesterday', '昨天'),
                    ('thisweek', '本周'),
                    ('thismonth', '本月'),
                    ('thisyear', '今年'),
                  ])
                    ChoiceChip(
                      label: Text(label, style: const TextStyle(fontSize: 11)),
                      selected: _dateMode == m,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        setState(() {
                          _dateMode = m;
                          if (m != null) {
                            // 选快捷时清自定义范围
                            _dateFrom.clear();
                            _dateTo.clear();
                          }
                        });
                        _saveCfg();
                        if (_hasQuery) _runQuery();
                      },
                    ),
                ],
              ),
            ),
            // 全宽开关（Row 里挤放会截断点击区，此前“区分大小写”点不动的原因）
            SwitchListTile(
              value: _caseSensitive,
              onChanged: (v) {
                setState(() => _caseSensitive = v);
                _saveCfg();
                if (_hasQuery) _runQuery();
              },
              title: const Text('区分大小写', style: TextStyle(fontSize: 13)),
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              value: _showHidden,
              onChanged: (v) async {
                setState(() => _showHidden = v);
                final p = await SharedPreferences.getInstance();
                await p.setBool('showHidden', v);
                if (_hasQuery) _runQuery();
              },
              title: const Text('显示隐藏文件', style: TextStyle(fontSize: 13)),
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  bool _showHistory() {
    if (!_focus.hasFocus || widget.appScope != null) return false;
    if (_q.text.trim().isNotEmpty) return false;
    return _history.isNotEmpty;
  }

  Widget _buildHistory(ThemeData theme) {
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final h in _history.take(8))
            InkWell(
              onTap: () {
                _q.text = h;
                _onQueryChanged(h);
                _focus.unfocus();
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                child: Row(
                  children: [
                    Icon(Icons.history,
                        size: 16, color: theme.colorScheme.outline),
                    const SizedBox(width: 10),
                    Expanded(child: Text(h, style: theme.textTheme.bodySmall)),
                    InkWell(
                      onTap: () async {
                        final list = [..._history]..remove(h);
                        final p = await SharedPreferences.getInstance();
                        await p.setStringList('searchHistory', list);
                        setState(() => _history = list);
                      },
                      child: Icon(Icons.close,
                          size: 16, color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    // 本地结果（scope2 / 应用入口）
    if (_sessId < 0) {
      if (_localResults.isEmpty) {
        return Center(
          child: _hasQuery
              ? Text('无匹配结果', style: theme.textTheme.bodySmall)
              : Text('输入关键词开始搜索', style: theme.textTheme.bodySmall),
        );
      }
      return ListView.builder(
        itemCount: _localResults.length,
        itemExtent: _itemExtent,
        itemBuilder: (context, i) => _tile(theme, _localResults[i]),
      );
    }
    if (_sessTotal == 0) {
      return Center(
          child: Text('无匹配结果', style: theme.textTheme.bodySmall));
    }
    return ListView.builder(
      itemCount: _sessTotal,
      itemExtent: _itemExtent,
      itemBuilder: (context, i) {
        final row = _lazyRowAt(i);
        if (row == null) return _skeleton(theme);
        return _tile(theme, row);
      },
    );
  }

  Widget _skeleton(ThemeData theme) => ListTile(
        dense: true,
        leading: Container(
          width: 24,
          height: 24,
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

  Widget _tile(ThemeData theme, Map<dynamic, dynamic> e) {
    final isDir = e['isDir'] == true;
    final path = e['path'] as String? ?? '';
    final name = e['name'] as String? ?? '';
    final (label, icon, color) = describe(name, isDir,
        folderColor: theme.colorScheme.primary);
    final thumb = !isDir && _extIn(name, _imageExts);
    final compact = TextStyle(
        fontSize: 11, height: 1.15, color: theme.colorScheme.outline);
    final sel = _selecting && _selected.contains(path);
    // 路径行数：1/2/3 固定行高等高；0=自适应（完整展开，块高不一）
    final maxLines = _pathLines == 0 ? null : _pathLines;
    final pathText = Text(
      path,
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.visible : TextOverflow.ellipsis,
      style: compact,
    );
    return ListTile(
      dense: true,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.25),
      selected: sel,
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
          : SizedBox(
              width: 42,
              height: 42,
              child: Center(child: Icon(icon, color: color)),
            ),
      title: Text.rich(
        TextSpan(children: _nameSpans(theme, name)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // 多选时也保留路径与大小（路径点击收敛仅在非多选生效）
      subtitle: _selecting
          ? pathText
          : GestureDetector(
              onTap: () => _scopeTo(path.substring(0, path.lastIndexOf('/'))),
              child: Row(
                children: [
                  Flexible(child: pathText),
                  Icon(Icons.filter_alt,
                      size: 11, color: theme.colorScheme.outline),
                ],
              ),
            ),
      trailing: Text(
        isDir ? '' : fmtSize(((e['size'] as num?)?.toInt() ?? 0)),
        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
      ),
      onTap: () {
        if (_selecting) {
          _toggleSel(path);
        } else {
          _openEntry(e);
        }
      },
      onLongPress: () =>
          _selecting ? _rangeSelTo(path) : _enterSelection(path),
    );
  }

  List<InlineSpan> _nameSpans(ThemeData theme, String name) {
    final spans = <InlineSpan>[TextSpan(text: name)];
    final q = _q.text.trim();
    if (q.isEmpty) return spans;
    final tokens = q
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty && _isNameToken(t))
        .toList();
    if (tokens.isEmpty) return spans;
    final lower = name.toLowerCase();
    final ranges = <(int, int)>[];
    for (final t in tokens) {
      final needle = _caseSensitive ? t : t.toLowerCase();
      final hay = _caseSensitive ? name : lower;
      var from = 0;
      while (true) {
        final i = hay.indexOf(needle, from);
        if (i < 0) break;
        ranges.add((i, i + needle.length));
        from = i + needle.length;
      }
    }
    if (ranges.isEmpty) return spans;
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[ranges.first];
    for (final r in ranges.skip(1)) {
      if (r.$1 <= merged.last.$2) {
        merged[merged.length - 1] =
            (merged.last.$1, r.$2 > merged.last.$2 ? r.$2 : merged.last.$2);
      } else {
        merged.add(r);
      }
    }
    final hl = theme.colorScheme.primary.withValues(alpha: 0.28);
    final out = <InlineSpan>[];
    var pos = 0;
    for (final (s, e) in merged) {
      if (s > pos) out.add(TextSpan(text: name.substring(pos, s)));
      out.add(TextSpan(
        text: name.substring(s, e),
        style: TextStyle(backgroundColor: hl, fontWeight: FontWeight.w600),
      ));
      pos = e;
    }
    if (pos < name.length) out.add(TextSpan(text: name.substring(pos)));
    return out;
  }

  static bool _isNameToken(String t) {
    if (RegExp(r'^[<>]=?\d+(\.\d+)?(b|kb|mb|gb)$', caseSensitive: false)
        .hasMatch(t)) {
      return false;
    }
    if (RegExp(r'^\d+(\.\d+)?(b|kb|mb|gb)\.\.\d+(\.\d+)?(b|kb|mb|gb)$',
            caseSensitive: false)
        .hasMatch(t)) {
      return false;
    }
    if (RegExp(r'^[<>]=?\d{4}(-\d{2})?(-\d{2})?$').hasMatch(t)) return false;
    if (const {
      'today', 'yesterday', 'thisweek', 'thismonth', 'thisyear'
    }.contains(t.toLowerCase())) {
      return false;
    }
    return true;
  }
}
