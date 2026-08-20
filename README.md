# ViewFile — Android 上的 "Everything"

一个 Android 平台的即时文件搜索引擎 + 文件管理器，对标 Windows 上的 Everything：
输入即出结果的全盘文件/文件夹搜索（含 root 区域），并附带完整文件管理功能。

## 技术路线（已定）

**Flutter UI + 原生引擎（Kotlin，热点路径可选 C++ NDK）混合架构。**

- Flutter 只负责 UI 与业务编排，保证开发效率和热重载；
- 重活全部下沉原生层：
  - 全量扫描（前台服务，readdir/stat 遍历）
  - inotify 增量监听（root 调大 watch 上限）
  - root 会话管理（libsu，兼容 Magisk / APatch / KernelSU）
  - 文件操作（复制/移动/删除/重命名/属性）
  - 索引存储（SQLite 持久化 + 内存索引即时搜索）

## 里程碑

- [ ] M0 脚手架：Flutter 项目、git、真机跑通
- [ ] M1 无 root 版：扫描 /sdcard → SQLite → 即时搜索 UI
- [ ] M2 root 接入：全盘索引 + inotify 实时更新 + 前台服务
- [ ] M3 文件管理器：浏览/复制/移动/删除/属性/打开方式/书签
- [ ] M4 打磨与发布：过滤/排序/主题，推送 GitHub

## 环境

- Flutter 3.41.6 stable / Dart 3.11.4 / Android SDK 36
- 测试机：Pixel 7（Android 16，arm64-v8a，APatch + Magisk root）
