# ViewFile

Android 上的 Everything：即时全盘文件搜索 + 完整文件管理 + WizTree 式空间分析。

Flutter UI + Kotlin 原生引擎，无后台常驻，支持 免 Root / Shizuku / Root 三层特权访问。

## 特性

- **即时搜索**：内存 SoA（Structure of Arrays）索引，135 万条目高命中词毫秒级响应；懒加载会话——总数即时返回、内容按页（300 条）按需拉取，十万级结果不卡顿
- **搜索语法**：大小 `>10mb`、`<500kb`、`1mb..50mb`；时间 `today`、`thisweek`、`>2024-01-01`；多词 AND 组合，如 `日志 >100mb thismonth`
- **类型筛选**：图片 / 视频 / 音频 / 文档 / APK / 压缩包 一键过滤（引擎侧执行）
- **三层特权访问**
  - T1 免 Root：所有文件访问权限（MANAGE_EXTERNAL_STORAGE）
  - T2 Shizuku：可读 Android/data、Android/obb
  - T3 Root：/data/data 全覆盖（可选深度索引）
- **文件管理**：浏览 / 复制 / 移动 / 删除 / 重命名 / 分享 / 多选（点选、区间选、全选/反选）/ MD5·SHA1·SHA256 校验（带进度）
- **内置查看器**：图片（双击缩放、滑动切换、列表缩略图）、视频/音频（ExoPlayer）、文本（等宽渲染 + 文内搜索高亮跳转）
- **压缩包浏览**：zip（纯 Dart）与 rar（自带 NDK 编译的 unrar 二进制）直接进入虚拟层级，内部文件可打开 / 预览 / 校验 / 提取
- **空间分析**：WizTree 式树形展开（占父文件夹百分比）+ 可下钻环形饼图，支持多选批量清理
- **实时性**：前台 inotify 监听（NDK C 实现；root 下按需提升 watch 限额、退出即恢复），增量对账秒级完成，界面无缝刷新不闪烁
- **按应用检索**：定位某应用的私有数据目录

## 隐私设计

- 无网络权限：不联网、不采集、不上传
- 无后台常驻：索引刷新只发生在前台使用期间，退出零耗电
- Root 卫生：不长期修改系统设置，不留可检测痕迹

## 性能（实测 OnePlus PLC110 / Android 15 / 135 万条目）

| 指标 | 数值 |
|---|---|
| 索引冷载入 | 3.0–3.6 s |
| 前台增量对账 | 0.2–2 s |
| 搜索 `jpg`（18,494 命中） | 会话 68–215 ms，分页 <0.1 ms |
| 搜索单字母（17 万命中） | 会话 43–116 ms |
| 内存（索引 + UI 基线） | ~380 MB PSS |
| 索引库体积 | 118 MB（87 B/条） |

## 构建

```bash
flutter pub get
flutter build apk --release
```

需要 Flutter 3.x 与 Android SDK；NDK 目标（vfwatch 监听器、vfunrar 解压器）由 Gradle/CMake 自动构建。

## 技术要点

- **存储**：SQLite `entry(id, parent_id, name, type, size, mtime)`，路径不落库；全量重建写独立库后原子 rename 顶替，支持 8KB 页紧凑模式与 VACUUM 压缩
- **内存索引**：SoA 并行数组 + 名称字节池（前缀去重）+ DFS 欧拉区间（O(1) 目录范围过滤）；内存预算保护，超限自动精简重建
- **同步**：目录 mtime 对账 + root 特权管道（`nsenter -t 1 -m` 绕过厂商 mount 过滤）；大规模删除守卫；管道部分输出拒采
- **搜索会话**：引擎侧持有命中索引集（IntArray，17 万命中仅 680 KB）；索引重建发布会话失效并由 UI 无缝自愈
- 详细架构与踩坑记录见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)

## 已知限制

- rar5 加密包不支持
- 未索引区域（如未开深度索引的 /data/data 深层）不参与搜索，浏览不受影响
- 重装 APK 后 root 管理器会重新请求授权

## 第三方组件

- [unrar](https://www.rarlab.com/rar_add.htm) 官方源码（vendored 于 `android/app/src/main/cpp/unrar_src/`）——仅用于 RAR 解压，遵循其自身许可（见目录内 license 文件；不得用于实现 RAR 压缩算法）
- [archive](https://pub.dev/packages/archive)、[video_player](https://pub.dev/packages/video_player)、[shared_preferences](https://pub.dev/packages/shared_preferences)、[path_provider](https://pub.dev/packages/path_provider)

## License

MIT（unrar 源码部分遵循其自身许可）
