import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/engine_api.dart';
import '../theme.dart';

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
  bool _showHidden = false;
  bool _rootGranted = false;
  bool _shizukuGranted = false;
  bool _shizukuBinder = false;
  bool _rootChecking = false;
  bool _shizukuChecking = false;
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
        _showHidden = p.getBool('showHidden') ?? false;
      });
    });
    // 打开即自动检测两层状态
    _checkRoot();
    _checkShizuku();
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

  Future<void> _checkShizuku() async {
    setState(() => _shizukuChecking = true);
    final granted = await _api.hasShizuku();
    final binder = await _api.shizukuBinderAlive();
    if (!mounted) return;
    setState(() {
      _shizukuGranted = granted;
      _shizukuBinder = binder;
      _shizukuChecking = false;
      _dirty = true;
    });
  }

  Future<void> _requestShizuku() async {
    final ok = await _api.requestShizuku();
    if (!mounted) return;
    if (ok) {
      await _checkShizuku();
    } else {
      // 弹出授权框后稍等再刷新状态
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) await _checkShizuku();
    }
  }

  @override
  Widget build(BuildContext context) {
    // canPop:false 拦截返回（含 AppBar 返回键），统一走带返回值的 pop；
    // 此前在 didPop 之后二次 pop 把主页也弹掉，导致黑屏
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _dirty);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: ListView(
          children: [
            const _SectionHeader('外观'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  for (final entry in AppTheme.seedColors.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: GestureDetector(
                        onTap: () => AppTheme.setSeed(entry.value),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Color(entry.value),
                            shape: BoxShape.circle,
                            border: AppTheme.seedValue == entry.value
                                ? Border.all(
                                    color: Theme.of(context).colorScheme.onSurface,
                                    width: 3)
                                : null,
                          ),
                          child: AppTheme.seedValue == entry.value
                              ? const Icon(Icons.check, size: 20, color: Colors.white)
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('明暗模式'),
              trailing: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, icon: Icon(Icons.auto_mode), label: Text('系统')),
                  ButtonSegment(value: 1, icon: Icon(Icons.light_mode), label: Text('浅色')),
                  ButtonSegment(value: 2, icon: Icon(Icons.dark_mode), label: Text('深色')),
                ],
                selected: {AppTheme.modeValue},
                showSelectedIcon: false,
                onSelectionChanged: (s) => AppTheme.setMode(s.first),
              ),
            ),
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
            SwitchListTile(
              secondary: const Icon(Icons.visibility_off_outlined),
              title: const Text('显示隐藏文件'),
              subtitle: const Text('显示 . 开头的文件与文件夹'),
              value: _showHidden,
              onChanged: (v) {
                setState(() => _showHidden = v);
                _save('showHidden', v);
              },
            ),
            const _SectionHeader('特权层级与索引范围'),
            ListTile(
              leading: const Icon(Icons.key),
              title: const Text('root（T3 · 全盘）'),
              subtitle: Text(_rootChecking
                  ? '检测中…'
                  : (_rootGranted ? '已授权：/data/data 与 Android/data 全覆盖' : '未授权或不可用')),
              trailing: TextButton(
                onPressed: _rootChecking ? null : _checkRoot,
                child: const Text('检测'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.phonelink_setup),
              title: const Text('Shizuku（T2 · 免 root）'),
              subtitle: Text(_shizukuChecking
                  ? '检测中…'
                  : (!_shizukuBinder
                      ? '服务未运行：请先在 Shizuku 应用里启动'
                      : (_shizukuGranted
                          ? '已授权：可读 Android/data、Android/obb（不含 /data/data）'
                          : '服务运行中，等待授权'))),
              trailing: TextButton(
                onPressed: _shizukuChecking ? null : (_shizukuGranted ? _checkShizuku : _requestShizuku),
                child: Text(_shizukuGranted ? '检测' : '授权'),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.manage_search),
              title: const Text('特权层索引'),
              subtitle: const Text(
                  '索引 Android/data、Android/obb、/data/local/tmp；root 再加 /data/data'),
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
