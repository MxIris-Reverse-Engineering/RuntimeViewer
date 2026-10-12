---
reviewed_file: Documentations/Plans/2026-07-26-global-search-design.md
reviewed_at: 2026-07-27
reviewer_model: claude-fable-5
doc_type: spec
extra_instructions: (none)
critical_count: 0
should_fix_count: 7
suggestion_count: 2
---

## 📄 文档信息

- **路径**: `Documentations/Plans/2026-07-26-global-search-design.md`
- **类型**: spec
- **文档行数**: 211
- **审查日期**: 2026-07-27

---

### 🔴 Critical (0)

(无)

---

### 🟡 Should Fix (7)

**1.** [D 可行性] `line 97–108` — 多 document 共享 `.local` engine 的取消/排队语义未定义
> 文档规定 coordinator 为 app 侧 per-document 组件（"与 `RuntimeBackgroundIndexingCoordinator` 平级、同样订阅 `documentState.$runtimeEngine`"），并要求"引擎切换/文档关闭时取消在途构建"。但语料 store 挂在 engine 上，而 `RuntimeEngine.swift:91` 为 `public static let local: RuntimeEngine`——进程级共享单例。具体失败路径：文档 A 关闭时取消共享 engine 上在建的 SwiftUI 语料（2 分钟级），仍打开的文档 B 覆盖率静默受损；设置 off→on 时每个 document 的 coordinator 各自"对所有已索引 image 补队"，产生重复构建。
> 建议: 明确 corpus 构建的取消归属（engine 侧引用计数或仅当最后一个 document 关闭时取消），并说明 `buildStateByImagePath` 是否用于跨 document 去重。

**2.** [D 可行性] `line 101–103, 184` — 语料驻留与构建总时长无总量上限
> 触发源 1 规定"`backgroundIndexingManager.events` 的 `.taskFinished(result: .completed)` → 该 image 排队"——每个后台索引完成的 image 都自动建语料；而预算表仅按两个框架给出"语料驻留(重度 session,~AppKit+SwiftUI 级) ≤ ~60 MB"。后台索引的 always-index 列表由用户配置（`RuntimeBackgroundIndexingCoordinator.swift` 中 `Settings.Indexing.AlwaysIndexEntry` 列表），配置数十个框架时驻留内存与串行构建总时长（SwiftUI 级单个 ~2 min）线性膨胀，文档没有上限、LRU 或降级策略——与本设计前置的"node-store 迁移(内存腰斩)"目标相悖。
> 建议: 增加总量上限或按 LRU 驱逐策略，至少在预算表补充多 image session 的推算。

**3.** [C 歧义] `line 120–124` — `resultLimit` 截断语义两可
> "`resultLimit: Int // 默认 1000,超限 truncated`"与 summary 字段"总命中、扫描 image 数、truncated 标志"并存，允许两种实现：(1) 扫描在收集满 1000 条后即停止，"总命中"= 1000（UI 只能显示 "1000+"）；(2) 扫描继续只计数不收集，"总命中"= 真实总数（UI 可显示 "共 34,027 条,展示 1000 条"）。两者的扫描成本与 UI 呈现都不同，且未说明 limit 是全局还是 per-image。
> 建议: 明确 truncated 后是否继续计数,以及 limit 的作用域。

**4.** [C 歧义] `line 157–161` — 二次定位的匹配算法未指定
> "把 `(query, lineText, matchRangeInLine)` 作为 pending highlight 传给 content……content 渲染完成后在显示文本中定位并 scroll + 闪烁高亮"。"定位"存在两种解读：(1) 在显示文本中查找 `lineText` 整行，再套用 `matchRangeInLine` 高亮；(2) 直接查找 `query`。当 `query` 在显示文本中多次出现（如搜 `init`），或 `lineText` 因用户 Transformer/strip 选项与 canonical 渲染不同而整行不一致时，两种解读产生不同结果；文档只定义了完全 miss 的 fallback（line 162–165），未定义多命中/部分匹配时选哪一处。
> 建议: 写明定位优先级（先整行匹配、失败再退 query 首个命中之类）。

**5.** [C 歧义] `line 118–119, 134–135` — scope 档位到 `SemanticType` 的映射未定义
> scope 有"`all | excludeComments | commentsOnly | symbolsOnly`"四档，而 `semanticKind` 仅给出"枚举(comment / typeName / member / function / plainText …)"——以"…"收尾的开放枚举。`symbolsOnly` 至少有两种解读：仅 typeName/member/function 等标识符类，或"除 comment 与 plainText 之外的全部"（含 keyword、数字字面量等）。Phase 1 单测列了"scope 四档"，但没有映射表就无法写出确定的断言。
> 建议: 给出 SemanticType → 四档 scope 的完整映射表,并补全 semanticKind 枚举。

**6.** [A 完整性] `line 65` — `BuildState.failed` 之后的行为未定义
> store 状态机含"`pending / building(progress) / built / failed`"，但全文没有 failed 之后的策略：是否自动重试、下次触发源事件是否重新排队、UI 覆盖率明细如何呈现（line 152–153 只描述了"正在构建 SwiftUI (43%)"一类构建中明细）。2 分钟级构建被取消或个别对象打印抛错是常态场景，缺失该定义会让 Phase 1 的"构建/驱逐/重建"单测无从断言 failed 分支。
> 建议: 定义 failed 的重试触发条件与 summary/覆盖率中的呈现方式。

**7.** [D 可行性] `line 78–79, 162–164` — canonical 与用户 Transformer 的语义分叉未处理
> "canonical options 固定为 `GenerationOptions.mcp`……与用户显示选项完全解耦——用户改显示选项不触发语料重建"。经核实 `.mcp` 的 `transformer` 字段落在 `@Default(Transformer.Configuration.default)`（`RuntimeObjectInterface+GenerationOptions.swift:14,19`）——固定默认值；而显示端经 `ContentTextViewModel` 送入的是用户自定义的 `settings.transformer`。用户自定义 Transformer 后：照屏幕文本搜索会 miss（语料是默认格式）；`Transformer.CType` 还改写声明正文的 C 类型拼写与语义类型（`ObjCDump+SemanticString.swift:497` 起，`Keyword` → `TypeName`），波及 `symbolsOnly` / `excludeComments` 域；二次定位整行匹配必 miss，且 fallback 文案"命中位于注释……未显示"在内容实际显示、仅格式不同时构成误导。文档 §3 仅处理了"不污染 display 缓存"（`lastTransformerConfiguration`），未处理该语义分叉。
> 建议: 明确取舍——canonical 跟随用户 transformer 并把 Transformer 设置变更列为驱逐重建触发源（推荐），或保持固定默认但在文档/搜索 UI 中声明"搜索基于默认渲染"并修正 fallback 文案。

---

### 🔵 Suggestion (2)

**1.** [F 验收] `line 180–198` — 预算表给出 <100 ms / ≤60 MB 量化指标，但 Phase 1/2 测试清单全为正确性项，未安排任何性能验证手段（signpost 基线或 perf test）。

**2.** [G 代码一致性] `line 94` — "Progress = `(built: Int, total: Int)`" 为 tuple 记法，而 `RuntimeEngineRequest.swift:51` 要求 `associatedtype Progress: Codable & Sendable`，Swift tuple 不满足 Codable，实现时需落为具名 struct（文档可先行注明以免照抄）。

---

### ✅ Strength (3)

- 代码引用准确率极高：文档引用的约 20 个标识符/路径逐一核实全部存在且语义吻合——`GenerationOptions.mcp` 的"全 strip 关、全注释开"与实际定义逐项一致，`.taskFinished(result: .completed)` 与 `RuntimeIndexingEvent` 实际 case 形态一致，`imageDidLoadPublisher` "用户显式点开"的语义与代码注释（后台索引不触发该 publisher）一致。
- 预算数字与实测数据自洽：27.3 MB 文本 × 2 ≈ 60 MB 上限、346 万 token × 8 B/token ≈ 27.7 MB span 开销，交叉验算无矛盾。
- 范围治理良好：范围界定前置声明、三阶段落地、正则等延后项显式归入 Phase 3、待定项单列于"开放项"而非隐藏 TBD。

---

### 📊 摘要

| 严重程度 | 数量 |
|---------|------|
| 🔴 Critical | 0 |
| 🟡 Should Fix | 7 |
| 🔵 Suggestion | 2 |
| ✅ Strength | 3 |

**维度分布**:
- A 完整性: 1    B 一致性: 0    C 歧义: 3    D 可行性: 3
- E Scope: 0    F 验收: 1    G 代码一致性: 1    H 结构: 0

---

### 已淘汰候选 (Dropped Candidates)

- [G] `docs/FrozenSemanticString.md` 疑似不存在 — 淘汰原因: 经 `git show feature/flat-contents-storage:docs/FrozenSemanticString.md` 验证在文档所指分支上存在。
- [G] "ObjC 侧本就无缓存"疑似不实 — 淘汰原因: 核实 `RuntimeObjCSection` 仅缓存 section 对象、无 per-object interface 缓存（`interfaceByObject` 仅存在于 `RuntimeSwiftSection`），文档表述准确。
- [B] 打印耗时两处数字（10.5 s/120 s vs ~11 s/~2 min）疑似不一致 — 淘汰原因: 复读后为同一数据的取整表述，非矛盾。
- [C] `matchRangeInLine: Range` 未写元素类型 — 淘汰原因: 行内注释已限定"UTF-16 offset"，语义只有一种解读，具体 Swift 类型属实现细节。
- [C] 非 ASCII 查询不做大小写折叠 — 淘汰原因: 文档已明示"非 ASCII 字节精确匹配"，行为已定义而非歧义。
- [D] UTF-8 扫描偏移转 UTF-16 需转码 — 淘汰原因: 常规实现细节，给不出具体失败场景。
- [A] Settings 开关在 RuntimeViewerSettings 中的键位未写 — 淘汰原因: Phase 2 已列"Settings 开关"、开放项 3 已覆盖默认值，剩余属实现细节。
- [E] Phase 3 项目（正则/持久化/结构化索引）over-scope — 淘汰原因: 已显式标记"后续,不阻塞 v1"，在文档自身的范围治理之内。
- [F] "缺少验收标准" — 淘汰原因: Phase 1/2 已列出覆盖构建/驱逐/匹配/取消/limit 的单测与 e2e 清单；仅性能项缺验证手段，已降为 🔵。
