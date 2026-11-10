# 2026-11-10 只开 My Mac 窗口，Mac Catalyst 服务也把它自己的 Always Index 建了一遍，多占约 420 MB

**调查日期：** 2026-11-10
**修复落地：** 本日，`next`
**Severity：** Medium —— 结果都对，没有数据丢失；但没有窗口用到的 Mac Catalyst 服务照样索引、建 Find 语料、备交叉引用：只开一个 My Mac 窗口时它占了 451 MB（0081 之前同样场景约 32 MB），启动后的头两分钟还白跑了 CPU（UIKitCore 的语料建了 56 秒）
**触发场景：** 提案 0081（系统镜像的数据跨 engine 只存一份）落地后，只在 My Mac 上开窗口；Always Index 里有对 Mac Catalyst 生效、又解析到 Catalyst 专用镜像的条目（这次是对所有 engine 生效的 SwiftUI——在 Catalyst 上解析到 `/System/iOSSupport/` 下的那份——和只限 Catalyst 的 UIKitCore）；Mac Catalyst engine 重载一次数据（服务进程连上、加载了镜像），或用户改了索引设置

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 只开着一个 My Mac 窗口，`RuntimeViewerCatalystService` 占 451 MB。日志显示 App 启动半分钟后，Catalyst 服务开始给 iOSSupport 版 SwiftUI 与 UIKitCore 建 Swift section 和 Find 语料，顺序正是它的 Always Index 条目顺序 |
| **影响范围** | 2026-11-09 0081 落地起（`ae752527` 让借用方持有归属 engine 的后台工作）。`main` 没有借用，不受影响。按同一条代码路径，附加进程的文档借用 My Mac 与 Catalyst 两边，只开附加进程窗口时两个归属 engine 都会跑自己的 Always Index |
| **根因** | 借用方持有归属 engine 的后台工作时，工作里的索引协调器照常创建，构造时就起了 reload 泵和设置观察；这两条路派发 Always Index 与主程序批次时只看协调器有没有关闭，不看 `hasStarted`（有文档真开在这个 engine 上才为真）。0081 只给「engine 背后换了进程」「借用关系变化」两条路加了这个检查 |
| **Status** | **Fixed** —— 检查下沉到 engine 自己批次的两个派发入口 `startAlwaysIndexBatches()` 与 `startMainExecutableBatch(reason:)`：没有文档开在 engine 上时，任何触发都不再启动它自己的批次 |

---

## 根因

0081 让 My Mac 与 Mac Catalyst 互相借用系统镜像：My Mac 窗口里的 Catalyst 专用镜像由 Catalyst engine 提供。为此，My Mac 文档的会话以「借用者」身份持有 Catalyst engine 的后台工作（`RuntimeEngineBackgroundWorkRegistry.borrow(_:as:)`），工作不存在就新建一份。按设计，借用者不触发归属 engine 自己的开场派发（主程序批次与 Always Index）：只有成员（开在这个 engine 上的文档）加入时才调用 `documentDidOpen()`，由它把 `hasStarted` 置为真再派发。

可后台工作一建出来，索引协调器的构造函数就启动了几样东西，其中两样会派发：

- **reload 泵**（`startReloadDataPump()`）：engine 每发一次 `.fullReload`，就重试一遍 Always Index（`retryAlwaysIndexBatches()` → `startAlwaysIndexBatches()`）。它是为远程 engine 的镜像列表晚到而设的，只看协调器有没有关闭。
- **设置观察**（`handleSettingsChange()`）：总开关或自定义开关打开、条目改变时派发 Always Index，启发式打开时派发主程序批次，同样不看 `hasStarted`。

0081 之前后台工作只由成员建出，成员加入的同时就调用了 `documentDidOpen()`，这两条路碰不到「还没开始」的协调器。0081 给借用者建出的工作里，`engineDidReset()` 与 `sharedCacheOwnersDidChange()` 加了 `hasStarted` 检查，这两条漏了。

于是只开 My Mac 窗口时，Catalyst engine 的数据一重载——服务进程连上后的第一次重载、它加载任何一个镜像——它的协调器就按 Catalyst 的平台解析 Always Index：SwiftUI 落到 iOSSupport 版，只限 Catalyst 的 UIKitCore 也生效（这个协调器本来就是 Catalyst engine 的），其余共用的系统镜像交给 My Mac，那边已经建过。同一份工作里的语料协调器与交叉引用预备协调器照常处理「engine 索引过的每个镜像」，所以这些镜像的语料与交叉引用也建了。

## 现场证据

Ultra 上用 `RuntimeViewer-Local.xcworkspace` 编的 Debug 版，启动约 50 分钟，没开 Malloc Stack Logging，给三个进程各抓了一份内存图（`leaks --forkCorpse --fullContent --outputGraph=…`），再离线用 `leaks --dominatorTree --groupByType` 按持有者归类：

- **唯一的窗口在 My Mac 上**：App 里只有一个 `DocumentState`；对三个 `RuntimeEngine` 跑 `leaks --traceTree`，侧栏的 `runtimeEngine` 指向本地 engine，会话的 `sharedCacheOwners.macCatalyst` 指向 `RuntimeEngineManager.macCatalystRuntimeEngine`。
- **Catalyst 服务 451 MB**：malloc 在用 237 MB——UIKitCore 等的 ObjC 索引约 50 MB、iOSSupport 版 SwiftUI 的语料 41.5 MB、交叉引用约 30 MB 等；其余约 190 MB 是这批工作释放后 malloc 还没还给系统的（已释放的大块 72 MB）。
- **日志**：App 21:44:30 启动；21:44:58 Catalyst 服务开始给 iOSSupport 版 SwiftUI 建 Swift section，21:45:37 建完它的语料（7,303 个对象，估算 45.6 MB，39 秒）；21:45:40 起轮到 UIKitCore，21:46:36 建完语料（9,403 个对象，估算 92 MB，56 秒，超过 64 MB 的常驻上限，存盘后不留在内存里）。
- 2026-11-08（0081 之前）同样只开一个 My Mac 窗口时，Catalyst 服务约 32 MB、堆 6.6 MB。

## 为什么测试没抓到

`SharedCacheBorrowingTests` 的「借用者不启动归属 engine 自己的索引」只断言了 `hasStarted` 为假，而且整组测试为了不让测试进程索引自己的依赖，把索引总开关关了；没有一条在只借用期间让归属 engine 重载、或改索引设置，再看归属 engine 开没开批次。

## 修复

- `startAlwaysIndexBatches()` 与 `startMainExecutableBatch(reason:)` 开头查 `hasStarted`。engine 自己的批次只从这两处启动，检查放在这里，reload 泵、设置变化，以及以后再加的触发都覆盖到。`engineDidReset()`、`sharedCacheOwnersDidChange()` 原有的检查保留：它们在派发之前还要取消批次、清空派发闸门。
- 设置观察照常运行：只借用期间改了设置，比较用的基线照样更新；之后有文档开到这个 engine 上，`documentDidOpen()` 按当时的设置派发。关掉总开关之类的取消路径也照旧。
- 借用者交给归属 engine 的批次（reason 为 `.borrowed`）不经过这两处，照旧由借用方的协调器发起。

## 横向排查

- 同一份后台工作里的 `FindCorpusCoordinator` 与 `CrossReferencePreparationCoordinator` 只处理 engine 已经索引过的镜像，自己不发起索引；engine 不再替没人要的条目索引，它们也就没有东西可建，不用改。
- 索引协调器启动 engine 自己批次的入口只有上面两个，都已检查。
- 只借用时，Catalyst engine 先前已经索引过的镜像（比如这次运行早些时候开过 Catalyst 窗口）仍会建语料、备交叉引用：engine 进程里的数据不自动丢弃是提案 0065 的设计，不属于这个问题。

## 验证

- 新增 `SharedCacheBorrowingTests` 两组用例：「归属 engine 重载时不启动自己的索引」1 个；「索引设置变化时不启动自己的索引」4 个（加 Always Index 条目、打开 Always Index、打开总开关、打开主程序索引）。断言是只借用期间 3 秒内，归属 engine 的协调器一个批次也不显示，在跑的、跑完的都算。修复前 5 个全红：归属 engine 给 libdispatch 开了 Always Index 批次，给测试进程的主程序（`swiftpm-testing-helper`）开了批次；修复后全绿，同组原有 9 个照常通过。
- **相关测试组**（按原始退出码）：后台索引、Report、文档生命周期、会话、App Nap activity、语料协调器、派生数据读回、推出数据共 15 组 98 个测试通过。
- **回归**：`RuntimeViewerApplicationTests` 全量 884 个、130 组，3 个失败。其中两个是满载下的等待超时，所在的两组单独重跑都通过：「语料构建期间一直持有 engine 的 activity」（等 120 秒）与「Call Hierarchy 展开调用方」（等 60 秒）。另一个是 `TitleActivityIndicatorTests` 的悬停用例，单独跑也失败，与这次改动无关：它只测 `TitleToolbarItem`，不碰 engine，同日改动之前的一次全量运行里就已经失败。
- 每次运行前后，两个包的锁文件没变；测试用的是内存里的设置，不碰用户的 `settings.json`。
- **真实 App**：修复后在 Ultra 上重新运行，只开一个 My Mac 窗口，等本地服务的索引结束（启动后约 2 分钟）：`RuntimeViewerCatalystService` 30 MB（峰值 36 MB），启动以来日志里没有它建 Swift section、语料或交叉引用的记录；本地服务 413 MB，App 94 MB。修复前同样的设置，Catalyst 服务在 451 MB、峰值 501 MB。
