# ViewFile — Android 上的 "Everything"

一个 Android 平台的即时文件搜索引擎 + 文件管理器，对标 Windows 上的 Everything：
输入即出结果的文件/文件夹搜索，并附带完整文件管理功能。

## 技术路线（已定）

**Flutter UI + 原生引擎（Kotlin，热点路径可选 C++ NDK）混合架构。**

- Flutter 只负责 UI 与业务编排，保证开发效率和热重载；
- 重活全部下沉原生层：全量扫描（前台/前台短时任务）、增量监听、
  root/Shizuku/SAF 三层文件访问、文件操作、索引存储。

## 核心设计决策（2026-08-20 调研后确定）

1. **三层访问引擎**（免 root 与 root 并行支持，面向大众）：
   - T1 免 root：`MANAGE_EXTERNAL_STORAGE` + MediaStore 增量；A11–A16 的
     Android/data 用 SAF 子目录授权（每个子目录一次系统弹窗，A13 起只能授权
     更深的子目录，不支持根级批量）。
   - T2 Shizuku（ADB/无线调试或 root 拉起）：以 shell uid 批量访问
     Android/data、Android/obb，免 root 的主流方案（MT管理器/FV/ZArchiver 同款）。
   - T3 root（libsu 常驻会话，兼容 Magisk/APatch/KernelSU）：全盘直读，
     含 /data/data、系统分区，且可直读 /data/media/0 绕过 FUSE 加速扫描。
2. **默认无后台常驻**（照顾大众用户对常驻的抵触）：
   - 默认"打开时增量刷新"：目录 mtime 对比遍历 + MediaStore 增量查询；
   - 应用前台期间才挂 inotify/fanotify 监听，退出即摘除并落盘增量；
   - 可选 opt-in 实时监听（root + kernel≥5.1 用 fanotify 文件系统级单标记，
     旧内核回退 inotify 并调大 max_user_watches）；事件驱动、无轮询，
     静态功耗≈0。
3. **A8–A16 全适配**：minSdk 26（Android 8.0），targetSdk 36。
   按版本分级：A8/9 走 legacy 存储；A10 requestLegacyExternalStorage 兜底；
   A11+ 分区存储 + All Files Access；A14+ 前台服务需声明类型；
   A15+ dataSync 类前台服务有每日 6 小时上限（默认无常驻设计天然规避）。

## 里程碑

- [x] M0 方案与仓库：git 初始化，可行性分析
- [x] M0.5 竞品调研：Search Everything / Quick Search / Solid Explorer /
      MiXplorer / X-plore / MT管理器（结论：无"开源 + 免root/root 双模式 +
      Everything 级即时索引"的完整同类产品，定位成立）
- [x] M1 脚手架 + 无 root 端到端（2026-08-20 真机验证通过）：
      扫描 /sdcard → SQLite staging 换表 → 内存排序数组 → 即时搜索 UI。
      Pixel 7 实测：扫描 67 条/121ms（本机可见条目全量），载入 1ms，
      单次查询 0.06–0.28ms，端到端（含通道往返）0–11ms。
      已知边界：A11+ FUSE 对所有应用隐藏 Android/data 与 Android/obb
      （本机该区域有 261 条，正是 M2 Shizuku/root 要覆盖的部分）。
      坑位记录：Android 16 禁止 execSQL 执行带返回行的 PRAGMA
      （journal_mode / wal_checkpoint 必须走 rawQuery）。
- [x] M2 root 接入 + 浏览模式（2026-08-20 真机验证通过）：
      自研 SuShell（su -c 检测/执行/流式，兼容 Magisk/APatch）；
      RootScanner 用 `find -print0 | xargs -0 stat` 单管道流式扫根区，
      /data/media/0/Android 映射回 /storage/emulated/0/... 路径自动去重；
      FileOps 删除/重命名 FUSE 失败回退 root rm/mv；
      浏览模式（默认 /sdcard，root 可到 /，面包屑导航）；
      搜索默认当前目录、一键切全盘。
      Pixel 7 实测：4134 条全量重建 0.6s（Android/data 解锁 263 条 +
      /data/data 3785 条，符号链接等非常规文件按设计跳过），
      索引载入 17ms，范围搜索 'apk' 当前目录 4 条 vs 全盘 16 条，
      Android/data 内文件 root 删除 + 索引同步正常。
      已知边界：索引不感知扫描后的新建文件（M3 增量体系已解决）。
- [x] M3 增量体系（2026-08-20 真机验证通过）：
      打开时增量对账（目录 mtime 比对只重扫变化子树 + root 区整区刷新）；
      前台实时监听——root 模式用 NDK 原生 vfwatch 进程（su 拉起，对索引
      全部目录含 /data/media/0、/data/data 挂 inotify，事件静默 2s 后自动
      增量同步；进程内 FileObserver 方案实测不可行：app uid 读不了原始路径）；
      免 root 模式监听 MediaStore。退出前台即停，无常驻。
      实测：root 原始路径新建文件 4s 内可搜，删除同样自动同步，
      孤儿进程清理正常（pkill 兜底）。
      侧边栏新增「使用提示与已知限制」页：访问分层/实时性边界/操作风险
      全量披露（含 inotify 上限临时调大的说明）。
- [x] M2.5 Shizuku 接入（2026-08-20 真机验证通过，含 root 禁用回退测试）：
      PrivShell 统一特权入口（root > Shizuku 自动降级），API 13 走
      IShizukuService binder newProcess；Shizuku 层覆盖 Android/data、obb、
      /data/local/tmp（/data/data 仅真 root）；扫描区城/浏览/删除/重命名/
      vfwatch 前台监听全链路支持 T2。
      真机问题记录：双 shizuku_server 实例导致授权回写丢失（弹窗无效、
      manager 列表不显示），清理单实例后恢复；pm grant 可直授框架级权限。
      root 隐藏侧信道加固：inotify 上限仅在实际不足时调大且停止即恢复
      原值（实测默认 52061 足够，未做任何系统改动）。
      其余：应用检索默认目录入口视图（Android/data、obb、data/data）、
      显示隐藏文件开关、空目录 xargs -r 修复、/Android 父目录 FUSE 隐藏
      data 的解封锁、设置页打开即自动检测特权层。
- [ ] M4 文件管理器：浏览/复制/移动/删除/重命名/属性/打开方式/书签
- [ ] M5 打磨与发布：过滤/排序/主题/国际化，推送 GitHub

## 环境

- Flutter 3.41.6 stable / Dart 3.11.4 / Android SDK 36
- 测试机：Pixel 7（Android 16，kernel 6.1，arm64-v8a，APatch + Magisk root，
  adb shell su 已授权 uid=0；inotify max_user_watches=52061，root 后需调大）
