import 'package:flutter/material.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';

/// APK 安装包管理：全盘 APK 按包名分组、按体积排序，清理旧版本
class ApkPage extends StatefulWidget {
  const ApkPage({super.key});

  @override
  State<ApkPage> createState() => _ApkPageState();
}

class _ApkGroup {
  _ApkGroup(this.key);
  final String key;
  final files = <Map<dynamic, dynamic>>[];
  int get total =>
      files.fold<int>(0, (s, e) => s + ((e['size'] as num?)?.toInt() ?? 0));
}

class _ApkPageState extends State<ApkPage> {
  final _api = EngineApi();
  bool _loading = false;
  List<_ApkGroup> _groups = const [];
  final _selected = <String>{};

  /// 从文件名提取包名键：com.tencent.mm-1.2.3.apk → com.tencent.mm
  static String packageKey(String name) {
    var n = name.toLowerCase();
    if (n.endsWith('.apk')) n = n.substring(0, n.length - 4);
    final m = RegExp(r'^(.*?)[-\s_v]+\(?\d').firstMatch(n);
    var key = m != null ? m.group(1)! : n;
    if (key.isEmpty) key = n;
    return key;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final start = await _api.searchStart('',
        sortKey: 'size', sortDesc: true, category: 'apk', hideDot: true);
    final total = (start['total'] as num?)?.toInt() ?? 0;
    final id = (start['id'] as num?)?.toInt() ?? -1;
    final byKey = <String, _ApkGroup>{};
    var fetched = 0;
    while (fetched < total) {
      final page = await _api.searchPage(id, fetched, 500);
      if (page.isEmpty) break;
      for (final e in page) {
        final name = e['name'] as String? ?? '';
        byKey.putIfAbsent(packageKey(name), () => _ApkGroup(packageKey(name)))
            .files
            .add(e);
      }
      fetched += page.length;
    }
    final groups = byKey.values.where((g) => g.files.isNotEmpty).toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    if (mounted) {
      setState(() {
        _groups = groups;
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _install(String path) async {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('正在安装…')));
    final r = await _api.installApk(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r['ok'] == true ? '已发起安装' : '安装失败：${r['error']}'),
    ));
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除安装包？'),
        content: Text('选中的 $n 个 APK 将被永久删除，不可恢复。'),
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
          if (_selected.isNotEmpty)
            IconButton(
              tooltip: '删除所选',
              icon: Icon(Icons.delete, color: theme.colorScheme.error),
              onPressed: _deleteSelected,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _groups.isEmpty
              ? Center(
                  child: Text('未找到 APK 文件', style: theme.textTheme.bodySmall))
              : ListView.builder(
                  itemCount: _groups.length,
                  itemBuilder: (context, i) => _buildGroup(theme, _groups[i]),
                ),
      bottomSheet: _groups.isEmpty || dupGroups == 0
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
                    onPressed: () {
                      setState(() {
                        for (final g in _groups) {
                          if (g.files.length > 1) {
                            // 保留最新（mtime 最大），其余选中
                            final sorted = [...g.files]..sort((a, b) =>
                                ((a['mtime'] as num?)?.toInt() ?? 0)
                                    .compareTo(
                                        (b['mtime'] as num?)?.toInt() ?? 0));
                            for (final f in sorted.take(sorted.length - 1)) {
                              _selected.add(f['path'] as String);
                            }
                          }
                        }
                      });
                    },
                    child: const Text('全选旧版本'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildGroup(ThemeData theme, _ApkGroup g) {
    final multi = g.files.length > 1;
    return ExpansionTile(
      dense: true,
      leading: Icon(
        multi ? Icons.content_copy : Icons.android,
        color: multi ? theme.colorScheme.error : theme.colorScheme.primary,
        size: 20,
      ),
      title: Text(g.key,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 13, fontWeight: multi ? FontWeight.w600 : null)),
      subtitle: Text(
        '${g.files.length} 个 · ${fmtSize(g.total)}',
        style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
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
              f['name'] as String? ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Text(
              '${fmtSize(((f['size'] as num?)?.toInt() ?? 0))} · ${fmtDate(((f['mtime'] as num?)?.toInt() ?? 0))}',
              style: TextStyle(
                  fontSize: 10.5, color: theme.colorScheme.outline),
            ),
            trailing: IconButton(
              tooltip: '安装',
              icon: const Icon(Icons.install_mobile, size: 20),
              onPressed: () => _install(f['path'] as String),
            ),
          ),
      ],
    );
  }
}
