# Background Indexing 实现审查 — 最终轮

审查对象:
- 分支 `feature/runtime-background-indexing` 上完整的 29 个 commit(Task 0–Task 24)
- [0002-background-indexing.md](../Evolution/0002-background-indexing.md)
- [2026-04-24-background-indexing-plan.md](../Plans/2026-04-24-background-indexing-plan.md)
- 承接 [2026-04-24](2026-04-24-background-indexing-review.md) / [2026-04-25](2026-04-25-background-indexing-review.md) / [2026-04-26](2026-04-26-background-indexing-review.md) 三轮 plan / evolution 审查(均已闭环)

本轮把 Plan / Evolution 视为已 Accepted,只对实际落地的 implementation 做最后一次代码审查,覆盖跨三层(Core actor / Application coordinator / AppKit UI)的整体行为。

**判定**: SHIP, with conditions —— 没有阻塞 merge 的 Critical issue,但有 6 条 Important 与 10 条 Minor 建议,部分应在 PR 中或紧随 PR 处理。

**2026-04-28 更新 — 修复状态:**

- ✅ **I3 source-switch staleness** — 已修。Coordinator 通过 RxSwift 订阅 `documentState.$runtimeEngine.skip(1)`,变化时 cancel 旧 pumps、cancel 旧 doc batches、清 relays、切引用、重启 pumps、若 isEnabled 重发 main exec batch。详见 [plan post-review fixes](../Plans/2026-04-24-background-indexing-plan.md#post-review-fixes-2026-04-28) 与 [Evolution 0002](../Evolution/0002-background-indexing.md) 假设 #1 / 场景 G / 决策日志 2026-04-28
- ⏳ **I1 (manager dedup)、I2 (loadImageForBackgroundIndexing 不发 imageDidLoadSubject 的 doc/test)、I4 (prioritize doc)、I6 (NSTableCellView 复用)、所有 Minor M1–M10** — 未处理,follow-up
- ⏳ **I5 (path normalization 不对称)** — 仅 iOS Simulator 激活,绑 iOS Simulator 支持工作,本轮不修

**验证结果**:
- `swift test` in `RuntimeViewerCore`:445/445 通过(其中 4 个 `XCTSkipUnless` 在 sandbox 下跳过 Foundation/CoreText 测试,本机 GUI 运行时全部命中)。
- `swift build` in `RuntimeViewerPackages`:0 错误,我们引入 0 警告。
- `xcodebuild` for `RuntimeViewer macOS` workspace:0 错误,0 警告,49.7s。

---

## Strengths(摘要)

1. **三层 seam 切得很干净**。`BackgroundIndexingEngineRepresenting: Sendable` 协议(无 `AnyObject`)给 manager 一个窄的边界,Mock 只 58 行,`InstrumentedEngine`(测试本地)也就几十行。`MachOImage` 这种非 Sendable 类型从未越界。
2. **取消处理在常见路径下正确**。`finalize` 里的 `wasCancelled || Task.isCancelled || state.batch.isCancelled` 三重 OR 是防御性正确;semaphore 用 `waitUnlessCancelled`;driving Task 通过 `Task.checkCancellation()` 把取消传播到正在跑的 `runSingleIndex`。`finalize` 只把 `.pending` / `.running` 翻成 `.cancelled` 而保留 `.completed` / `.failed`,符合 Evolution 0002 决议 #2。
3. **保留失败批次的语义直观**。"完成且含失败 → 留到用户清除;取消 → 立即清掉"是合理的用户视角。Toolbar 的 `hasFailures` 经 `aggregateRelay → MainWindowController.setupBindings → backgroundIndexingItem.itemView.state` 一路冒泡,链路清晰。
4. **Settings observation 重注册放置正确**。`withObservationTracking { … } onChange:` 的 callback 跳回 MainActor 后再读最新快照、再注册;只对 `isEnabled` 切换做动作,depth / maxConcurrency 改动有意 no-op(下一次 `startBatch` 自动用新值)。变化频率被人类 UI 节奏天然限速。
5. **Actor 单元测试覆盖度扎实**。`RuntimeBackgroundIndexingManagerTests` 跑了 BFS dedup、依赖解析失败 → `.failed` item、并发上限(实测的 lock-counting `InstrumentedEngine`)、cancel-mid-batch、cancelAll、prioritize 事件发射。`test_prioritize_emitsTaskPrioritizedEvent` 故意放弃 "load order" 改为 "event emission" 断言,是 CI 稳定性的正确选择。
6. **Engine API 与既有面一致**。三个新 public 方法都走 `request { local } remote: { … }` + `CommandNames`;`imageDidLoadPublisher` 镜像现有 `reloadDataPublisher` / `imageNodesPublisher` 的 Combine 风格。没有发明新机制。
7. **文档密度异常高**。BFS 中的 `// try?` 注释、`// Class is @MainActor` 提示、`DocumentState.runtimeEngine` 的 immutability 警告、`machOImageName(forPath:)` 的 TODO 都到位。未来维护者不会迷路。

---

## Critical — 阻塞 merge

无。

---

## Important — 进 PR 之前修或同步开 follow-up

### I1. Manager 实际未实现 batch dedup,但 coordinator 注释声称"会 dedup"

Evolution 0002 第 626 行写:*"manager 去重:如果某活动批次的 `rootImagePath == root` 且 `reason` 的判别式匹配,返回其已有 `RuntimeIndexingBatchID` 而非新启动一个。"*

Coordinator 在 [`RuntimeBackgroundIndexingCoordinator.swift:240-241`](../../RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift) 的注释说:
```
// Manager dedups batches that share rootImagePath + reason discriminant, so a
// second call here is a no-op rather than a wasted batch.
```

但 `RuntimeBackgroundIndexingManager.startBatch` 没有任何 dedup 逻辑 —— 每次都 alloc 新 ID 并加进 `activeBatches`。这是用户在 PR 描述里点出的"已知 pre-existing 问题 #3"(`documentDidOpen` 的 `.appLaunch` 与同一路径 `imageDidLoad` 之间的双批次),而注释让它看上去已经修了,实际没有。

可选修法:
- **实现 dedup**:在 `RuntimeBackgroundIndexingManager.startBatch` 里扫一遍 `activeBatches.values`,如果存在 `rootImagePath == root` 且 `reason` 判别式相同且 `!isFinished`,直接返回那条 ID。约 10 行。
- **或删掉假注释,把 spec 降级**。更新 Evolution 0002 标 dedup 为延后,把 coordinator 的注释改成"manager 不 dedup,我们目前接受冗余工作"。

建议第一种 —— 改动小、spec 已经写了 dedup 是目标、用户也明确点出双批次。文件 `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift:51-73`。

### I2. `loadImageForBackgroundIndexing` 不发 `imageDidLoadSubject`,但 doc / test 都没说

`loadImage(at:)`(RuntimeEngine.swift:530-542)成功后会发 `imageDidLoadSubject.send(path)` 并 `sendRemoteImageDidLoadIfNeeded(path:)`。

`loadImageForBackgroundIndexing(at:)`(`RuntimeEngine+BackgroundIndexing.swift:29-40`)有意不发 —— 否则每个被后台索引的 image 又会触发 `handleImageLoaded`,递归 spawn 新 batch。这是正确判断。

但是:
- doc comment 只提了不调 `reloadData`,没提不发 `imageDidLoadSubject` —— 后者对正确性同样关键。加一行说明。
- `RuntimeEngineIndexStateTests.swift:61-70`(`test_loadImageForBackgroundIndexing_doesNotTriggerReloadData`)名字是 reloadData 跳过,但断言只检查"image 变成 indexed",既没断言"无 reload 通知"也没断言"无 imageDidLoad 通知"。补一个 `Combine.sink` 断言"调用期间 publisher 不发火"。

### I3. Source-switch 时 coordinator 抓住旧 engine ✅ FIXED 2026-04-28

`MainCoordinator.swift:34` 在 `.main(let runtimeEngine)` 时 reassign `documentState.runtimeEngine`。`backgroundIndexingCoordinator` 是 `lazy var`,首次访问后捕获了那时候的 engine + manager。后果:

- Source switch 后 toolbar 状态停止反映新 engine 的 batches(`MainWindowController.swift:160-171` 在每次 `setupBindings` 重绑,但 `aggregateStateObservable` 来自旧 coordinator 的 relay,relay 又被旧 manager 喂)。
- `documentDidOpen` / `documentWillClose`(`Document.swift:21, 25`)调到旧 coordinator 的旧 manager;新 engine 的 batch 永远启动不了。
- Sidebar `prioritize` 调旧 manager,无效果。

`DocumentState.runtimeEngine` 的 doc comment 警告了不要 reassign,**但 MainCoordinator 现在的代码就在违反这个 contract**。Source switch 是真实用户路径,toolbar 静默与现实脱钩是糟糕体验。

可选修法:
- 在 `MainCoordinator.prepareTransition` `.main(...)` 处,reassign 之后调 `documentState.recreateBackgroundIndexingCoordinator()`,新 coordinator 重新订阅事件 + 重新装 manager。约 15 行。
- 或让 coordinator 不持有 `engine`,每次现取 `documentState.runtimeEngine`(但这样事件泵也得重建,反而更复杂)。

建议第一种作为紧随 PR 的修复,而不是无限期 follow-up。文件 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift:34` 与 `RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift:37-38`。

**修复 2026-04-28**:采用方案 (b) 的轻量变体 —— coordinator 不重建,通过 RxSwift `documentState.$runtimeEngine.skip(1)` 订阅 swap。`engine` 改 `var`,`handleEngineSwap(to:)` 取消旧 pumps、cancel 旧 manager 上的 doc batches(fire-and-forget)、清 `documentBatchIDs` / `batchesRelay` / `aggregateRelay`、切引用、重启 pumps、若 isEnabled 重发 main exec batch。`DocumentState.runtimeEngine` 的 doc comment 同步改为 reassignable。`MainCoordinator.prepareTransition` `.main(...)` 路径无变,沿用现有 `documentState.runtimeEngine = runtimeEngine` 触发 BehaviorRelay。

### I4. `prioritize(imagePath:)` 对已 dispatched 的路径无效

`prioritize` 把路径塞进 `priorityBoostPaths`、置 `hasPriorityBoost = true`、发 `.taskPrioritized`。但 `runBatch`(line 134)在开始时把 pending 列表 snapshot 进局部 `var pending`,`popNextPrioritizedPath` 之后只在这个本地数组里找 boosted 项。

只有在 `runBatch` while loop 还没把 P 弹出时,boost 才能改变 dispatch 顺序;一旦 P 已经 `.running` 或被弹出待 dispatch,boost 等于 no-op。

测试 `test_prioritize_emitsTaskPrioritizedEvent` 只断言事件发射,不断言加载顺序变化。所以 contract 实际是"best-effort priority boost,可能对已离开 pending 的项无效"。这没问题,但**要在 public 方法的 doc comment 与 spec 里写明**。当前 `prioritize` 没有任何 doc comment。文件 `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift:38-49`。

### I5. `isImageIndexed` 与 `loadImageForBackgroundIndexing` 之间路径规范化不对称

`isImageIndexed`(`RuntimeEngine+BackgroundIndexing.swift:6-15`)在查 factory 缓存前调 `DyldUtilities.patchImagePathForDyld(path)`。`loadImageForBackgroundIndexing`(line 29-40)不调 —— 用 raw path。所以在非空 `DYLD_ROOT_PATH`(simulator runner)下,BFS 会:`isImageIndexed("/Foo")` → false(用 unpatched key 查 patched key 的 cache);然后调 `loadImageForBackgroundIndexing("/Foo")`,把 unpatched key 写入 cache;**下次 `isImageIndexed` 还是 false**,造成每轮 BFS 都重新加载。

这是用户在 PR 描述里的"已知 pre-existing 问题 #2"`loadImage` 不规范化的另一个版本。本机 macOS 上 `patchImagePathForDyld` 是 no-op(只在 simulator 下生效),所以**只有上 iOS Simulator 支持时才会暴露**。

修法二选一:
- `loadImageForBackgroundIndexing` 也 patch path(项目级修复:同时让 `loadImage(at:)` 也 patch);
- 把 `isImageIndexed` 的 patch 移除,接受现有 factory 用的是 unpatched key。

合同必须二选一。当前的"isImageIndexed patch / loadImage* 不 patch"是错配。文件 `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift:6-15, 29-40`。

### I6. UI 在每次 `outlineView(viewFor:)` 都重建 NSTableCellView

`BackgroundIndexingPopoverViewController.swift:282-322` 每次取 cell 都 alloc 一个新的 `NSTableCellView` + `Label` + 一组新的 SnapKit 约束。Popover 刷新时调 `outlineView.reloadData()` 然后 `expandItem(nil, expandChildren: true)` —— 一个深 5、~30 个 dep 的 batch 在 actor 每发一次事件就要分配 ~30 个 view。在并发 4 的批次里 5+ Hz 都可能。

AppKit 标准做法是 `outlineView.makeView(withIdentifier:owner:)` + identifier-based recycling,配置一次,每行 populate。`.taskStarted` / `.taskFinished` 流在屏幕上打开时这是可量到的性能回归,尤其 spinner 还在转。

不是正确性 bug,popover 可关闭、用户也不大会一直打开它。但本地 fix ~20 行,且项目其他 outline view(sidebar / MCP status)都是 makeView-with-identifier 风格,这一处不一致。文件 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift:282-322`。

---

## Minor

### M1. Manager actor 在 `runBatch` 拿到 semaphore 后立即取消时的可重入

`runBatch`(line 146-162):
```swift
do {
    try await semaphore.waitUnlessCancelled()
} catch { wasCancelled = true; break }
if Task.isCancelled { wasCancelled = true; break }   // ← 拿到 slot 但没 signal() 就 break
```

如果 `waitUnlessCancelled` 成功(slot 拿到),但 `Task.isCancelled` 在 addTask 之前变 true,我们 break 了又没 signal。因为 semaphore 是函数局部变量,函数返回时随 stack 销毁,实际无害。但如果有人把 semaphore 提到实例级,这就是埋的雷。要么在 `if Task.isCancelled` 之前 `defer { semaphore.signal() }`,要么加注释说明 leak 是因为函数局部所以可接受。

### M2. `events` AsyncStream 启动期可能丢事件(理论上)

`startEventPump` 里 `await self.engine.backgroundIndexingManager.events` 在 Task 调度后才订阅。在 `init` 返回到这个 Task 真正跑起来之间,manager 理论上可能 yield 事件 —— 实际上 engine 此刻 `.initializing`,不会有事件。AsyncStream 默认 `.unbounded`,所以也不会丢;但如果 buffering policy 改了就会。把 manager init 里的 buffering policy 显式声明(`AsyncStream<RuntimeIndexingEvent>.makeStream(bufferingPolicy: .unbounded)`)能锁住意图。

### M3. `BackgroundIndexingPopoverViewController.outlineView(child:ofItem:)` 每次都重建 batch 列表

Line 260-262 用 `compactMap` 过滤 `renderedNodes` 取 batches,而 NSOutlineView 每次刷新会调这个方法 O(visible-rows) 次。`nodes` 更新时 cache 一份 batch-only slice 即可。简单修复。

### M4. `engine.reloadData(isReloadImageNodes: false)` 每个 batch 终态都触发一次,会 reload 整个 imageList

Coordinator `apply` 里 `.batchFinished` 与 `.batchCancelled` 都派发:
```swift
Task { [engine] in
    await engine.reloadData(isReloadImageNodes: false)
}
```

每个 batch 完成时调一次(不是每个 item),这点是好的;但 `reloadData(false)` 仍然会 reload 整个 imageList(`DyldUtilities.imageNames()` + RPC 推)。多个 doc 各跑 batch 时可能抖动。考虑加 100ms debounce,窗口期内不再有 batch 完成才发火。不是 bug,只是 polish。

### M5. `Document.close()` 不 await `documentWillClose` 的取消

`Document.close()`(`Document.swift:24-27`)同步调 `documentWillClose()`,后者 spawn 一个 Task 取消 batches 再返回,然后 `super.close()` 继续。取消异步在飞,如果 engine + manager 在 Task 落地前就 deinit,`cancelBatch` 跑在已 `finish()` 的 AsyncStream 上 —— 因为有 `guard let state = activeBatches[id] else { return }` 兜底,无害,但语义脆弱。要么在 close() 里 await 取消,要么显式注释说"fire-and-forget"。

### M6. `subscribeToIsEnabled` 在 popover ViewModel 与 coordinator 重复

`BackgroundIndexingPopoverViewModel.swift:109-124` 与 `RuntimeBackgroundIndexingCoordinator.swift:260-275` 都给 `Settings.backgroundIndexing.isEnabled` 写了 `withObservationTracking` re-registration。两处不严格冗余(popover 只关心 isEnabled;coordinator 关心 isEnabled 切换以启动/取消批次),但模板代码在两层重复。可以抽出一个 `Settings.observe(\.backgroundIndexing.isEnabled)` helper。不阻塞,但这种 SwiftUI/Rx-Settings 桥接只会越来越多。

### M7. `BackgroundIndexingToolbarState.disabled` 是死代码

state 枚举 4 个 case(`idle` / `disabled` / `indexing` / `hasFailures`),但 `MainWindowController.swift:160-171` 只产 `idle` / `indexing` / `hasFailures` —— `disabled` 永远不发。要么把 toolbar 也接 `Settings.backgroundIndexing.isEnabled`(关闭时发 `.disabled`),要么删掉这个 case。

### M8. BFS 的 `try?` 吞错有代价

Line 90 `(try? await engine.isImageIndexed(path: path)) == true` 与 line 111 `(try? await engine.dependencies(for: path)) ?? []` 把远端错误吞掉。注释说明了 trade-off,但在 XPC 短暂掉线时,BFS 会产出半成品的图(大多数 dep 没采到),后续 batch 全靠 `loadImageForBackgroundIndexing` 抛错才暴露,用户看到 N 个并发失败但找不到共因。考虑:如果 root 的 `engine.isImageIndexed` 抛错,直接发一条 `.batchCancelled`(reason "engine disconnected")替代半成品 batch。文件 `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift:75-127`。

### M9. 测试缺口 —— coordinator 层集成测试没写

16 个 actor 测试都在 `RuntimeBackgroundIndexingManager` 用 mock engine。`RuntimeBackgroundIndexingCoordinator` 的事件泵本身没测 —— `apply(event:)` 是个纯 batch state machine,可以用 mock manager 测:
- `.batchFinished` 含全部 `.failed` items 时,batch 应保留在 `batchesRelay`,aggregate 更新。
- `.batchCancelled` 移除 batch。
- `clearFailedBatches` 移除全失败的批次,保留干净的。

这些是用户可见规则,目前无回归保护。`RuntimeViewerApplication` 已有(弱)测试 target,至少补一条"settings 关闭 → cancelAll 触发"的 happy-path 测试。

### M10. Popover 三种空/列表态没显式 z-stack 顺序

`emptyDisabledStack`、`emptyIdleView`、`scrollView` 都是中央/全填的(line 117-130),靠 `isEnabled` / `hasAnyBatch` 组合控制 `isHidden`(line 215-225)。组合正确(每次只一个可见),但未来重构破了组合就会 z-fight 而无明显错指示。要么改成 `NSTabView`-style switcher,要么 debug 断言"三者中至少两个 hidden"。

---

## 风险评估 —— 明天 merge 的话最坏会怎样

最高风险:**I3 source-switch staleness**。开了 feature 的用户在 local / remote / Bonjour 之间切换,会安静地丢失后台索引(toolbar 项显示 idle,但新 engine 的 batches 启动不了)。可能数小时都注意不到,而且更可能被报成"toolbar 项坏了"而不是"已知限制"。

次高:**I1 没有真正的 dedup**,与 `documentDidOpen` + `imageDidLoad` 的交互意味着 main executable 在启动时被索引两次,每个重复 batch 浪费 ~200ms 的 dyld + ObjC/Swift 解析。macOS 15+ 现代硬件下不可见;CI/老硬件会被报"索引慢"。

第三:**I5 路径规范化**潜伏(只在 simulator 下激活),目前无用户影响,但随着 iOS Simulator 支持上线立即活化。

三者都不会数据损坏、卡死 app、或影响非 feature 用户。Feature 是 opt-in(`isEnabled = false` 默认),不开就零风险面。

---

## Verdict

**SHIP, with conditions:**

- I1(manager dedup) —— 进 PR 前实现 OR 写一篇 KnownIssues。约 10 行,spec 已经要求。
- I3(source-switch staleness) —— 在本分支修 OR 立 P1 follow-up issue 并在 PR body 里链上。用户已经知道这事;倾向在分支上修,但 P1 issue 可接受。
- I2、I4 —— doc/test 改动,进 PR 前做。
- I5 —— P2 follow-up,与 iOS Simulator 支持工作绑定。
- I6 —— P2 polish issue。
- M1–M10 —— 单独开"Background Indexing polish"汇总 issue,后续 PR 处理。

架构站得住(Sendable seam 保得住,actor 可重入被 manager 的小 public 表面框住,AsyncStream / Combine / Rx 桥的取舍都有理由),actor 的测试覆盖度真好,doc 注释密度可以做范本。三轮审查抹掉了所有显眼陷阱;剩下的问题真实但都不大。

---

## 附:相关文件路径

- `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift` — I1, I4, M1, M8
- `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift` — I2, I5
- `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeEngineIndexStateTests.swift` — I2
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift` — I3
- `RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift` — I3
- `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift` — I1(误导注释), M5, M9
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift` — I6, M3, M10
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift` — M7
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift` — M5
