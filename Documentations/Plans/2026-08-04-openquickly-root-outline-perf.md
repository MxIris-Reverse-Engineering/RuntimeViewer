# Open Quickly 惰性物化 + 根侧边栏后台过滤 + Outline 展开持久化合并

- **Status**: Implemented（本文档与代码同批落地）
- **Date**: 2026-08-04
- **Related**: `Documentations/Plans/2026-08-04-sidebar-filter-pipeline-perf.md`（本文完成其 §6 跟进项 1 与 4）、`Documentations/Plans/specialization-typepicker-perf-r2.md`（惰性 cellVM 思路的先例）
- **Regression suites**: `OpenQuicklyLazyConstructionTests.swift`、`SidebarRootFilterPipelineTests.swift`、`StatefulOutlineViewAutosaveTests.swift`

## 1. 动机（为什么做）

2026-08 侧边栏过滤重构（前述 sidebar-filter-pipeline 文档）之后，性能排查清单上还剩三个主线程热点，本次一并处理：

1. **Open Quickly 的 2×N eager 构建**：`SidebarRuntimeObjectListViewModel.reloadData` 在主线程为 Open Quickly 再 eager 构建一整套 `forOpenQuickly: true` 的 cell view model（图标 + 富文本标题 + 子树），与侧边栏那份合计 2×N。10k 行 debug 实测约 250 ms/次镜像加载——而多数会话根本不打开 Open Quickly。
2. **根侧边栏过滤全在主线程**：`SidebarRootViewModel` 每个 keystroke 在主线程对整棵镜像树做递归 `localizedCaseInsensitiveContains` 级联（首次还要在主线程递归拼接每个节点的聚合名）。shared cache 场景镜像树数千节点。
3. **`StatefulOutlineView` 展开持久化 O(n²)**：每收到一条 `itemDidExpand` / `itemDidCollapse` 通知就全行扫描 + 写一次 `UserDefaults`。option-点击展开大子树时每个条目一条通知，N 条通知 × O(N) 扫描 = O(N²)。

## 2. 范围（改了哪些部分）

| 文件 | 改动 |
|---|---|
| `Sidebar/SidebarRuntimeObjectCellViewModel.swift` | 新增静态纯函数 `haystack(for: RuntimeObject)`：不物化 cellVM 直接从值树算出与实例属性 `currentAndChildrenNames` 逐字节一致的 haystack（两边都按 `displayName` 排序子节点、单空格连接；高亮 range 的映射正确性依赖这一契约，有对拍测试钉死）。 |
| `Sidebar/SidebarRuntimeObjectListViewModel.swift` | 删除 `nodesForOpenQuickly`（全项目无外部使用者）。reload 只存排序好的 `[RuntimeObject]` 值数组；haystack 在首次查询时后台计算并按 reload 代次缓存；匹配后只为命中行物化 cellVM（`openQuicklyCellViewModelsByRowIndex` 按行号缓存、跨 keystroke 复用，DifferenceKit 行身份稳定）；清空只给已物化的行去高亮。类从 `final` 放开（测试需要 seeded 子类，与基类一致）。 |
| `Sidebar/SidebarRootCellViewModel.swift` | 删除 `filter` didSet 级联与 `currentAndChildrenNames` lazy 聚合名（双双失去唯一调用者）；新增 `unfilteredChildren` 与 `applyFilterOutcome(filteredChildren:)` 作为管线的主线程应用出口。 |
| `Sidebar/SidebarRootFilterPipeline.swift`（新增） | 三段式管线（snapshot 主线程 → verdicts 任意线程 → apply 主线程），逐层复刻旧级联语义：聚合名 contains 匹配、**自身名字命中则整棵子树不过滤**、否则按子树聚合名递归过滤。聚合名在 verdict 阶段后移到后台一趟 post-order 算完。空查询走同步 `resetToUnfiltered` 快路径（纯指针写）。 |
| `Sidebar/SidebarRootViewModel.swift` | keystroke 处理改为 `scheduleRootRefilter()`：取消前任 + 代次令牌 + 空查询同步复位 + 非空查询后台 verdict；`$nodes` 重建时作废在飞任务（视觉行为与旧版一致：镜像树重建时过滤复位）。 |
| `RuntimeViewerUI/AppKit/StatefulOutlineView.swift` | 通知处理改为 `scheduleExpansionPersist()`：一个 burst 只在下一个 main-queue turn 执行一次全行扫描 + 一次 UserDefaults 写入（前置条件在 flush 时重查）。新增 `package private(set) var expansionAutosavePersistCount` 作为回归测试 seam。view 释放时未 flush 的 burst 丢弃——展开状态本就是 best-effort UI 状态。 |
| `RuntimeViewerPackages/Package.swift` | 测试 target 增加 `RuntimeViewerUI` 依赖（`package` 可见性的 seam 需要同包 import）。 |
| 测试（3 个新套件 + 基建） | 见 §4。另有测试基建 `SharedLocalEngineTestLock.swift`：跨 suite 互斥锁 + 引擎启动屏障（见 §5 的意外发现）。 |

## 3. 关键设计与取舍

- **Open Quickly 的匹配对象从 cellVM 换成纯值 haystack**。匹配只需要字符串；cellVM 只有被显示的行才需要。物化成本从 reload 时 O(N) 主线程一次性支付，变为查询时 O(命中数) 增量支付且跨 keystroke 复用。最坏情况（宽 fuzzy 查询命中过万）单次仍会物化大量行——但那正是「用户真的要看这一万行」的场景，成本花在刀刃上，且退格收窄时全部复用。
- **haystack 双实现的字节级契约**。fuzzy 高亮 range 是相对纯值 haystack 计算的，物化后的 cellVM 又拿自己的 `currentAndChildrenNames` 做 range 映射——两边必须逐字节一致。静态函数与实例属性互相交叉引用注释 + `haystackParity` 测试钉死。
- **根侧边栏不复用 `SidebarRuntimeObjectFilterPipeline`**：两者语义不同（根侧边栏是「自身命中 → 子树全显」的目录树语义，运行时对象树是 scope 剪枝 + 模式化匹配语义），硬泛化会让两边都难读。管线骨架（三段式 + 代次令牌 + 形状校验）按同一模式各自实现。
- **聚合名后移到 verdict 阶段**：旧实现的 lazy 聚合名缓存在首次过滤时于主线程递归拼接整棵树。管线把聚合名和匹配放进同一趟后台 post-order 递归，主线程 snapshot 只抄节点名。相应地 cellVM 上的 lazy 聚合名属性删除，避免两套实现漂移。
- **Outline 持久化用「合并」而非「节流」**：burst 内第一条通知排队一次 flush，其余通知免费；flush 时重查全部前置条件（filter 状态可能在窗口内变化）。不用定时器——`DispatchQueue.main.async` 的下一 turn 就够，用户感知不到延迟，also 不引入取消管理。

**放弃的方案**：给 Open Quickly 上 `DifferentiableBox` 惰性 cellVM（CLAUDE.md §9 的三条件不满足——行有高亮状态，需要跨 keystroke 的订阅身份）；在后台构建 cellVM（`RuntimeObjectIcon` 的静态缓存无锁、只在主线程访问，后台构建会引入数据竞争换 250ms，不值）；给根侧边栏做高亮（旧版根侧边栏本就无高亮，本次不加行为）。

## 4. 结果与验证

- **回归测试**（3 个新套件，共 7 条，全部通过；全包 81 测试 4 连跑无 flake）：
  - `OpenQuicklyLazyConstruction`：haystack 字节级对拍；端到端——reload 物化 **0** 行（旧版此处已建满 N 行）、查询只物化命中行且全带高亮、重复查询复用同一批实例（`ObjectIdentifier` 集合相等）、清空去高亮但缓存保温、reload 全量作废。
  - `SidebarRootFilterPipeline`：管线输出与独立参考实现在 5 组查询（含目录段命中、全 miss）下逐行一致；空查询复位恢复全树；VM 端到端（150ms 合并窗 + 后台 verdict + 清空复位 + 不触发导航）。
  - `StatefulOutlineViewAutosave`：60 项 expand-all burst 同步阶段 0 次持久化、flush 后 ≤2 次全行扫描（旧版 60+ 次）、持久化集合正确；collapse 后增量持久化正确。
- **量级变化**（debug、与前文基线同机同 N 推算）：镜像加载的 Open Quickly 份额 ~250 ms → **0**（首次查询时后台补 haystack，一次性、不在主线程）；根侧边栏 keystroke 的主线程成本从「整树 ICU contains 级联」降为「snapshot 抄名 + apply 指针写」；outline 展开 burst 从 O(N²) 行访问 + N 次 defaults 写降为一次扫描 + 一次写。
- App 构建（sibling workspace，Catalyst helper → RuntimeViewer macOS）见任务输出：0 error / 0 warning。

## 5. 影响面与意外发现

- 行为语义不变：Open Quickly 的结果集与顺序（fuzzy 分数序）、根侧边栏的目录树过滤语义、outline 的持久化内容均有对拍/断言钉死。肉眼可见变化只有结果出现方式（后台化后异步出现）与持久化时机（burst 结束后一拍）。
- `SidebarRuntimeObjectListViewModel` 从 `final` 放开为可子类化（测试 seeding 需要，且与基类姿态一致）；`nodesForOpenQuickly` 属性删除（无外部使用者）。
- **意外发现（测试基建）**：swift-testing 跨 suite 并行 + 进程共享的 `RuntimeEngine.local` 会互扰——(a) 真引擎 `reloadData` 集成测试的 `.fullReload` 广播会命中并发 suite 里正在断言的缓存/seeded VM；(b) `RuntimeEngine.local` 首次 `connect()` 的 `observeRuntime()` 会经由非结构化 `Task` 在**任意时刻**补发一次启动 `.fullReload`。两者都是既有行为，此前 74 测试时靠调度运气没撞上，81 测试后撞上了。修复：`SharedLocalEngineTestLock.swift` 提供跨 suite 互斥锁（广播方与广播敏感方都持锁）+ 一次性启动屏障（等 image nodes 就绪 + 250ms 宽限）；`RuntimeInterfaceCacheTests` 以 async suite init 统一过屏障。**新增会订阅共享引擎数据变更的测试时必须遵循同一模式。**

## 6. 迁移 / 跟进注意事项

- 前文 sidebar 文档 §6 的跟进项 1（Open Quickly eager 构建）与 4（根侧边栏管线化）由本文落地；其余项（TypePicker debounce 对齐、fuzzy 高亮构建后台化）维持按测量再决定。
- `SidebarRuntimeObjectCellViewModel.haystack(for:)` 与 `currentAndChildrenNames` 的字节级契约：改任何一边的排序/连接规则必须同步另一边，并跑 `OpenQuicklyLazyConstruction` 套件。
- 启动 `.fullReload` 补发与广播的 `Task` 包裹（`RuntimeEngine.broadcast`）是产品代码的既有事实；如果未来它在 app 侧也造成可观测问题（例如启动早期的 UI 闪烁），修复点在引擎侧，不要在测试屏障上加码掩盖。
