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
          _Section(theme, '搜索', [
            _Tip(
              theme,
              Icons.search,
              '即时搜索与高级配置',
              '点击主界面搜索框进入搜索页：输入即出结果；页内可配置搜索范围'
                  '（当前目录 / 全盘 / 当前界面）、区分大小写、文件类型、大小与'
                  '时间过滤，还可以直接使用搜索语法。',
            ),
            _Tip(
              theme,
              Icons.terminal,
              '搜索语法',
              '关键词后可拼过滤条件：大小如 >10mb、<500kb、1mb..50mb；时间如 '
                  'today、thisweek、>2024-01-01；多个条件与关键词空格分隔、'
                  '全部同时满足。例如「日志 >100mb thismonth」。',
            ),
            _Tip(
              theme,
              Icons.filter_alt,
              '结果中逐层收敛',
              '点击结果里显示的路径行，可把搜索范围立即缩小到该文件所在的'
                  '文件夹，反复点击可层层逼近目标；「当前界面」范围则在当前'
                  '结果列表内继续过滤。',
            ),
            _Tip(
              theme,
              Icons.history,
              '搜索历史',
              '按键盘搜索键或点开结果会记录关键词（最多 20 条），聚焦搜索框'
                  '时下拉展示，可单条删除或清空。',
            ),
          ]),
          _Section(theme, '文件操作', [
            _Tip(
              theme,
              Icons.delete_outline,
              '回收站',
              '删除默认移入回收站（侧边栏进入），可随时恢复到原路径或清空；'
                  '确认框里也可选择永久删除。压缩包内的条目只能永久删除。',
            ),
            _Tip(
              theme,
              Icons.folder_zip,
              '压缩包浏览',
              '点击 zip / rar 压缩包直接进入内部层级（面包屑可跳转、返回键'
                  '逐级退出），内部文件支持打开、预览、播放与校验。rar5 加密'
                  '包暂不支持。',
            ),
            _Tip(
              theme,
              Icons.fingerprint,
              '完整性校验',
              '文件详情里的「校验」计算 MD5 / SHA1 / SHA256（单遍读取，带进度'
                  '百分比），结果可长按选中复制。',
            ),
            _Tip(
              theme,
              Icons.drive_file_move,
              '复制 / 移动 / 重命名',
              '多选后底部操作栏可批量复制或移动到任意目录（支持新建文件夹）；'
                  '受系统保护的区域会自动改用已授权的更高权限执行。',
            ),
          ]),
          _Section(theme, '清理工具', [
            _Tip(
              theme,
              Icons.analytics_outlined,
              '空间分析',
              'WizTree 式树形展开：每项显示占父文件夹的百分比，按大小降序；'
                  '可切换饼图逐级下钻。支持长按多选批量清理。',
            ),
            _Tip(
              theme,
              Icons.find_in_page_outlined,
              '大文件查重',
              '先按大小分组找出候选，再比对每份文件前 1MB 指纹确认重复；'
                  '阈值可自定（默认 10MB）。选中后移入回收站，「选中新出的'
                  '重复」自动保留每组最早的一份。',
            ),
            _Tip(
              theme,
              Icons.android_outlined,
              'APK 管理',
              '全盘安装包按应用分组、按占用排序，多版本标红；「全选旧版本」'
                  '按修改时间保留最新一份，其余一键清理。',
            ),
          ]),
          _Section(theme, '存储访问', [
            _Tip(
              theme,
              Icons.verified,
              '免 root',
              '授予「所有文件访问」后可索引和浏览内部存储全部常规文件。',
            ),
            _Tip(
              theme,
              Icons.lock_outline,
              '系统封锁区',
              'Android 11 起系统在 FUSE 层对所有应用隐藏 Android/data 与 '
                  'Android/obb——即使授予「所有文件访问」也一样。需要 Shizuku '
                  '或 root 才能纳入索引与浏览。',
            ),
            _Tip(
              theme,
              Icons.phonelink_setup,
              'Shizuku',
              '无需 root 的折中方案：以 shell 身份运行，可读 Android/data、'
                  'Android/obb 与 /data/local/tmp；应用私有目录 /data/data '
                  '仍然不可见（仅真 root 可读）。先在 Shizuku 应用中启动服务，'
                  '再到本应用设置页授权。',
            ),
            _Tip(
              theme,
              Icons.key,
              'root',
              '可索引 /data/data（可选深度索引）、/data/local/tmp，并解锁全部'
                  '封锁区；文件操作在需要时自动改用 root 执行。重装应用后 '
                  'root 管理器会重新请求授权。',
            ),
          ]),
          _Section(theme, '索引与实时性', [
            _Tip(
              theme,
              Icons.bolt,
              '打开时自动增量',
              '每次打开自动做增量对账（目录修改时间比对，只重扫变化的子树），'
                  '新建/删除的文件无需手动重建索引。',
            ),
            _Tip(
              theme,
              Icons.visibility,
              '前台实时监听',
              '前台期间监听文件变化，静默片刻后自动同步，界面无缝刷新；'
                  '切到后台立即停止，不耗电。root 模式会在需要时临时提高系统'
                  '监听上限并在停止时恢复原值。',
            ),
            _Tip(
              theme,
              Icons.edit_off,
              '同名文件的内容修改（已知边界）',
              '文件被原地修改（文件名不变）不会触发目录变化，其大小/修改时间'
                  '要等下一次全量重建才会刷新；文件名搜索不受影响。',
            ),
            _Tip(
              theme,
              Icons.memory,
              '系统分区默认不索引',
              '/system、/vendor 等只读分区体积大、几乎不变，默认不索引，可在'
                  '设置中开启；/proc、/sys 等虚拟文件系统永远不索引。符号链接、'
                  'socket、设备节点按设计跳过。',
            ),
          ]),
          _Section(theme, '隐私与耗电', [
            _Tip(
              theme,
              Icons.wifi_off,
              '不联网',
              '应用没有网络权限：不联网、不采集、不上传，所有数据都保存在'
                  '本机。',
            ),
            _Tip(
              theme,
              Icons.battery_saver,
              '无后台常驻',
              '无后台服务、无轮询。索引更新只发生在打开 app 的几秒内与前台'
                  '使用期间；空闲时不消耗 CPU。',
            ),
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
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
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
                  Text(
                    body,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
