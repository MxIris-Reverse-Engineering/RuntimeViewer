# 0017 - `@Observed` 惰性创建 relay

- **状态**: Implemented
- **创建日期**: 2026-09-02
- **最后更新**: 2026-09-02
- **关联**: [0005](0005-cellvm-appearance-single-observed.md)「替代方案 B」预留的后续项；代码改动在上游 [RxSwiftPlus](https://github.com/Mx-Iris/RxSwiftPlus)

## 摘要

`@Observed`（RxSwiftPlus）目前一声明就分配 `BehaviorRelay → BehaviorSubject → NSRecursiveLock`：每个属性约 450–500 B、3 次堆分配，读一次值就过一次递归锁。本项目里被成千上万次实例化的只有 sidebar 的两种 cell ViewModel——镜像列表 13,159 个 `SidebarRootCellViewModel`，浏览一个镜像再加数千个 `SidebarRuntimeObjectCellViewModel`，每个一条 `@Observed appearance`。0005 之后稳态仍有约 27k 把 `NSRecursiveLock`，几乎全是它们。而真正订阅 `$appearance` 的只有 cell view，NSOutlineView 只为进入可视区的行造 cell view，所以绝大多数 relay 从生到死没有订阅者。

改法：值先存在一个带 `os_unfair_lock` 的小盒子里，第一次访问 `$property` 才创建 `BehaviorRelay`，之后 relay 是唯一真源。`$property` 的类型、订阅即回放、`bind(to: $x)`、可重入写回全部保持原样，项目里 99 处 `@Observed` 与 108 处 `$x` 不改一行。

## 方案

### RxSwiftPlus 侧

- `Observed<Value>` 的存储从 `BehaviorRelay` 换成内部 `final class ObservedStorage<Value>`，状态是 `enum { inline(Value) / materialized(BehaviorRelay) }`，由堆分配的 `os_unfair_lock` 保护。
- `wrappedValue` 读写只碰盒子；`projectedValue` 首次访问时用当前值建 relay 并缓存；`init(relay:)` 起步即 materialized。
- 锁序：盒子锁内绝不取 relay 的锁——读先拷出 relay 引用、解锁后再取值，写解锁后再 `accept`。这既避免与 `BehaviorSubject` 的订阅回放（持锁回调）形成 ABBA 死锁，也保住 RxSwift 的重入语义：订阅回调里同步写回同一属性不死锁。
- 新增只读 `hasMaterializedRelay: Bool`，给测试证明「某条路径从没碰过 relay」。
- `Sendable` 改为诚实的 `@unchecked Sendable where Value: Sendable`（`BehaviorRelay` 本就不是 Sendable，原写法靠 Swift 5 模式放行）；去掉无库演化时没有意义的 `@frozen`。
- 单测（swift-testing，`Tests/RxSwiftPlusTests/ObservedTests.swift`）：不碰 `$x` 不建 relay；`$x` 只建一次且以最新值播种；订阅后写入可达；`bind(to: $x)` 回写 wrappedValue；`init(relay:)` 共享；订阅回放中同步写回不死锁；并发读写与 `$x` 一致。

### RuntimeViewer 侧

- `SidebarRuntimeObjectCellViewModel` / `SidebarRootCellViewModel` 加 `package var hasMaterializedAppearanceRelay`。
- 新增 `SidebarFilterRelayMaterializationTests`：对数百行 cell 树跑文字过滤（contains / fuzzy / 清空）× 分类筛选（关 / 只看泛型），再做一遍 type-select 式的直读，断言没有任何 cell 建出 relay；绑定一行 cell view 只让那一行建出 relay；镜像列表过滤同样不建。
- `Package.swift` 给 RxSwiftPlus 接上 `USING_LOCAL_DEPENDENCIES` 本地搜索路径（与 RxAppKit 等同型），worktree 侧补 `.worktrees/RxSwiftPlus` 符号链接。
- AGENTS.md「ViewModel Conventions」记一条硬规则：要当前值就读属性本身，只有订阅或绑定才碰 `$property`；批量路径里一句 `$property.value` 就会把每行的 relay 全建出来。
- 交付：RxSwiftPlus 打 `0.2.4`，本项目 pin 升到 `from: "0.2.4"`。

### 验收

同 0005 的负载（五镜像索引 + 全量拖拽浏览一个镜像），用 `heap -sortBySize` 复测：

| 指标 | 0005 落地后 | 预期 |
|---|---|---|
| `NSRecursiveLock`（稳态，13k 镜像行） | 27,341 | 镜像行贡献的约 13k 消失；具体数字待复测回填 |
| `BehaviorSubject<SidebarRootCellViewModel.Appearance>` | 13,189 | 只剩显示过的行 |
| `NSRecursiveLock`（全量浏览后） | 42,218 | 与显示过的行数同阶：拖拽滚过的行每行仍建一套 |

诚实的边界：relay 一旦建出不再拆，所以省的是「从没显示过的行」，不是「当前不在屏幕上的行」。全量滚过的镜像一行都省不了。

### 假设

- 本项目所有 `@Observed` 的写入方都在主线程（`ViewModel` / `DocumentState` / 两个 ExportingState 是 `@MainActor`，8 处 `bind(to: $x)` 全在 `observeOnMainScheduler()` 之后，cell VM 文档约定主线程写），但 RxSwiftPlus 还被 Camera / CodeEditorView / CodeOrganizer 使用，所以 wrapper 保持线程安全，不加 `@MainActor`。
- 两处测试缝（`hasMaterializedRelay`、`hasMaterializedAppearanceRelay`）按「测试需要一个能证明否定的公开信号」加入；用户若不接受可改为仅在 `DEBUG` 下暴露。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-02 | Created as Draft | 用户提问「`Observed` 用得很多，怎么优化」，调研发现 0005 留下的上游项 |
| 2026-09-02 | 采用「只惰性创建、不拆 relay、`$x` 类型不变」的最安全变体，状态直接 In Progress | 用户拍板「先按最安全的改法改」。退订即拆 relay 需要 `$x` 换成自有类型，属 API 改动，108 处用法要逐一确认，留作后续 |
| 2026-09-02 | 本次不换成宏实现 | 宏能生成 `$x`：标准库 `@TaskLocal` 就声明为 `@attached(peer, names: prefixed(`$`))`，所以宏版可以做到 `x` / `$x` / `_x` 表面完全一致、调用点零改动。但对「惰性建 relay」这个目标，wrapper 已经零改动做到，换宏只多出宏插件的编译成本。宏真正多出来的是两项 API 层能力：按对象共享一套注册表（未观察的属性只剩值本身，省掉每属性一个存储对象与两次 malloc）、投影改成只读类型以尊重 `private(set)`（会波及 8 处 `bind(to: $x)`）。两项都是独立的 API 重设计，留作后续 |
| 2026-09-02 | 更正：上一行最初写的理由是「宏无法生成 `$` 前缀声明」，这是错的 | 用户指出 `@TaskLocal` 宏；已在 SDK 的 `_Concurrency.swiftinterface` 核实其 `names: prefixed(`$`)` 声明 |
| 2026-09-02 | Implemented，落地编号 0017 | 上游 RxSwiftPlus `0.2.4` 已发布（commit `45a1301`），本项目 pin 升到 `from: "0.2.4"`，三份 `Package.resolved` 同步；`RuntimeViewerApplicationTests` 37 套件 197 测试在本地与远程解析下各跑一遍全绿。验收表里的 heap 数字待用户用 0005 同款负载复测后回填。配套文档裁定：不需要单独的指南或实现说明，规则已记入 AGENTS.md「ViewModel Conventions」；无新术语进术语表 |
| 2026-09-02 | 不替换 RxSwift 内部的 `NSRecursiveLock` | 锁在 `BehaviorSubject` 里，换掉等于重写 subject；订阅回放持锁且 `MainScheduler` 在主线程同步执行，全靠递归锁才不死锁。惰性化后带锁的 relay 只剩几十个，换锁无收益 |
