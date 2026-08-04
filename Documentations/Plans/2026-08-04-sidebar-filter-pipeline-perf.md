# Sidebar 过滤管线性能重构（didSet 守卫 + 后台匹配 + Open Quickly 竞态修复）

- **Status**: Implemented（本文档与代码同批落地）
- **Date**: 2026-08-04
- **Related**: `Documentations/Plans/specialization-typepicker-perf-r2.md`（同类问题在 TypePicker 上的先例）、`Documentations/Plans/2026-05-17-content-text-attributedstring-optimization.md`（内容区渲染管线，仍待批准，不在本次范围内）
- **Regression suite**: `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/SidebarFilterPerformanceBaselineTests.swift`

## 1. 动机（为什么做）

侧边栏（按镜像浏览运行时对象）的文本过滤在大镜像（dyld shared cache 中 10k+ 类型）上每个 keystroke 造成 **~3.5 秒主线程冻结**，零命中查询同样付全价。基线测量（debug 构建、Apple Silicon、N = 10,000，见回归测试套件的 `[baseline]` 输出）：

| 场景 | 修复前 | 标题重建次数（前） |
|---|---|---|
| contains 过滤（默认模式），任意命中数 | 3454–3654 ms | 10,000 |
| 清空搜索框 | 3763 ms | 20,000 |
| fuzzy 过滤（Open Quickly 配置），命中 100 | 4132 ms | 10,100 |
| 构建 10k 个 cellVM（镜像加载） | 3618 ms | — |
| VM 端到端一次搜索 | 3661 ms | — |

根因有四层，全部在主线程上叠加：

1. **每行两个无守卫的 didSet**：`FilterEngine.filter` 的复位循环对每个 item 触发 `filterResult = nil`，didSet 无条件重建 `NSAttributedString` 标题（nil→nil 也重建）；清空查询时该复位执行两遍（2N 次重建）。
2. **didSet 副作用级联**：`filter` 属性的 didSet 递归重过滤整棵子树，且每个节点每次级联都读一次 `appDefaults.filterMode`（`@Dependency` + `UserDefaults` 读取，实测约占 cellVM 构建成本的 90%——3618 ms 中约 3300 ms）。
3. **haystack 无缓存**：`currentAndChildrenNames` 每次访问递归拼接整棵子树的名字，一轮过滤每节点访问 1–3 次。
4. **"500 ms debounce" 从未生效**：`.just(pair).debounce(500ms)` 中 `just` 发出元素后立即 complete，而 RxSwift 的 `debounce` 在上游 complete 时立即冲刷挂起元素——所以每个 keystroke 都立刻同步执行全量过滤（端到端实测 64 ms 内出结果，证明无任何延迟发生过）。

另有两个顺带确认的正确性问题：

- **大小写分支反转**：`FilterEngine` 的 contains 分支写反了——`isCaseInsensitive == true` 用大小写敏感的 `contains`，`false` 反而用 `localizedCaseInsensitiveContains`。
- **Open Quickly 竞态**：搜索用无取消、无代次校验的 `Task.detached`，两次搜索可并发改写同一批 cellVM，且慢的旧查询可能后返回、覆盖新结果。

## 2. 范围（改了哪些部分）

全部在 `RuntimeViewerPackages/Sources/RuntimeViewerApplication` + AppKit 侧一行按钮默认值：

| 文件 | 改动 |
|---|---|
| `FilterEngine.swift` | 拆出纯函数核心 `FilterEngine.match(_:haystacks:) -> [FilterMatchVerdict]`（无副作用、线程安全、保序：fuzzy 按分数、contains 按输入序）；`filter/isCaseInsensitive/mode` 合并为 `FilterContext: Equatable`；变异式 `filter(context:items:)` 保留给单层调用（cellVM 局部路径），只在值变化时写回；**修正大小写分支**。 |
| `Sidebar/SidebarRuntimeObjectCellViewModel.swift` | `filterResult` didSet 加 nil→nil 守卫；`filterContext` 带判等守卫的 computed setter（局部级联入口）；`currentAndChildrenNames` 缓存 + `rebuildChildren`/`children` setter 时沿 parent 链向上失效；新增 `applyFilterOutcome(...)`（管线主线程应用出口，不触发级联）；`scope` 改为普通存储属性；删除 `applyScopeRecursively`。 |
| `Sidebar/SidebarRuntimeObjectFilterPipeline.swift`（新增） | 三段式管线：`snapshot`（主线程，值类型树，读缓存 haystack）→ `verdicts`（任意线程，逐层复刻旧级联语义，含协作取消）→ `apply`（主线程，形状不匹配时放弃而非错配应用）。 |
| `Sidebar/SidebarRuntimeObjectViewModel.swift` | `rebuildFilteredNodes` 替换为 `scheduleRefilter()`：取消前任 + 代次令牌 + 空查询同步快路径 + 非空查询后台匹配；`debounce` 改为 `delay(150ms)`（真正生效的合并窗口，flatMapLatest 负责取消）。 |
| `Sidebar/SidebarRuntimeObjectListViewModel.swift` | Open Quickly 的 `Task.detached` 替换为取消 + 代次守卫的 `scheduleOpenQuicklyRefilter`；`nodesForOpenQuickly` 重建时同步作废在飞搜索；debounce 500→150 ms；不再向永不显示的子级 cellVM 级联高亮。 |
| `Sidebar/SidebarRootViewModel.swift` | 同样的 `debounce`→`delay(150ms)` 修正（根侧边栏过滤本身仍在主线程，见 §6）。 |
| `RuntimeViewerUsingAppKit/.../SidebarRuntimeObjectViewController.swift` | 大小写按钮默认 `.on`：引擎修正反转逻辑后，保持默认行为（大小写不敏感）不变，且按钮高亮状态从此与实际行为一致。 |

## 3. 关键设计与取舍

- **匹配下后台、变异留主线程**。cellVM 同时被可见 cell 绑定、被 outline view 数据源在主线程读取，且 CLAUDE.md 规定 sidebar cellVM 必须保持 eager（持有过滤高亮与订阅身份）。因此与 TypePicker 方案的唯一结构差异是：后台只算"谁命中"（纯值快照 → verdict 树），所有 cellVM 写入回到主线程 apply 步骤，天然无竞争。
- **守卫让 apply 步骤 O(变化的高亮) 而非 O(节点)**。nil→nil 跳过是最大单项收益；contains 模式（默认）无高亮，keystroke 主线程成本降为 0 次标题重建。
- **代次令牌而非锁**。reload / splice / 新查询都发生在主线程同步块内并 bump 代次；旧任务的 apply 在其后到达主线程时发现代次不符直接丢弃。`apply` 再以形状校验兜底（不匹配则保留旧结果）。
- **`delay` 替代无效的 `debounce`，且窗口从 500 压到 150 ms**。匹配已后台化且可取消，不再需要保守窗口；空查询保持立即应用（清空不闪旧结果）。
- **逐层复刻旧排序语义**。verdict 递归在每一层调用与旧代码相同的匹配（fuzzy 分数序 / contains 输入序 / scope 先剪枝再匹配），有专门的对拍测试（`pipelineMatchesMutatingCascade`）保证管线与单层级联逐字节一致。
- **保留变异式 `FilterEngine.filter`**：specialization splice 路径需要同步重建单个节点的 `_filteredChildren`（`reloadRow` 信号发出时子级必须已就位），这条局部路径继续走带守卫的级联。

**放弃的方案**：lazy cellVM（`DifferentiableBox`）——CLAUDE.md 明确排除 sidebar；给 `DifferentiableBox` 加缓存——Evolution 0004 已裁决不做；把 `NSAttributedString` 构建也移下后台——当前唯一剩余的大额主线程转换（fuzzy 全命中↔清空，10k 次合法重建 ≈ 160-200 ms debug）只出现在 fuzzy 宽查询转换上，不值得为它破坏 cellVM 的主线程所有权模型（见 §6 跟进项）。

## 4. 结果（同一测试套件、同机、debug 构建）

| 场景 | 修复前 | 修复后 | 标题重建（前 → 后） |
|---|---|---|---|
| contains 过滤，全命中 | 3654 ms | **54 ms** | 10,000 → **0** |
| contains 过滤，命中 100 | 3561 ms | **62–69 ms** | 10,000 → **0** |
| contains 过滤，零命中 | 3454 ms | **64–81 ms** | 10,000 → **0** |
| 清空搜索 | 3763 ms | **17–20 ms** | 20,000 → **0** |
| fuzzy 命中 100 | 4132 ms | **331–423 ms** | 10,100 → **100** |
| fuzzy 全命中 | 4599 ms | **638–760 ms** | 20,000 → 10,000（合法：每行高亮真实变化） |
| fuzzy 清空 | 3565 ms | **159–204 ms** | 20,000 → 10,000（合法：逐行去高亮） |
| 树形 10k 节点 contains | 3652 ms | **112–138 ms** | 10,000 → **0** |
| 构建 10k cellVM | 3618 ms | **237–272 ms**（去掉了每节点的 UserDefaults 读取） | — |
| VM 种子 reload | 7429 ms | **227–293 ms** | — |
| VM 端到端一次搜索 | 3661 ms（同步冻结） | **250 ms**（含 150 ms 合并窗，主线程零冻结） | — |

且修复后所有耗时中的匹配部分都已移出主线程；上表 contains/fuzzy 行的数值是回归测试里同步调用变异式包装的量测值，真实 UI 路径只在主线程支付 apply 步骤。

## 5. 影响面

- 侧边栏搜索、scope 过滤、Open Quickly、根侧边栏搜索的行为语义不变（有对拍测试）；肉眼可见变化只有两个：结果出现的延迟由"冻结后一起出现"变为"150 ms 合并窗后异步出现"；大小写按钮默认高亮（行为与从前的默认一致）。
- iOS / Catalyst：改动全部平台中立，`Input`/`Output`/public API 无变化。
- `FilterableItem` / `FilterEngine` 是 internal API，唯一 conformer 是 `SidebarRuntimeObjectCellViewModel`，无外部波及。

## 6. 迁移 / 跟进注意事项

- **回归断言已翻转**：`SidebarFilterPerformanceBaselineTests` 现在钉死"keystroke 只允许重建高亮真实变化的行"。任何让计数回升的改动都会被测试抓住。
- **跟进（未做，按测量再决定）**：
  1. Open Quickly 的 `nodesForOpenQuickly` 仍在主线程 eager 构建第二份 N 个 cellVM（现约 250 ms/10k，debug）；如需进一步压缩镜像加载时间，考虑延迟构建或复用 sidebar 那份。
  2. TypePicker 的 debounce 仍是 500 ms（真 debounce，生效中）；如要与 sidebar 的 150 ms 手感对齐，单独一行改动。
  3. fuzzy 宽查询 ↔ 清空的 10k 次合法高亮重建（~200 ms debug）如成为可感知瓶颈，方案是把高亮 `NSAttributedString` 构建挪进 verdict 阶段（后台），apply 只做赋值——需要先给 cellVM 的 title 通道设计后台构建协议，勿轻做。
  4. 根侧边栏（`SidebarRootViewModel`）过滤仍在主线程（量级小 + 有缓存 + 本次修好了合并窗口）；如 shared cache 镜像树继续膨胀，可复用本管线。
  5. 内容区渲染管线优化（2026-05-17 计划的 PR1/PR2）仍待批准，与本次无关但同属"流畅度卖点"主线。
