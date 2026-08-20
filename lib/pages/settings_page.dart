import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/engine_api.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _api = EngineApi();
  int _resultLimit = 200;
  bool _rootIndex = true;
  bool _systemIndex = false;
  bool _rootGranted = false;
  bool _rootChecking = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _resultLimit = p.getInt('resultLimit') ?? 200;
        _rootIndex = p.getBool('rootIndex') ?? true;
        _systemIndex = p.getBool('systemIndex') ?? false;
      });
    });
  }

  Future<void> _save(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    }
    setState(() => _dirty = true);
  }

  Future<void> _checkRoot() async {
    setState(() => _rootChecking = true);
    final ok = await _api.hasRoot();
    if (!mounted) return;
    setState(() {
      _rootGranted = ok;
      _rootChecking = false;
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) Navigator.pop(context, _dirty);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: ListView(
          children: [
            const _SectionHeader('搜索'),
            ListTile(
              leading: const Icon(Icons.format_list_numbered),
              title: const Text('单次最多显示结果数'),
              trailing: DropdownButton<int>(
                value: _resultLimit,
                items: const [100, 200, 500, 1000, 2000]
                    .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _resultLimit = v);
                  _save('resultLimit', v);
                },
              ),
            ),
            const _SectionHeader('root 与索引范围'),
            ListTile(
              leading: const Icon(Icons.key),
              title: const Text('root 状态'),
              subtitle: Text(_rootChecking
                  ? '检测中…'
                  : (_rootGranted ? '已授权（T3 全盘）' : '未授权或不可用')),
              trailing: TextButton(
                onPressed: _rootChecking ? null : _checkRoot,
                child: const Text('检测'),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.manage_search),
              title: const Text('root 全盘索引'),
              subtitle: const Text('索引 Android/data、Android/obb、/data/data、/data/local/tmp'),
              value: _rootIndex,
              onChanged: (v) {
                setState(() => _rootIndex = v);
                _save('rootIndex', v);
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.memory),
              title: const Text('索引系统分区'),
              subtitle: const Text('/system、/vendor、/product（数量大，默认关闭）'),
              value: _systemIndex,
              onChanged: (v) {
                setState(() => _systemIndex = v);
                _save('systemIndex', v);
              },
            ),
            const _SectionHeader('行为'),
            const ListTile(
              leading: Icon(Icons.battery_saver),
              title: Text('无后台常驻'),
              subtitle: Text('索引刷新只发生在打开 app 与前台使用期间，退出不消耗电量'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary)),
      );
}
