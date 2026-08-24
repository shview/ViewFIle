import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/engine_api.dart';
import '../utils/archive_support.dart';
import '../utils/format.dart';
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
  bool _showHidden = false;
  bool _cfgExpanded = false;

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
      _showHidden = p.getBool('showHidden') ?? false;
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextField(
            controller: _q,
            focusNode: _focus,
            autofocus: widget.initialQuery.isEmpty,
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
      ),
      body: Column(
        children: [
          if (_cfgExpanded) _buildCfgPanel(theme),
          if (_showHistory()) _buildHistory(theme),
          if (_hasQuery)
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
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildList(theme)),
        ],
      ),
    );
  }

  int get _totalShown =>
      _sessId >= 0 ? _sessTotal : _localResults.length;

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
            // 大小 + 时间
            Row(
              children: [
                Text('大小', style: theme.textTheme.labelSmall),
                const SizedBox(width: 8),
                SizedBox(
                  width: 58,
                  child: TextField(
                    controller: _sizeMin,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        isDense: true, hintText: '最小', suffix: Text('MB')),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) => _onQueryChanged(''),
                  ),
                ),
                const Text(' — '),
                SizedBox(
                  width: 58,
                  child: TextField(
                    controller: _sizeMax,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        isDense: true, hintText: '最大', suffix: Text('MB')),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) => _onQueryChanged(''),
                  ),
                ),
                const SizedBox(width: 16),
                Text('时间', style: theme.textTheme.labelSmall),
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
                        setState(() => _dateMode = m);
                        _saveCfg();
                        if (_hasQuery) _runQuery();
                      },
                    ),
                ],
              ),
            ),
            Row(
              children: [
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
                const SizedBox(width: 8),
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
        itemExtent: 60,
        itemBuilder: (context, i) => _tile(theme, _localResults[i]),
      );
    }
    if (_sessTotal == 0) {
      return Center(
          child: Text('无匹配结果', style: theme.textTheme.bodySmall));
    }
    return ListView.builder(
      itemCount: _sessTotal,
      itemExtent: 60,
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
    return ListTile(
      dense: true,
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
      subtitle: GestureDetector(
        onTap: () => _scopeTo(path.substring(0, path.lastIndexOf('/'))),
        child: Row(
          children: [
            Flexible(
              child: Text(path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: compact),
            ),
            Icon(Icons.filter_alt, size: 11, color: theme.colorScheme.outline),
          ],
        ),
      ),
      trailing: Text(
        isDir ? '' : fmtSize(((e['size'] as num?)?.toInt() ?? 0)),
        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
      ),
      onTap: () => _openEntry(e),
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
