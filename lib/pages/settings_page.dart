import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _resultLimit = 200;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _resultLimit = p.getInt('resultLimit') ?? 200);
    });
  }

  Future<void> _setLimit(int v) async {
    setState(() => _resultLimit = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('resultLimit', v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              onChanged: (v) => v != null ? _setLimit(v) : null,
            ),
          ),
          const _SectionHeader('索引与访问层级'),
          const ListTile(
            leading: Icon(Icons.verified_user_outlined),
            title: Text('当前：T1 免 root'),
            subtitle: Text('覆盖 /sdcard（不含系统隐藏的 Android/data 与 Android/obb）'),
          ),
          const ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text('T2 Shizuku / T3 root'),
            subtitle: Text('开发中（M2）：全盘索引，含 /data/data'),
            enabled: false,
          ),
          const _SectionHeader('行为'),
          const ListTile(
            leading: Icon(Icons.battery_saver),
            title: Text('无后台常驻'),
            subtitle: Text('索引刷新只发生在打开 app 与前台使用期间，退出不消耗电量'),
          ),
        ],
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
