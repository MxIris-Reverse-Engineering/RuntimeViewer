# 0007 - RuntimeViewer 接入 UIFoundation Settings

- **状态**: Implemented
- **作者**: JH
- **日期**: 2026-08-13
- **最后更新**: 2026-08-16

## 摘要

让 RuntimeViewer 直接采用 UIFoundation 已抽取的 `UIFoundationSettings` 与
`UIFoundationSettingsUI`：RuntimeViewer 继续拥有自己的设置数据结构、八个业务页面和资源，
删除重复的 JSON 存储、防抖保存、SwiftUI 设置窗口骨架、侧栏图标、侧栏控制和全局
`NSSplitViewItem` method swizzling。

## 动机

RuntimeViewer 当前同时承担两类职责：

1. RuntimeViewer 特有的设置模型与页面，例如 Theme、Transformer、Indexing、MCP、Helper Service；
2. 任意 AppKit 应用都相同的持久化 store、`AppSettings` binding、设置窗口、侧栏和页面导航。

第二类能力已经在 UIFoundation 中形成独立产品。继续保留两份实现会让修复和行为演进分叉，尤其是
现有窗口通过全局 method swizzling 禁止侧栏折叠，而 UIFoundation 已提供作用域限定且带回归测试的
实现。

## 提议方案

### 模型层

- `RuntimeViewerSettings` 依赖 `UIFoundationSettings`。
- 顶层 `Settings` 保持 `@Observable final class`，并在 macOS 上遵守 `PersistentSettings`；业务监听继续
  按顶层属性失效。
- 使用 `SettingsStore` 与 `FileSystemSettingsStorage` 统一加载、防抖保存和即时保存。
- 通过 `accessPersistedValues()` 明确触达七个编码属性，让 UIFoundation Store 独立建立保存监听；删除原来
  七处重复的保存 `didSet`。
- 保留 MetaCodable 的 `@Codable` / `@Default`，确保旧 JSON 缺少新增字段时仍采用默认值。
- 保留既有 `settings.json` 文件名以及 `RuntimeViewer` / `RuntimeViewer-Debug` 目录，避免制造数据迁移。
- 旧主题数据迁移在 store 加载完成后执行。

### UI 层

- `RuntimeViewerSettingsUI` 依赖 `UIFoundationSettingsUI`。
- 八个业务页面和外观图片资源原地保留。
- 本地 `AppSettings` 缩减为 UIFoundation 泛型属性包装器的 typealias。
- RuntimeViewer 的窗口控制器只负责注册八个 `SettingsPage` 和提供现有 dependency key。
- 删除本地 `SettingsForm`、`SettingsIcon`、`SettingsRootView`、侧栏 introspection 和 method swizzling。
- 移除 RuntimeViewer 不再使用的 `SwiftUIIntrospect` package dependency。

### 调用方

- 继续通过 RuntimeViewer 的 dependency key 访问唯一的 UIFoundation settings store，不创建第二份状态。
- 读写始终经过 `SettingsAccess` 到达 Store 当前持有的 `@Observable Settings`；加载替换整个对象后，既有
  调用点不会持有旧对象。
- Theme、Updater、MCP 与 Background Indexing 的 observation tracking 必须在 tracking closure 内读取
  对应具体属性。会反复重装的 Rx tracking 需要在 closure 外解析并捕获 dependency，再在 closure 内读取
  属性，避免 MainActor 重装跳转丢失 dependency context。
- `MCPBridgeServer` 是 actor；读取 MainActor 隔离的 store 时改为显式异步跳转。

### 平台边界

`UIFoundationSettings` 当前只在 macOS 暴露 API，而 `RuntimeViewerSettings` 仍被跨平台 target 使用。
纯 `Settings` observable class 及其嵌套业务类型继续跨平台编译；`PersistentSettings` conformance、store、加载和
持久化只在 macOS 启用。非 macOS 平台继续使用默认业务值，不引入设置窗口。

## 替代方案考量

### 整个 `RuntimeViewerSettings` target 删除

否决。UIFoundation 只提供通用设施，不拥有 RuntimeViewer 的业务 schema、迁移、Updater client 或页面。

### 继续保留 RuntimeViewer 自己的 class store，仅替换窗口

否决。class 模型本身保留，但保存、加载与防抖必须进入 UIFoundation；否则仍保留七处手写 `didSet` 与
本地存储实现，无法完成模型层接入。

### 把 Settings 改成值类型并在根值上保存

落地中否决。它能让通用 Store 借根值赋值自动保存，但会把所有 Observation 合并到 `store.value`：改
Theme 也会唤醒 Transformer。曾实现并通过测试，随后因用户要求保留细粒度监听而撤回，改为 UIFoundation
Store 观察 class 模型的 `accessPersistedValues()`。

### 为值类型 Store 缓存 key-path projection

否决。它可以在根值写入后逐个比较并只通知命中的业务监听，但要求所有 setting value `Equatable`，还要
维护 projection 身份、写回与首次 tracking 不得登记根值等机制。原有 `@Observable class` 已天然提供所需
粒度，无需重复建模。

### 把 RuntimeViewer 的业务设置搬进 UIFoundation

否决。Theme、MCP、Indexing、Transformer、Sparkle 与 Helper Service 都绑定 RuntimeViewer 的服务和
依赖，不是基础 UI 能力。

## 影响

- **用户可见变化**：设置页面内容保持不变；窗口新增 UIFoundation 提供的页面前进/后退导航。
- **数据与配置兼容**：继续读取同一路径的 `settings.json`；MetaCodable 默认值语义保持不变。
- **依赖**：RuntimeViewer 启用 UIFoundation 的 `Settings` trait，并移除 `SwiftUIIntrospect`。
- **观察粒度**：按顶层属性失效。读取 `transformer` 的 tracking 不响应 `theme` 修改；Theme 内部仍是
  值类型 section，所以 Theme 任一字段会共同唤醒 Theme listener。
- **持久化契约**：新增编码属性时必须同步加入 `accessPersistedValues()`；否则该属性仍会随别的保存落盘，
  但单独修改它不会启动自动保存。
- **平台与最低版本**：macOS 仍为 15+；非 macOS 不启用 UIFoundation 持久化 API。
- **发布**：RuntimeViewer 依赖 UIFoundation `0.16.0` 或更高版本；`0.16.0` 同时包含 Settings trait 与
  `@Observable` 引用模型 Store，干净环境可以直接按语义版本解析。

## 验收标准

1. 既有 `settings.json` 能完整解码，缺少新字段时仍应用默认值。
2. UI 修改任何设置都会更新唯一 store，并在防抖后写回原路径。
3. 八个设置页面、图片资源、Updater、MCP、Theme 与 Background Indexing 行为保持。
4. RuntimeViewer 不再包含设置窗口 method swizzling，也不再依赖 `SwiftUIIntrospect`。
5. RuntimeViewerPackages 单元测试与 macOS App build 使用 agent 独立产物目录通过。
6. 不启动 Simulator；本次不包含交互式 UI 验证。

## 落地步骤

1. 接通 UIFoundation trait、products 与本地 checkout。
2. 让 RuntimeViewer 的 `@Observable Settings` 接入 UIFoundation store，保留磁盘与解码兼容，并把保存
   监听集中到 `accessPersistedValues()`。
3. 替换 UI 壳并删除重复文件与依赖。
4. 更新调用方、观察链以及 MCP actor 跨 MainActor 读取设置的路径。
5. 添加回归测试，更新文档索引与 `AGENTS.md`。
6. 执行 package tests 与 macOS App build。

## 实施结果

- 顶层 `Settings` 保持 `@Observable final class`，并以 UIFoundation 的 `SettingsStore` /
  `FileSystemSettingsStorage` 读写原有 `settings.json`。Store 监听七个持久化属性，不再由属性 `didSet`
  自己调保存。
- `SettingsAccess` 保留现有 `@Dependency(\.settings)` 调用面，但不持有第二份状态；SwiftUI 的
  `AppSettings` 也直接绑定同一个 `Settings.store`。
- 设置窗口改为 UIFoundation 的 `SettingsWindowController`，八个业务页面以 `SettingsPage` 注册；本地
  window/sidebar/form/icon 壳层、全局 `NSSplitViewItem` swizzling 与 `SwiftUIIntrospect` 已删除。
- 设置窗口通过顶层 `SettingsConfiguration` 把 sidebar 图标统一设为 15 pt，恢复迁移前
  `20 pt frame - 2 × 2.5 pt padding` 得到的实际 glyph 尺寸，同时继续使用无底板、无阴影的
  `.plainSymbol`。
- 新增三个回归测试：旧 payload 的缺失字段兼容、dependency 动态成员写入触发 store 自动保存，以及
  `transformer` 监听不响应 `theme` 修改但响应真正的 Transformer 修改。
- `RuntimeViewerPackages` 全部 57 个测试通过；`RuntimeViewerMCP` 独立编译通过。
- XcodeBuildMCP 使用独立 DerivedData 完成 Catalyst helper 和 macOS App 构建；本地多仓库 workspace 与
  只使用远端依赖的 Distribution workspace 都通过，且无 warning/error。
- 按任务边界未启动 Simulator，也未做交互式 UI 验证。

## 已知限制

**UIFoundation 版本（已解决）。** 2026-08-14 的 sidebar 图标修正用到了当时尚未发布的
`SettingsConfiguration`，而版本下限仍写着 `0.16.0`——那个 tag 并不含这个类型，导致任何没有启用本地
UIFoundation checkout 的构建（CI、全新 clone，以及本分支自己重 pin 的 Distribution workspace）都编不过。
UIFoundation `0.17.0` 已发布并同时包含 `SettingsConfiguration` 和设置窗口的位置恢复修复，下限与三份
lockfile 均已提到 0.17.0。

**依赖图冲突（本分支仍在，需靠 main 解决）。** 直接用 SwiftPM 把 `RuntimeViewerPackages` 切到全远端
依赖时，依赖图在进入源码编译前就会报 `MachOSwiftSection`（0.14.1）与 `swift-semantic-string` 都声明
`OutputTransformer` target。这与 Settings 迁移无关：`main` 上的 `0cb669c`（升级到 MachOSwiftSection
0.15.2 及其拆出的包，并把 `Transformer.swift` 改为同时 re-export `OutputTransformer` 与
`SwiftOutputTransformer`）已经解决了它，但该提交尚未进入 `next`，因此也不在本分支上。

在本分支上，用本地兄弟仓库构建同样不通——本地 MachOKit / MachOSwiftSection 已经走在 `next` 前面
（`MachOExtensions` 模块已不存在）。也就是说本分支目前两端都编不过，且两端都不是本次改动造成的。
2026-08-16 的验证是在一份把 `main` 合进来的一次性副本上做的：`RuntimeViewerSettings` /
`RuntimeViewerSettingsUI` / `RuntimeViewerApplication` / `RuntimeViewerMCPBridge` 与 macOS App target
全部编译通过，设置持久化测试全绿。**本分支合入前需要先把 `main` 并进 `next`。**

## 决策日志

| 日期 | 决策 | 说明 |
|---|---|---|
| 2026-08-13 | Created as Draft | 用户要求 RuntimeViewer 直接接入当前 UIFoundation 的 Settings 模块。 |
| 2026-08-13 | Accepted → In Progress | 用户明确批准直接实施；改动放在独立 feature branch。 |
| 2026-08-13 | Implemented | 持久化、binding 与设置窗口均已接入 UIFoundation；回归测试及本地/Distribution 构建通过。 |
| 2026-08-13 | Design amended | 值类型根 Store 会把所有监听合并到 `value`；按用户意见恢复 `@Observable class Settings`，由 UIFoundation Store 通过显式属性触达统一保存，从而保留业务属性级监听。 |
| 2026-08-14 | Post-migration correction | 迁移后 `.plainSymbol` 从原先带 padding 的 15 pt 实际 glyph 放大到 20 pt；改由 UIFoundation 的统一 `Configuration` 显式传 15 pt。新 API 发布前，本分支的验证使用本地 UIFoundation checkout。 |
| 2026-08-14 | API naming correction | UIFoundation 把三个呈现入口共用的配置从 window controller namespace 提升为顶层 `SettingsConfiguration`；RuntimeViewer 调用点同步写出新类型名。 |
| 2026-08-16 | Review follow-up | PR #99 的 `/code-review` 产出 14 条 findings，逐条裁决记录在 [`KnownIssues/2026-08-16-uifoundation-settings-adoption-review-findings.md`](../KnownIssues/2026-08-16-uifoundation-settings-adoption-review-findings.md)。11 条已修（版本下限、窗口位置、加载/落盘时机、actor 隔离、平台守卫、持久化测试等），1 条判为误报（非 macOS 持久化），2 条延后（`OutputTransformer` 依赖声明由 main 解决）。UIFoundation 0.17.0 为此发布。 |
