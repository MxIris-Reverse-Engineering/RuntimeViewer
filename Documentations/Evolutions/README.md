# Evolution 提案索引

- **项目类型**: App（macOS，AppKit）

面向终端用户的应用，提案的「影响」一节关注用户可见变化、可发现性、数据与配置兼容、
平台与最低版本、发布流程，**不涉及 ABI**。

提案格式与流程见全局 `CLAUDE.md` 的「Evolution 提案制」一节，用 `/evolution <描述>` 创建。

愿景在提案**之上**：一个愿景统领多个提案，提案头部用「所属愿景」回指。见 [`../Visions/`](../Visions/)。

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
| [0010](0010-interface-snapshot-export.md) | 把接口导出成图片 | Draft | 把当前接口渲染成带主题配色的 PNG。需拍板渲染路径：自己排版生成侧已有的 `NSAttributedString`（不依赖 Xcode），还是借 `SourceEditorView` 的截图 API（所见即所得，但底层是已知不可靠的 `cacheDisplay`）。 |
| [0011](0011-uifoundation-settings-adoption.md) | RuntimeViewer 接入 UIFoundation Settings | Implemented | 保留 RuntimeViewer 业务设置模型与页面，采用 UIFoundation 的持久化 store、属性包装器、设置窗口和导航，并删除重复壳层。原以 `0007` 起草，与本分支的 `0007` 撞号，合流时改为 `0011`。 |
| [0013](0013-replace-uxkit-with-appkitplus.md) | 用 AppKitPlus 取代 UXKit | In Progress | 导航容器从 Apple 私有的 `UXKit.framework` 换成 AppKitPlus 的 `NSNavigationController`（port 自 OpenUXKit，接口同名同义），三个 `UX` 前缀基类改名为 `Base*` 并直接继承 `NSViewController` / `NSNavigationController`，删除 `OpenUXKit`、`UXKitCoordinator` 依赖与 `USING_SYSTEM_UXKIT` 开关。取代 `feature/uifoundation-navigation` 上的 0012。 |
| [0014](0014-inject-ios-simulator-process.md) | 支持注入 iOS Simulator 进程 | In Progress | 注入器把自身地址空间的符号地址喂给目标进程，打崩了三个 SpringBoard。先加平台守卫止血，再把符号解析改为针对目标进程，让 dlopen 路径支持 iOS Simulator 目标。原以 `0013` 起草，与本分支的 `0013` 撞号，合流时改为 `0014`。 |
| [0015](0015-build-embedded-products-in-app-phase.md) | 让主 App 的构建阶段自己产出嵌入的 iOS-family 产物 | Withdrawn | 曾给主 App 加构建阶段，用 `env -i` + 独立 DerivedData 的嵌套 xcodebuild 产出 Catalyst helper 与 iOS Simulator 载荷。2026-08-30 撤回并删除该阶段：独立 DerivedData 让新旧判断永不命中，一次 Release 构建从 86 秒涨到 554 秒；且 helper 那一半从未生效——嵌入阶段取的是 `SRCROOT` 下的 `PBXFileReference`，不是它写入的 `BUILT_PRODUCTS_DIR`。GUI 缺载荷即不嵌入，要连载荷一起测就跑 RunScript.sh。 |
| [0016](0016-application-viewmodel-tests.md) | RuntimeViewerApplication ViewModel 测试覆盖 | Implemented | 为 `RuntimeViewerApplication` 的每个 ViewModel 补一份按公共契约覆盖的 swift-testing 套件，引擎相关用例用专用的进程内 `RuntimeEngine`；加两处 internal 测试缝，并修掉 `AppDefaults` 测试默认值读写用户真实书签文件的问题。 |
| [0017](0017-observed-lazy-relay.md) | `@Observed` 惰性创建 relay | Implemented | 上游 RxSwiftPlus 改 `@Observed`：值先放在带 `os_unfair_lock` 的小盒子里，首次访问 `$property` 才建 `BehaviorRelay`。没被订阅的属性不再背一整套 relay 加 `NSRecursiveLock`，13k 镜像行与未滚到的对象行受益；`$property` 类型不变，99 处用法零改动。0005「替代方案 B」的后续。 |
| [0018](0018-rxobserved-macro.md) | `@RxObserved` 宏：仿 `@Observable` 的内联可观察属性 | Implemented | 0017 的下一步：`@Observed` wrapper 换成宏，存储变成内联在对象里的 `RxObservedSlot` 值类型，未观察的属性零分配零锁；`$x` 类型不变，99 处一对一替换。 |
| [0019](0019-helper-daemon-reinstall-button.md) | Helper 设置页的重装按钮 | In Progress | 设置页面的 Helper Service 行在服务已启用时加一个 Reinstall 按钮，取代「先卸载再安装」两步操作。重装序列不是新写的——`HelperServiceManager` 里那条只有启动时版本不匹配才会走到的序列抽成共用的 `performReinstall()`，两个调用点共用同一份代码（含绕开 `SMAppService` 磁盘记账滞后的 1 秒停顿）。 |
| [draft](draft-runtime-bookmark-scope.md) | RuntimeBookmarkScope：把持久化身份从显示名手里拿走 | Accepted | 新建稳定的 `RuntimeBookmarkScope` 取代三处各自拼出来的键（含 pid 的书签键、用进程显示名的 sidebar autosave 键、编码了 `name` 却按忽略 `name` 比较的落盘表示）。身份走 descriptor 上的 `@Default` 字段以保持混版兼容，`RuntimeSource` 不动。在 `feature/runtime-bookmark-scope` 上实现，拆三个 PR。 |
| [draft](draft-engine-management-module.md) | 引擎管理下沉为无 UI 模块 `RuntimeViewerEngineManagement` | In Progress | 愿景《无头 RuntimeViewer》第一步。`RuntimeEngineManager` 及伙伴从 `RuntimeViewerApplication` 搬进不依赖 AppKit / RxSwift 的新 target，开三条缝：`RuntimeEngineManagerConfiguration`（广播 / 共享 / 系统引擎 / 重连各自开关）、`RuntimeResourceLocating`（载荷与 Catalyst helper 路径不再写死 `Bundle.main`）、`RuntimeProcessAttacher`（承接 App target 里的注入收尾）。App 行为零变化。 |
| [draft](draft-command-line-interface-foundation.md) | `runtime-viewer-cli` 基础：命令级协议、常驻 CLI host 与本地来源 | In Progress | 愿景第二步，不依赖抽模块。新包 `RuntimeViewerCommandLine/`：Codable 命令与结果模型、Unix domain socket 长度前缀 JSON、常驻 host 的自动拉起 / 单例 / 空闲退出、本地来源上的全部查询命令（`images` … `export`）。`--json` 即结果模型。 |
| [draft](draft-command-line-interface-multi-source.md) | `runtime-viewer-cli` 多来源：全部运行时来源、attach 与 App 充当 host | Draft | 愿景第三步，依赖前两篇。独立 host 换上 `.headlessHost` 的 `RuntimeEngineManager`，新增 `sources` / `attach` / `detach`，`--source` 覆盖 local / catalyst / pid / process / engine；App 启动即充当 host 并接管独立 host。 |
| [draft](draft-command-line-interface-app-embedding.md) | `runtime-viewer-cli` 嵌入 App 包与设置页 | Draft | 愿景第四步。Xcode command-line tool target 嵌到 `Contents/Helpers/` 随 App 签名公证；Settings 新增「Command Line Tool」页做 `/usr/local/bin` 符号链接与「允许命令行访问」开关。 |

> 0000 与 0001 采用早期格式，正文没有状态字段，此处如实标为「未标注」。按「旧文档原地不动」的约定不回填。

> **编号占用提醒**：`0007` 曾在两条 feature 分支上各被用过一次，2026-08-16 合流时已解决——
> `feature/objc-rendering-and-indexing` 的 `0007-objc-relationship-index-returns-to-application.md`
> 保留 `0007`，`feature/uifoundation-settings-adoption` 的那篇改号为 `0011`。
> 尚未合入本分支的占用：`0005` 在 `feature/node-store-adoption`（`0005-cellvm-appearance-single-observed.md`），
> `0012` 在 `feature/uifoundation-navigation`
> （`0012-replace-uxkit-navigation-with-uifoundation.md`，已被本分支的 0013 取代）。
> **新提案从 `0020` 起编号**，不要只看本分支已有的文件挑下一个空号。
>
> **`0013` 是第二次撞号，2026-08-29 合流时已解决**——`feature/inject-ios-simulator-process`
> 与 `next` 上的 `0013-replace-uxkit-with-appkitplus.md` 同号，两者互不知情。按前一次 `0007`
> 的先例，先入 `next` 的 `0013-replace-uxkit-with-appkitplus.md` 保号，后到的
> `0013-inject-ios-simulator-process.md` 改号为 `0014`。本条与
> `draft-runtime-bookmark-scope` 无关——那篇按 skill 的规定，落地时才分配编号，此处仍记为 draft。

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
