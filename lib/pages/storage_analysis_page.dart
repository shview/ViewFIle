import 'package:flutter/material.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';

/// WizTree 式空间分析：树形展开，按递归大小降序，色带表示占比
class StorageAnalysisPage extends StatefulWidget {
  const StorageAnalysisPage({super.key, this.initialPath = '/storage/emulated/0'});

  final String initialPath;

  @override
  State<StorageAnalysisPage> createState() => _StorageAnalysisPageState();
}

class _StorageAnalysisPageState extends State<StorageAnalysisPage> {
  final _api = EngineApi();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('空间分析'),
        actions: [
          IconButton(
            tooltip: '切换到根目录',
            icon: const Icon(Icons.home_outlined),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: _TreeNode(
        path: widget.initialPath,
        api: _api,
        depth: 0,
        isRoot: true,
      ),
    );
  }
}

/// 单个树节点：可展开，显示子项按大小降序
class _TreeNode extends StatefulWidget {
  const _TreeNode({
    required this.path,
    required this.api,
    required this.depth,
    this.isRoot = false,
  });

  final String path;
  final EngineApi api;
  final int depth;
  final bool isRoot;

  @override
  State<_TreeNode> createState() => _TreeNodeState();
}

class _TreeNodeState extends State<_TreeNode> {
  List<Map<dynamic, dynamic>> _children = [];
  bool _expanded = false;
  bool _loading = false;
  int _totalSize = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isRoot) {
      _expanded = true;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    final r = await widget.api.listDir(widget.path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r['ok'] == true) {
        final all = List<Map<dynamic, dynamic>>.from(r['entries'] ?? const []);
        _children = all.where((e) {
          final s = _sizeOf(e);
          return s > 0; // 只显示非空项
        }).toList()
          ..sort((a, b) => _sizeOf(b).compareTo(_sizeOf(a)));
        _totalSize = _children.fold<int>(0, (sum, e) => sum + _sizeOf(e));
      }
    });
  }

  int _sizeOf(Map<dynamic, dynamic> e) {
    if (e['isDir'] == true) {
      return (e['dirSize'] as num?)?.toInt() ?? 0;
    }
    return (e['size'] as num?)?.toInt() ?? 0;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded && _children.isEmpty) _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = widget.isRoot
        ? (widget.path == '/storage/emulated/0' ? '内部存储' : widget.path)
        : widget.path.substring(widget.path.lastIndexOf('/') + 1);

    return Column(
      children: [
        // 节点行
        InkWell(
          onTap: _toggle,
          child: Container(
            padding: EdgeInsets.fromLTRB(
                16.0 + widget.depth * 16.0, 6, 12, 6),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 20,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.folder,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: widget.depth < 2 ? FontWeight.w600 : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  fmtSize(_totalSize > 0 ? _totalSize : 0),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 展开的子节点
        if (_expanded) ...[
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            ..._children.take(50).map((child) => _buildChild(child)),
          if (_children.length > 50)
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 4),
              child: Text(
                '... 还有 ${_children.length - 50} 项',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildChild(Map<dynamic, dynamic> child) {
    final theme = Theme.of(context);
    final isDir = child['isDir'] == true;
    final name = child['name'] as String? ?? '';
    final size = _sizeOf(child);
    final pct = _totalSize > 0 ? size / _totalSize : 0.0;

    // WizTree 色带：按占比分配颜色
    final barColor = _colorForPercent(pct);

    if (isDir && size > 1024 * 1024) {
      // 大目录：可展开
      return _TreeNode(
        path: child['path'] as String,
        api: widget.api,
        depth: widget.depth + 1,
      );
    }

    // 文件或小目录：单行
    return Padding(
      padding: EdgeInsets.fromLTRB(32.0 + widget.depth * 16.0, 2, 12, 2),
      child: Row(
        children: [
          Icon(
            isDir ? Icons.folder_outlined : _fileIcon(name),
            size: 16,
            color: isDir ? theme.colorScheme.primary : theme.colorScheme.outline,
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
          // 色带
          Container(
            width: (pct * 80).clamp(4.0, 80.0),
            height: 4,
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Text(
              fmtSize(size),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Color _colorForPercent(double pct) {
    if (pct > 0.3) return const Color(0xFFE53935); // 红
    if (pct > 0.15) return const Color(0xFFFB8C00); // 橙
    if (pct > 0.05) return const Color(0xFFFDD835); // 黄
    if (pct > 0.02) return const Color(0xFF43A047); // 绿
    return const Color(0xFF1E88E5); // 蓝
  }

  IconData _fileIcon(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(ext)) {
      return Icons.image;
    }
    if (['mp4', 'mkv', 'avi', 'mov'].contains(ext)) return Icons.movie;
    if (['mp3', 'flac', 'wav', 'ogg'].contains(ext)) return Icons.audiotrack;
    if (['zip', 'rar', '7z', 'tar'].contains(ext)) return Icons.folder_zip;
    if (ext == 'apk') return Icons.android;
    return Icons.insert_drive_file;
  }
}
