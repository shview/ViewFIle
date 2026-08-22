# ViewFile — Android 上的 Everything

Android 平台的即时文件搜索引擎 + 文件管理器，对标 Windows 上的 Everything：
输入即出结果的文件/文件夹搜索（含系统隐藏区），附带完整文件管理功能。
免 root 可用，root / Shizuku 解锁全盘索引。

> **交接说明**：本文档面向接手本项目的 AGENT 或开发者。包含完整架构、
> 全部踩坑记录（每条真机复现过）、操作协议与路线图。读完即可继续开发。
> 代码量约 5900 行（Kotlin 3520 / Dart 2180 / C 174），单仓库无子模块。

---

## 1. 项目状态（2026-08-21 深夜，21 个提交）

### 1.1 能力矩阵

| 能力 | 状态 |
|---|---|
| 即时搜索（全盘/当前目录/按应用） | ✅ 真机验证 |
| 文件管理（浏览/多选/打开/分享/重命名/删除） | ✅ 真机验证 |
| 三层访问：免root(T1) / Shizuku(T2) / root(T3) | ✅ 真机验证 |
| 打开时增量同步 + 前台实时监听（无常驻） | ✅ 真机验证 |
| 排序（名称/大小/时间/升降序）+ 文件夹统计（子项数/递归大小） | ✅ |
| 按应用检索（/data/data + Android/data + obb 三目录） | ✅ |
| 主题色（7 色）+ 明暗模式 + 隐藏文件开关 + 系统分区可选 | ✅ |
| DB v3（parent_id 树形结构，无路径落库） | ✅ 百万级实测 |
| SoA 内存索引（名字池 + 平行数组 + 欧拉区间） | ✅ 133 万条实测 |
| 复制/移动 | ❌ M4 待实现 |
| WizTree 式空间分析 | ❌ backlog（数据已具备） |
| 500 万级条目 | ❌ 需目录映射树解析化（见路线图） |

### 1.2 关键实测数据（OnePlus PLC110 / Android 15 / Magisk root / 22 万条）

| 指标 | 数值 | 备注 |
|---|---|---|
| 全量重建 22 万条 | **4.6s** | FUSE 1.1s + Android 管道 2.9s + 建库 0.5s |
| 全量重建 133 万条（深度） | **~75s** | /data/data 深度区 39s 为主 |
| SoA 载入 22 万条 | **558-677ms** | 含路径重建 + 欧拉区间 + 排序 |
| SoA 载入 133 万条 | **3.2-3.8s** | 池去重后唯一名 18.9 万 |
| 增量同步 22 万条 | **2.3s** | 修复前 67s（键偏移 bug） |
| 搜索延迟 | **15-130ms** | 含范围过滤（欧拉区间 O(1)） |
| DB 体积 22 万条 | **19MB** | +41KB WAL |
| DB 体积 133 万条 | **116MB** | v2 同规模 667MB（缩小 5.7 倍） |
| 内存 133 万条 SoA | **Java 堆 178MB** | 对象模型 630MB/OOM |
| 内存预算守卫 | `largeMemoryClass × 6200` | 512MB 堆 ≈ 310 万条上限 |
| 名字池去重率 | ~15%（22 万→18.9 万唯一） | cache/.log 等重复名合并 |
| 应用列表 | 610 apps / 3.4s | 图标懒加载，列表秒回 |

---

## 2. 架构

### 2.1 整体分层

```
┌──────────────────────────────────────────────────┐
│ Flutter (Dart, ~1400 行) — UI 与业务编排          │
├──────────────────────────────────────────────────┤
│ lib/main.dart              入口 + 主题 + zh 本地化│
│ lib/api/engine_api.dart    MethodChannel 封装     │
│ lib/pages/home_page.dart   主页(浏览/搜索/多选)   │
│ lib/pages/apps_page.dart   按应用检索             │
│ lib/pages/settings_page.dart 设置                │
│ lib/pages/tips_page.dart   使用提示与已知限制      │
│ lib/theme.dart             主题色/明暗切换         │
│ lib/utils/format.dart      大小/日期/文件类型分类  │
├──────────────────────────────────────────────────┤
│ Kotlin 引擎 (~3520 行) com.viewfile.viewfile.core│
├──────────────────────────────────────────────────┤
│ MainActivity.kt    通道绑定（全部后台化，防 ANR） │
│ Engine.kt          单例：2 线程池(scan+mutation/search)│
│                    状态机 IDLE→SCANNING/SYNCING→READY│
│                    scanRequested 抢占标志          │
│ Db.kt              schema v3 + IndexSink 接口     │
│                    deleteSubtree(递归 CTE)        │
│ IndexBuilder.kt    全量重建器→index-new.db→原子rename│
│ Scanner.kt         FUSE 并行扫描(4worker采集+单线程落库)│
│ RootScanner.kt     特权区 find|stat 管道流式      │
│                    + parseStatLine + mapDisplay   │
│ SyncScanner.kt     增量对账((parent_id,name)语义) │
│                    + 大规模删除守卫 + 扫描抢占     │
│ SearchIndex.kt     SoA 内存索引(P2)               │
│                    + namePool/nameRef/tin/tout    │
│                    + sortIdx(免装箱三路快排)      │
│ SuShell.kt         su 封装(nsenter 进 PID1 命名空间)│
│ ShizukuShell.kt    Shizuku binder AIDL 执行       │
│ Fs.kt              目录浏览(FUSE优先/特权回退)     │
│                    + isFuseBlocked 判定           │
│ FileOps.kt         打开/分享/重命名/删除          │
│                    root 回退(rm/mv)              │
│ TreeWatcher.kt     前台实时监听+进程级共享生命周期协调器│
│                    + owner epoch/Process identity 防跨实例竞态│
├──────────────────────────────────────────────────┤
│ NDK C (~174 行) android/app/src/main/cpp/vfwatch.c│
│ root/shizuku 拉起的 inotify 监听进程              │
│ stdin 喂目录清单→stdout R 握手 / D ordinal / X 失败│
│ 打包为 libvfwatch.so (需 useLegacyPackaging=true) │
└──────────────────────────────────────────────────┘
```

### 2.2 三层特权访问（PrivShell 自动降级 ROOT > SHIZUKU > NONE）

```
T3 root:  su -c "nsenter -t 1 -m -- /system/bin/sh -c '<cmd>'"
          ↑ 必须进 PID1 命名空间——ColorOS 在 app ns 过滤 /data/data
          覆盖: /data/media/0/Android + /data/data + /data/local/tmp

T2 Shizuku: IShizukuService binder newProcess (API 13 走 AIDL)
            shell 身份可读 Android 区与 tmp，不能读 /data/data
            注意: newProcess 已私有化，需 binder 反射

T1 免root:  MANAGE_EXTERNAL_STORAGE + FUSE
            Android/data、obb 在 FUSE 层被系统隐藏（所有 app 一致）
            前台监听退化为 MediaStore Observer
```

**路径映射**：`/data/media/0/Android` ↔ `/storage/emulated/0/Android`
（`RootScanner.toDisplay / toRaw`，索引用 display 路径，命令用 raw 路径）

### 2.3 数据库 v3（SQLite）

```sql
CREATE TABLE entry(
  id        INTEGER PRIMARY KEY,   -- 构建时顺序分配
  parent_id INTEGER NOT NULL,      -- parent_id < id 恒成立（不变式）
  name      TEXT NOT NULL,         -- 路径不落库（v2 是体积主因）
  type      INTEGER NOT NULL,      -- 0=file 1=dir
  size      INTEGER NOT NULL DEFAULT 0,
  mtime     INTEGER NOT NULL DEFAULT 0  -- 毫秒
);
CREATE UNIQUE INDEX idx_entry_parent_name ON entry(parent_id, name);
-- meta 表: schema 指纹 + scan_cfg 指纹(root/sys/deep/tier)
```

**全量重建流程**：
```
IndexBuilder.begin()
  → 建独立 index-new.db（WAL + synchronous=OFF + 20万条分批）
  → FUSE 并行扫描（4 worker 采集 + 单线程批量落库）
  → root 管道扫描（find|stat 流式）
  → finishAndSwap()
      → commit 事务
      → CREATE UNIQUE INDEX（建后索引）
      → wal_checkpoint(TRUNCATE)
      → 关闭旧连接 → 删 index.db* → rename → 重开连接
```

### 2.4 SoA 内存索引（SearchIndex.kt）

```
名字池 namePool: 所有条目名的 UTF-8 拼接（保留原大小写）
  → 排序后同名相邻 → 去重为唯一名池
  → nameRef[entryIdx] = uniqueIdx（引用数组）
  ⚠️ 去重必须精确匹配（cmpNameExact 逐字节），
     不能用大小写不敏感比较——Tencent ≠ tencent！

平行数组（密集下标）:
  parentId[]  密集父下标（根 = -1）
  isDir[]     / size[] / mtime[] / entryId[]
  tin[]/tout[] DFS 欧拉区间（子树判定 O(1)）

sortIdx[]  字典序排列（免装箱三路快排，折叠比较排序）
           查询按此顺序取前 N（结果天然字典序）

路径: 不驻留内存
  pathOf(Hit) → 沿 parentId 链拼接（仅结果 ≤200 条时）
  dirIds/dirMtimes HashMap → 同步/范围查询用（仅目录 ~38k 条）
```

### 2.5 同步体系（无常驻设计）

```
打开 app 时:
  1. ensureIndexLoaded（SoA 载入 + 预算守卫）
  2. needsRescan 指纹检查（配置变化→全量重建）
  3. _autoSync 静默增量对账

增量对账 (SyncScanner):
  watcher 事件默认 dirty scope（最多 256 个父目录）:
    → D ordinal 聚合后映射为 display parent，去重并补父目录
    → FUSE 只对账目标父目录；仅新发现子树做首次完整下钻
    → root 只重列目标父目录；删除/重命名由其父目录直接子项 diff 收敛
    → dirty 聚合超过 256 立即转 full 并清集合；root 目标超过 16 也转 full，限制 shell 次数
    → 未路由路径、scope 超限、MediaStore/坏协议走 full
    → 任一区失败/扫描让位后静默追加最多一次 full recovery；full 再失败保持 pending，
      等下一事件、生命周期或手动同步触发，不忙循环
    → 手动同步、启动同步始终 full
  FUSE 区: 始终递归现存子目录（mtime 仅跳过当层 diff）
    → listFiles 任一层失败则 fuseOk=false，其他子树仍 best-effort
    → changed 目录只在 diffChildren 成功后提交 mtime
      （新目录在成功前 mtime=0，保证下轮重试）
  root 区: find -type d | stat 只 stat 目录
    → 管道 rc≠0 → 整区跳过（不删不重列）
    → 大规模删除守卫: >2000 或 >20% 已知 → 拒删并标记 incomplete
    → 变化目录批量重列（300 目录/管道，单轮上限 2000）
    → 仅 shell+chunk diff 成功后提交 mtime；超额 deferred 保留旧值
    → 纯 cap deferred 会后台静默续排一轮；任一处理失败不立即重试
    → 深度上限: /data/data 默认两层，防逐层蔓延
    → 各阶段检查 scanRequested → 扫描请求到达立即让位
  输出分段 telemetry: scope/dirtyCount + fuseElapsedMs/fuseOk + 每个 root area
    耗时、变更、deferredDirs/processingOk/massDeleteGuarded

前台实时监听 (TreeWatcher + vfwatch):
  vfwatch 进程（su/shizuku 拉起）对全部索引目录挂 inotify
  → stdin 清单以 "." 结束；stdout 先 `R requested installed`
  → 事件为 `D <0-based directory ordinal>`；`X`/坏协议/溢出均 fail-closed
  → Kotlin 用启动快照将 ordinal 还原为 dirty directory，事件仅作触发信号
  → 只过滤 ViewFile 自身 databases 目录；不粗放过滤其他 app
  → reader 只向主 Handler 投递；聚合/停止/dispatch 都在同一 Handler 原子处理
  → 聚合 dirty parent，静默 2s → 跑 scoped 增量对账拿精确结果
  → Engine single-flight 合并同步期间的新 dirty，full 请求优先，完成后最多一轮 trailing
  → scoped event/trailing 成功且无 trailing 时，按最后 dirty/完成时间静默 1.8s 后做一次
    同 scope settle；新 dirty 合并并重置 settle，settle 自身成功不续排，失败仅走一次 full recovery
  → telemetry 标注 cause=event/trailing/recovery/settle，以及 settle 的 scheduled/coalesced/
    cancelled、scope/count/elapsed；event/trailing/recovery 在启动时原子绑定最新前台配置；
    stop 解绑定配置并保留待 settle scope，resume 安全吸收后 kick
  → 健康复用还要求 MEDIA/SU/SHIZUKU 模式完全一致；权限层或 rootIndex 改变即替换实例
  → 只在目录集合增删时 refresh helper；文件内容更新不重启
  → 所有 TreeWatcher 实例共享唯一进程级 daemon executor
  → start/stop/refresh/fallback 以 owner epoch 串行；旧实例 stop 不推进新 owner epoch，
    仅摘除自身资源且不得 pkill 继任者；pause→resume 的 stop/start 保持投递顺序
  → Dart 用进程级 `max(clock,last+1)` 分配每次 start/stop 的 lifecycleIntent，
    页面 dispose 不冒充后台 stop；Engine 以 latest-intent-wins 维护 desiredForeground；
    stop/ready 握手可抢占，resume 会重试曾回退 MediaStore 的 root transition
  → pkill 仅 rc=0/1 视为已清理；失败保留 cleanup-pending，禁止启动新 native helper，
    fail-closed 回退 MediaStore
  → pkill 使用 app 私有 nativeLibraryDir 绝对路径 + `[l]ibvfwatch\.so` 精确身份，
    不匹配自身/其他 app 同名进程；helper 启动前持久记录后端与绝对身份
  → watch-mode helper 启动即以 `PR_SET_NAME` 设置 15 字节专属 comm
    `vf.viewfile.vfw`；设置失败即退出，rename helper 模式不改名
  → 新进程按记录预清孤儿；SU 可直接清理；Shizuku 先用 `pidof libvfwatch.so`
    兼容旧版，再以 `pidof vf.viewfile.vfw` 检测新版，避免旧→新 comm 迁移窗口漏检；
    两条命令均可靠 absent 才可直接放行
  → 发现 PID 后以 `/proc/<pid>/exe` 归属到 ViewFile exact/package-wide 路径，
    只用包专属正则清理并复核；旧通用名无法确认归属时 fail-closed，绝不按通用名 kill
  → 仅旧通用名命中的 ViewFile PID 还须读取 cmdline：argc=1 才是旧 watcher；
    明确 `--rename-noreplace` 的短时 rename helper 忽略，不确定则 fail-closed
  → 历史 SU 记录转为 Shizuku 时无法排除更高权限孤儿，直接 fail-closed；pidof/readlink
    不兼容、执行失败、目标清理后仍可见都回退 MediaStore
  → 数据清除/重装导致无记录时，ROOT 使用严格 package-wide 跨版本身份同时覆盖
    Android 8 与现代 `/data/app` 布局；失败在 refresh 重试
  → 应用只读 max_user_watches，绝不修改 sysctl；容量不足回退 MediaStore
```

### 2.6 启动内存预算守卫

```
loadIndexAsync:
  COUNT(entry) > largeMemoryClass × 6200
  → resetForRebuild（废弃索引）
  → 返回 -1 → Dart 侧关闭深度开关 → 精简模式自动重建

catch OOM → 同样自愈（-1 信号）
```

---

## 3. 构建与部署

### 3.1 常用命令

```bash
flutter pub get
flutter test                               # Flutter 单元测试（5 个）
cd android && ./gradlew :app:testDebugUnitTest --configure-on-demand  # Kotlin 单测
flutter build apk --release                # 产物 ~22.5MB
flutter analyze                            # 静态分析
```

### 3.2 ⚠️ 安装安全协议（事故教训，必须遵守）

**`adb install` 必须作为独立短命令执行，绝不与其他命令捆绑。**
曾被中断的 install 留下坏 APK → dex 校验风暴 → MTK Hang_Detect
强制重启整机（用户日常机，事故等级最高）。

```bash
# 正确流程：
adb install build/app/outputs/flutter-apk/app-release.apk     # 独立执行
adb shell su -c 'md5sum /data/app/*/com.viewfile.viewfile-*/base.apk'  # 校验
md5sum build/app/outputs/flutter-apk/app-release.apk          # 本地对比
```

### 3.3 测试设备

| 设备 | 型号 | 角色 | 注意事项 |
|---|---|---|---|
| 测试机 | Pixel 7（Android 16，Magisk，root+shizuku 已授权） | 功能验证 | 锁屏+通知栏卡住：WAKEUP+上滑解锁 |
| 真机 | OnePlus PLC110（Android 15，Magisk，**用户日常机**） | 规模/性能 | **UI 自动化前确认前台**；用户使用中禁 input 注入 |

其他：
- Magisk 直授权：`sqlite3 /data/adb/magisk.db "INSERT OR REPLACE INTO policies (uid,policy,...) VALUES (<uid>,2,0,1,1)"`
- 授权"所有文件访问"：`adb shell appops set com.viewfile.viewfile MANAGE_EXTERNAL_STORAGE allow`
- Shizuku 授权：`adb shell pm grant com.viewfile.viewfile moe.shizuku.manager.permission.API_V23`

### 3.4 调试通道

| logcat 标签 | 内容 |
|---|---|
| `ViewFile/Scan` | 构建分段计时 / SoA built 摘要 / 载入耗时 |
| `ViewFile/Sync` | 同步增删统计 / 守卫触发 / 让位 / 分区跳过 |
| `ViewFile/Search` | 查询延迟 / 命中数 / scope |
| `ViewFile/Watch` | vfwatch 启停 / watch limit / 进程退出 |
| `ViewFile/Build` | 构建库 commit/index/swap 耗时 |
| `ViewFile/Su` / `ViewFile/Shizuku` | 特权层探测与降级 |
| `ViewFile/Fs` | 目录浏览路径决策 |

- R8 混淆映射：`build/app/outputs/mapping/release/mapping.txt`
  （类名映射如 `c0.p → IndexBuilder`，ANR 栈反查必用）
- ANR 栈：`su -c 'kill -3 <pid>'` → `/data/anr/trace_NN`
- 内核崩溃：`/sys/fs/pstore/console-ramoops-0`
- OnePlus 系统 logcat 刷得极快，诊断前 `adb shell su -c 'logcat -G 16M'`

---

## 4. 踩坑记录（接手必读，每条真机复现过，按严重程度排序）

### 4.1 崩溃/死机级

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | 中断 adb install → 整机重启 | 坏 APK → dex 校验风暴 → 4GB 脏页缓存 → MTK Hang_Detect 2 分钟倒计时 → 强制重启 | 安装必须独立短命令（§3.2 协议） |
| 2 | ensureDirChain 无前导斜杠死循环 | `substringBeforeLast('/')` 无斜杠时返回原串，while 永不终止 → CPU 100% 卡死 | 入口守卫 `if (!path.startsWith("/")) return 0` |
| 3 | SoA 载入 `length=0; index=0` 崩溃 | 池去重赋 nameRef 在目录映射之后，pathOfIdx 读 IntArray(0) | 调整顺序：排序→去重→目录映射→统计 |
| 4 | SQLite 写事务跨线程死锁 | Android SQLite 写事务绑定唯一连接，跨线程插入永久等待 | 并行扫描改"采集入队、单线程落库" |

### 4.2 数据损坏/性能劣化级

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 5 | **名字池去重大小小写合并 → 同步键偏移 2/3 → 67s 同步** | `cmpName` 大小写不敏感，Tencent/tencent 合并后路径重建返回错误大小写 | 新增 `cmpNameExact` 逐字节比较（去重专用） |
| 6 | 同步管道部分输出 → 误删 15.5 万条 | find\|stat 管道部分失败（rc≠0 但有部分输出），缺失目录被当成已删除 | rc≠0 整区跳过 + 大规模删除守卫（>2000 或 >20% 拒删） |
| 7 | 祖先 mtime 清零 → 同步死循环膨胀 | ensureDir 补祖先链时传 mtime=0，真实值被覆盖 → 永远判"变化" | 补链绝不写 mtime（`update=false` 参数） |
| 8 | journal=OFF 百万级 SQLITE_CORRUPT | 某些设备上 journal=OFF + 大事务导致库损坏 | 构建库改 WAL + 20 万条分批事务 |
| 9 | 同步逐层蔓延 | 变化目录重列无深度上限 → 下层变化引入更深层 → 最终全量 | 重列遵守 `area.depth` 上限 |
| 10 | 扫描区重叠 → UNIQUE 冲突 | FUSE 与 root 管道双写 Android 子树 | FUSE 侧 `fuseSkip` 跳过该子树 |
| 11 | 平行根链（同一路径多个 DB 条目） | ensureDir 补链时未先查 (parent_id,name) | ensureDir 先查 DB，仅缺失时补目录行/父链 |

### 4.3 功能/体验级

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 12 | Android 16 execSQL 拒绝带返回行的 PRAGMA | `PRAGMA journal_mode/WAL` 等返回结果行 | 必须走 `rawQuery` |
| 13 | nsenter `--` 分隔符 | toybox nsenter 把后续 `-c` 当自己的选项 | `nsenter -t 1 -m -- /system/bin/sh -c '<cmd>'` |
| 14 | ColorOS app 命名空间过滤 /data/data | Magisk su 默认继承 app ns，root 也只见自己与 GMS | 所有 su 命令经 nsenter 进 PID1 ns |
| 15 | 换行文件名撕裂 stat 输出 | 文件名含 \n → stat 行被拆成碎片 → 根级垃圾/死循环 | 源头丢弃非 `/` 开头的行 |
| 16 | VACUUM 在 WAL 模式写整库进 WAL | WAL 中 VACUUM 把整个新库写入 WAL 文件 | VACUUM 后必须 `wal_checkpoint(TRUNCATE)` |
| 17 | String.toLowerCase 慢路径 | 22 万条调用分钟级 | 手写 ASCII fastLower / SoA 折叠字节比较 |
| 18 | 主线程特权检测 ANR | su 探测最长 5s，在主线程阻塞输入 | 所有通道检测全部后台化 |
| 19 | Shizuku 双 server 授权丢失 | 授权弹窗写一个 server、app 连另一个 | 杀双实例重拉单实例；`pm grant` 直授 |
| 20 | watcher 空库期 0 目录启动 | 空库时 dirIds 为空，watcher 监听 0 目录且不自愈 | `watchedDirCount > 0` 健康检查 |
| 21 | 异步 pkill 误杀新 vfwatch | 旧 TreeWatcher.stop 与新实例 start 跨实例并发 | 进程级共享 executor 串行，owner epoch+Process identity 拒绝旧任务 |
| 22 | 扫描请求排队等同步 67s | scanExec 单线程被长同步占住 | `scanRequested` 标志 + 同步各阶段让位 |
| 23 | inotify watch 容量不足 | `/proc/sys/fs/inotify/max_user_watches` 是全局设置 | 只读容量，绝不修改 sysctl；不足时回退 MediaStore |

---

## 5. 路线图（按优先级）

### P3：500 万级支持（用户明确要求按最坏情况优化）

- **目录映射树解析化**：dirIds/dirMtimes/denseStats 三个 HashMap 在 70 万
  目录时约 300MB，是最后的内存大头。方案：保留 children 数组（按名排序），
  路径→id 用逐段二分查找（O(depth×log)），统计用三平行数组
- **搜索加速**：百万级线性扫描 130-400ms/键击，可加首字节桶或 n-gram
  倒排（参考 plocate）
- 更大堆设备（largeMemoryClass 768MB+）自动放宽预算

### M4：文件管理补全

- 复制/移动（目标目录选择器 + root 区 mv/cp 回退 + 进度）
- 书签/快速访问
- WizTree 式空间分析二级页（denseStats 递归大小数据已具备）

### 其他 backlog

- SAF 批量授权向导（A13 起体验差，仅作 T1 补充）
- 应用图标磁盘缓存
- 深度同步提速（133 万条单轮 ~55s：180k 目录 stat 对账）
- FUSE 并行扫描调优（binder 往返是瓶颈）
- lint 清理

---

## 6. 已知限制（App 内"使用提示"页有面向用户的版本）

- 同名文件原地修改不触发目录 mtime 变化，size/mtime 待全量重建刷新
- 保护区域（Android/data 内）文件暂不支持打开/分享
- 深度索引 /data/data 默认关闭；开启后 133 万级内存 ~178MB（SoA 稳定）
- /proc、/sys 不索引；符号链接/socket/设备节点不入索引
- Shizuku 服务重启后需重新拉起
- 增量同步会补建缺失的目录行/父链；对账失败时保留旧 mtime 供下轮重试

---

## 7. 开发环境

| 项 | 值 |
|---|---|
| Flutter | 3.41.6 stable |
| Dart | 3.11.4 |
| Android SDK | 36（licenses 已接受） |
| JDK | Android Studio JBR 21（Gradle 门禁） |
| minSdk | 26（Android 8.0） |
| targetSdk | 36（Android 16） |
| 依赖 | shared_preferences, shizuku api/provider 13.1.5, androidx.core |
| NDK | 发布配置 arm64-v8a + armeabi-v7a；Debug 门禁另构建 x86_64，`useLegacyPackaging=true` |
| OS | Windows + Git Bash；MSYS 路径 `export MSYS_NO_PATHCONV=1` |

---

## 8. Git 里程碑

| 提交 | 里程碑 | 要点 |
|---|---|---|
| `49acf01` | 同步键偏移修复 | 去重精确匹配 + 同步守卫 + 扫描抢占 |
| `c729900` | SoA 载入顺序修复 | nameRef 初始化竞态 |
| `1ab616c` | 完整交接 README | 本文档首版 |
| `bc0a15f` | P2 加固 + 安装事故 | 免装箱快排 + 池去重 + 安全协议 |
| `77eb51c` | P2 SoA 内存索引 | 名字池+平行数组+欧拉区间 |
| `acfb97a` | 130 万压力测试 | 换行文件名 / WAL CORRUPT / prefs 竞态 |
| `f51cdec` | P1 真机验证 | 4.6s / 19MB |
| `2ce19d1` | P1 DB v3 | parent_id 结构 + 5 修复 |
| `a1268ec` | P0 止血 | 预算守卫 / OOM 自愈 / WAL 修复 |
| `2968883` | nsenter + 并行 + ANR | ColorOS 解锁 / FUSE 并行 / 主线程后台化 |
| `d8d1a71` | 真机适配第一批 | 列表懒加载 / fastLower / 同步冷却 |
| `81a4e14` | M2.5 Shizuku T2 | PrivShell 降级 / 应用检索 / 主题 |
| `32eeead` | M3.2 vfwatch 前台监听 | NDK 方案 / 提示页 |
| `32337f7` | M3.1 增量同步 | mtime 对账 / 本地化 / 黑屏修复 |
| `9780d80` | M2.1 统计/排序 | 递归大小 / 按应用 / 主题 |
| `d39202f` | M2 root 接入 | 浏览模式 / 范围搜索 / root 文件操作 |
| `ae0bc6a` | M1.5 多选与文件操作 | 打开/分享/重命名/删除 |
| `7419a79` | M1 端到端首版 | 扫描/SQLite/搜索 |
| `5825b7f` | M0.5 竞品调研 | 定位成立 |
| `c18edb8` | M0 初始化 | 方案与里程碑 |
