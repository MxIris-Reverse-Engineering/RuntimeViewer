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
  标出种类和段的角色。
- 字段偏移树的每个节点区域覆盖它自己和全部后代的行，嵌套即树；枚举逐 case 的多行注释按行拆开。

上游三篇（2026-10-31 都已实现，见决策日志里各自的状态）：

| 仓库 | 提案 | 给出的接口 |
|------|------|------------|
| swift-semantic-string | `docs/AnnotationRegions.md` | `AnnotationRegion` / `AnnotationSegment` 两种组件；`FrozenSemanticString.separatingAnnotationRegions()` 返回干净文本和 `AnnotationRegionTable` |
| MachOSwiftSection | `draft-comment-structure.md` | `SwiftDeclarationPrintConfiguration.marksCommentStructure` |
| MachOObjCSection | `draft-objc-comment-structure-marking.md` | `ObjCInterfaceBuilder(indexer:machO:marksCommentStructure:)` |

最终的清单，即 `RuntimeInterfaceCommentStructure` 里的常量：

- **Swift 的 kind**：memberAddress、vtableOffset、pwtOffset、fieldOffset、fieldOffsetUnknown、
  fieldLayoutNode、typeLayout、typeLayoutElement、enumLayoutSummary、enumLayoutCase 及其 Header /
  Encoding / Note / FixedBytes / Byte 子区域、exportStatus、protocolExtensionDefault、
  privateDeclarationSource、conditionalWitness、conditionalWitnessBranch、strippedSymbolicRequirement。
- **ObjC 的 kind**：impAddress、ivarOffset、ivarOffsetUnknown、propertySynthesis、propertyDynamic、
  typeNote。
- 其余说明性注释都是 swift-semantic-string 自带的 **note**。
- **段的角色**：marker、label、qualifier、separator、key、value、name、type、treePrefix、text。
- 区域的范围裁掉首尾空白；`fieldOffset` 包住整棵树，每个 `fieldLayoutNode` 包住它自己和全部后代的行；
  相邻的同 kind 区域各是各的；续行的对齐空格算在 marker 里。用户装了 Transformer 模板的注释整条只有
  一个 text 段，枚举 case 块只剩 `enumLayoutCase` 一层。

### 二、Core：引擎负责分离，表随 interface 一起走

- 内容面板请求 interface 时多带一个内部生成选项 `GenerationOptions.marksCommentStructure`：不出现在
  Generation Options 弹窗里，只在 SourceEditor 与标签开关都打开时为真（`Settings.Editor.drawsCommentTags`）。
  它放在外层的 `GenerationOptions`，不进 Swift / ObjC 两组选项：一个开关管两种语言，用户设的那两组和
  Find 读语料用的映射（`applySwitches(of:)`）都不受影响。存下来的值永远是默认的 false，MCP 与 CLI
  也不打开它。
- `RuntimeSwiftSection` 把它写进打印配置；配置一变 section 自己的 interface 缓存就清空，和其余选项
  一样，带注释表和不带的不会互相顶替。`RuntimeObjCSection` 交给 `ObjCInterfaceBuilder`。Find 语料
  用的另一台打印器不打开它。
- 引擎打印后立即分离（`RuntimeObjectInterface(object:markedInterfaceString:)`）：上游的表按名字换算
  成 `RuntimeInterfaceCommentStructure`，不属于任何区域的段丢掉。`interfaceString` 本身与今天逐字节
  相同，所以导出、Find、CLI、MCP 和 `NSTextView` 面板都看不到任何区别。对端是旧版本、不认识这个
  选项或字段时为 nil，面板退回今天的样子。
- 这个选项进了 interface cache 的键，两种面板各自缓存，互不影响。`currentMergedGenerationOptions`
  与内容面板的取数一半按同一个判断设它，点链接时预热的缓存项正好是跳过去后要取的那一项。打开或关掉
  标签时取数重来一遍，`ContentSourceEditorViewController` 不再自己重发同一份 source；它在下发前仍按
  开关把关，开关刚关、关之前发出的请求才回来时不会把装饰带上去。

### 三、App：把注释表变成「装饰」

- `ContentTextViewModel` 的 `RenderedInterface` 多带一份装饰描述（`InterfaceCommentDecorations`），在
  渲染流水线的后台调度器上由注释表算出，逻辑放在 `RuntimeViewerApplication`。规则按段的角色定：
  - **藏**：开头的 `//`、`/*` 和它后面一个空格（续行多出来的对齐空格留着，case 块的各行因此仍缩在
    头行下面），结尾的 ` */` 整个藏；separator 里的语法标点（`:`、括号、`,`、`;`、反引号、`—`、`#`）
    藏掉，剩下的若全是空白只留一个空格。`=`、`..<` 这类有意思的符号留着。
  - **着色**：label、key、qualifier 用标签名的颜色，value 用数值色，type、name 各用自己的颜色，正文
    保持注释色；treePrefix 画成透明，留给展开三角。
  - **标签**：一般一条注释一行一个标签，正文不进标签（整行只有正文时除外）；Type Layout、枚举摘要、
    stripped requirement 在每个 key 处另起一个标签；case 头行在 name 和 key 处另起；字段树的行只给
    value 打标签；字节行的标签到第一个 value 为止，后面的二进制不进；note 与认不出的种类整行一个 note
    标签。段里含 `.error` 语义（解析不出的地址）的标签改成 warning；`fieldOffsetUnknown`、
    `ivarOffsetUnknown`、`exportStatus` 本身就是 warning。
  - **收起**：有子节点的 `fieldOffset` / `fieldLayoutNode`，三角画在 treePrefix 末尾的 `├── ` 那格，
    根行没有前缀就画在注释符号前的两格缩进里；`enumLayoutCase` 收起到它的头行，三角在头行的缩进里。
    都是默认收起。
  - Print Exported Declarations Only 时 App 自己写的两行提示，也由 App 给出注释表（两条 note）。
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
| 圆角底与展开三角 | 自己的一个 `LayoutVisualization`；图层是自己的 `CAShapeLayer`，放进 `contentView.underlayLayer`，矩形取 `contentView.selectionRects(for:coalesceInteriorRects:includeLineSpacing:)` | 三个钩子在每个布局 pass 都会回调（`layoutContentView`，0x21B7E8）；框架自己的 `RangeHighlightLayoutVisualization` 就是这样画的（0x8A13C / 0x8AC34）。没用框架的 `SourceEditorRangeHighlightLayer`：它的形状与圆角没有导出的 setter（`init()`，0x254528），自己画同样的 4pt 圆角矩形更简单，stub 也少一个类 |
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
  没有可链接的导出符号，实际 26.6 与 27.2 都导出了它（装饰控制器就用它）。注释已随第 2 步更正，那段
  代码的行为不变。

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
2. **Bridge 装饰控制器。**（已完成）`CommentDecorationController`：隐藏列、位移、分色、圆角底、点 ▸
   收放、默认收起，以及它与 `FoldStateCache`、换 source 时先展开全部折叠的配合；`SourceEditorBridging`
   的 `setSource` 多了 `commentDecorations:` 参数，另加 `applyCommentTagColors(...)`。装饰描述是一个
   `@objc` 协议（`SourceEditorBridgingCommentDecorations`），全是 UTF-16 范围的平行数组：标签与样式、
   着色段与样式（label / value / type / name / concealed）、隐藏范围、可收起的行（三角画在哪几列、
   收起时藏到哪、是否默认收起）。藏什么、怎么上色由 App 决定，bridge 只照做。
   `CommentDecorationTests` 7 个测试：隐藏标记与冒号后的渲染、标签与三角的图层、默认收起（内层先折、
   展开外层后内层仍收着）、点三角收放、换回同一份 source 时恢复用户留下的折叠而不是默认值、不带装饰时
   一切照旧、2000 个默认收起的行设源加排版共 0.225 秒。`Stubs/VerifyAcrossXcodes.sh` 加了带装饰的
   `setSource` 和 `applyCommentTagColors`，在 27.2 与 26.6 上都跑通。
3. **App 侧。**（已完成）RuntimeViewerCore 新增 `RuntimeInterfaceCommentStructure`：注释的 kind、
   UTF-8 范围与外层注释，段的角色、UTF-8 范围与所属注释，kind 与 role 都是生产方的字符串（附已知
   清单的静态常量）。按列编码，kind 与 role 去重成表；解码时检查各列等长、索引不越界、范围不溢出。
   `RuntimeObjectInterface` 加可选的 `commentStructure`，旧对端的回复里没有这个键就是 nil。
   RuntimeViewerApplication 新增 `InterfaceCommentDecorations`（规则见「方案 · 三」）；
   `ContentTextViewModel` 的取数一半带上注释表，渲染一半在后台算出装饰放进 `RenderedInterface`。
   `ContentSourceEditorViewController` 在 Comment Tags 开着时把装饰交给 bridge、开关变化时重新下发同一
   份 source，并在每次套主题时下发标签配色；Settings › Editor 新增 Comment Tags
   （`Settings.Editor.showsCommentTags`，默认开）。测试：`InterfaceCommentDecorationsTests` 8 个、
   `RuntimeInterfaceCommentStructureTests` 5 个，内容管线、设置持久化、跨版本 interface 请求的既有
   套件照常通过。注释表此时还没有来源，引擎要到第 4 步才会填它。
4. **接上上游。**（代码已完成，抬 pin 待上游落地）内部生成选项、两个打印器的开关、引擎分离后填进
   线上模型，以及内容面板按 SourceEditor 与标签开关请求它，都已写好；最终的 kind / role 清单已补进
   「方案 · 一」。对着三个上游的分支验证通过（swift-semantic-string 的 `next`、MachOSwiftSection 的
   `feature/comment-structure`、MachOObjCSection 的 `feature/objc-comment-structure-marking`）：
   - Core 新增 `RuntimeInterfaceCommentStructureEngineTests` 5 个：用测试包里的 Swift fixture 和
     libobjc 的 `NSObject` 打印，要了注释表的文本、span 与 identifier 和不要时完全相同；文本里的每条
     注释都落在表里某条注释内、且从注释符号开始；范围层层嵌套；kind 与 role 都在已知清单里，各选项
     该出的 kind 都出现了。`GenerationOptionsTests` 补一条：不带这个键的旧请求按 false 解码。
   - Packages 新增 `InterfaceCommentDecorationsEngineTests` 4 个：在引擎给的真实注释表上，隐藏、
     着色和标签都不出注释，每条注释的符号都藏了，字段树与 case 块都能收起、从行尾折起。
   - 剩下抬 pin：三方进各自的 `next` 后一次抬齐五个锁文件。**在那之前，这条分支用默认的远程依赖编
     不过**，它用到的三个上游接口在现在钉的版本里都还没有。
5. **收尾。**（部分完成）`Stubs/VerifyAcrossXcodes.sh` 已补调新接口（随第 2 步）；0009 的决策日志已
   记一行指向本提案。实机截图核对颜色与观感待用户看过：第 4 步的代码已能对着三个上游的分支编出 App，
   引擎会发注释表了，面板上能看到装饰。

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
| 2026-10-31 | 第 2 步完成 | 实现中定下的几处：圆角底用自己的 `CAShapeLayer`，不用框架的高亮图层（理由见「方案 · 四」）；树形前缀不隐藏而是画成透明，三角画在它 `├── ` 那一格，根行与 case 头行的三角画在注释符号前的缩进里，这样有子节点和没有子节点的行对得齐；`FoldStateCache` 的键加上「是否带装饰」，同一份文本开关标签前后各记各的折叠；换 source 时先清空旧装饰再展开旧折叠，新装饰等新数据源就位后才装上，避免框架按旧文本排版时拿到新文本的列号；默认收起先折内层再折外层；按住 ⌥ 点三角整棵展开或收起。没能在 26.6 上跑行为测试：27.2 编出的测试包用的 swift-testing 符号 26.6 没有，混用两版框架又会让进程里出现两份 SourceEditor 而崩溃；26.6 的覆盖靠 `VerifyAcrossXcodes.sh` 跑通带装饰的整个接口。 |
| 2026-10-31 | 第 3 步完成 | 注释表的线上模型由 RuntimeViewer 自己定义，按列编码：一个大框架的 interface 有上万个段，每段一个带键的对象会比它描述的文本还大，`FrozenSemanticString` 出于同样的理由也是按列编码。开头的注释符号只藏 `//` 与它后面一个空格，续行的对齐空格留着，否则 case 块的各行会和头行挤在同一列。`=` 不藏（`@synthesize width = _width`、字节行的 `offset 0x08 = 0x01` 靠它读懂），只藏语法标点。 |
| 2026-10-31 | 停在第 4 步，等上游 | 上游三篇的草案都已写好、等用户在各自的会话里批准：swift-semantic-string 的 `separatingAnnotationRegions()`（`docs/AnnotationRegions.md`），MachOSwiftSection 的 `marksCommentStructure`（`draft-comment-structure.md`），MachOObjCSection 的 `marksCommentStructure`（`draft-objc-comment-structure-marking.md`）。三方已对齐：区域范围裁掉首尾空白、相邻同 kind 分得开、开关打开时分离后的文本逐字节相同；kind 与 role 的最终清单即本提案「方案 · 一」与 `RuntimeInterfaceCommentStructure` 里的常量，ObjC 多了 `ivarOffsetUnknown`，Swift 多了 `typeLayoutElement`、`conditionalWitness`、`conditionalWitnessBranch`、`strippedSymbolicRequirement`，去掉了 interface 路径不输出的 `spareBits`、`deletedMethodSlot`、`ambiguousAttribution`。 |
| 2026-10-31 | 第 4 步的代码先对着上游的分支写好，抬 pin 留到三方都进各自的 `next` | 三个上游当天都已实现：swift-semantic-string 已推到它的 `next`（2698750），还没发版；MachOSwiftSection 推了功能分支 `feature/comment-structure`，并在本地合进 `next`、未推送；MachOObjCSection 推了功能分支 `feature/objc-comment-structure-marking`，要等 swift-semantic-string 发版才合进它的 `next`。现在就抬 pin，五个锁文件要改两遍、验证也要跑两轮，所以只写代码、用三个上游的分支验证。代价是抬 pin 之前这条分支用默认的远程依赖编不过。 |
| 2026-10-31 | 这个选项放在外层 `GenerationOptions`，Swift 一侧随打印配置一起比较 | 一个开关管两种语言，用户的两组选项、Find 读语料用的映射都不用动。Swift section 的 interface 缓存本来就在打印配置变了时清空，带注释表和不带的不会互相顶替，不必另立一份缓存。 |
| 2026-10-31 | 打开或关掉标签改由重新取数驱动，VC 不再自己重发 source | 请求带上了这个选项，开关一变内容面板本来就会重新取数；VC 再重发一次，关掉标签时会连着两次 `setSource` 同样的文本。VC 下发前仍按开关把关，关掉之前发出、关掉之后才回来的请求不会把装饰带上去。 |
