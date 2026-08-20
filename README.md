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
- [ ] M1 脚手架 + 无 root 端到端：扫描 /sdcard → SQLite → 即时搜索 UI
- [ ] M2 三层访问引擎接入：root（libsu）→ Shizuku → SAF 批量授权向导
- [ ] M3 增量体系：打开时增量 + 前台监听 + 可选实时监听
- [ ] M4 文件管理器：浏览/复制/移动/删除/重命名/属性/打开方式/书签
- [ ] M5 打磨与发布：过滤/排序/主题/国际化，推送 GitHub

## 环境

- Flutter 3.41.6 stable / Dart 3.11.4 / Android SDK 36
- 测试机：Pixel 7（Android 16，kernel 6.1，arm64-v8a，APatch + Magisk root，
  adb shell su 已授权 uid=0；inotify max_user_watches=52061，root 后需调大）
