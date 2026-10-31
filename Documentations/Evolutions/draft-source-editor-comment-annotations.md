# Draft - SourceEditor 内容面板：注释画成标签，字段偏移树与枚举布局可折叠

- **状态**: In Progress
- **创建日期**: 2026-10-31
- **最后更新**: 2026-10-31
- **所属愿景**: [自建代码视图引擎](../Visions/CodeViewEngine.md)
- **关联提案**: [0009](0009-content-editor-engine-selection.md)（接入 SourceEditor）；上游三篇见「方案 · 一」
- **实现分支 / PR**: `feature/source-editor-comment-annotations`（worktree `.worktrees/RuntimeViewer-SourceEditorCommentAnnotations`）

## 摘要

内容面板用 Xcode 的 SourceEditor 显示时（Settings › Editor 打开 SourceEditor），生成器输出的注释——
地址、VTable / PWT / 字段偏移、Type Layout、ObjC 的 IMP 与 ivar 偏移、各种说明——不再是一行行灰色
注释，而是画成 Xcode 式的圆角标签：`//`、`/* */` 和标点不显示，标签名与数值分色，多字段的拆成几个
相邻标签。Swift 的字段偏移树（`// Field offset: 0x8` 下面那串 `├──` 行）变成可折叠的大纲，默认只剩
根那一行；枚举布局的摘要拆成一排标签，每个 case 的说明块默认收起到 Case 那一行。`NSTextView` 那条
路径不变。

注释的结构由生成器在打印时标出，RuntimeViewer 不解析注释文本。为此 swift-semantic-string、
MachOSwiftSection、MachOObjCSection 各有一篇配套改动，已交给三个仓库各自的会话去做。

## 方案

### 一、结构从生成器来（上游三篇）

- **swift-semantic-string**：新增一种区域组件（仿 `VisibilityRegion` / `DefinitionRegion`），标记写在
  原子的 identifier 上，文本一个字节不变；冻结后分离出干净文本和一张表（UTF-8 范围、kind、属性、
  深度、外层区域）。相邻的同 kind 区域要能分开，与另外两种区域按任意顺序嵌套共存。
- **MachOSwiftSection、MachOObjCSection**：打印配置各加一个默认关的开关，开着时给每条注释包上区域，
  标出种类和段的角色。种类的起点清单：memberAddress、vtableOffset、pwtOffset、fieldOffset、
  fieldOffsetUnknown、fieldLayoutNode、typeLayout、enumLayoutSummary、enumLayoutCase（及其
  Header / Encoding / Note / FixedBytes / Byte 子区域）、spareBits、exportStatus、deletedMethodSlot、
  ambiguousAttribution、privateDeclarationSource、protocolExtensionDefault；ObjC 的 impAddress、
  ivarOffset、propertySynthesis、propertyDynamic、typeNote；其余说明性注释为 note。段的角色：
  marker、label、qualifier、separator、key、value、name、type、treePrefix、text。
- 字段偏移树的每个节点区域覆盖它自己和全部后代的行，嵌套即树；枚举逐 case 的多行注释按行拆开。
- 最终的 kind / role 清单以两个生产方回报的为准，上游三篇的链接与清单在它们落地后补进本节。

### 二、Core：引擎负责分离，表随 interface 一起走

- 内容面板请求 interface 时多带一个内部生成选项：不出现在 Generation Options 弹窗里，只在
  SourceEditor 与标签开关都打开时为真。`RuntimeSwiftSection` / `RuntimeObjCSection` 据此打开打印器
  的开关。
- 引擎打印后立即分离。`RuntimeObjectInterface` 多一个可选字段带上注释表，`interfaceString` 本身与
  今天逐字节相同，所以导出、Find、CLI、MCP 和 `NSTextView` 面板都看不到任何区别。对端是旧版本、
  不认识这个字段时为 nil，面板退回今天的样子；`RuntimeObjectInterfaceWireCompatibilityTests` 补一条。
- 这个选项进了 interface cache 的键，两种面板各自缓存，互不影响。

### 三、App：把注释表变成「装饰」

- `ContentTextViewModel` 的 `RenderedInterface` 多带一份装饰描述，在渲染流水线的后台调度器上由注释
  表算出：UTF-8 换算成 UTF-16 范围；每个标签的可见段与要藏的段；大纲节点所在的行与子树末行；每个
  case 说明块的折叠范围；默认收起的范围。逻辑放在 `RuntimeViewerApplication`，用 fixture 打印出的
  表做单元测试。
- `ContentSourceEditorViewController` 把装饰交给 bridge。`SourceEditorBridging` 只传 `NSValue`、
  `NSNumber`、`NSString` 的数组：这份文件同时编进 App 与 bundle，在里面定义类会在 Objective-C 运行
  时里出现两份同名类。

### 四、Bridge：一个装饰控制器，几种框架扩展点

新增 `CommentDecorationController`，每次换 source 时整体替换。下表的依据都来自 Xcode 27.2（27B52，
SourceEditor UUID `6E5DBC54-96DD-3101-A63E-CDCE9E3B0572`）的反编译，地址取自
`/Volumes/RE/SourceEditor/Xcode/27.2/` 下的导出：

| 要做的事 | 用的扩展点 | 依据 |
|---|---|---|
| 藏起 `// `、`/* */`、标点和树形前缀 | `HiddenTextOverrideProvider` | `processedLineRenderData`（0x22F8C4）把可见列拼成新串，所以隐藏的列收拢、不留空；只在建行图层（`makeLineLayer`，0x22F3D4）时求值，变化要驱逐行图层才生效；所有回答都是 `[]` 等于整行照常显示，要全藏得回答 `[0..<0]`；复制走未隐藏的行数据（`attributedString(for:context:)`，0x39E24C），复制出的是原文 |
| 标签内边距、大纲缩进 | `ColumnShiftOverrideProvider` | `columnShiftsForLine`（0x231700）把 `[列: 点数]` 变成相对位移，`CoreTextLineLayout.layout`（0xEF74）在这些列把文本切成片段；折叠的「…」就靠它让位（`FoldedRegionDisplay.columnShiftEffectsForLine`，0xD0758） |
| 标签名、数值分色 | `TextAttributeOverrideProvider` | 属性原样 `addAttributes:range:`（0x22B5F8）交给 CoreText；列范围越过行长直接 `fatalError`（0009 已记） |
| 圆角底 | 自己的一个 `LayoutVisualization`；图层用 `SourceEditorRangeHighlightLayer`，放进 `contentView.underlayLayer`，矩形取 `contentView.selectionRects(for:coalesceInteriorRects:includeLineSpacing:)` | 三个钩子在每个布局 pass 都会回调（`layoutContentView`，0x21B7E8）；框架自己的 `RangeHighlightLayoutVisualization` 就是这样画的（0x8A13C / 0x8AC34）。图层的形状与圆角没有导出的 setter，只能用默认的 `.token` 与 4pt 圆角（`init()`，0x254528）；要别的形状就自己画 `CAShapeLayer` |
| 收起大纲节点和 case 说明块 | `FoldingController.fold(_:animate:completion:)` / `unfold(_:restoreNestedFolds:animate:)` | 任意范围都能折，`fold(ranges:)`（0xDA140）不查 `foldableRanges`；`fold(lineRanges:)` 会把首行一起藏掉，所以从「节点行的行末」折到「子树末行的行末」；被折那行的行尾必定出现「…」块（`makeEllipsisLayer`，0xD0454；单击选中、双击展开），没找到关掉它的开关；`stateDictionaryForSaving` / `restore(from:)`（0xDD7A4 / 0xDDC08）会带上这些折叠，现有的 `FoldStateCache` 照常记住 |
| 点 ▸ 展开、收起 | `SourceEditorViewEventConsumer` | `mouseDown(with:)`（0x328208）先逐个问 consumer，命中即止；`positionAtPoint`（0x434E8C） |

- **不用 `SourceEditorRangeHighlightController.highlight`**：每个高亮都注册一个 visualization 和一个
  属性 provider，每个布局 pass 逐个回调（0x8C388 起），几千条注释撑不住。圆角底由一个 visualization
  统一画，只画可见行（以 `sourceRangeForVisibleLinesIn(rect:inContentView:)` 为界），图层用池复用。
- 默认收起：一份 source 第一次出现、`FoldStateCache` 里没有它时，收起每棵字段偏移树的根和每个 case
  说明块；有记录就按记录恢复。
- 颜色取自主题：底色是注释色加透明度，标签名用注释色，数值用数字色，跟随明暗外观。
- 上面用到的接口在 26.6 与 27.2 都已导出（两版的 `nm -gU` 对照过），`Stubs/` 补的声明以 27.2 的导出
  为准，照 `Stubs/README.md` 的流程重算 `.tbd`。
- 顺带发现：bridge 里 `applyTextLeadingMargin` 的注释说 `SourceEditorLayoutManager.invalidateAllLayout()`
  没有可链接的导出符号，实际 26.6 与 27.2 都导出了它。与本提案无关，另行处理。

### 五、设置

Settings › Editor 加一个「Comment Tags」开关，默认开。关掉就是今天的样子：bridge 撤掉全部 provider
与图层，引擎也不再标注。

### 六、验证

- 单元测试：装饰描述（App 侧）；隐藏列、位移、默认收起，以及带着这些折叠换 source（bridge 测试
  bundle，离屏即可，0009 已证明可行）。
- `Stubs/VerifyAcrossXcodes.sh` 补调新接口，26.6 与 27.x 各起一个进程跑。
- 反编译没定下来的几件事，实现前写运行时探针确认，探针先给用户看再跑：隐藏列里的插入点、选区与
  ⌘-click；同一行的多个位移是否叠加；行图层缓存超过 10001 个时整体驱逐（`layoutContentView` 里），
  3 万行的文档会不会因此频繁重建。
- 颜色与观感以实机截图为准，离屏不判颜色（0009 的老规矩）。

### 没有询问就采用的假设

- 只做 SourceEditor 面板，`NSTextView` 不动；Swift 与 ObjC 都做。
- 复制、⌘F 查找和 Find 导航都按原文；大纲点 ▸ 展开一层，按住 ⌥ 点展开整棵。
- 说明性的长注释（Evidence 之类）同样画成一个标签，不另设样式。
- 打开 Print Exported Declarations Only 时 App 自己写的两行提示，也作为 note 标签显示。
- 对端是旧版本、拿不到注释表时静默退回今天的样子，不提示。

## 落地步骤

每一步单独构建通过、测试通过后提交。

1. **Stub 与框架行为测试。**（已完成）`Stubs/` 补上要用的声明：`HiddenTextOverrideProvider`、
   `ColumnShiftOverrideProvider`、`LayoutVisualization`，`SourceEditorLayoutManager` 的注册、驱逐与
   可见范围方法，`SourceEditorContentView` 的 `underlayLayer`、`layoutBounds`、`selectionRects`，
   `SourceEditorLineLayer`、`SourceEditorTextSelectionRect`，`FoldingController` 的按范围折叠与展开；
   照 `Stubs/README.md` 重算 `.tbd`。bridge 测试 bundle 新增 `SourceEditorOverlayBehaviorTests`，在
   Xcode 27.2 上钉住了反编译没定下来的几件事，8 个测试全部通过：
   - 隐藏的列收拢；回答 `[]` 等于整行照常显示，`[0..<0]` 才是全藏。
   - 属性覆盖与列位移都按**原文的列号**计，隐藏了前面的列也不用换算。
   - 同一行的多个位移叠加：第 3 列 20 点、第 10 列 10 点，第 12 列共移 30 点。
   - 任意一段 `//` 行都能折，从首行行末折起首行保持原样；先折内层再折外层，展开外层时带
     `restoreNestedFolds: true` 内层仍是折着的。
   - 顺带踩到的：`evictLineLayersForLineRange` 的范围越过文档末行是 `fatalError`
     （`SourceEditorDataSource`：「Invalid line 3 of 3」），不是空操作。
2. **Bridge 装饰控制器。** `CommentDecorationController`：隐藏列、位移、分色、圆角底、点 ▸ 收放、
   默认收起，以及它与 `FoldStateCache`、换 source 时先展开全部折叠的配合；`SourceEditorBridging`
   新增传装饰的入口。测试覆盖每一项。
3. **App 侧。** RuntimeViewerCore 定义注释表的线上模型（`RuntimeObjectInterface` 的可选字段，补线上
   兼容测试）；RuntimeViewerApplication 由它算出装饰描述（测试用手写的表）；
   `ContentSourceEditorViewController` 接上；Settings › Editor 加 Comment Tags 开关。
4. **接上上游。** 依赖上游三篇落地：内部生成选项、打开打印器开关、引擎分离后填进线上模型、抬 pin、
   用 fixture 做端到端测试；最终的 kind / role 清单补进「方案 · 一」。
5. **收尾。** `Stubs/VerifyAcrossXcodes.sh` 补调新接口；0009 的决策日志记一行指向本提案；实机截图
   核对颜色与观感。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-31 | Created as Draft | 用户希望 SourceEditor 面板里的注释有标签效果，字段偏移树能折叠展开，枚举布局也整理一下。 |
| 2026-10-31 | 注释结构由生成器输出，App 侧不解析注释文本 | 用户在两者之间选了生成器输出：打印器本来就知道每条注释是什么，App 再按文本格式反推一遍是重复劳动，用户开了 Transformer 自定义模板时还会认不出。代价是要改三个上游仓库，已交给三个仓库各自的会话。这也是愿景「语义由生成侧直供」的一次落实。 |
| 2026-10-31 | 标签藏起注释符号与标点，多字段的拆成多个 | 用户选定。反编译确认隐藏的列会收拢，不会留出空白。 |
| 2026-10-31 | 字段偏移树默认收起到根 | 用户选定。收起用框架自己的 `FoldingController`，被折那行的行尾总有「…」块，用户知情。 |
| 2026-10-31 | 枚举布局：标签加折叠 | 用户选定。另一个方案「字节网格」要在两行之间画一张表，需要还没验证过的框架能力，这次不做。 |
| 2026-10-31 | 圆角底自己画，不用 `SourceEditorRangeHighlightController` | 它每个高亮注册一个 visualization 和一个属性 provider，每个布局 pass 都逐个回调，几千条注释撑不住。 |
| 2026-10-31 | 用户批准，开始实现 | 状态改 Accepted，补上落地步骤。 |
| 2026-10-31 | 反编译没定下来的行为改用 bridge 测试 bundle 里的测试确认，不另写探针脚本 | 测试同样能回答这些问题，而且作为回归测试一直留着；离屏驱动 bridge 的测试 0009 已证明可行。 |
| 2026-10-31 | 第 4 步依赖上游三篇，先做 1–3、5 | 上游的 API 还没定稿；App 侧的线上模型由 RuntimeViewer 自己定义，第 4 步只写把上游的表换算进来的那一层。功能分支从本地 `next` 切出，它比远端多 7 个「只看导出的 Swift 声明」的提交（已在远端功能分支上），两条线都改了内容面板，叠在上面可以少一次冲突。 |
| 2026-10-31 | 第 1 步完成，状态改 In Progress | 行为测试的结论见「落地步骤 · 1」。bridge 测试 bundle 的基线本来就有 2 个失败（`SourceEditorScrollerTests`）：8f3414e0 有意关掉了滚动条自动隐藏，测试没跟着改，与本提案无关，不在这条分支上修。 |
