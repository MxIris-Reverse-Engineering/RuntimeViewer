# Global Search 设计文档

- **日期**: 2026-07-26
- **状态**: 设计定稿,待实现
- **前置**:
  - 语料探针实测(本仓库 `feature/interface-corpus-probe` 分支,`RuntimeViewerCore/Sources/InterfaceCorpusProbe/`)
  - swift-semantic-string `FrozenSemanticString`(分支 `feature/flat-contents-storage`,docs/FrozenSemanticString.md)
  - node-store 迁移(内存腰斩 + per-image 索引释放路径,`removeSubIndexer`)

## 背景与动机

RuntimeViewer 目前只能在单个 image 的对象列表里按名字过滤(sidebar FilterEngine),
没有跨 image、深入 interface 正文的搜索能力。逆向工作流里高频出现的诉求:

- 找一个 selector / 属性名出现在哪些类里(声明、协议、category)
- 拿一个地址反查是哪个方法(IMP 地址注释)
- 搜某个 property attributes / offset / layout 注释片段

**范围界定(已确认)**:只搜**已索引的 image**(用户点开过的 + 后台索引批次完成的),
不做全 dyld shared cache 扫描;**支持注释搜索**(受 GenerationOptions 影响的
ivar offset / IMP 地址 / property attributes / field offset / layout 等注释)。

## 实测依据(探针,AppKit + SwiftUI,`.mcp` 全开选项,macOS 26 arm64)

| | AppKit | SwiftUI | 合计 |
|---|---|---|---|
| interface 数(含 children) | 4,194 | 6,839 | 11,033 |
| 纯文本语料 | 12.5 MB | 14.8 MB | **27.3 MB** |
| 注释占比 | 50.2% | 61.1% | 56.1% |
| 打印耗时(单线程) | 10.5 s | 120 s | 130 s |
| token 数 | — | — | 346 万(平均 7.9 B/token) |

关键结论:

1. **纯文本量级完全可承受**——最重的两个系统框架合计 27 MB,一般 session 的全量
   语料预计几十 MB。
2. **注释约占语料一半**——必须全开生成才搜得到,但绝对量不构成压力。
3. **瓶颈是打印耗时,不是内存**——SwiftUI 单 image 2 分钟(单线程),生成必须
   后台、增量、可取消。
4. **不能走 display 缓存路径**——探针经 `engine.interface(...)` 打印导致
   `RuntimeSwiftSection.interfaceByObject` 全量缓存,基线进程涨到 1.27 GB
   (O2 后 ~285 MB,但 display 缓存与语料职责必须分离,见下)。

## 核心设计

### 1. 语料形态:per-object `FrozenSemanticString`

语料条目直接驻留 `FrozenSemanticString`(text 一份 + 8 B/token span +
identifier 内插表),**不再做「纯文本 + 注释区间表」的降级形态**。理由:

- 内存 ≈ 2× 纯文本(AppKit + SwiftUI 量级 ~60 MB 上限),可承受;
- span 自带 `SemanticType`,搜索域过滤(排除注释 / 仅注释 / 仅符号)零额外结构;
- snippet 可按 span 语义着色渲染,结果列表质量与 content 视图一致;
- 免去维护第二种序列化/驻留格式。

被否决的替代:per-image 拼接大 blob + offset 表——扫描略快,但丢 span 信息、
增加拼接/偏移簿记,且 27 MB 量级下逐对象扫描的开销差异可忽略。

### 2. `RuntimeInterfaceCorpusStore`(新,RuntimeViewerCore,engine 侧 actor)

```
actor RuntimeInterfaceCorpusStore {
    struct Entry { let object: RuntimeObject; let interface: FrozenSemanticString }
    private var entriesByImagePath: [String: [Entry]]
    private var buildStateByImagePath: [String: BuildState]   // pending / building(progress) / built / failed
}
```

- 挂在 `RuntimeEngine` 上(lazy 属性,与 `backgroundIndexingManager` 同模式);
  **语料永远住在拥有 section 的进程里**,远程引擎场景下不过线。
- **驱逐**与 section 生命周期严格对齐:`removeSection(for:)` /
  `removeAllSections()` / `RuntimeEngine.stop()`(`releaseIndexedSections`)
  时同步清掉对应 image 的语料。node-store 分支刚打通的释放路径是现成挂载点。
- 设置总开关关闭时整体清空。

### 3. 语料生成:canonical 选项 + 旁路打印

- **canonical options 固定为 `GenerationOptions.mcp`**(全 strip 关、全注释开),
  与用户显示选项完全解耦——用户改显示选项不触发语料重建。
- Section 层新增**旁路打印路径**(Swift / ObjC 各一):用 canonical options 打印
  → `frozen()` → 返回;**不写 `interfaceByObject`、不动
  `lastTransformerConfiguration`**(避免污染 display 缓存或触发其驱逐逻辑)。
  ObjC 侧本就无缓存,只需选项旁路;Swift 侧要显式绕开。
- Engine 层 `_buildInterfaceCorpus(for imagePath:)`:枚举该 image 全部对象
  (含 children,与探针一致),逐对象旁路打印入 store;**逐对象响应
  `Task.checkCancellation`**;进度按 built/total 上报。

### 4. 生成时机:app 侧驱动,engine 侧执行

新增两个 `RuntimeEngineRequest`(按既有模式:`CommandNames` 加 case +
`registerSharedHandlers` 加一行,proxy 链自动透传):

- `BuildInterfaceCorpusRequest: RuntimeEngineProgressRequest`
  (`imagePath`;Progress = `(built: Int, total: Int)`;Response = 统计)
- `SearchInterfacesRequest: RuntimeEngineProgressRequest`(见 §5)

app 侧新增 `GlobalSearchCorpusCoordinator`(RuntimeViewerApplication,
`@MainActor`,与 `RuntimeBackgroundIndexingCoordinator` 平级、同样订阅
`documentState.$runtimeEngine` 换引擎重接):

- 触发源:
  1. `backgroundIndexingManager.events` 的 `.taskFinished(result: .completed)`
     → 该 image 排队;
  2. `imageDidLoadPublisher`(用户显式点开 image)→ 排队并置顶;
  3. 设置开关 off→on → 对所有已索引 image 补队。
- 队列串行(并发 1)、`.utility` 优先级——打印是分钟级重活,不与交互抢
  QoS;引擎切换/文档关闭时取消在途构建。
- 独立于背景索引 coordinator 的理由:背景索引管"让 image 有索引",语料管
  "让已索引 image 可搜",生命周期与取消语义都不同,揉在一起会把两套队列
  状态机搅在一处。

### 5. 搜索执行(engine 侧)

`SearchInterfacesRequest` 字段:

```
query: String
options: { caseSensitive: Bool, matchMode: contains | wholeWord,
           scope: all | excludeComments | commentsOnly | symbolsOnly }
resultLimit: Int        // 默认 1000,超限 truncated
```

- Progress = `[GlobalSearchMatch]` 增量批次(按 image 粒度推送,UI 边搜边出);
  Response = `GlobalSearchSummary`(总命中、扫描 image 数、truncated 标志、
  未建语料的已索引 image 列表——UI 据此提示覆盖率)。
- `GlobalSearchMatch`(Codable,过线的只有它,不含 Frozen 本体):

```
object: RuntimeObject
imagePath: String
lineNumber: Int
lineText: String            // 命中行截断 snippet
matchRangeInLine: Range     // UTF-16 offset,UI 高亮用
semanticKind: 枚举(comment / typeName / member / function / plainText …)
```

- **匹配算法**:对每个 entry 在 `frozen.text` 的 UTF-8 上做 ASCII case-folding
  子串扫描(非 ASCII 字节精确匹配);span 游标随扫描顺序推进,命中时 O(1) 取
  语义类别 → scope 过滤;行号/行文本由命中偏移向两侧找 `\n`。27 MB 全量扫
  预算 < 100 ms,取消检查按 entry 粒度。
- wholeWord 以标识符字符类([A-Za-z0-9_$])边界判定。
- 正则模式**不进 v1**(留 Phase 3;text 是现成 String,后续加 `Regex` 直搜即可)。

### 6. UI(MVVM-C,AppKit)

- `MainRoute` 新增 `globalSearch`;⇧⌘F 唤起。呈现为 document 窗口的
  **非模态辅助面板**(不用 sheet——搜索期间必须能浏览跳转)。
- `GlobalSearchViewModel`(RuntimeViewerApplication):
  - Input:searchString(debounce ~300 ms)/ scope / caseSensitive /
    resultSelected / resultOpenInNewTab / cancelClick
  - `@Observed private(set)`:结果(按 image 分组)、searchState
    (idle / searching / done(summary) / truncated)、corpusCoverage
    (已建语料 / 已索引 image 数,含"正在构建 SwiftUI (43%)"一类明细)
- 结果列表 `outlineView.rx.nodes`,image 组 → match 行;match 行 cell 显示
  着色 snippet + 命中高亮。命中可达千级,cell ViewModel 走
  `DifferentiableBox` lazy 模式(CLAUDE.md 表格规则 9 的适用场景)。
- **跳转**:选中结果 → `documentState.selectionRouter.trigger(.selectAtRoot(object))`
  (或 `.openInNewTab`);随后 content 内**二次定位**:把
  `(query, lineText, matchRangeInLine)` 作为 pending highlight 传给 content
  (经 documentState 一次性握手字段),content 渲染完成后在显示文本中定位并
  scroll + 闪烁高亮。
- **显示选项差异 fallback**:语料按全开生成,用户显示选项可能关掉了命中所在
  注释——二次定位 miss 时降级为:跳到对象 + find bar 预填 query,并提示
  "命中位于注释,受当前 Generation Options 影响未显示"。

### 7. 一致性与边界

- **注释地址是 per-run 的**(ASLR/attach):语料仅驻内存、跟随 engine 生命周期,
  v1 不落盘。未来若做磁盘持久化,必须剔除地址列或按 slide 归一化(已在探针
  阶段记录)。
- image 重新索引(卸载后再加载)→ removeSection 驱逐旧语料,索引完成事件
  重新排队构建,天然一致。
- 语料构建期间搜索:store 返回已建部分 + summary 报告缺口,UI 呈现覆盖率,
  不阻塞。
- `RuntimeObjectInterface` 已含 `FrozenSemanticString`(远程两端同版本要求
  已存在),本 feature 的 match 结构不传 Frozen,不新增版本耦合。
- 父/子对象 interface 内容可能有少量重叠(探针 child 部分占 17–31.5%),
  两处命中都如实报告(与 Xcode 行为一致),不做去重。

## 内存与性能预算

| 项 | 预算 | 依据 |
|---|---|---|
| 语料驻留(重度 session,~AppKit+SwiftUI 级) | ≤ ~60 MB | 27.3 MB 文本 × ~2(Frozen span 开销) |
| 单次全量搜索延迟 | < 100 ms + IPC | 27 MB 顺序扫描,arm64 GB/s 级 |
| 语料构建(后台,串行 .utility) | AppKit ~11 s、SwiftUI ~2 min | 探针实测,打印耗时持平于 display 路径 |
| 构建期间峰值增量 | 单对象级(旁路不缓存 SemanticString) | O1/O2 已消除装箱驻留 |

## 分阶段落地

- **Phase 1(Core)**:`RuntimeInterfaceCorpusStore` + 旁路打印路径 +
  `BuildInterfaceCorpusRequest` / `SearchInterfacesRequest` + 驱逐挂点。
  单测:构建/驱逐/重建;匹配正确性(大小写、wholeWord、scope 四档、行号/
  snippet/range);取消;limit/truncated;远程 dispatch 形态(local 即可覆盖协议面)。
- **Phase 2(App)**:`GlobalSearchCorpusCoordinator` + Settings 开关 +
  `GlobalSearchViewModel` / ViewController / `MainRoute.globalSearch` +
  跳转与二次定位。探针改造为 corpus builder 的 e2e 校验(语料字节与探针输出
  一致)。
- **Phase 3(后续,不阻塞 v1)**:结构化符号索引(声明模型直查、按 kind 精确
  过滤、地址精确反查 `RuntimeMemberAddress`)、正则匹配、语料磁盘持久化
  (image UUID 键,剔除地址列)。

## 待实现前确认的开放项

1. 辅助面板的具体呈现(独立 NSPanel vs 附着在 content 区的 find-navigator 式
   侧栏)——不影响 Core 层,Phase 2 动工前定。
2. 语料构建并发度:串行(推荐,SwiftUI 级 image 才 2 分钟)vs 并发 2——待
   Phase 1 落地后按实际体感调。
3. Settings 开关默认值:建议默认开(仅在已索引 image 上工作,增量成本与
   背景索引同源)。
