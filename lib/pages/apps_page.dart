import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/engine_api.dart';

/// 选择一个应用，返回 {pkg, label, dirs} 供按应用搜索
class AppsPage extends StatefulWidget {
  const AppsPage({super.key, required this.rootAvailable});

  final bool rootAvailable;

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  final _api = EngineApi();
  final _filterCtl = TextEditingController();
  List<Map<dynamic, dynamic>> _apps = [];
  List<Map<dynamic, dynamic>> _filtered = [];
  bool _loading = true;
  final _icons = <String, Uint8List>{};
  final _iconPending = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 行构建时懒加载图标（列表本身不等待图标）
  void _loadIcon(String pkg) {
    if (_icons.containsKey(pkg) || _iconPending.contains(pkg)) return;
    _iconPending.add(pkg);
    _api.getAppIcon(pkg).then((b) {
      if (mounted) {
        setState(() {
          if (b != null && b.isNotEmpty) _icons[pkg] = b;
          _iconPending.remove(pkg);
        });
      }
    });
  }

  Future<void> _load() async {
    try {
      final apps = await _api.listApps();
      if (mounted) {
        setState(() {
          _apps = apps;
          _filtered = apps;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onFilter(String q) {
    final key = q.trim().toLowerCase();
    setState(() => _filtered = _apps.where((a) {
          final label = (a['label'] as String? ?? '').toLowerCase();
          final pkg = (a['pkg'] as String? ?? '').toLowerCase();
          return key.isEmpty || label.contains(key) || pkg.contains(key);
        }).toList());
  }

  void _pick(Map<dynamic, dynamic> app) {
    final pkg = app['pkg'] as String;
    Navigator.pop<Map<String, dynamic>>(context, {
      'pkg': pkg,
      'label': app['label'] as String? ?? pkg,
      'dirs': [
        '/data/data/$pkg',
        '/storage/emulated/0/Android/data/$pkg',
        '/storage/emulated/0/Android/obb/$pkg',
      ],
    });
  }

  @override
  void dispose() {
    _filterCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('按应用检索')),
      body: Column(
        children: [
          if (!widget.rootAvailable)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              color: theme.colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded),
                    SizedBox(width: 8),
                    Expanded(
                        child: Text('未检测到 root：应用私有目录（/data/data）与 '
                            'Android/data 目前无法读取，仅能搜索已索引区域',
                            style: TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _filterCtl,
              onChanged: _onFilter,
              decoration: const InputDecoration(
                hintText: '过滤应用名或包名…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemExtent: 64,
                    itemBuilder: (context, i) {
                      final a = _filtered[i];
                      final pkg = a['pkg'] as String? ?? '';
                      final system = a['system'] == true;
                      _loadIcon(pkg);
                      final icon = _icons[pkg];
                      return ListTile(
                        dense: true,
                        leading: (icon != null && icon.isNotEmpty)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.memory(icon,
                                    width: 34, height: 34, fit: BoxFit.cover),
                              )
                            : Icon(
                                system ? Icons.android : Icons.apps,
                                color: system ? theme.disabledColor : null,
                              ),
                        title: Text(a['label'] as String? ?? pkg,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(pkg,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: system
                            ? Text('系统', style: theme.textTheme.bodySmall)
                            : null,
                        onTap: () => _pick(a),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
