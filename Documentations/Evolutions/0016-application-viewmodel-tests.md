# 0016 - RuntimeViewerApplication ViewModel 测试覆盖

- **状态**: Implemented
- **创建日期**: 2026-09-02
- **最后更新**: 2026-09-02

## 摘要

`RuntimeViewerApplication` 里的 10 个 `ViewModel<Route>` 子类与 4 个 Cell ViewModel，此前只有围绕特定缺陷的
回归测试（过滤管线、Open Quickly 惰性构造、重载失效、内容管线拆分等）和 `SidebarRuntimeObjectCellViewModel`
的两条特化场景，没有一份按 ViewModel 逐个覆盖其公共契约（`Input` → `Output` / `DocumentState` 变化）的套件。
本提案为每一个 ViewModel 补上这样的 swift-testing 测试（`RuntimeViewerApplicationTests` 新增 14 个测试文件与
4 个支撑文件），并为此加两处 `internal` 可见性的测试缝。调研中同时发现 `AppDefaults` 的测试默认值会让测试进程
读写用户真实的书签文件，本提案一并修掉。

## 方案

### 测试放在哪条边界上

- ViewModel 一律通过公共边界测：构造时注入 `DocumentState` 与既有的记录型 `MockRouter`，用 `PublishRelay` 造
  `Input`，观察 `Output` 的 Driver / Signal 以及 `documentState` 的状态变化。不 mock 项目自己的类型。
- 需要引擎数据的 ViewModel（Content 文本、Inspector 类层级 / 关系、Sidebar 对象列表）用进程内真实的
  `RuntimeEngine(source: .local)`，做法与 RuntimeViewerCore 自己的测试一致。`TestRuntimeEngine.shared()`
  在每个测试进程里只建一个**专用**引擎并加载 libobjc + Foundation，之后不再对它 `loadImage`；断言锚点用
  `NSObject` / `NSString` / `NSMutableString` 这类稳定符号。需要改变引擎状态的用例（加载一个尚未映射的镜像、
  无法连通的客户端引擎）各自建私有引擎。
- 这条路线与既有的 `SharedLocalEngineTestLock` 互补而非重复：那把锁保护的是绑定在进程共享单例
  `RuntimeEngine.local` 上的测试；本提案的 ViewModel 通过 `.switchEngine` 绑到专用引擎，`.local` 的启动广播
  到不了它们，因此不需要取锁，也不会和取锁的套件互相干扰。
- Rx 流用两个 async 助手转成可 await 的值：`nextValue(from:where:)` 等第一个满足条件的元素，
  `values(from:during:)` 收集一段时间内的全部元素，用来证明「没有发射」。

### 两处测试缝（已获批准）

1. `AppDefaults` 新增 `internal init(storageDirectoryURL:)`，两个 `@ResilientFileStorage` 属性改为在初始化器里
   指定目录（复用该包装器已有的 `directoryURL` 初始化器），两阶段迁移也从同一目录读旧文件。测试用
   `AppDefaults.isolated()` 在临时目录建全新实例，并行套件互不可见；生产仍只有 Application Support 那一个单例。
2. `ResolvedThemeStream.init` 由 `private` 放宽为 `internal`，让 `ContentTextViewModel` 的测试能用
   `withDependencies` 注入自己的主题流，而不是依赖进程单例首次解析时捕获的那份 settings。

### `AppDefaults` 的数据安全问题

- 书签文件在 `~/Library/Application Support/AppStorage/`，路径不按 bundle 区分；App 未启用沙盒。所以测试进程一旦
  解析到 `AppDefaults.shared`，读写的就是用户真实的书签文件。
- `@DependencyEntry` 会把属性初始化表达式当作 `testValue`。此前它是 `AppDefaults.shared`，意味着任何在测试上下文
  里解析 `\.appDefaults` 的代码都静默命中真实文件；`TestSupport.withLiveDependencyContext` 走 `.live` 上下文，
  同样命中。`init` 里的两阶段迁移由测试宿主自己的 UserDefaults 标记把关：调研时 `com.apple.dt.xctest.tool` 与
  `swiftpm-testing-helper` 两个域里 `bookmarkMigrationCompleted` 均已为 true，说明迁移在过去的测试运行中至少执行
  过一次。
- 现在 `testValue` 指向 `AppDefaults.testFallback`（临时目录）。它只兜底那些 `withDependencies` 作用域够不到的
  解析——典型是 Sidebar 管线在 GCD 线程上新建的 cell ViewModel。要断言书签内容的测试仍各自注入
  `AppDefaults.isolated()`。`withLiveDependencyContext` 也改为固定注入隔离实例，其余键继续走 live。

### 依赖注入约定

- 所有 ViewModel 在 `ViewModelTestEnvironment.make { }` 里构造：它同时覆盖 `appDefaults`（隔离实例）、
  `settings`（`SettingsAccess.preview`，内存存储，不会写回用户的 debug 设置文件）与 `resolvedThemeStream`
  （用该 settings 新建的实例）。
- 转换闭包多为 `[weak self]`，测试必须让 ViewModel 活到断言之后（`defer { withExtendedLifetime(viewModel) {} }`）。

### 覆盖清单

| ViewModel | 测试文件 | 覆盖的行为 |
|-----------|----------|------------|
| `ViewModel<Route>` 基类（借 `ContentPlaceholderViewModel` / `InspectorPlaceholderViewModel`） | `ViewModelBaseTests` | 协作者保持；`currentMergedGenerationOptions` 合并存储选项与 transformer 设置；`commonLoading` 跟随活动；`delayedLoading` 只报告超过 500ms 的加载 |
| `ContentTextViewModel` | `ContentTextViewModelTests` | 渲染接口（`renderedInterface` 与 `attributedString` 一致）与镜像名；选中名跟随文档；点击链接 push；⌘⇧ 点击开新 tab；无法解析时报 `runtimeObjectNotFound` |
| `InspectorClassViewModel` | `InspectorClassViewModelTests` | 继承链逐行；`update(for:)` 换对象 / 同对象不重取；未索引镜像给空层级 |
| `InspectorRelationshipsViewModel` | `InspectorRelationshipsViewModelTests` | 按 kind 的标题与空提示；NSObject 子类含 NSString；点击 push；`update(for:)` 立即换标题并重载 |
| `InspectorSwiftSpecializationViewModel` | `InspectorSwiftSpecializationViewModelTests` | 只列特化子项；添加特化触发路由；选择 push；`update(for:)` |
| `InspectorRuntimeNodeViewModel` | `InspectorRuntimeNodeViewModelTests` | 持有节点（该类目前没有其他行为） |
| `SidebarRootViewModel` | `SidebarRootViewModelTests` | 节点镜像来源；索引后按绝对路径可查；搜索过滤与 begin / end 信号；点镜像切换文档；点目录发出展开深度 |
| `SidebarRootDirectoryViewModel` | `SidebarRootDirectoryViewModelTests` | 节点跟随引擎镜像树；添加书签按 scope 键存储 |
| `SidebarRootBookmarkViewModel` | `SidebarRootBookmarkViewModelTests` | 只列当前 scope 的书签；删除、移动；过滤时禁止移动 |
| `SidebarRuntimeObjectViewModel` | `SidebarRuntimeObjectViewModelTests` | `makeSections` 分组排序；已加载空镜像 → loaded + empty；未加载 → notLoaded → 点击加载；引擎不可达 → 错误文案 |
| `SidebarRuntimeObjectListViewModel` | `SidebarRuntimeObjectListViewModelTests` | `findCell` 祖先链；真实对象按 kind 分区且区内按名排序；搜索过滤；scope 过滤；`selectCell` 解析选中；Open Quickly 模糊过滤；点击 / 新 tab / Open Quickly 导航；添加对象书签 |
| `SidebarRuntimeObjectBookmarkViewModel` | `SidebarRuntimeObjectBookmarkViewModelTests` | 按存储顺序列出；删除、移动；空态 |
| `SidebarRootCellViewModel` | `SidebarRootCellViewModelTests` | 子节点排序；迭代顺序；`applyFilterOutcome` 只换可见子项；appearance |
| `SidebarRuntimeObjectCellViewModel` | `SidebarRuntimeObjectCellViewModelTests` | 原有两条 + 重复追加为 no-op、`matchesScopeRecursively`、`filterContext` 文本过滤 |
| `InspectorRelationshipsCellViewModel` / `InspectorSwiftSpecializationCellViewModel` | `InspectorCellViewModelTests` | appearance 的标题 / 副标题、次级与三级图标 |

**未覆盖并说明原因**：`SidebarRootViewModel.Input.selectedNode` 会调用
`documentState.backgroundIndexingCoordinator.prioritize(imagePath:)`，该效果只在后台索引协调器内部可见，
留给后台索引自己的测试；`withLoadingPlaceholder` 的时序属于 `RuntimeViewerArchitectures`；过滤管线的成本模型、
Open Quickly 的惰性物化、重载失效与内容管线拆分已由既有的专项套件覆盖，本提案不重复；UIKit 分支
（`#else` 路由）在 macOS 测试进程里不编译。

### 如何运行

```bash
cd RuntimeViewerPackages
swift build --build-tests --scratch-path /tmp/<agent>/SwiftPM/RuntimeViewerPackages
swift test --skip-build --scratch-path /tmp/<agent>/SwiftPM/RuntimeViewerPackages --filter RuntimeViewerApplicationTests
```

成败只看 `swift test` 的退出码。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-02 | Created：「给 RuntimeViewerApplication 补一下测试，每一个 ViewModel 都要测」 | 用户原始需求 |
| 2026-09-02 | 用户批准两处测试缝（`AppDefaults.init(storageDirectoryURL:)`、`ResolvedThemeStream.init` 放宽为 internal） | 不加缝则 4 个书签 ViewModel 与 `ContentTextViewModel` 无法安全测试 |
| 2026-09-02 | `\.appDefaults` 的 `testValue` 改为临时目录的兜底实例，而不是去掉 testValue 让测试报错 | 去掉后 Sidebar 管线在 GCD 线程上新建的 cell ViewModel 仍会解析到无覆盖的上下文而失败；兜底实例既安全又不需要每个测试都为此操心 |
| 2026-09-02 | 引擎相关用例用专用的进程内引擎，不为 `RuntimeEngine` 引入协议缝，也不复用 `RuntimeEngine.local` | `RuntimeEngine` 是具体 actor，Core 测试已走同一路线；专用引擎让这些套件不必参与 `SharedLocalEngineTestLock` 的串行化 |
| 2026-09-02 | 测试的 `settings` 一律用 `SettingsAccess.preview` | live 实例背后是用户的 `RuntimeViewer-Debug/settings.json`，写入会随自动保存落盘 |
| 2026-09-02 | 最初在 `main` 检出上完成，随后按 `next` 的 API（scope 键书签、`SettingsAccess`、`RuntimeObjectCellAppearance`、过滤管线）重做并只落在 `next` | 这项工作本应在 `next` 上进行；两支的 ViewModel 已大幅分叉，补丁无法直接搬运 |
| 2026-09-02 | 编号 0016、状态 Implemented，与测试代码同一批次落地 | 落地时取 `origin/main` 与 `origin/next` 的全局最大编号（0015）+1；无需配套指南，运行方式与约定已写入 `AGENTS.md` 的 Testing 一节；未引入新术语，词汇表不变 |
