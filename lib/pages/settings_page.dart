import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/engine_api.dart';
import '../theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  final _api = EngineApi();
  bool _rootIndex = true;
  bool _systemIndex = false;
  bool _deepData = false;
  bool _compactDb = false;
  int _pathLines = 3;
  bool _vacuuming = false;
  int _dbBytes = 0;
  bool _rootGranted = false;
  bool _shizukuGranted = false;
  bool _shizukuBinder = false;
  bool _hasPerm = false;
  bool _permChecking = true;
  bool _rootChecking = false;
  bool _shizukuChecking = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _rootIndex = p.getBool('rootIndex') ?? true;
        _systemIndex = p.getBool('systemIndex') ?? false;
        _deepData = p.getBool('deepDataIndex') ?? false;

        _compactDb = p.getBool('compactDb') ?? false;
        _pathLines = p.getInt('pathLines') ?? 3;
      });
    });
    _api.stats().then((s) {
      if (mounted) {
        setState(() => _dbBytes = (s['dbBytes'] as num?)?.toInt() ?? 0);
      }
    });
    _checkPerm();
    // 打开即自动检测两层状态
    _checkRoot();
    _checkShizuku();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统授权页返回后刷新状态
    if (state == AppLifecycleState.resumed) _checkPerm();
  }

  Future<void> _checkPerm() async {
    final ok = await _api.hasPermission();
    if (!mounted) return;
    setState(() {
      _hasPerm = ok;
      _permChecking = false;
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

  double _vacuumEstimateSec() {
    // 读写各一遍，按闪存 ~40MB/s 保守估算
    if (_dbBytes <= 0) return 5;
    return (_dbBytes / 1024 / 1024) * 2 / 40;
  }

  Future<void> _confirmVacuum() async {
    final est = _vacuumEstimateSec();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('压缩数据库？'),
        content: Text(
          'VACUUM 会重写整个索引库以整理碎片${_compactDb ? '并切换到 8KB 页' : ''}，'
          '预计约 ${est.toStringAsFixed(0)} 秒。\n期间搜索仍可用，但文件写入操作会暂停。',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _vacuuming = true);
    final r = await _api.vacuum(pageSize: _compactDb ? 8192 : null);
    if (!mounted) return;
    setState(() => _vacuuming = false);
    if (r['ok'] == true) {
      setState(() => _dbBytes = (r['bytes'] as num?)?.toInt() ?? _dbBytes);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '完成：${((r['elapsedMs'] as num?)?.toInt() ?? 0) / 1000}s，'
            '现在 ${((_dbBytes) / 1024 / 1024).toStringAsFixed(1)} MB'),
      ));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('失败：${r['error']}')));
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
            ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: const Text('搜索结果路径行数'),
              subtitle: const Text('长路径换行显示；自适应完整展开（行高不一）'),
              trailing: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1')),
                  ButtonSegment(value: 2, label: Text('2')),
                  ButtonSegment(value: 3, label: Text('3')),
                  ButtonSegment(value: 0, label: Text('自适应')),
                ],
                selected: {_pathLines},
                showSelectedIcon: false,
                onSelectionChanged: (s) async {
                  setState(() => _pathLines = s.first);
                  final p = await SharedPreferences.getInstance();
                  await p.setInt('pathLines', s.first);
                },
              ),
            ),
            const _SectionHeader('搜索'),
            const _SectionHeader('权限'),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('系统存储权限'),
              subtitle: Text(
                _permChecking
                    ? '检测中…'
                    : (_hasPerm
                        ? '已授权（所有文件访问）'
                        : '未授权：无法建立文件索引'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: TextButton(
                onPressed: () => _api.requestPermission(),
                child: Text(_hasPerm ? '检测' : '去授权'),
              ),
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
              secondary: const Icon(Icons.account_tree_outlined),
              title: const Text('深度索引 /data/data'),
              subtitle: const Text(
                  '默认只索引两层（应用概览）。深度索引会纳入应用全部私有文件，'
                  '重度应用（如微信）可达百万条，内存/空间/耗时显著增加'),
              value: _deepData,
              onChanged: (v) {
                setState(() => _deepData = v);
                _save('deepDataIndex', v);
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
            const _SectionHeader('存储与性能'),
            SwitchListTile(
              secondary: const Icon(Icons.data_saver_on),
              title: const Text('紧凑数据库（8KB 页）'),
              subtitle: const Text(
                  '库体积约省 5-8%、B 树更浅；下次重建索引时生效，'
                  '对随机读写性能影响可忽略（写入均为批量）'),
              value: _compactDb,
              onChanged: (v) {
                setState(() => _compactDb = v);
                _save('compactDb', v);
              },
            ),
            ListTile(
              leading: const Icon(Icons.compress),
              title: const Text('立即压缩数据库'),
              subtitle: Text(_dbBytes > 0
                  ? '当前 ${( _dbBytes / 1024 / 1024).toStringAsFixed(1)} MB · '
                    '预计 ${_vacuumEstimateSec().toStringAsFixed(0)} 秒（期间文件操作暂停）'
                  : '整理碎片并收缩空间'),
              trailing: _vacuuming
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('执行'),
              onTap: _vacuuming ? null : _confirmVacuum,
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
