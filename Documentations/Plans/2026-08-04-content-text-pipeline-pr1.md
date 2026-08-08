# 内容区渲染管线拆分（PR1：主题变化不再重拉接口 + 后台构建富文本）

- **Status**: Implemented（本文档与代码同批落地）
- **Date**: 2026-08-04
- **Related**: `Documentations/Plans/2026-05-17-content-text-attributedstring-optimization.md`（原始三阶段计划；本文是其 PR1 的落地记录，PR0 throttle 已先行落地）、`Documentations/Plans/2026-08-04-sidebar-filter-pipeline-perf.md`（同一"流畅度卖点"主线的侧边栏部分）
- **Regression suite**: `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ContentTextPipelineTests.swift`

## 1. 动机（为什么做）

`ContentTextViewModel` 原先是一条单管线：

```
combineLatest($runtimeObject, options, theme, transformer)
    → flatMapLatest { XPC 拉接口 }
    → 主线程构建 NSAttributedString
    → setAttributedString 全文档重排
```

两个结构性浪费：

1. **主题/字号变化重新跨 XPC 拉接口**。接口内容（`SemanticString`）与主题完全无关，但 theme 挂在同一个 `combineLatest` 上，任何字号 ± 都触发整条链，其中 XPC 往返是最贵的一段。
2. **整份富文本在主线程从零构建**。大接口（UIView.h 量级、数万 token）每次几十到几百毫秒的主线程冻结。

另有两个排查中确认的正确性 bug，一并修复：

3. **管线一错即死**：`.catchAndReturn(nil)` 挂在最外层。RxSwift 语义是"上游 error → 发补偿值 → complete 整条链"，所以任何一次接口拉取失败后，该 tab 的内容管线永久停摆——之后切主题、改生成选项都不再刷新，直到导航换绑新 ViewModel。
4. **`Observable.tracking` 内解析 `@Dependency` 的隐患**（测试中暴露）：tracking 桥的 re-arm 跑在裸 `DispatchQueue.main.async` 上，task-local 依赖上下文丢失，闭包内的 `@Dependency(\.settings)` 会按环境默认上下文重新解析。App 进程默认 `.live` 所以线上无症状；但任何非 live 默认上下文（测试进程为 `.test`）下，第一次 re-arm 就会解析出另一个 `Settings` 实例，tracking 从此追踪错对象、链路静默死亡。`ResolvedThemeStream` 与 `ContentTextViewModel` 的 transformer 流都踩在这个模式上。

## 2. 范围（改了哪些部分）

| 文件 | 改动 |
|---|---|
| `RuntimeViewerApplication/Content/ContentTextViewModel.swift` | 管线拆两截：**fetch 半程**（`$runtimeObject` × `$options.distinctUntilChanged()` × `transformer.distinctUntilChanged()` → XPC，theme 不再参与）+ **render 半程**（`combineLatest(interfaceStream, themeObservable)` → 后台调度器构建 → 主线程 bind）。`catchAndReturn(nil)` 移进 `flatMapLatest` 内层。新增可注入的 `InterfaceProvider`（internal，默认走 engine，测试用来计数/模拟失败）与 `nonisolated static renderAttributedString(for:theme:)`。两个 signpost 区间：`content.interfaceFetch` / `content.attributedStringBuild`（subsystem `com.RuntimeViewer.RuntimeViewerApplication`，category `Content.TextPipeline`）。 |
| `RuntimeViewerApplication/Theme/ResolvedThemeStream.swift` | `@Dependency(\.settings)` 解析移出 tracking 闭包，arm 时捕获实例（修 §1.4）。 |
| `RuntimeViewerArchitectures/Observable+Tracking.swift` | 文档新增 `- Important:` 契约：**绝不在 `access` 闭包内解析 `@Dependency`**，解析一次、捕获实例。 |
| `RuntimeViewerApplication/Theme/SemanticString+ThemeProfile.swift` | builder 出口 `attributedString.copy()` 固化 immutable——跨线程交接契约（后台构建、主线程消费），可变工作副本不再逃逸。 |
| `RuntimeViewerCore/Common/RuntimeObjectInterface+GenerationOptions.swift` | `GenerationOptions` 补 `Equatable`（三个成员本就 Equatable），供 `distinctUntilChanged()` 使用。 |
| `RuntimeViewerCore/Common/RuntimeObjectInterface.swift` | 补 public memberwise init（测试构造 stub 需要；原先只有 internal 合成 init）。 |

## 3. 关键设计与取舍

- **theme 移出 fetch 流是本次的全部要点**。fetch 半程只对"真正需要重新生成接口"的输入（对象、生成选项、transformer）敏感；render 半程消费 `share(replay: 1)` 的最新接口 + 最新主题。字号连点（工具栏已有 120ms throttle）只走 render 半程：零 XPC、零主线程构建，主线程只剩 `setAttributedString` 本身。
- **后台构建的线程安全前提已逐项核实**：`ResolvedTheme` 的 color/font 查表是 init 后只读字典（`d6c8a12e` 预解析）；builder 只分配 immutable 的 NSFont/NSColor/NSAttributedString；出口 `.copy()` 保证跨线程传递的是 immutable 实例。原计划的三个 Open Questions（`@Observed` 隔离、`setAttributedString` 内部拷贝、transformer 误触发）全部有了确定答案，不再是风险。
- **`flatMapLatest` 双层取消**：fetch 半程换对象/选项时取消在飞的旧 fetch；render 半程主题连变时丢弃落后的构建结果，只发布最新一份。
- **错误处理位置即语义**：catch 在内层 = "这一次失败"；catch 在外层 = "整条订阅完蛋"。修复后单次失败表现为一次 nil（UI 保持旧文本），管线继续活着——有专门的回归测试钉死。
- **`InterfaceProvider` 注入而非 mock 引擎**：`RuntimeEngine` 是具体类型难以替身；把"拉接口"收窄成一个 `@Sendable` 闭包，默认实现按调用时读 `documentState.runtimeEngine`（引擎可在文档生命周期内被切换，不能 init 时冻结），测试注入计数器/失败器。public API 不变（原 init 变为 convenience）。

**放弃/未做的方案**：PR2（`.semanticType` 自定义 attribute + 增量重涂）与 PR3（in-place `addAttributes` 避免全文档重排）维持原计划的度量门控——PR1 之后主题变化的剩余成本只有"后台全量重建 + 主线程 `setAttributedString`"，只有大接口上字号 tap 到首屏可见仍 >100ms 才值得加复杂度。`renderAttributedString` 的字节等价测试已就位，将来 PR2 的重涂输出必须与它逐字节一致。

## 4. 结果与验证

- 回归测试（`ContentTextPipeline` suite，3 条）：
  1. **字号变化零重拉**：fetch 计数在初次渲染后为 1，字号 +3 触发重渲染（新字号已生效）后计数仍为 1。
  2. **失败不杀管线**：首次 fetch 抛错后改生成选项，第二次 fetch 成功、`attributedString` 恢复输出，计数 = 2。
  3. **渲染等价 + immutable 出口**：`renderAttributedString` 与直接调 builder 逐字节相等，且返回值不是 `NSMutableAttributedString`。
- 全部包测试 64/64 通过（9 个 suite，含侧边栏基线套件）。
- Instruments 度量入口：Logging template 过滤 `Content.TextPipeline`，两个区间分别对应 XPC 拉取与富文本构建；PR2/PR3 是否启动以此为准。

## 5. 影响面

- 行为语义不变：初次渲染、对象切换、选项/transformer 变化的路径与之前一致（loading 指示仍只包 fetch 段）；主题/字号变化从"重拉 + 主线程重建"降为"后台重建"。
- 肉眼可见变化：大文档上连按字号 ± 不再卡顿；接口拉取失败后主题/选项调整仍然生效（原来会永久冻结）。
- UIKit / Catalyst：`themeObservable` / `transformerObservable` 在该分支是 `.just(...)` 常量，管线拆分对其零行为变化；`ConcurrentDispatchQueueScheduler` 与 builder 平台中立。
- `RuntimeObjectInterface` 新增 public init、`GenerationOptions` 新增 `Equatable` 均为纯增量 API，无破坏。

## 6. 迁移 / 跟进注意事项

- **`Observable.tracking` 新契约**：access 闭包内禁止解析 `@Dependency`（文档已写进桥接层）。现存两处调用点均已改为 arm 时捕获；新增调用点请遵循同一模式。
- **PR2 门控条件**：大接口（UIView.h 量级）字号 tap → 首屏可见 >100ms（用 `content.attributedStringBuild` signpost 量），才启动 `.semanticType` 增量重涂；启动时字节等价测试直接复用本套件第 3 条。
- **PR3 门控条件**：PR2 后颜色-only 主题切换若 `setAttributedString` 全文档重排仍可感知，再评估 in-place `addAttributes`。
- 测试套件会真实读写本机 `Settings.shared`（字号、生成选项），每条测试均在 `defer` 中恢复原值；suite 是 `.serialized`，不与其它 settings 触碰型测试并行。
