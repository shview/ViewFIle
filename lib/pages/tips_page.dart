import 'package:flutter/material.dart';

/// 使用提示与已知限制：随版本更新维护，描述当前能力的真实边界
class TipsPage extends StatelessWidget {
  const TipsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('使用提示与已知限制')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Section(theme, '存储访问分层', [
            _Tip(theme, Icons.verified, '免 root（当前 T1）',
                '可索引和浏览内部存储（/sdcard）全部常规文件。'),
            _Tip(theme, Icons.lock_outline, '系统封锁区（重要限制）',
                'Android 11 起系统在 FUSE 层对所有应用隐藏 Android/data 与 '
                'Android/obb——即使授予“所有文件访问”也一样。免 root 模式下这两个'
                '目录及其中的文件不在索引与浏览范围内。'),
            _Tip(theme, Icons.key, 'root（T3）',
                '授权后可索引 /data/data、/data/local/tmp 并解锁 Android/data、'
                'Android/obb；删除/重命名会自动改用 root 权限执行。'),
            _Tip(theme, Icons.schedule, 'Shizuku（T2，开发中）',
                '面向无 root 用户的中间方案，届时可在免 root 下读取 Android/data。'),
          ]),
          _Section(theme, '索引与实时性', [
            _Tip(theme, Icons.bolt, '打开时自动增量',
                '每次打开 app 自动做一次增量对账（目录修改时间比对，只重扫变化'
                '的子树），新建/删除的文件无需手动重建索引。'),
            _Tip(theme, Icons.visibility, '前台实时监听',
                'app 在前台期间监听文件变化，静默 2 秒后自动同步；切到后台立即'
                '停止监听，不消耗电量（无常驻设计）。root 模式通过一个以 root '
                '运行的原生辅助进程监听（含系统隐藏目录），期间会临时调大内核'
                'inotify 监听上限（/proc/sys/fs/inotify/max_user_watches，'
                '重启手机后自动恢复系统默认值，不影响其他应用）。'),
            _Tip(theme, Icons.edit_off, '同名文件的内容修改（已知缺陷）',
                '文件被原地修改（文件名不变）不会触发所在目录的 mtime 变化，'
                '其大小/修改时间要等下一次全量重建（右上角刷新）才会刷新；'
                '文件名搜索不受影响。'),
            _Tip(theme, Icons.memory, '系统分区默认不索引',
                '/system、/vendor 等只读分区体积大、几乎不变，默认不索引；'
                '可在设置中开启。/proc、/sys 等虚拟文件系统永远不索引。'),
            _Tip(theme, Icons.link_off, '非常规文件不入索引',
                '符号链接、socket、设备节点按设计跳过，因此索引条数会少于 '
                'find 等工具的原始计数。'),
          ]),
          _Section(theme, '文件操作', [
            _Tip(theme, Icons.delete_forever, '删除不可恢复',
                '删除不经过回收站、不可撤销；对话框会列出数量与名称，'
                '请在确认前仔细核对。root 区域的删除同样直接生效。'),
            _Tip(theme, Icons.open_in_new_off, '保护区域暂不能打开/分享',
                'Android/data 等封锁区内的文件，其他应用无法读取，'
                '因此“打开/分享”暂不可用；可先复制到可见区域（复制/移动'
                '功能开发中）。'),
            _Tip(theme, Icons.drive_file_rename_outline, '重命名与索引',
                '重命名/删除后索引即时同步，无需重建。'),
          ]),
          _Section(theme, '按应用检索', [
            _Tip(theme, Icons.apps, '搜索范围',
                '同时搜索所选应用的 /data/data、Android/data、Android/obb '
                '三个目录；进入即列出该应用全部已索引文件，可继续输入关键词过滤。'),
            _Tip(theme, Icons.key_off, '需要 root',
                '应用私有目录需要 root 才能读取；无 root 时仅能检索已索引的'
                '常规区域。'),
          ]),
          _Section(theme, '其他', [
            _Tip(theme, Icons.battery_saver, '耗电说明',
                '无后台常驻、无轮询。索引更新只发生在：打开 app 的几秒内、'
                '前台使用期间。前台监听为事件驱动，空闲时不消耗 CPU。'),
            _Tip(theme, Icons.palette, '个性化',
                '设置中可切换主题色（7 种）与明暗模式；文件夹图标颜色'
                '跟随主题主色。'),
            _Tip(theme, Icons.construction, '开发中的功能',
                '复制/移动、WizTree 式空间分析、Shizuku 支持、多语言界面。'),
          ]),
        ],
      ),
    );
  }

  static Widget _Section(ThemeData theme, String title, List<Widget> tips) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
          child: Text(title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: theme.colorScheme.primary)),
        ),
        ...tips,
      ],
    );
  }
}

class _Tip extends StatelessWidget {
  final ThemeData theme;
  final IconData icon;
  final String title;
  final String body;

  const _Tip(this.theme, this.icon, this.title, this.body);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(body,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
