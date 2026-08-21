# ViewFile — Android 上的 Everything

Android 平台的即时文件搜索引擎 + 文件管理器，对标 Windows 上的 Everything：
输入即出结果的文件/文件夹搜索（含系统隐藏区），附带完整文件管理功能。
免 root 可用，root / Shizuku 解锁全盘索引。

> **交接说明**：本文档面向接手本项目的 AGENT 或开发者，包含架构、
> 实测数据、全部踩坑记录与操作协议。读完即可继续开发。

---

## 1. 项目状态速览（2026-08-21）

| 能力 | 状态 |
|---|---|
| 即时搜索（全盘/当前目录/按应用） | ✅ 真机验证 |
| 文件管理（浏览/多选/打开/分享/重命名/删除） | ✅ 真机验证 |
| 三层访问：免root(T1) / Shizuku(T2) / root(T3) | ✅ 真机验证 |
| 打开时增量同步 + 前台实时监听（无常驻） | ✅ 真机验证 |
| 排序/统计/主题/隐藏文件/按应用检索 | ✅ |
| DB v3（parent_id 结构）+ SoA 内存索引（P2） | ✅ 133.8 万条真机实测 |
| 复制/移动 | ❌ 未实现（M4） |
| WizTree 式空间分析 | ❌ 未实现（backlog） |
| 500 万级条目 | ❌ 需目录映射树解析化（见路线图） |

### 关键实测数据（OnePlus PLC110 / Android 15 / Magisk root）

| 指标 | 数值 |
|---|---|
| 全量重建 22 万条 | 4.6s（Android 区 2.9s） |
| 全量重建 133.8 万条（深度） | ~75s（建索引 1.1s，swap 16ms） |
| 库体积 22 万条 | 19MB |
| 库体积 133.8 万条 | 116MB（上一代结构 667MB） |
| SoA 载入 133.8 万条 | 3.2-3.8s |
| 内存（SoA，133.8 万条） | Java 堆 178MB（对象模型为 630MB/OOM） |
| 搜索延迟 | 15-130ms |
| 前台同步（22 万条规模） | ~3s |

---

## 2. 架构

```
┌────────────────────────────────────────────┐
│ Flutter (Dart) — UI 与业务编排              │
│  lib/main.dart        入口+主题+zh本地化    │
│  lib/api/engine_api.dart  MethodChannel 封装│
│  lib/pages/home_page.dart  主页(浏览/搜索/多选)│
│  lib/pages/apps_page.dart  按应用检索       │
│  lib/pages/settings_page.dart 设置          │
│  lib/pages/tips_page.dart  使用提示与已知限制│
│  lib/theme.dart 主题色/明暗   lib/utils/format.dart 工具│
├────────────────────────────────────────────┤
│ Kotlin 引擎 (com.viewfile.viewfile.core)    │
│  MainActivity.kt  通道绑定（全部后台化）     │
│  Engine.kt        单例：三线程池(scan/search/ops)│
│  Db.kt            schema v3 + IndexSink 接口│
│  IndexBuilder.kt  全量重建→index-new.db→原子rename│
│  Scanner.kt       FUSE 并行扫描(4worker采集+单线程落库)│
│  RootScanner.kt   特权区 find|stat 管道流式  │
│  SyncScanner.kt   增量对账((parent_id,name)语义)│
│  SearchIndex.kt   SoA 内存索引(P2)          │
│  SuShell.kt       su 封装(nsenter 进 PID1 ns)│
│  ShizukuShell.kt  Shizuku binder 执行       │
│  Fs.kt            目录浏览(FUSE优先/特权回退) │
│  FileOps.kt       打开/分享/重命名/删除      │
│  TreeWatcher.kt   前台实时监听              │
├────────────────────────────────────────────┤
│ NDK C: android/app/src/main/cpp/vfwatch.c  │
│  root/shizuku 拉起的 inotify 监听进程        │
│  (libvfwatch.so, 事件只当触发信号)          │
└────────────────────────────────────────────┘
```

### 2.1 三层特权访问（PrivShell 自动降级 ROOT > SHIZUKU > NONE）

- **T3 root**：SuShell 执行，**所有命令经 `nsenter -t 1 -m` 进入 PID1 挂载
  命名空间**（ColorOS 等在 app 命名空间过滤 /data/data 视图——不进 PID1 ns
  则 root 也只能看到自己与 GMS）。覆盖 /data/media/0/Android、/data/data、
  /data/local/tmp
- **T2 Shizuku**：IShizukuService binder newProcess（API 13 的 newProcess 已
  私有化，走 AIDL binder）。shell 身份可读 Android 区与 tmp，不能读 /data/data
- **T1 免root**：MANAGE_EXTERNAL_STORAGE + FUSE。Android/data、Android/obb
  在 FUSE 层被系统隐藏（所有 app 一致），此时不可见

### 2.2 数据库 v3

```sql
CREATE TABLE entry(
  id INTEGER PRIMARY KEY,        -- 构建时顺序分配，parent_id < id 恒成立
  parent_id INTEGER NOT NULL,    -- 路径不落库（v2 重复存 path+parent 是体积主因）
  name TEXT NOT NULL,
  type INTEGER NOT NULL,         -- 0=file 1=dir
  size INTEGER NOT NULL DEFAULT 0,
  mtime INTEGER NOT NULL DEFAULT 0  -- 毫秒
);
CREATE UNIQUE INDEX idx_entry_parent_name ON entry(parent_id, name);
```

- 全量重建写入独立 `index-new.db`（WAL + synchronous=OFF + 20 万条分批事务 +
  完成后建索引），原子 rename 顶替 `index.db`——主库永不出现巨型 WAL
- meta 表存 schema 指纹与 scan_cfg 指纹（root/sys/deep/tier），配置变化自动重扫

### 2.3 SoA 内存索引（SearchIndex.kt，P2）

- 名字池（UTF-8 原大小写）+ 唯一名去重池 + nameRef 引用数组
- 平行数组：parentId/isDir/size/mtime/entryId/tin/tout
- **DFS 欧拉区间**：子树判定 O(1)，范围搜索免路径前缀比较
- sortIdx：免装箱三路快排（折叠字节比较）→ 查询按字典序取前 N
- 路径不驻留：结果/目录映射按需沿 parent 链重建
- 内存 ~133B/条（含映射开销）；预算守卫 `largeMemoryClass × 6200`
  （512MB 堆 ≈ 310 万条，超限自愈回精简模式并关闭深度开关）

### 2.4 同步体系（无常驻设计）

1. **打开时对账**：FUSE 区按目录 mtime 递归（未变即剪枝）；root 区
   `find -type d | stat` 只 stat 目录，变化目录批量重列（300 目录/管道，
   单轮上限 2000，遵守深度上限防逐层蔓延）
2. **前台实时监听**：vfwatch 进程（su/shizuku 拉起）对全部索引目录挂
   inotify；事件只当触发信号，静默 2s 后跑对账拿精确结果；冷却 25s 防风暴；
   退后台即停。root 下仅当默认 watch 上限不足才临时调大并停止时恢复
   （root 隐藏侧信道：/proc/sys/fs/inotify/max_user_watches 全局可读）
3. 无轮询、无后台服务、无任何持久系统改动

### 2.5 扫描区与显示路径

- /data/media/0/Android 在索引中映射为 /storage/emulated/0/Android（用户
  友好且与 FUSE 结果去重）
- FUSE 走查在 root 管道激活时跳过该子树（`Engine.fuseSkip`），否则双写
  撞 UNIQUE
- /data/data 默认只索引两层（深度开关在设置页），微信级应用可产生百万条目

---

## 3. 构建与部署

```bash
flutter pub get
flutter test                              # 单元测试
flutter build apk --release               # 产物 build/app/outputs/flutter-apk/app-release.apk
```

### ⚠️ 安装安全协议（事故教训，必须遵守）

**`adb install` 必须作为独立短命令执行，绝不与其他命令捆绑**。曾被中断的
install 留下坏 APK → dex 校验风暴 → MTK Hang_Detect 强制重启整机。
正确流程：

```bash
# 1. 独立安装
adb install build/app/outputs/flutter-apk/app-release.apk
# 2. 校验完整性（设备与本地 md5 必须一致）
adb shell su -c 'md5sum /data/app/*/com.viewfile.viewfile-*/base.apk'
md5sum build/app/outputs/flutter-apk/app-release.apk
```

### 测试设备

| 设备 | 型号 | 用途 |
|---|---|---|
| 测试机 | Pixel 7（Android 16，Magisk，root+shizuku 已授权） | 功能验证 |
| 真机 | OnePlus PLC110（Android 15，Magisk，用户日常机） | 规模/性能验证 |

注意事项：
- 两台机 adb 切换时先 `adb devices` 确认
- OnePlus 是用户日常机：UI 自动化前先 `dumpsys window | grep mCurrentFocus`
  确认前台；用户正在使用（聊天等界面）时禁止 input 注入
- Pixel 长时间不用会锁屏+通知栏卡住：`KEYCODE_WAKEUP` + 上滑解锁后操作
- 授权辅助：Magisk 策略库可直接授权
  `sqlite3 /data/adb/magisk.db "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES (<uid>,2,0,1,1)"`

### 调试通道

- logcat 标签：`ViewFile/Scan`（构建/载入分段计时）、`ViewFile/Sync`、
  `ViewFile/Search`（查询延迟）、`ViewFile/Watch`、`ViewFile/Build`、
  `ViewFile/Su`、`ViewFile/Shizuku`、`ViewFile/Fs`
- R8 混淆映射：`build/app/outputs/mapping/release/mapping.txt`（ANR 栈
  反查用，类名如 c0.p → IndexBuilder）
- ANR 栈抓取：`su -c 'kill -3 <pid>'` → `/data/anr/trace_NN`
- 内核崩溃：`/sys/fs/pstore/console-ramoops-0`

---

## 4. 踩坑记录（接手必读，每条都真机复现过）

1. **Android 16 的 execSQL 拒绝带返回行的语句**：`PRAGMA journal_mode/WAL`、
   `wal_checkpoint` 必须走 `rawQuery`
2. **nsenter `--` 分隔符**：toybox nsenter 会把后续命令的 `-c` 当自己的
   选项：`nsenter -t 1 -m -- /system/bin/sh -c '<cmd>'`
3. **ColorOS app 命名空间过滤 /data/data**：见 §2.1，nsenter 是唯一解
4. **文件名含换行符**（微信日志类）：stat 输出被撕成碎片行，碎片会被
   解析成根级垃圾条目/触发补链死循环。已在 RootScanner 源头丢弃非
   `/` 开头的行
5. **journal=OFF 在百万级触发 SQLITE_CORRUPT**（多次复现）：构建库必须
   WAL + 分批事务（20 万条/批）
6. **SQLite 写事务绑定唯一连接**：跨线程插入会永久等待连接（死锁）。
   并行扫描采用"采集入队、单线程落库"
7. **路径前导斜杠**：parent 链重建根级行时必须 `"/" + name`，漏斜杠则
   全部内存路径失配（搜索/同步全瘫）
8. **补链时祖先 mtime 禁止写 0**：否则真实 mtime 被清零 → 永远判"变化"
   → 同步死循环膨胀（SyncScanner.ensureDir 的 update 参数）
9. **异步 pkill 竞态**：stop 的 pkill 线程会误杀 refresh 刚拉起的新
   vfwatch。清理必须同步完成（在后台线程里做）
10. **VACUUM 在 WAL 模式把整库重写进 WAL**：必须 VACUUM 后再
    `wal_checkpoint(TRUNCATE)`
11. **中断的 adb install = 整机重启事故**：见 §3 安装协议
12. **String.toLowerCase 是 Android 慢路径**：22 万条调用分钟级→手写
    ASCII fastLower 毫秒级（SoA 后用折叠字节比较）
13. **主线程禁做特权检测/DB 查询**：su 探测最长 5s，曾致 Input
    Dispatching Timeout ANR。MainActivity 所有通道全部后台化
14. **Shizuku 双 server 实例**：授权弹窗写进一个、app 连的是另一个
    （表现为"点了允许没用"）。杀双实例重拉单实例解决；pm grant 可直授
    框架级权限
15. **空库期 watcher 误启**：dirIds 为空时启动的 0 目录实例必须可被
    替换（TreeWatcher.watchedDirCount 健康检查）

---

## 5. 路线图（按优先级）

### P3：500 万级支持（用户明确要求按最坏情况优化）
- **目录映射树解析化**：dirIds/dirMtimes/denseStats 三个 HashMap 在 70 万
  目录时约 300MB，是最后的内存大头。方案：保留 children 数组（按名排序），
  路径→id 用逐段二分查找（O(depth×log)），mtime 用平行数组，统计用三
  平行数组。调用方：SyncScanner/Fs/TreeWatcher/SearchIndex
- 搜索加速：百万级线性扫描 130-400ms/键击，可加首字节桶或 n-gram
  （参考 plocate 倒排）
- 更大堆设备（largeMemoryClass 768MB+）自动放宽预算

### M4：文件管理补全
- 复制/移动（目标目录选择器 + root 区 mv/cp 回退 + 进度）
- 书签/快速访问
- WizTree 式空间分析二级页（数据已具备：denseStats 递归大小）

### 其他 backlog
- SAF 批量授权向导（Android/data 逐子目录，A13 起体验差，仅作 T1 补充）
- 应用图标磁盘缓存（当前每次进列表页重新生成）
- 深度同步提速（当前 133 万条规模单轮 ~55s：180k 目录 stat 对账）
- FUSE 并行扫描进一步调优（binder 往返是瓶颈，4 线程已近饱和）
- lint 清理：lib/api/engine_api.dart 有未用 import 等小问题

---

## 6. 已知限制（App 内"使用提示"页有面向用户的版本）

- 同名文件原地修改不触发目录 mtime 变化，size/mtime 待下次全量重建刷新
- 保护区域（Android/data 内）文件暂不支持打开/分享（其他应用无法读取）
- 深度索引 /data/data 默认关闭（两层概览）；开启后 133 万级应用内存
  ~178MB（SoA 后已稳定）
- /proc、/sys 不索引；符号链接/socket/设备节点不入索引（索引数会少于
  find 原始计数）
- Shizuku 服务重启后需重新拉起；root 层级下 adb 授权在 Magisk 中给
  shell 授权一次即可

---

## 7. 开发环境

- Flutter 3.41.6 stable / Dart 3.11.4 / Android SDK 36 / JDK 25
- minSdk 26（Android 8.0）～ targetSdk 36（Android 16）
- 依赖：shared_preferences、dev.rikka.shizuku:api/provider 13.1.5、
  androidx.core
- NDK：仅 vfwatch.c（arm64-v8a + armeabi-v7a），`useLegacyPackaging=true`
  （需落盘可执行）
- Windows + Git Bash 开发；MSYS 路径转换用 `export MSYS_NO_PATHCONV=1`

## 8. Git 历史（里程碑全记录）

```
bc0a15f P2加固: 免装箱快排+池去重; 事故记录与安装协议
77eb51c P2 SoA内存索引（测试机全功能验证）
acfb97a 130万深度压力测试（3修复: 换行文件名/WAL/竞态）
f51cdec P1 真机验证（4.6s/19MB）
2ce19d1 P1 DB v3 全套（5修复）
a1268ec P0 启动预算守卫/OOM自愈/WAL修复
2968883 nsenter+深度限制+确认对话框+并行扫描+ANR修复
d8d1a71 真机适配第一批（列表懒加载/fastLower/同步冷却）
81a4e14 M2.5 Shizuku T2 + 应用检索 + 主题
32eeead M3.2 vfwatch 前台监听 + 提示页
32337f7 M3.1 增量同步 + 本地化 + 黑屏修复
9780d80 M2.1 统计/排序/按应用/主题
d39202f M2 root接入 + 浏览模式
ae0bc6a M1.5 多选与文件操作
7419a79 M1 端到端首版
5825b7f M0.5 竞品调研
c18edb8 M0 初始化
```
