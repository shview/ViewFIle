import 'package:flutter/material.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';

/// 目标目录选择器：浏览目录树，选定后返回路径。
/// 用于复制/移动的目标位置。
class DestPickerPage extends StatefulWidget {
  const DestPickerPage({
    super.key,
    required this.title,
    this.initialDir = '/storage/emulated/0',
  });

  final String title;
  final String initialDir;

  @override
  State<DestPickerPage> createState() => _DestPickerPageState();
}

class _DestPickerPageState extends State<DestPickerPage> {
  final _api = EngineApi();
  String _currentDir = '/storage/emulated/0';
  List<Map<dynamic, dynamic>> _dirs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentDir = widget.initialDir;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await _api.listDir(_currentDir);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r['ok'] == true) {
        _dirs = List<Map<dynamic, dynamic>>.from(r['entries'] ?? const [])
            .where((e) => e['isDir'] == true)
            .toList();
      } else {
        _dirs = [];
        _error = r['error'] as String?;
      }
    });
  }

  void _navigateUp() {
    if (_currentDir == '/storage/emulated/0') return;
    final parent =
        _currentDir.substring(0, _currentDir.lastIndexOf('/'));
    _currentDir = parent;
    _load();
  }

  Future<void> _newFolder() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('创建')),
        ],
      ),
    );
    if (ok != true || ctl.text.trim().isEmpty) return;
    final name = ctl.text.trim();
    final r = await _api.listDir('$_currentDir/$name');
    if (r['ok'] == true) return; // 已存在
    // 通过 mkdir channel 创建（复用 rename 的路径）
    // 简化：用 listDir 探测后通过 transfer 的目标目录不存在时的自动创建
    // 直接用原生 mkdir
    await _api.mkdir('$_currentDir/$name');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: _currentDir == '/storage/emulated/0',
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _navigateUp();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: '上一级',
              onPressed: _currentDir == '/storage/emulated/0' ? null : _navigateUp,
              icon: const Icon(Icons.arrow_upward),
            ),
            IconButton(
              tooltip: '新建文件夹',
              onPressed: _newFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
          ],
        ),
        body: Column(
          children: [
            // 当前路径
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              child: Text(
                _currentDir,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 目录列表
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!, style: theme.textTheme.bodySmall))
                      : _dirs.isEmpty
                          ? Center(
                              child: Text('无子文件夹',
                                  style: theme.textTheme.bodySmall))
                          : ListView.builder(
                              itemCount: _dirs.length,
                              itemExtent: 56,
                              itemBuilder: (context, i) {
                                final d = _dirs[i];
                                final count =
                                    (d['dirCount'] as num?)?.toInt() ?? 0;
                                return ListTile(
                                  dense: true,
                                  leading: Icon(Icons.folder,
                                      color: theme.colorScheme.primary),
                                  title: Text(d['name'] as String? ?? ''),
                                  trailing: Text('$count 项',
                                      style: theme.textTheme.bodySmall),
                                  onTap: () {
                                    _currentDir = d['path'] as String;
                                    _load();
                                  },
                                );
                              },
                            ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              icon: const Icon(Icons.check),
              label: Text('选择此处'),
              onPressed: () => Navigator.pop(context, _currentDir),
            ),
          ),
        ),
      ),
    );
  }
}
