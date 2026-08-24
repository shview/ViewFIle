import 'package:flutter/material.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';

/// 大文件查重：大小过滤（用户输入阈值）→ 按大小分组 → 头 1MB MD5 二次分组
class DupePage extends StatefulWidget {
  const DupePage({super.key});

  @override
  State<DupePage> createState() => _DupePageState();
}

class _DupeGroup {
  _DupeGroup(this.size, {this.verified = false});
  final int size;
  bool verified; // false = 大小相同的候选（指纹比对中）
  final files = <Map<dynamic, dynamic>>[];
}

class _DupePageState extends State<DupePage> {
  final _api = EngineApi();
  final _sizeCtl = TextEditingController(text: '10');

  String? _phase; // null=待开始 / 'scan' / 'hash' / null done
  double? _progress;
  List<_DupeGroup> _groups = [];
  int _scanned = 0;
  int _dupBytes = 0;
  final _selected = <String>{};

  Future<void> _start() async {
    final mb = double.tryParse(_sizeCtl.text.trim());
    if (mb == null || mb <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入有效的大小阈值（MB）')));
      return;
    }
    setState(() {
      _phase = 'scan';
      _progress = null;
      _groups = const [];
      _scanned = 0;
      _dupBytes = 0;
      _selected.clear();
    });
    // 引擎会话：>Nmb + 大小降序（同尺寸天然相邻）+ 排除隐藏
    final start = await _api.searchStart('>=${mb.toStringAsFixed(0)}mb',
        sortKey: 'size', sortDesc: true, hideDot: true);
    final total = (start['total'] as num?)?.toInt() ?? 0;
    final sessId = (start['id'] as num?)?.toInt() ?? -1;
    final bySize = <int, List<Map<dynamic, dynamic>>>{};
    var fetched = 0;
    while (fetched < total) {
      final page =
          await _api.searchPage(sessId, fetched, 500);
      if (page.isEmpty) break;
      for (final e in page) {
        if (e['isDir'] == true) continue;
        final s = (e['size'] as num?)?.toInt() ?? 0;
        bySize.putIfAbsent(s, () => []).add(e);
      }
      fetched += page.length;
      if (mounted) setState(() => _progress = fetched / total);
    }
    _scanned = fetched;

    // 阶段一：大小相同的候选组立即上屏（后台逐组精筛，界面实时收敛）
    final candidates = [
      for (final e in bySize.entries)
        if (e.value.length >= 2) e.value
    ];
    if (!mounted) return;
    setState(() {
      _phase = null;
      _groups = [
            for (final c in candidates)
              _DupeGroup((c.first['size'] as num?)?.toInt() ?? 0)
                ..files.addAll(c),
          ]..sort((a, b) => b.size.compareTo(a.size));
    });
    _refine();
  }

  /// 阶段二：逐组比对头 1MB 指纹，把候选组替换为确认重复组（无重复则移除）
  Future<void> _refine() async {
    setState(() => _phase = 'hash');
    final total = _groups.length;
    var done = 0;
    for (final g in List<_DupeGroup>.of(_groups)) {
      if (!mounted) return;
      final byHead = <String, List<Map<dynamic, dynamic>>>{};
      var seq = 0;
      for (final f in g.files) {
        final r = await _api.hashHead(f['path'] as String);
        final h = r['ok'] == true ? r['md5'] as String? : 'err-${seq++}';
        byHead.putIfAbsent(h ?? '?', () => []).add(f);
      }
      done++;
      if (!mounted) return;
      setState(() {
        _progress = total == 0 ? null : done / total;
        final refined = <_DupeGroup>[
          for (final v in byHead.values)
            if (v.length >= 2)
              _DupeGroup(g.size, verified: true)..files.addAll(v),
        ];
        final i = _groups.indexOf(g);
        if (refined.isEmpty) {
          _groups.removeAt(i);
        } else {
          _groups.replaceRange(i, i + 1, refined);
        }
        _dupBytes = _groups.fold<int>(
            0, (s, g2) => s + g2.size * (g2.files.length - 1));
      });
    }
    if (mounted) setState(() => _phase = null);
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除重复文件？'),
        content: Text('选中的 $n 项将被永久删除，不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _phase = 'hash');
    final r = await EngineApi().delete(_selected.toList());
    if (mounted) {
      setState(() => _phase = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['ok'] == true ? '已删除 $n 项' : '部分删除失败')));
      _start(); // 重新扫描
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _phase != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('大文件查重'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '批量选择',
            icon: const Icon(Icons.checklist),
            onSelected: (v) => setState(() {
              switch (v) {
                case 'all':
                  for (final g in _groups) {
                    for (final f in g.files) {
                      _selected.add(f['path'] as String);
                    }
                  }
                case 'none':
                  _selected.clear();
                case 'invert':
                  final all = <String>{
                    for (final g in _groups)
                      for (final f in g.files) f['path'] as String,
                  };
                  final next = all.difference(_selected);
                  _selected
                    ..clear()
                    ..addAll(next);
                case 'old':
                  // 选中每组较早的重复，保留最新一份
                  for (final g in _groups) {
                    if (g.files.length < 2) continue;
                    final sorted = [...g.files]..sort((a, b) =>
                        ((a['mtime'] as num?)?.toInt() ?? 0).compareTo(
                            (b['mtime'] as num?)?.toInt() ?? 0));
                    for (final f in sorted.take(sorted.length - 1)) {
                      _selected.add(f['path'] as String);
                    }
                  }
              }
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all', child: Text('全选所有重复文件')),
              PopupMenuItem(value: 'none', child: Text('全不选')),
              PopupMenuItem(value: 'invert', child: Text('反选')),
              PopupMenuItem(value: 'old', child: Text('选中所有旧版本（每组保留最新）')),
            ],
          ),
          if (_selected.isNotEmpty)
            IconButton(
              tooltip: '删除所选',
              icon: Icon(Icons.delete, color: theme.colorScheme.error),
              onPressed: busy ? null : _deleteSelected,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Text('大于'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 64,
                  child: TextField(
                    controller: _sizeCtl,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        isDense: true, suffixText: 'MB'),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: busy ? null : _start,
                  child: Text(_groups.isEmpty ? '开始' : '重新扫描'),
                ),
                const Spacer(),
                if (_groups.isNotEmpty)
                  Text(
                    '${_groups.length} 组 · 可释放 ${fmtSize(_dupBytes)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
              ],
            ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  LinearProgressIndicator(value: _progress, minHeight: 3),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _phase == 'scan' ? '扫描大文件…' : '比对文件指纹…',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _groups.isEmpty && !busy
                ? Center(
                    child: Text(
                        _scanned > 0 ? '未发现重复的大文件' : '输入阈值后开始查重（大小相同 + 头 1MB 指纹一致）',
                        style: theme.textTheme.bodySmall),
                  )
                : ListView.builder(
                    itemCount: _groups.length,
                    itemBuilder: (context, i) => _buildGroup(theme, _groups[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroup(ThemeData theme, _DupeGroup g) {
    final groupPaths = g.files.map((f) => f['path'] as String).toList();
    final selCount =
        groupPaths.where((p) => _selected.contains(p)).length;
    final groupChecked = selCount == groupPaths.length;
    final groupPartial = selCount > 0 && !groupChecked;
    return ExpansionTile(
      dense: true,
      leading: Checkbox(
        tristate: true,
        value: groupChecked
            ? true
            : groupPartial
                ? null
                : false,
        onChanged: (v) => setState(() {
          if (v == true) {
            _selected.addAll(groupPaths);
          } else {
            _selected.removeAll(groupPaths);
          }
        }),
      ),
      title: Text(
        '${g.files.first['name']} × ${g.files.length} · 每份 ${fmtSize(g.size)}'
        '${g.verified ? '' : ' · 比对中…'}',
        style: TextStyle(
            fontSize: 13,
            color: g.verified ? null : theme.colorScheme.outline),
      ),
      subtitle: Text(
        g.verified
            ? '可释放 ${fmtSize(g.size * (g.files.length - 1))} · 勾选整组'
            : '大小相同的候选，正在比对指纹',
        style: TextStyle(
            fontSize: 11, color: theme.colorScheme.outline),
      ),
      children: [
        for (final f in g.files)
          ListTile(
            dense: true,
            leading: IconButton(
              icon: Icon(
                _selected.contains(f['path'])
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: _selected.contains(f['path'])
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              onPressed: () => setState(() {
                if (!_selected.remove(f['path'])) _selected.add(f['path']);
              }),
            ),
            title: Text(
              f['path'] as String? ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.done_all, size: 16),
              label: const Text('选中新出的重复（保留最早）', style: TextStyle(fontSize: 12)),
              onPressed: () => setState(() {
                for (final f in g.files.skip(1)) {
                  _selected.add(f['path'] as String);
                }
              }),
            ),
          ),
        ),
      ],
    );
  }
}
