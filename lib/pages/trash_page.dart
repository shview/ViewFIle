import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../api/engine_api.dart';
import '../utils/format.dart';

const kTrashDir = '/storage/emulated/0/.viewfile_trash';

class _TrashItem {
  _TrashItem({
    required this.id,
    required this.name,
    required this.original,
    required this.trashPath,
    required this.size,
    required this.time,
  });
  factory _TrashItem.fromJson(Map<String, dynamic> j) => _TrashItem(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        original: j['original'] as String? ?? '',
        trashPath: j['trashPath'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        time: (j['time'] as num?)?.toInt() ?? 0,
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'original': original,
        'trashPath': trashPath,
        'size': size,
        'time': time,
      };

  final String id;
  final String name;
  final String original;
  final String trashPath;
  final int size;
  final int time;
}

/// 回收站元数据与搬运（移动本身复用引擎 transfer/mkdir/delete 通道）
class TrashStore {
  TrashStore._();
  static const _metaFile = '$kTrashDir/.meta.json';

  static Future<List<_TrashItem>> load() async {
    try {
      final f = io.File(_metaFile);
      if (!await f.exists()) return const [];
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      return [
        for (final e in list) _TrashItem.fromJson(Map<String, dynamic>.from(e))
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<_TrashItem> items) async {
    try {
      await io.Directory(kTrashDir).create(recursive: true);
      final f = io.File(_metaFile);
      await f.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// 移入回收站：每批进唯一时间戳子目录（防同名冲突），按落盘存在性判成功
  static Future<int> put(List<String> paths) async {
    final api = EngineApi();
    final items = await load();
    var n = 0;
    var seq = 0;
    for (var i = 0; i < paths.length; i += 50) {
      final batch = paths.skip(i).take(50).toList();
      final dir =
          '$kTrashDir/${DateTime.now().millisecondsSinceEpoch}_$seq';
      seq++;
      await api.mkdir(dir);
      await api.transfer(batch, dir, move: true);
      for (final p in batch) {
        final name = p.substring(p.lastIndexOf('/') + 1);
        final trashPath = '$dir/$name';
        var ok = false;
        var size = 0;
        try {
          final st = io.FileStat.statSync(trashPath);
          ok = st.type != io.FileSystemEntityType.notFound;
          size = st.size;
        } catch (_) {}
        if (ok) {
          items.add(_TrashItem(
            id: '${dir.hashCode}_$name',
            name: name,
            original: p,
            trashPath: trashPath,
            size: size,
            time: DateTime.now().millisecondsSinceEpoch,
          ));
          n++;
        }
      }
    }
    await save(items);
    return n;
  }

  /// 恢复到原路径（原父目录不存在则先创建）
  static Future<bool> restore(_TrashItem it) async {
    final parent = it.original.substring(0, it.original.lastIndexOf('/'));
    await EngineApi().mkdir(parent);
    final r =
        await EngineApi().transfer([it.trashPath], parent, move: true);
    final ok = r['ok'] == true || ((r['succeeded'] as num?)?.toInt() ?? 0) > 0;
    if (ok) {
      final items = await load();
      await save(items.where((e) => e.id != it.id).toList());
    }
    return ok;
  }

  static Future<bool> deleteForever(_TrashItem it) async {
    final r = await EngineApi().delete([it.trashPath]);
    if (r['ok'] == true) {
      final items = await load();
      await save(items.where((e) => e.id != it.id).toList());
    }
    return r['ok'] == true;
  }

  static Future<int> empty() async {
    final items = await load();
    var n = 0;
    for (final it in items) {
      final r = await EngineApi().delete([it.trashPath]);
      if (r['ok'] == true) n++;
    }
    await save(const []);
    return n;
  }
}

class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<_TrashItem> _items = [];
  bool _loading = true;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await TrashStore.load();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
      _busy = null;
    });
  }

  Future<void> _restore(_TrashItem it) async {
    setState(() => _busy = it.id);
    final ok = await TrashStore.restore(it);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '已恢复到 ${it.original}' : '恢复失败（原目录可能已不存在）'),
    ));
    _reload();
  }

  Future<void> _deleteForever(_TrashItem it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除？'),
        content: Text('「${it.name}」将无法恢复。'),
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
    setState(() => _busy = it.id);
    await TrashStore.deleteForever(it);
    if (mounted) _reload();
  }

  Future<void> _emptyAll() async {
    if (_items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空回收站？'),
        content: Text('共 ${_items.length} 项将永久删除，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = 'ALL');
    final n = await TrashStore.empty();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已清空 $n 项')));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          IconButton(
            tooltip: '清空回收站',
            icon: const Icon(Icons.delete_forever),
            onPressed: _items.isEmpty || _busy != null ? null : _emptyAll,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline,
                          size: 56, color: theme.colorScheme.outline),
                      const SizedBox(height: 8),
                      Text('回收站为空',
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemExtent: 76,
                  itemBuilder: (context, i) {
                    final it = _items[i];
                    final busy = _busy == it.id || _busy == 'ALL';
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.delete_outline),
                      title: Text(it.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${fmtSize(it.size)} · 原路径 ${it.original}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: theme.colorScheme.outline),
                      ),
                      trailing: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '恢复到原路径',
                                  icon: const Icon(Icons.restore),
                                  onPressed: () => _restore(it),
                                ),
                                IconButton(
                                  tooltip: '永久删除',
                                  icon: Icon(Icons.delete_forever,
                                      color: theme.colorScheme.error),
                                  onPressed: () => _deleteForever(it),
                                ),
                              ],
                            ),
                    );
                  },
                ),
    );
  }
}
