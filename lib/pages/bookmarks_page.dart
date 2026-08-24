import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/format.dart' show describe;

/// 书签/快速访问（路径存 SharedPreferences）
class Bookmarks {
  static Future<List<String>> load() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList('bookmarks') ?? const [];
  }

  static Future<bool> toggle(String path) async {
    final p = await SharedPreferences.getInstance();
    final list = await load();
    if (list.contains(path)) {
      list.remove(path);
      await p.setStringList('bookmarks', list);
      return false;
    }
    list.insert(0, path);
    await p.setStringList('bookmarks', list);
    return true;
  }

  /// 仅添加（已存在则跳过），返回是否新加入
  static Future<bool> add(String path) async {
    final p = await SharedPreferences.getInstance();
    final list = await load();
    if (list.contains(path)) return false;
    list.insert(0, path);
    await p.setStringList('bookmarks', list);
    return true;
  }

  static Future<bool> contains(String path) async => (await load()).contains(path);
}

class BookmarksPage extends StatefulWidget {
  const BookmarksPage({super.key, required this.onOpen});

  final void Function(String path) onOpen;

  @override
  State<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends State<BookmarksPage> {
  List<String> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await Bookmarks.load();
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('书签')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Text('暂无书签。在文件详情里点「收藏」添加。',
                      style: theme.textTheme.bodySmall),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final p = _items[i];
                    final name = p.substring(p.lastIndexOf('/') + 1);
                    final isDir =
                        !p.contains('.') || p.lastIndexOf('.') < p.lastIndexOf('/');
                    final (_, icon, color) = describe(name, isDir,
                        folderColor: theme.colorScheme.primary);
                    return ListTile(
                      dense: true,
                      leading: Icon(icon, color: color, size: 20),
                      title: Text(name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(p,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5,
                              color: theme.colorScheme.outline)),
                      trailing: IconButton(
                        tooltip: '移除书签',
                        icon: Icon(Icons.close,
                            size: 18, color: theme.colorScheme.outline),
                        onPressed: () async {
                          await Bookmarks.toggle(p);
                          _reload();
                        },
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        widget.onOpen(p);
                      },
                    );
                  },
                ),
    );
  }
}
