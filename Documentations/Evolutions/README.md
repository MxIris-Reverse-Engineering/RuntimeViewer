# Evolution 提案索引

- **项目类型**: App（macOS，AppKit）

面向终端用户的应用，提案的「影响」一节关注用户可见变化、可发现性、数据与配置兼容、
平台与最低版本、发布流程，**不涉及 ABI**。

提案格式与流程见全局 `CLAUDE.md` 的「Evolution 提案制」一节，用 `/evolution <描述>` 创建。

## 提案

| # | 标题 | 状态 | 摘要 |
|---|------|------|------|
| [0000](0000-bonjour-reliability.md) | Bonjour Connection Reliability Improvements | 未标注 | Bonjour 发现与连接的可靠性修复：设备间歇性失败、连接丢失后不重试、iOS 先启动时 macOS 发现不到。 |
| [0001](0001-ida-compatible-objc-export.md) | IDA Compatible ObjC Export Mode | 未标注 | 新增「IDA 兼容」ObjC 头文件导出模式，产出三份互补文件，最大化导入 IDA Pro 9.3+ 后的信息保真度。 |
| [0002](0002-background-indexing.md) | 后台索引 | Accepted | 针对目标进程已加载镜像的依赖闭包，主动解析 ObjC 与 Swift 元数据。由每个 `RuntimeEngine` 持有的 actor `RuntimeBackgroundIndexingManager` 驱动，Settings 可配置，Toolbar 弹出框展示进度。 |
| [0003](0003-generic-type-specialization.md) | 泛型类型特化 | In Progress | 用户在 Inspector 的 Specialization tab 为泛型类型选定具体类型组合，特化结果作为 sidebar 子节点呈现，泛型参数被替换且 metadata 字段填上真实数值。 |
| [0004](0004-differentiable-box-lazy-cellvm.md) | DifferentiableBox 与 Lazy Cell ViewModel 渲染范式 | Draft | 在 `RuntimeViewerArchitectures` 引入 `DifferentiableBox<Model>`，把任意 `Hashable` 领域模型适配为 DifferenceKit 的 `Differentiable`，使表格与大纲视图的 Rx 数据源走「轻量身份元素 + cell 级惰性 ViewModel」。 |
| [0006](0006-mcp-transport-bind-failure-teardown.md) | MCP Transport 绑定失败的资源回收与状态如实化 | Implemented | 绑定失败改为显式 `start()` 判定：失败即回收 transport（线程 56→0）、`serverState` 如实 `.stopped`、端口文件带所有权守卫不误删他人文件。残余 5.57 MiB 为上游 SwiftMCP adapter↔engine 引用环，与线程数硬编码一并列为上游跟进项。 |
| [0007](0007-objc-relationship-index-returns-to-application.md) | ObjC 关系索引归还应用侧 | 部分被 0008 取代 | MachOObjCSection 0003 的下游适配：渲染与解析层搬进库（**保留**），关系表改由应用从 `ObjCIndexingEvent` 事件流重建（**已被 0008 取代**）。 |
| [0008](0008-symmetric-objc-and-swift-index-layers.md) | ObjC 与 Swift 索引层的对称化 | Implemented | `RuntimeObjCInterfaceIndexer` 回到与 `RuntimeSwiftInterfaceIndexer` 同构的形态：包装库侧 upstream、eager 反向表、`addSubIndexer` / `removeSubIndexer` 聚合、由 factory 持有聚合器，`RuntimeRelationshipsResolver` 从遍历所有 image 退回成查两次聚合器。取代 0007 的关系索引设计。 |
| [0009](0009-content-editor-engine-selection.md) | 内容视图编辑器选型：继续 NSTextView 还是改用 Xcode SourceEditor | Accepted | 采纳方案 B：运行时 `dlopen` Xcode 私有 `SourceEditor` 框架，编辑器代码隔离在可选加载的 bridge bundle 内，`ContentSourceEditorViewController` 与现有 `NSTextView` 实现绑定同一 ViewModel 以便随时降级。当前为 opt-in 开关，语法高亮暂为词法级、主题转换未做。 |
| [0011](0011-uifoundation-settings-adoption.md) | RuntimeViewer 接入 UIFoundation Settings | Implemented | 保留 RuntimeViewer 业务设置模型与页面，采用 UIFoundation 的持久化 store、属性包装器、设置窗口和导航，并删除重复壳层。原以 `0007` 起草，与本分支的 `0007` 撞号，合流时改为 `0011`。 |

> 0000 与 0001 采用早期格式，正文没有状态字段，此处如实标为「未标注」。按「旧文档原地不动」的约定不回填。

> **编号占用提醒**：`0007` 曾在两条 feature 分支上各被用过一次，2026-08-16 合流时已解决——
> `feature/objc-rendering-and-indexing` 的 `0007-objc-relationship-index-returns-to-application.md`
> 保留 `0007`，`feature/uifoundation-settings-adoption` 的那篇改号为 `0011`。
> 尚未合入本分支的占用：`0005` 在 `feature/node-store-adoption`（`0005-cellvm-appearance-single-observed.md`），
> `0010` 在 `feature/source-editor-integration`。**新提案从 `0012` 起编号**，
> 不要只看本分支已有的文件挑下一个空号。

## 与 `Plans/` 的关系

`Plans/` 下的文档是提案制确立**之前**的产物，同一件事往往拆成 `-design.md` 与 `-plan.md` 两份。
今后新的改动一律只写一份提案，不再拆分。已有的 `Plans/` 文档保持原样，不迁移、不改名。

其中与提案直接对应的有：

- 0000 ↔ [`Plans/2026-03-03-bonjour-reliability.md`](../Plans/2026-03-03-bonjour-reliability.md)
- 0002 ↔ [`Plans/2026-04-24-background-indexing-plan.md`](../Plans/2026-04-24-background-indexing-plan.md)、
  [`Plans/2026-04-29-background-indexing-history-plan.md`](../Plans/2026-04-29-background-indexing-history-plan.md)、
  以及 [`Reviews/`](../Reviews/) 下的五轮审查记录
- 0003 ↔ [`Plans/2026-05-11-nested-generic-specialization-design.md`](../Plans/2026-05-11-nested-generic-specialization-design.md)、
  [`Plans/2026-05-11-nested-generic-specialization-plan.md`](../Plans/2026-05-11-nested-generic-specialization-plan.md)、
  [`Plans/specialization-typepicker-perf-r2.md`](../Plans/specialization-typepicker-perf-r2.md)
