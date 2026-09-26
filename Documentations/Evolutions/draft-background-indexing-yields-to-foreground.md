# Draft - 后台索引给前台加载让路

- **状态**: Implemented
- **创建日期**: 2026-09-26
- **最后更新**: 2026-09-26
- **所属愿景**: 无

## 摘要

设置里开着 5 条「始终索引」（AppKit、Foundation、libswiftCore、SwiftUI、SwiftUICore）时，启动后立刻打开
AppKit，列表要等后台差不多全部建完才出来：Debug 构建下单独打开 AppKit 要 25 秒，这时要 41 秒。原因是同一个
进程里同时有 6 个大镜像在建（5 个后台批次，外加前台把 AppKit 又完整建了一遍），它们互相拖慢，其中最重的是
进程内共享的 Swift 运行时泛型元数据缓存。CPU 核并不紧张，所以 QoS 帮不上忙。本提案做两件事：

1. 让「Max Concurrent Tasks」真正成为所有批次共用的上限，并且前台加载进行时不再启动新的后台构建。设置里一直写的是共用上限，代码却是每个批次各算各的。
2. 前台打开一个后台正在建的镜像时，直接加入那次构建，不再重建。这是 [0002](0002-background-indexing.md)「竞态/边界条件」第 1 条早就要求、但一直没落地的按路径串行化。

## 方案

**依据**

复现测试是 `ForegroundLoadDuringBackgroundIndexingTests`：同一进程里扮演 App 和本地运行时 XPC service，
走真实的 XPC 传输，后台批次用 App 同一个 `RuntimeBackgroundIndexingManager`，前台用侧栏同一个
`objectsWithProgress(in:)`，从 user-initiated 任务发起。

| 后台同时在建 | 前台打开 AppKit |
|---|---|
| 无（Debug 基线） | 24.9–25.7 秒 |
| 只有 AppKit 自己 | 25.3 秒 |
| 另外 4 个 | 29.6 秒 |
| 5 个都在 | 40.6–41.8 秒（4 次） |
| 无（Release 基线） | 8.9 秒 |
| 5 个都在（Release） | 11.3 秒（2 次，1.26 倍） |

Release 同样变慢，但轻得多：它做了泛型特化，Swift 运行时元数据的查找少得多。Debug 下的 41 秒大半是 Debug
构建放大的结果；发布版用户遇到的是同一个现象，只是轻一些。

整段连续采样，并和基线逐个函数对比：
- 前台几乎一直在计算。多出的约 15 秒里，Swift 运行时（泛型元数据缓存查找、类型转换、协议一致性）增加了 6.3 秒；其中 `StableAddressConcurrentReadableHashMap` 慢到 6.7 倍，`LockingConcurrentMap` 3 倍。程序代码增加 5.0 秒（1.33 倍），拷贝与分配增加 2 秒。
- 等 MachOSwiftSection 共享缓存（Thread Performance Checker 报出的 `SharedCacheBuildPromise.wait`，路径是 `ObjCImplementationClassIndex` → `SymbolIndexStore`）只有 0.45 秒。
- 内存压力全程正常。
- 只有 AppKit 自己的后台批次时，前台保持基线速度，后台和它同时结束。可见是后台在等前台建好的缓存，不是前台被后台拖住。

**改动一：后台构建共用一个上限，前台加载时不开新的**

- `RuntimeBackgroundIndexingManager` 把「每个批次一个 `AsyncSemaphore`」换成管理器级的一个槽位池：同一时刻正在建的镜像总数不超过上限，不管有几个批次。
  - 上限取最近一次 `startBatch` 传进来的 `maxConcurrency`（协调器每次都传当前设置）。
  - 调小时不打断正在跑的构建，只是不再放行新的。
  - 批次内部的 FIFO 顺序和 `prioritize` 的插队语义不变。
- `RuntimeEngine` 记录在途的前台镜像加载，包括 `loadImage(at:)`、`loadImage(at:onProgress:)`、`objects(in:)`、`objectsWithProgress(in:)`。
  - 在途数从 0 变 1、从 1 变 0 时通知管理器。
  - 大于 0 期间，管理器不放行新的后台构建；已经在跑的构建不暂停（原因见决策日志）。
- 设置页「Max Concurrent Tasks」的说明改成如实描述取舍：数值越大，后台越快建完，但这期间打开的镜像会更慢。`Settings.Indexing.maxConcurrency` 的注释同步修正。

**改动二：同一镜像的并发请求共用一次构建**

- `RuntimeObjCSectionFactory` 和 `RuntimeSwiftSectionFactory` 各加一张「在建」表，形如 `[String: Task<Section, Error>]`，用 dyld 规范路径做键。
  - 同一镜像的后到请求等先到那次构建的结果，不再重建。
  - 覆盖工厂里所有会为一个镜像新建 section 的入口，包括 ObjC 按名字懒建的那一条。
- 进度：每次构建内部总是带一个转发器。
  - 发起者和后加入者都把自己的进度通道挂上去，后加入者从加入那一刻起收到后续进度，进度条不会停住。
  - 返回前先把转发排空，保持现有「进度不会晚于响应到达」的保证。
- 优先级：前台等的是一个 Swift `Task`。
  - 被等的任务正在运行时，Swift 运行时会把等待方的优先级覆盖到执行它的线程上（Swift 6.3.2 `stdlib/public/Concurrency/TaskStatus.cpp` 运行中任务的提权分支），不管这条线程属于哪个 executor。
  - 所以即使构建是由 utility 的后台请求发起的，前台加入后也按 user-initiated 跑。

**不在本提案内**

- 让 MachOSwiftSection 的 `SharedCacheBuildPromise` 在等待时把优先级借给构建方。它只值 0.45 秒，另在那个仓库做，能消掉 Thread Performance Checker 的警告。
- `SymbolIndexStore.prepareWithProgress` 把符号索引写死在 `DispatchQueue.global(qos: .userInitiated)` 上，使后台索引的这一步也按 user-initiated 跑。这同样属于 MachOSwiftSection。

**假设（未询问，直接采用）**

- 前台加载只算上面四个入口。取接口、层级、关系这些请求通常只命中已建好的 section，不计入。
- 远端引擎（Bonjour、模拟器）走同一套管理器逻辑。「加入在建构建」只在运行这份代码的 host 上生效，旧版本 host 行为不变。
- 取消语义不变：批次取消不打断已经在跑的构建，今天就是这样。

**验证**

- 常驻测试：
  - 工厂层：同一镜像的两个并发请求拿到同一个 section 实例，后加入者收到进度。
  - 管理器层（沿用 `MockBackgroundIndexingEngine`）：跨批次同时在跑的构建数不超过上限；前台在途时不放行新构建，前台结束后恢复。
- 复现场景 `ForegroundLoadDuringBackgroundIndexingTests` 永久保留，但只在设置了性能测试开关时运行：它要约一分钟，还依赖另一个进程量出的基线，不适合进常规测试。修复后用它确认你的场景回到基线附近，数字补进本提案。

**实现与结果**

- 新增 `RuntimeSectionBuild`（`RuntimeViewerCore/Core/RuntimeSectionBuild.swift`）：表示一次可以被多个请求共同等待的构建。
  - 构建在自己的任务里跑。
  - 进度先写进一条中转流，再分发给所有挂上来的进度通道，返回前把中转流排空。
- 两个工厂新增 `sectionBuilds` 表。按路径建、ObjC 按名字懒建两条入口都经过它。
  - section 在构建内部完成登记，然后才放行等待者。登记包括：缓存、挂进聚合索引；Swift 侧还有 `setupForFactory` 和登记候选 ID。
  - 顺带消除了一个老问题：同一镜像并发建两次时，聚合索引会被挂上两份子索引。
- 管理器：每个批次的 `AsyncSemaphore` 换成管理器级的槽位。
  - 批次先拿槽位再挑路径，等待期间发生的 `prioritize` 仍然生效。
  - `foregroundLoadDidBegin` / `foregroundLoadDidEnd` 之间不放行新槽位。
  - 引擎的四个前台入口统一经过 `performingForegroundLoad` 通知管理器。
- 设置的注释、设置页说明、协调器里关于 `maxConcurrency` 的注释都已同步。
- 测试：
  - 修复前失败、修复后通过：`concurrencyLimitIsSharedAcrossBatches`，以及 `SectionFactoryConcurrentRequestTests` 里 ObjC、Swift 两个「拿到同一个 section」的用例。
  - 新增：`noBackgroundLoadStartsWhileAForegroundLoadIsInFlight`，以及两个「后加入的请求仍收到进度」的用例。
  - 复现场景要设置 `RUNTIME_VIEWER_PERFORMANCE_TESTS` 才运行，断言阈值 1.5 倍。
- 你的场景（Debug，5 条始终索引，并发 28）：修复后前台打开 AppKit 用了 30.1 秒和 35.1 秒（基线 25.7 秒，即 1.17 倍、1.37 倍），修复前是 40.6–41.8 秒。剩下的变慢来自另外 4 个仍在同时构建的镜像，这是「只按设置值」的代价。Release 下修复后是 10.4 秒和 9.9 秒（基线 8.6 秒，1.21 倍、1.15 倍），修复前是 11.3 秒（1.26 倍）。

## 决策日志

| 日期 | 决定 | 理由 |
|---|---|---|
| 2026-09-26 | Created as Draft | 用户反馈：启动后直接打开 AppKit（在后台索引里），一直卡在进度条，直到后台索引全部完成才进列表。诊断后用户选定「全局上限 + 前台让路」与「同一镜像共用一次构建」两项，并要求补测 Release |
| 2026-09-26 | 不暂停已经在跑的后台构建 | 构建是 MachOSwiftSection / MachOObjCSection 内部的长段同步计算，只能在库里加暂停点。暂停点若落在某个共享缓存项的构建中间，前台又正好要用这一项，两边就会互等死锁 |
| 2026-09-26 | 不调整 QoS | 28 核只用了 6–10 个，核不紧张；瓶颈是进程内共享结构的争用，QoS 管不到 |
| 2026-09-26 | 同时在建的镜像数只按设置值，不另加固定上限，默认值 4 不变 | 用户在三个选项里选定。另两个选项是「新装默认值改成 2」和「无论设置多大都固定最多 2 个」。按删减实验估计，你的配置（28，5 条始终索引）在 Debug 下从 41 秒降到约 30 秒，改善主要来自不再重复建同一个镜像；想更快就把设置调低 |
| 2026-09-26 | 状态改为 In Progress，在 `feature/background-indexing-yields-to-foreground` 上实现 | 用户确认两项都做；按 worktree 规则从 `next` 切出 |
| 2026-09-26 | 复现场景的断言阈值定为 1.5 倍，而不是 1.25 倍 | 修复后两次实测是 1.17 倍和 1.37 倍，1.25 倍会被环境波动打穿；修复前是 1.63–1.67 倍。1.5 倍能把两者分开，还留有余量。剩下的变慢是另外 4 个构建带来的，属于上一条选择的代价，不是缺陷 |
| 2026-09-26 | 管理器测试里一个原本就有的崩溃不在本提案内处理，另行定夺 | 完整测试时崩过一次：`runSingleIndex` 读 `unowned engine`，但引擎已经释放。在改动前的 `next` 上把管理器测试重复 100 遍同样会崩；跳过 `prioritizeIsNoOpForUnknownPath` 后，改动前、改动后各重复 100 遍都不崩。这条测试启动批次后直接返回，批次比测试里保活的引擎活得久。c96f229b 引入 `unowned` 时认为「引擎释放会同步释放管理器」，漏了正在运行的批次任务会持有管理器 |
| 2026-09-26 | Implemented：`feature/background-indexing-yields-to-foreground` 合入 `next` | 用户：「合并过来」。一个提交，未推送。验证：<br>· 修复前失败的 3 个测试转绿，新增的 3 个通过；<br>· RuntimeViewerCoreTests 共 315 个（跳过会崩的 `prioritizeIsNoOpForUnknownPath`），只有 Relationships 两份基线不一致，两处都在未改动的 `next` 上复现，与本改动无关、未动：Swift 那份是「ObjC 类与 Swift 类互标」提案记录过的 `__C.Decimal…` → `__C.NSDecimal…`；ObjC 那份是 Foundation 多了 `AttributeScopes._DefaultScopeRegistration`，`NSObject` 子类从 315 个变成 316 个；<br>· RuntimeViewerCommunicationTests 205 个全过；<br>· RuntimeViewerPackages 编译通过，App target 没有单独编。<br>配套文档：不另写实现说明或使用指南，设计理由在代码注释和本提案里；没有新术语 |
