import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';
import 'dest_picker_page.dart';

/// 扁平化可见行（DFS 展开序），选择/区间选择与主页逻辑一致
class _Row {
  _Row(this.entry, this.depth, this.pctBase, {this.isRoot = false})
      : loading = false;
  _Row.loading(this.depth)
      : entry = const {},
        pctBase = -1,
        isRoot = false,
        loading = true;

  final Map<dynamic, dynamic> entry;
  final int depth; // 缩进层级（根=0）
  final int pctBase; // 百分比基数 = 父目录总大小（WizTree 语义），-1 = 无
  final bool isRoot;
  final bool loading;

  String get path => entry['path'] as String? ?? '';
  String get name => entry['name'] as String? ?? '';
  bool get isDir => entry['isDir'] == true;
}

/// WizTree 式空间分析：树形展开 + 饼图下钻，按递归大小排序，彩色百分比标签
class StorageAnalysisPage extends StatefulWidget {
  const StorageAnalysisPage({super.key, this.initialPath = '/storage/emulated/0'});

  final String initialPath;

  @override
  State<StorageAnalysisPage> createState() => _StorageAnalysisPageState();
}

class _StorageAnalysisPageState extends State<StorageAnalysisPage> {
  final _api = EngineApi();
  static const _kSdcard = '/storage/emulated/0';

  late String _rootPath;
  bool _pieMode = false;
  String _piePath = _kSdcard;

  // 排序：size | name | time（默认按大小降序，WizTree 风格）
  String _sortKey = 'size';
  bool _sortDesc = true;

  // 树状态
  final _childrenCache = <String, List<Map<dynamic, dynamic>>>{};
  final _loadingDirs = <String>{};
  final _expanded = <String>{};
  final _rows = <_Row>[];

  // 多选状态
  bool _selecting = false;
  final _selected = <String>{};
  int _anchorIdx = -1;

  @override
  void initState() {
    super.initState();
    _rootPath = widget.initialPath;
    _piePath = _rootPath;
    _expanded.add(_rootPath);
    _ensureLoad(_rootPath);
    _rebuild();
  }

  int _sizeOf(Map<dynamic, dynamic> e) => e['isDir'] == true
      ? (e['dirSize'] as num?)?.toInt() ?? 0
      : (e['size'] as num?)?.toInt() ?? 0;

  void _sortList(List<Map<dynamic, dynamic>> l) {
    l.sort((a, b) {
      int c;
      switch (_sortKey) {
        case 'name':
          c = ((a['name'] as String? ?? '').toLowerCase())
              .compareTo((b['name'] as String? ?? '').toLowerCase());
        case 'time':
          c = ((a['mtime'] as num?)?.toInt() ?? 0)
              .compareTo((b['mtime'] as num?)?.toInt() ?? 0);
        default:
          c = _sizeOf(a).compareTo(_sizeOf(b));
      }
      return _sortDesc ? -c : c;
    });
  }

  Future<void> _ensureLoad(String dir) async {
    if (_childrenCache.containsKey(dir) || _loadingDirs.contains(dir)) return;
    _loadingDirs.add(dir);
    final r = await _api.listDir(dir);
    if (!mounted) return;
    _loadingDirs.remove(dir);
    if (r['ok'] == true) {
      final kids = [
        for (final e in (r['entries'] as List? ?? const []))
          Map<dynamic, dynamic>.from(e),
      ].where((e) => _sizeOf(e) > 0).toList();
      _sortList(kids);
      _childrenCache[dir] = kids;
    } else {
      _childrenCache[dir] = const [];
    }
    _rebuild();
  }

  void _rebuild() {
    if (!mounted) return;
    setState(_rebuildRaw);
  }

  void _rebuildRaw() {
    _rows.clear();
    final rootKids = _childrenCache[_rootPath];
    final rootTotal =
        rootKids?.fold<int>(0, (s, e) => s + _sizeOf(e)) ?? 0;
    _rows.add(_Row(
      {
        'path': _rootPath,
        'name': _rootPath == _kSdcard ? '内部存储' : _rootPath.substring(_rootPath.lastIndexOf('/') + 1),
        'isDir': true,
        'dirSize': rootTotal,
        'size': 0,
        'mtime': 0,
      },
      0,
      -1,
      isRoot: true,
    ));
    if (_expanded.contains(_rootPath)) _walk(_rootPath, 1);
  }

  /// WizTree 语义：每行百分比 = 占其父文件夹的比例（与横条宽度一致），
  /// 层级从属靠缩进线 + 条宽的视觉包含关系表达
  void _walk(String dir, int depth) {
    final kids = _childrenCache[dir];
    if (kids == null) {
      _rows.add(_Row.loading(depth));
      return;
    }
    final parentTotal = kids.fold<int>(0, (s, e) => s + _sizeOf(e));
    for (final child in kids) {
      _rows.add(_Row(child, depth, parentTotal));
      if (child['isDir'] == true) {
        final p = child['path'] as String;
        if (_expanded.contains(p)) _walk(p, depth + 1);
      }
    }
  }

  // ---------- 展开 ----------

  void _toggleExpand(String path) {
    setState(() {
      if (!_expanded.remove(path)) _expanded.add(path);
      // 必须重建行列表：_rows 是快照，只改集合不重走 walk 界面不会变
      // （此前收回/展开已缓存目录无效的根因）
      _rebuildRaw();
    });
    _ensureLoad(path);
  }

  // ---------- 多选（与主页逻辑一致） ----------

  List<_Row> get _selectableRows =>
      _rows.where((r) => !r.loading && !r.isRoot).toList();

  void _enterSelection(int idx) => setState(() {
        _selecting = true;
        _selected.add(_rows[idx].path);
        _anchorIdx = idx;
      });

  void _toggleAt(int idx) => setState(() {
        final p = _rows[idx].path;
        if (!_selected.remove(p)) _selected.add(p);
        _anchorIdx = idx;
      });

  void _rangeSelectTo(int idx) {
    final a = _anchorIdx, b = idx;
    if (a < 0 || a >= _rows.length || b < 0 || b >= _rows.length) return;
    final lo = math.min(a, b), hi = math.max(a, b);
    setState(() {
      for (var i = lo; i <= hi; i++) {
        final r = _rows[i];
        if (!r.loading && !r.isRoot) _selected.add(r.path);
      }
    });
  }

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
        _anchorIdx = -1;
      });

  void _selectAll() => setState(() {
        _selected.addAll(_selectableRows.map((r) => r.path));
      });

  void _selectNone() => setState(() => _selected.clear());

  void _invertSelection() => setState(() {
        final next = _selectableRows
            .where((r) => !_selected.contains(r.path))
            .map((r) => r.path)
            .toSet();
        _selected
          ..clear()
          ..addAll(next);
      });

  bool get _allSelectedAreFiles {
    final rows = _selectableRows.where((r) => _selected.contains(r.path));
    return rows.isNotEmpty && rows.every((r) => !r.isDir);
  }

  Future<void> _copyPaths() async {
    await Clipboard.setData(ClipboardData(text: _selected.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('已复制 ${_selected.length} 个路径'),
          duration: const Duration(seconds: 1)),
    );
    _exitSelection();
  }

  Future<void> _sharePaths() async {
    final err = await _api.share(_selected.toList());
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _transferSelected({required bool move}) async {
    if (_selected.isEmpty) return;
    final dest = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => DestPickerPage(
          title: move ? '移动到...' : '复制到...',
          initialDir: _rootPath,
        ),
      ),
    );
    if (dest == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${move ? '移动' : '复制'} ${_selected.length} 项到 $dest ...'),
      duration: const Duration(seconds: 2),
    ));
    final r = await _api.transfer(_selected.toList(), dest, move: move);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: r['ok'] == true
          ? Text("已${move ? '移动' : '复制'} ${r['succeeded']} 项到 $dest")
          : Text("部分失败：${r['succeeded']} 成功，${r['failedCount']} 失败"),
    ));
    if (r['ok'] == true) _afterMutation();
  }

  Future<void> _deleteSelected() async {
    final paths = _selected.toList();
    final files = _selectableRows
        .where((r) => _selected.contains(r.path) && !r.isDir)
        .length;
    final dirs = paths.length - files;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除？'),
        content: Text(
          '将删除 $files 个文件、$dirs 个文件夹（共 ${paths.length} 项）。\n\n'
          '此操作不可恢复，也不会进入回收站。',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final r = await _api.delete(paths);
    if (!mounted) return;
    final ok = r['ok'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '已删除' : '删除失败：${r['error'] ?? '部分项目失败'}'),
      duration: const Duration(seconds: 2),
    ));
    if (ok) _afterMutation();
  }

  /// 删除/移动后：目录大小全部失效，重载根
  void _afterMutation() => _resetTo(_rootPath);

  void _resetTo(String path) {
    setState(() {
      _rootPath = path;
      _piePath = path;
      _selecting = false;
      _selected.clear();
      _anchorIdx = -1;
      _childrenCache.clear();
      _loadingDirs.clear();
      _expanded
        ..clear()
        ..add(path);
    });
    _ensureLoad(path);
    _rebuild();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_selecting && !(_pieMode && _piePath != _rootPath),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _exitSelection();
        } else if (_pieMode && _piePath != _rootPath) {
          // 饼图下钻后返回 = 回上一级，而不是退出页面
          setState(() {
            _piePath =
                _piePath.substring(0, _piePath.lastIndexOf('/'));
            if (_piePath.isEmpty) _piePath = _rootPath;
          });
        }
      },
      child: Scaffold(
        appBar: _selecting ? _buildSelectAppBar() : _buildAppBar(),
        body: Column(
          children: [
            Expanded(
              child: _pieMode
                  ? _PieView(
                      key: ValueKey('pie-$_piePath'),
                      path: _piePath,
                      api: _api,
                      onDrillDown: (p) => setState(() => _piePath = p),
                    )
                  : ListView.builder(
                      itemCount: _rows.length,
                      itemBuilder: (context, i) => _buildRow(_rows[i], i),
                    ),
            ),
            if (_selecting) _buildBottomBar(theme),
          ],
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: Text(_pieMode
          ? (_piePath == _rootPath ? '空间分析' : _piePath.split('/').last)
          : '空间分析'),
      actions: [
        if (_pieMode && _piePath != _rootPath)
          IconButton(
            tooltip: '上一级',
            icon: const Icon(Icons.arrow_upward),
            onPressed: () => setState(() {
              _piePath =
                  _piePath.substring(0, _piePath.lastIndexOf('/'));
              if (_piePath.isEmpty) _piePath = _rootPath;
            }),
          ),
        IconButton(
          tooltip: '回到内部存储根目录',
          icon: const Icon(Icons.home_outlined),
          onPressed: _rootPath == _kSdcard
              ? null
              : () => _resetTo(_kSdcard),
        ),
        if (!_pieMode)
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
                for (final l in _childrenCache.values) {
                  _sortList(l);
                }
              });
              _rebuild();
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'size',
                checked: _sortKey == 'size',
                child: const Text('大小'),
              ),
              CheckedPopupMenuItem(
                value: 'name',
                checked: _sortKey == 'name',
                child: const Text('名称'),
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
          tooltip: _pieMode ? '切换到树形' : '切换到饼图',
          icon: Icon(_pieMode ? Icons.account_tree : Icons.pie_chart),
          onPressed: () => setState(() => _pieMode = !_pieMode),
        ),
      ],
    );
  }

  AppBar _buildSelectAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelection,
      ),
      title: Text('已选 ${_selected.length} 项'),
      actions: [
        IconButton(
          tooltip: '全选',
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

  Widget _buildBottomBar(ThemeData theme) {
    Widget action(IconData icon, String label, VoidCallback onTap,
        {bool enabled = true, Color? color}) {
      final c = color ?? (enabled ? theme.colorScheme.onSurface : theme.disabledColor);
      return SizedBox(
        width: 76,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: c, size: 22),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(fontSize: 11, color: c),
                  maxLines: 1),
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
              action(Icons.share, '分享', _sharePaths,
                  enabled: _allSelectedAreFiles),
              action(Icons.content_copy, '复制路径', _copyPaths),
              action(Icons.file_copy_outlined, '复制到', () => _transferSelected(move: false)),
              action(Icons.drive_file_move_outlined, '移动到', () => _transferSelected(move: true)),
              action(Icons.delete, '删除', _deleteSelected,
                  color: theme.colorScheme.error),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(_Row r, int idx) {
    final theme = Theme.of(context);
    final selected = _selected.contains(r.path);
    final size = r.isRoot ? (r.entry['dirSize'] as num?)?.toInt() ?? 0 : _sizeOf(r.entry);
    final pct = (!r.isRoot && r.pctBase > 0) ? size / r.pctBase : null;

    if (r.loading) {
      return Padding(
        padding: EdgeInsets.only(left: 20.0 + r.depth * 20.0, top: 6, bottom: 6),
        child: Row(
          children: [
            const SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text('加载中…', style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }

    return InkWell(
      onTap: () {
        if (_selecting) {
          _toggleAt(idx);
        } else if (r.isDir) {
          _toggleExpand(r.path);
        }
      },
      onLongPress: () =>
          _selecting ? _rangeSelectTo(idx) : _enterSelection(idx),
      child: Container(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.25)
            : null,
        padding: const EdgeInsets.only(right: 10),
        child: Row(
          children: [
            // 左侧层级竖线（每级一条）
            for (var i = 0; i < r.depth; i++)
              SizedBox(
                width: 20,
                height: 38,
                child: Center(
                  child: Container(width: 1, color: theme.dividerColor),
                ),
              ),
            if (!_selecting && r.isDir)
              Icon(
                _expanded.contains(r.path)
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 20,
                color: theme.colorScheme.outline,
              )
            else if (!_selecting)
              // 占位对齐：文件行没有展开箭头，补同宽避免缩进错位
              const SizedBox(width: 20),
            Icon(
              r.isDir ? Icons.folder : _fileIcon(r.name),
              size: 16,
              color: r.isDir ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                r.name,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: r.depth < 2 ? FontWeight.w600 : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 百分比（占父文件夹，WizTree 语义）
            if (pct != null) ...[
              SizedBox(
                width: 52,
                child: Text(
                  '${(pct * 100).toStringAsFixed(pct >= 0.1 ? 1 : 2)}%',
                  style: TextStyle(
                    color: Color.lerp(
                        theme.colorScheme.onSurface, _pctColor(pct), 0.7),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            SizedBox(
              width: 66,
              child: Text(
                fmtSize(size),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  fontWeight: r.isRoot ? FontWeight.w700 : null,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 相对父文件夹的百分比配色（WizTree 语义）
  static Color _pctColor(double pct) {
    if (pct > 0.3) return const Color(0xFFE53935);
    if (pct > 0.15) return const Color(0xFFFB8C00);
    if (pct > 0.05) return const Color(0xFFFDD835);
    if (pct > 0.02) return const Color(0xFF43A047);
    return const Color(0xFF1E88E5);
  }

  static IconData _fileIcon(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(ext)) return Icons.image;
    if (['mp4', 'mkv', 'avi', 'mov'].contains(ext)) return Icons.movie;
    if (['mp3', 'flac', 'wav', 'ogg'].contains(ext)) return Icons.audiotrack;
    if (['zip', 'rar', '7z', 'tar'].contains(ext)) return Icons.folder_zip;
    if (ext == 'apk') return Icons.android;
    return Icons.insert_drive_file;
  }
}

// ==================== 饼图视图 ====================

class _PieView extends StatefulWidget {
  const _PieView({
    super.key,
    required this.path,
    required this.api,
    required this.onDrillDown,
  });

  final String path;
  final EngineApi api;
  final void Function(String) onDrillDown;

  @override
  State<_PieView> createState() => _PieViewState();
}

class _PieViewState extends State<_PieView> {
  List<Map<dynamic, dynamic>> _items = [];
  bool _loading = true;
  int _totalSize = 0;
  int _pressedIndex = -1;

  static const _palette = [
    Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835),
    Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA),
    Color(0xFFD81B60), Color(0xFF00ACC1), Color(0xFF6D4C41),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.api.listDir(widget.path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r['ok'] == true) {
        _items = [
          for (final e in (r['entries'] as List? ?? const []))
            Map<dynamic, dynamic>.from(e),
        ].where((e) => _sizeOf(e) > 0).toList()
          ..sort((a, b) => _sizeOf(b).compareTo(_sizeOf(a)));
        _totalSize = _items.fold<int>(0, (s, e) => s + _sizeOf(e));
      }
    });
  }

  int _sizeOf(Map<dynamic, dynamic> e) => e['isDir'] == true
      ? (e['dirSize'] as num?)?.toInt() ?? 0
      : (e['size'] as num?)?.toInt() ?? 0;

  int _sliceAt(Offset pos, double size) {
    final center = Offset(size / 2, size / 2);
    final dx = pos.dx - center.dx;
    final dy = pos.dy - center.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    final outer = size / 2 - 6;
    final inner = outer - 58;
    if (dist > outer || dist < inner) return -1;

    var angle = math.atan2(dy, dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    if (angle >= 2 * math.pi) angle -= 2 * math.pi;

    final sliceCount = math.min(_items.length, 10);
    var cumulative = 0.0;
    for (var i = 0; i < sliceCount; i++) {
      final sweep = _sliceFraction(i) * 2 * math.pi;
      if (angle >= cumulative && angle < cumulative + sweep) return i;
      cumulative += sweep;
    }
    return -1;
  }

  double _sliceFraction(int i) {
    if (_totalSize <= 0) return 0;
    if (i < math.min(_items.length, 9)) return _sizeOf(_items[i]) / _totalSize;
    var rest = 0;
    for (var j = 9; j < _items.length; j++) {
      rest += _sizeOf(_items[j]);
    }
    return rest / _totalSize;
  }

  void _onSliceTap(int i) {
    if (i < 0) return;
    if (i < math.min(_items.length, 9)) {
      final e = _items[i];
      if (e['isDir'] == true) widget.onDrillDown(e['path'] as String);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return Center(child: Text('无数据', style: Theme.of(context).textTheme.bodySmall));
    }
    final theme = Theme.of(context);
    final dirName = widget.path == '/storage/emulated/0'
        ? '内部存储'
        : widget.path.substring(widget.path.lastIndexOf('/') + 1);

    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 20),
          Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => setState(() => _pressedIndex = _sliceAt(d.localPosition, 300)),
                onTapUp: (d) {
                  final i = _sliceAt(d.localPosition, 300);
                  setState(() => _pressedIndex = -1);
                  _onSliceTap(i);
                },
                onTapCancel: () => setState(() => _pressedIndex = -1),
                child: CustomPaint(
                  painter: _PiePainter(
                    items: _items,
                    totalSize: _totalSize,
                    pressedIndex: _pressedIndex,
                    centerLabel: '$dirName\n${fmtSize(_totalSize)}',
                    labelStyle: theme.textTheme.titleSmall!,
                  ),
                  size: const Size(300, 300),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ...List.generate(math.min(_items.length, 10), (i) {
            final isOther = i == 9;
            final name =
                isOther ? '其他（${_items.length - 9} 项）' : _items[i]['name'] as String? ?? '';
            final size = (_sliceFraction(i) * _totalSize).round();
            final pct = _sliceFraction(i) * 100;
            final color = isOther ? const Color(0xFF78909C) : _palette[i];
            final drillable = !isOther && _items[i]['isDir'] == true;
            return InkWell(
              onTap: drillable ? () => _onSliceTap(i) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${pct.toStringAsFixed(1)}%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 66,
                      child: Text(
                        fmtSize(size),
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 环形饼图：前 9 项独立扇区 + “其他”聚合，按下扇区外扩高亮，扇区内绘制百分比
class _PiePainter extends CustomPainter {
  _PiePainter({
    required this.items,
    required this.totalSize,
    required this.pressedIndex,
    required this.centerLabel,
    required this.labelStyle,
  });

  final List<Map<dynamic, dynamic>> items;
  final int totalSize;
  final int pressedIndex;
  final String centerLabel;
  final TextStyle labelStyle;

  static const _palette = [
    Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835),
    Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA),
    Color(0xFFD81B60), Color(0xFF00ACC1), Color(0xFF6D4C41),
  ];

  int _sizeOf(Map<dynamic, dynamic> e) => e['isDir'] == true
      ? (e['dirSize'] as num?)?.toInt() ?? 0
      : (e['size'] as num?)?.toInt() ?? 0;

  double _sliceFraction(int i) {
    if (totalSize <= 0) return 0;
    if (i < math.min(items.length, 9)) return _sizeOf(items[i]) / totalSize;
    var rest = 0;
    for (var j = 9; j < items.length; j++) {
      rest += _sizeOf(items[j]);
    }
    return rest / totalSize;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width / 2 - 6;
    final innerR = outerR - 58;
    final sliceCount = math.min(items.length, 10);

    var start = -math.pi / 2;
    for (var i = 0; i < sliceCount; i++) {
      final sweep = _sliceFraction(i) * 2 * math.pi;
      if (sweep <= 0) continue;
      final pressed = i == pressedIndex;
      final r = pressed ? outerR + 6 : outerR;
      final color = i == 9 ? const Color(0xFF78909C) : _palette[i];

      final path = Path()
        ..arcTo(Rect.fromCircle(center: center, radius: r), start, sweep, false)
        ..arcTo(Rect.fromCircle(center: center, radius: innerR), start + sweep, -sweep, false)
        ..close();
      canvas.drawPath(path, Paint()..color = color);

      if (_sliceFraction(i) >= 0.04) {
        final mid = start + sweep / 2;
        final labelR = (r + innerR) / 2;
        final pos = center + Offset(math.cos(mid), math.sin(mid)) * labelR;
        final tp = TextPainter(
          text: TextSpan(
            text: '${(_sliceFraction(i) * 100).toStringAsFixed(0)}%',
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
      }
      start += sweep;
    }

    final lines = centerLabel.split('\n');
    var cy = center.dy -
        (lines.length * labelStyle.fontSize! * labelStyle.height!) / 2;
    for (final line in lines) {
      final tp = TextPainter(
        text: TextSpan(text: line, style: labelStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: innerR * 1.7);
      tp.paint(canvas, Offset(center.dx - tp.width / 2, cy));
      cy += labelStyle.fontSize! * labelStyle.height!;
    }
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.items != items ||
      old.pressedIndex != pressedIndex ||
      old.totalSize != totalSize;
}
