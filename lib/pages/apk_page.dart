import 'package:flutter/material.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';

/// APK 安装包管理：按真实包名分组（PackageManager 读 APK 头），
/// 按占用排序清理旧版本；进入页面才加载，不占主进程资源
class ApkPage extends StatefulWidget {
  const ApkPage({super.key});

  @override
  State<ApkPage> createState() => _ApkPageState();
}

class _ApkGroup {
  _ApkGroup(this.key);
  final String key;
  final files = <Map<dynamic, dynamic>>[]; // 附带 realPkg/ver 注入字段
  int get total =>
      files.fold<int>(0, (s, e) => s + ((e['size'] as num?)?.toInt() ?? 0));
}

class _ApkPageState extends State<ApkPage> {
  final _api = EngineApi();
  String? _phase; // 'list' / 'meta' / null
  List<_ApkGroup> _groups = const [];
  final _selected = <String>{};
  int _pkgParsed = 0;
  int _pkgTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _phase = 'list');
    // 全盘 APK（引擎会话，进入本页才建）
    final start = await _api.searchStart('',
        sortKey: 'size', sortDesc: true, category: 'apk', hideDot: true);
    final total = (start['total'] as num?)?.toInt() ?? 0;
    final id = (start['id'] as num?)?.toInt() ?? -1;
    final entries = <Map<dynamic, dynamic>>[];
    var fetched = 0;
    while (fetched < total) {
      final page = await _api.searchPage(id, fetched, 500);
      if (page.isEmpty) break;
      entries.addAll(page);
      fetched += page.length;
    }
    if (!mounted) return;
    setState(() => _phase = 'meta');

    // 真实包名：PackageManager 读 APK 头（比文件名猜测可靠）
    final paths = entries.map((e) => e['path'] as String).toList();
    final metas = await _api.apkMeta(paths);
    final metaByPath = <String, Map<dynamic, dynamic>>{};
    for (final m in metas) {
      metaByPath[m['path'] as String] = m;
    }
    _pkgTotal = paths.length;
    _pkgParsed = paths
        .where((p) => (metaByPath[p]?['pkg'] as String?)?.isNotEmpty == true)
        .length;
    final byPkg = <String, _ApkGroup>{};
    for (final e in entries) {
      final p = e['path'] as String;
      final m = metaByPath[p];
      final pkg = (m?['pkg'] as String?)?.isNotEmpty == true
          ? m!['pkg'] as String
          : _fallbackKey(e['name'] as String? ?? '');
      final g = byPkg.putIfAbsent(pkg, () => _ApkGroup(pkg));
      g.files.add({...e, 'realPkg': m?['pkg'], 'ver': m?['ver']});
    }
    final groups = byPkg.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    if (mounted) {
      setState(() {
        _groups = groups;
        _phase = null;
      });
    }
  }

  static String _fallbackKey(String name) {
    var n = name.toLowerCase();
    if (n.endsWith('.apk')) n = n.substring(0, n.length - 4);
    final m = RegExp(r'^(.*?)[-\s_v]+\(?\d').firstMatch(n);
    final k = m != null ? m.group(1)! : n;
    return k.isEmpty ? n : k;
  }

  Future<void> _install(Map<dynamic, dynamic> f) async {
    final pkg = f['realPkg'] as String? ?? '未知包名';
    final ver = f['ver'] as String? ?? '?';
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装 APK？'),
        content: SelectionArea(
          child: Text(
            '包名：$pkg\n版本：$ver\n'
            '大小：${fmtSize(((f['size'] as num?)?.toInt() ?? 0))}\n'
            '路径：${f['path']}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('安装')),
        ],
      ),
    );
    if (ok != true) return;
    messenger.showSnackBar(const SnackBar(content: Text('正在安装…')));
    final r = await _api.installApk(f['path'] as String);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
        content: Text(r['ok'] == true ? '已发起安装' : '安装失败：${r['error']}')));
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除？'),
        content: Text('选中的 $n 个 APK 将被删除，不可恢复。'),
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
    setState(() => _selected.clear());
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(r['ok'] == true ? '已删除 $n 项' : '部分删除失败')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dupGroups = _groups.where((g) => g.files.length > 1).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('APK 管理'),
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
                  _selectOld();
              }
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all', child: Text('全选')),
              PopupMenuItem(value: 'none', child: Text('全不选')),
              PopupMenuItem(value: 'invert', child: Text('反选')),
              PopupMenuItem(value: 'old', child: Text('选中所有旧版本（每组保留最新）')),
            ],
          ),
          if (_selected.isNotEmpty)
            IconButton(
              tooltip: '删除所选',
              icon: Icon(Icons.delete, color: theme.colorScheme.error),
              onPressed: _deleteSelected,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_phase == null && _pkgTotal > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _pkgParsed == _pkgTotal
                      ? '$_pkgTotal 个安装包 · 包名已解析'
                      : '$_pkgTotal 个安装包 · 包名解析 $_pkgParsed'
                          '${_pkgParsed == 0 ? '（读不到包名，按文件名分组）' : ''}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            ),
          Expanded(
            child: _phase != null
                ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(strokeWidth: 2.5),
                  const SizedBox(height: 12),
                  Text(_phase == 'list' ? '扫描全盘 APK…' : '读取安装包信息…',
                      style: theme.textTheme.bodySmall),
                ],
              ),
            )
          : _groups.isEmpty
              ? Center(
                  child: Text('未找到 APK 文件',
                      style: theme.textTheme.bodySmall))
              : ListView.builder(
                  itemCount: _groups.length,
                  itemBuilder: (context, i) => _buildGroup(theme, _groups[i]),
                ),
          ),
        ],
      ),
      bottomSheet: _groups.isEmpty || dupGroups == 0 || _phase != null
          ? null
          : Padding(
              padding: EdgeInsets.only(
                  left: 16,
                  bottom: MediaQuery.of(context).padding.bottom + 8,
                  top: 4),
              child: Row(
                children: [
                  Text('$dupGroups 个应用存在多版本',
                      style: theme.textTheme.bodySmall),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(_selectOld),
                    child: const Text('全选旧版本'),
                  ),
                ],
              ),
            ),
    );
  }

  void _selectOld() {
    for (final g in _groups) {
      if (g.files.length < 2) continue;
      final sorted = [...g.files]..sort((a, b) =>
          ((a['mtime'] as num?)?.toInt() ?? 0)
              .compareTo((b['mtime'] as num?)?.toInt() ?? 0));
      for (final f in sorted.take(sorted.length - 1)) {
        _selected.add(f['path'] as String);
      }
    }
  }

  Widget _buildGroup(ThemeData theme, _ApkGroup g) {
    final multi = g.files.length > 1;
    final groupPaths = g.files.map((f) => f['path'] as String).toList();
    final selCount = groupPaths.where(_selected.contains).length;
    final groupChecked = selCount == groupPaths.length;
    final groupPartial = selCount > 0 && !groupChecked;
    final vers = {
      for (final f in g.files)
        if (f['ver'] != null) f['ver'] as String,
    };
    return ExpansionTile(
      dense: true,
      leading: Checkbox(
        tristate: true,
        value: groupChecked ? true : groupPartial ? null : false,
        onChanged: (v) => setState(() {
          if (v == true) {
            _selected.addAll(groupPaths);
          } else {
            _selected.removeAll(groupPaths);
          }
        }),
      ),
      title: Text(
        g.key,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 13, fontWeight: multi ? FontWeight.w600 : null),
      ),
      subtitle: Text(
        '${g.files.length} 个 · ${fmtSize(g.total)}'
        '${multi ? ' · 可清理旧版' : ''}'
        '${vers.length > 1 ? ' · ${vers.join(' / ')}' : ''}',
        style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
      ),
      children: [
        for (final f in g.files)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
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
                if (!_selected.remove(f['path'] as String)) {
                  _selected.add(f['path'] as String);
                }
              }),
            ),
            title: Text(
              f['name'] as String? ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            // 完整路径：同名包靠它区分来源
            subtitle: Text(
              f['path'] as String? ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 10.5, color: theme.colorScheme.outline),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      fmtSize(((f['size'] as num?)?.toInt() ?? 0)),
                      style: TextStyle(
                          fontSize: 11, color: theme.colorScheme.outline),
                    ),
                    Text(
                      f['ver'] as String? ?? '',
                      style: TextStyle(
                          fontSize: 10, color: theme.colorScheme.outline),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: '安装（有确认）',
                  icon: const Icon(Icons.install_mobile, size: 20),
                  onPressed: () => _install(f),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
