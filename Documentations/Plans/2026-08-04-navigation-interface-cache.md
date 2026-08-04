# 导航接口缓存（RuntimeInterfaceCache：来回导航 / 切 tab / 重复点链接不再重拉 XPC）

- **Status**: Implemented（本文档与代码同批落地）
- **Date**: 2026-08-04
- **Related**: `Documentations/Plans/2026-08-04-content-text-pipeline-pr1.md`（内容管线拆分——本缓存复用其 fetch/render 分离与 `InterfaceProvider` 测试缝）、`Documentations/Plans/2026-08-04-sidebar-filter-pipeline-perf.md`（同一"流畅度卖点"主线）
- **Regression suite**: `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/RuntimeInterfaceCacheTests.swift` + `ContentTextPipelineTests.navigationRevisitRendersFromCache`

## 1. 动机（为什么做）

内容导航的每一步（点类型链接、切 tab、back/forward、侧边栏点击）都会让 `ContentCoordinator` 重新绑定一个全新的 `ContentTextViewModel`，而全工程没有任何接口结果缓存——在 A、B 两个类之间来回跳，每一步都重新跨 XPC 拉一遍接口。附带一个隐藏的双倍浪费：**点一次链接实际是两次 XPC**——`transform(_:)` 先用默认 `GenerationOptions()` 拉一遍目标接口（只为解析出跳转对象），push 之后新 ViewModel 再用用户实际 options 拉第二遍，两次的 key 甚至不同。

另有一个顺带确认的既有不一致：工具栏"保存文件"和拖拽分享走的是 `appDefaults.options` **未合并 transformer 配置**的裸 options，用户改过 transformer 设置后，**保存出的文本和内容区显示的文本可能不一样**。

## 2. 范围（改了哪些部分）

| 文件 | 改动 |
|---|---|
| `RuntimeViewerApplication/Content/RuntimeInterfaceCache.swift`（新增） | 文档级 LRU 缓存：`@MainActor`，key = `(RuntimeObject, GenerationOptions)`，容量 16；同 key 并发请求共享同一 in-flight `Task`；`nil` 与 error 不缓存；generation token 保证"晚到的旧 fetch 不能污染 flush 后的缓存"；init 内订阅 `$runtimeEngine`（换引擎→清空+换订阅）与 `dataChangePublisher`（任何事件→保守全清）。 |
| `RuntimeViewerApplication/DocumentState.swift` | 新增 `public private(set) lazy var interfaceCache`（仿 `backgroundIndexingCoordinator` 模式）。 |
| `RuntimeViewerApplication/ViewModel.swift` | 新增 `currentMergedGenerationOptions` 计算属性：stored options + 实时 transformer 配置，与内容管线 fetch 半程的合并逻辑逐字一致——所有想与内容区共享缓存条目的取用点都必须用它，key 才对得上。 |
| `RuntimeViewerApplication/Content/ContentTextViewModel.swift` | 默认 `InterfaceProvider` 从直连引擎改为路由缓存；provider 提升为存储属性，`transform(_:)` 的两条链接解析流也走同一 provider（注入的测试 provider 因此能观测到全部 fetch）；链接解析的 options 从 `.init()` 改为 `currentMergedGenerationOptions`——解析那次直接暖缓存，push 后的展示 fetch 命中，**一次点击一次 XPC**。 |
| `RuntimeViewerUsingAppKit/Main/MainViewModel.swift` | 保存文件、拖拽分享两处改走 `documentState.interfaceCache` + `currentMergedGenerationOptions`：保存可见对象为缓存命中，且导出文本从此与屏幕显示一致（顺带修掉 §1 的不一致）。 |
| `RuntimeViewerCore/Core/RuntimeObjCSection.swift`、`Core/RuntimeSwiftSection.swift`、`Common/RuntimeObjectInterface+GenerationOptions.swift` | `ObjCGenerationOptions` / `SwiftGenerationOptions`（含 `MemberSortOrder`）/ `GenerationOptions` 补 `Hashable`（成员全是 Bool 与 String enum，纯编译器合成；与上一批补 `Equatable` 同类的纯增量 API）。 |

## 3. 关键设计与取舍

- **缓存 fetch 半程的产物（`RuntimeObjectInterface`），不缓存 `NSAttributedString`**。接口的 `SemanticString` 与主题无关，是跨 XPC 最贵的一段；富文本构建已在 PR1 后台化（几十 ms 级），且它依赖主题——缓存它意味着 key 要卷入 fontSize 连续值（2026-05-17 计划否决过的 Option C）。
- **对象解析与 options 无关，已核实**：`RuntimeEngine._interface(for:options:)` 按 `RuntimeObject` 的 kind/mangled name/imagePath 定位 section 并解析目标，options 只进文本生成（`updateConfiguration` / `interface(for:using:transformer:)` 的文本参数）。因此链接解析改用 merged options 是安全的——解析出的对象相同，顺手暖了缓存。
- **`@MainActor` 而非 actor**：与全项目文档级服务一致（`DocumentState`、`backgroundIndexingCoordinator` 均 `@MainActor`），Rx 订阅接线零摩擦；每次导航一次 main hop 做字典查找，成本可忽略。所有存储变更被 main actor 串行化，配合"只有 fetch 创建者写回存储"的结构，无锁无竞争。
- **generation token 兜底 flush 与 straggler 的竞态**：flush 先 bump generation；早于 flush 启动的 fetch 完成后发现 generation 不符，把结果交还调用方但不写回存储。已有专门测试钉死。
- **in-flight 共享带来的免费收益**：链接点击的解析 fetch 与 push 后新 ViewModel 的展示 fetch 若在时间上重叠，第二个直接挂在第一个的 Task 上——两条消费路径合计一次引擎往返。
- **失效策略取保守全清**：`fullReload`（镜像加载、reloadData）与 `specializationAdded` 都直接 `invalidateAll()`。事件稀少（用户级操作触发），全清永远正确；按 imagePath 精细失效的复杂度不值得。注入路径已核实被覆盖：注入后要么引擎广播 `.fullReload`（`_loadImage` / `reloadData`），要么文档整体换引擎（`$runtimeEngine` 订阅清空）。
- **`nil` 与 error 不缓存**："找不到"可能在另一镜像加载后变为"找得到"，dead link 重查成本极低；error 缓存则会把一次瞬时 XPC 故障放大成持续错误。
- **批量消费者绕过缓存**：接口批量导出与 MCP 工具继续直连引擎——一次批量扫描会把导航即将回访的条目全部逐出，属于反收益。

**放弃的方案**：
- 引擎侧缓存——缓存必须在 XPC 客户端这一侧才省得掉往返；引擎侧还要处理多客户端一致性。
- `NSCache` ——不提供 LRU 序且逐出时机不可测试；手写 16 容量 LRU 共 20 行。
- 按 `(engineID, imagePath)` 精细失效——事件频率不支撑这个复杂度。

## 4. 结果与验证

- `RuntimeInterfaceCacheTests`（8 条）：重复命中 1 次 fetch；不同 options 分 key；并发合并为 1 次 fetch；error / nil 均不缓存、下次重试；`invalidateAll` 强制重拉；**真实引擎 `reloadData` 广播经 RxCombine 接线冲刷缓存**（wiring 集成测试）；LRU 按最近使用逐出（touch 后的旧条目存活，未 touch 的被逐出）；flush 后晚到的 in-flight 结果交还调用方但不入缓存。
- `ContentTextPipelineTests.navigationRevisitRendersFromCache`：同一 `DocumentState` 上先后创建两个 `ContentTextViewModel`（模拟 push 走、back 回来），第二个渲染完成时 fetch 计数仍为 1。
- 全部包测试 74/74 通过（10 个 suite）。
- App 目标经 sibling workspace 构建通过（helper + 主 App，0 error / 0 warning）。

## 5. 影响面

- **行为语义变化只有一处理论窗口**：attach 到活进程时，若目标进程的运行时在**无任何数据事件**的情况下原地变化（既没加载镜像、没触发 reload、没换引擎），16 条内的旧接口会显示缓存值；此前每次导航都重拉、能"碰巧"看到最新。所有已知变更路径（加载镜像、注入、specialization、手动 reload、换 source）都会广播事件或换引擎，均触发全清。
- 链接点击、保存文件、拖拽分享的输出文本从"裸 options"统一为"merged options"：保存/分享的文本与内容区显示逐字一致（此前 transformer 配置不参与保存路径，是既有 bug）。
- iOS / Catalyst：缓存与合并逻辑平台中立（UIKit 分支 transformer 恒为 `.init()`，与 fetch 半程一致）；无 public API 破坏，`Hashable` 均为纯增量。
- 内存上界：16 × 典型几十 KB `SemanticString`，个别 `UIView.h` 量级 MB 级条目参与 LRU 自然轮换，无需内存压力钩子。

## 6. 迁移 / 跟进注意事项

- **新增单对象接口取用点的规矩**：走 `documentState.interfaceCache` + `currentMergedGenerationOptions`，key 才能与内容区共享；批量路径（导出、MCP）继续直连引擎，不要"顺手"套缓存。
- 若未来出现"引擎数据在无事件下变化"的合法场景（例如注入后的热改写不经任何广播），补一条 `dataChangePublisher` 事件即可，缓存侧无需改动——失效面是事件驱动的。
- 容量 16 为经验值；若 Instruments 显示导航深度普遍超过 16，调大即可（`RuntimeInterfaceCache.init` 的 `capacity` 参数，测试已参数化）。
