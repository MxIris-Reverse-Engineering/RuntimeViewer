# 0064 - SourceEditor 内容面板：注释画成标签，字段偏移树与枚举布局可折叠

- **状态**: Implemented
- **创建日期**: 2026-10-31
- **最后更新**: 2026-11-05
- **所属愿景**: [自建代码视图引擎](../Visions/CodeViewEngine.md)
- **关联提案**: [0009](0009-content-editor-engine-selection.md)（接入 SourceEditor）；上游三篇见「方案 · 一」
- **实现分支 / PR**: `feature/source-editor-comment-annotations`（worktree `.worktrees/RuntimeViewer-SourceEditorCommentAnnotations`）

## 摘要

内容面板用 Xcode 的 SourceEditor 显示时（Settings › Editor 打开 SourceEditor），生成器输出的注释——
地址、VTable / PWT / 字段偏移、Type Layout、ObjC 的 IMP 与 ivar 偏移、各种说明——不再是一行行灰色
注释，而是画成淡灰底的胶囊标签，标签名按注释说的是什么带一点颜色（地址、偏移、布局、声明信息、警告、
说明），文字整体比代码暗：`//`、`/* */` 和标点不显示，标签名、键与数值分色，多字段的拆成几个相邻标签。Swift 的字段偏移树（`// Field offset: 0x8` 下面那串 `├──` 行）变成可折叠的大纲，默认只剩
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
  - **类别**：每个标签按它所在注释的 kind 归进一类，类别决定颜色：address（memberAddress、
    impAddress）、offset（VTable / PWT / 字段偏移、字段树、ivar 偏移）、layout（Type Layout、枚举布局
    的各部分）、declaration（`@synthesize` / `@dynamic`、protocol-extension default、私有声明出处、
    条件 witness、stripped requirement、ObjC 的类型说明）、warning、note（其余与认不出的 kind）。
  - **着色**：label、qualifier 用所在标签那一类的标签名颜色，key 不分类别用一种键的颜色，value、
    type、name 各用自己的颜色，正文保持注释色；treePrefix 画成透明，留给展开三角。（key 原先与 label
    同色，2026-11-05 分开，见决策日志。）
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
| 胶囊底与展开三角 | 自己的一个 `LayoutVisualization`；图层是自己的 `CAShapeLayer`，放进 `contentView.underlayLayer`，矩形取 `contentView.selectionRects(for:coalesceInteriorRects:includeLineSpacing:)` | 三个钩子在每个布局 pass 都会回调（`layoutContentView`，0x21B7E8）；框架自己的 `RangeHighlightLayoutVisualization` 就是这样画的（0x8A13C / 0x8AC34）。没用框架的 `SourceEditorRangeHighlightLayer`：它的形状与圆角没有导出的 setter（`init()`，0x254528），自己画更简单，圆角、描边也能随意定，stub 也少一个类 |
| 收起大纲节点和 case 说明块 | `FoldingController.fold(_:animate:completion:)` / `unfold(_:restoreNestedFolds:animate:)` | 任意范围都能折，`fold(ranges:)`（0xDA140）不查 `foldableRanges`；`fold(lineRanges:)` 会把首行一起藏掉，所以从「节点行的行末」折到「子树末行的行末」；被折那行的行尾必定出现「…」块（`makeEllipsisLayer`，0xD0454；单击选中、双击展开），没找到关掉它的开关；`stateDictionaryForSaving` / `restore(from:)`（0xDD7A4 / 0xDDC08）会带上这些折叠，现有的 `FoldStateCache` 照常记住 |
| 点 ▸ 展开、收起 | `SourceEditorViewEventConsumer` | `mouseDown(with:)`（0x328208）先逐个问 consumer，命中即止；`positionAtPoint`（0x434E8C）。点下去时三角转四分之一圈（0.18 秒），背后一个圆形按下效果淡出（0.3 秒）；三角因此只画一个 ▸，展开时靠旋转变成 ▾ |
| 带标签的行加高，空出的高度上下各一半 | `HiddenTextOverrideProvider` 把注释符号后那个原本藏起的空格放回来，`TextAttributeOverrideProvider` 给它挂一个不占宽度、上伸与下伸都比注释字体多出一半间距的 CoreText run delegate，颜色设为透明 | 这一行的依据是 26.6（UUID `CBBA3D3B-632D-38EC-9BCD-545B1176BA82`）的反编译加 27.2 上的测试。框架没有加高某一行的接口：`setLineExpansionEffectForLine(_:height:)`（0x6B4A4）只把高度记下再请求排版，只在 `layoutContentForLine` 里读（0x750C4），而且只有比行本身矮时才生效——把行截短，不到 0.5 就藏起，是插入行的展开动画用的。行高由 `CoreTextLineLayout.layout(boundsWidth:minLineHeight:)` 用 `CTLineGetTypographicBounds` 量出（0xF878），所以一个更高的零宽字符就能撑高整行，文字落在上伸与下伸之间；行高取上伸加下伸之和上取整。27.2 上由 `SourceEditorOverlayBehaviorTests` 的 `aTallerZeroWidthRunRaisesItsLineAroundItsText` 与 `aLineIsAsTallAsItsFontsAscentPlusDescentRoundedUp` 实测 |
| 三角上的指针是箭头 | `CursorRectOverrideProvider`，用 `SourceEditorView.addCursorRectOverrideProvider(_:)` 注册 | `resetCursorRects()`（0x441A90）先在 `contentRectForCursor()` 上铺 I-beam，再逐个问 provider，把回答在视图自己身上 `addCursorRect(_:cursor:)`，所以矩形用 `SourceEditorView` 的坐标、盖过 I-beam；`contentRectForCursor()`（0x4220BC）是视图自身的固定区域，滚动时没人更新这些矩形，所以文字一滚动、三角一移位就调 `invalidateCursorRects()`（0x422084，即 `window.invalidateCursorRects(for:)`） |

- **不用 `SourceEditorRangeHighlightController.highlight`**：每个高亮都注册一个 visualization 和一个
  属性 provider，每个布局 pass 逐个回调（0x8C388 起），几千条注释撑不住。圆角底由一个 visualization
  统一画，只画可见行（以 `sourceRangeForVisibleLinesIn(rect:inContentView:)` 为界），图层用池复用。
- 默认收起：一份 source 第一次出现、`FoldStateCache` 里没有它时，收起每棵字段偏移树的根和每个 case
  说明块；有记录就按记录恢复。
- 外观由 App 给：`SourceEditorBridgingCommentTagAppearance`（又一个 `@objc` 协议，理由同装饰描述）
  按类别给出填充、描边与标签名的颜色，外加键、数值、类型名与名字的颜色，圆角、描边宽度和左右留白，
  bridge 每次调用时读一遍存下来。App 的 `SourceEditorCommentTagAppearance` 画胶囊：圆角取标签高度的
  一半，不描边，留白 6 pt；填充不分类别，取主题注释色的深色 13%、浅色 10%；类别只落在标签名上——每类
  一个固定色相（地址蓝、偏移绿、布局紫、声明信息琥珀、警告橙红），标签名取这个色相与注释色各一半，
  说明取注释色；键用注释色；数值与名字用正文色压到 60%（浅色 62%），类型名用主题的类型色压到 62%
  （浅色 70%），都比代码暗。11-05 之前每类的填充与 1 pt 细边都用自己的色相，标签名用全色，数值是
  正文色的 82% / 78%（见决策日志）。留白是列位移，烤在排版表里，变了就按已载入的装饰重建。
- 带标签的行比文字高 4 pt，上下各 2 pt（`tagLineSpacing`），胶囊和三角仍按文字的高度画，空出的高度
  落在胶囊外面。撑高的做法见上表：每一行注释的注释符号后都有一个原本藏起的空格，放回来挂上零宽的
  run delegate。它的上伸与下伸取 App 传来的注释字体（`commentFont`，主题给注释的字体）的原值，各加
  半个间距，不先取整：编辑器把上伸加下伸的和整个上取整当作行高（11 pt 的 SF Mono 是 10.63 + 2.32，
  行高 13），先各自取整会让每一行多出 1 pt，第一版就这样多了。胶囊的高度按同样的和上取整来算。
  行号不用另管：框架把行号竖直居中在每一行第一段的中线上（26.6 的
  `SourceEditorGutterMarginContentView.layoutLineNumberForLine(_:with:)`，0x1D069C，量的是
  `layoutFrameForFirstFragmentOfVisibleLine(_:includeLineSpacing:)`），撑高的字符就在行首，加出的
  高度又平分在文字上下，行号仍与文字齐平。要不要放回那个空格也烤在排版表里，间距从无到有、从有到无
  时重建；间距的大小或字体变了只换 run delegate，重排即可。还没收到 App 的外观时不加高。
- 编辑器折行时，一个标签可能落在几行上。同一行内照旧取选区矩形；一旦跨行，选区在折行处会一直伸到
  视图边缘，所以改为逐列量、按行分组，每行画一个胶囊，行首行尾的空格不算。
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
- 复制、⌘F 查找和 Find 导航都按原文；大纲点 ▸ 展开一层，按住 ⌥ 点展开整棵。复制这一条已实测（见决策
  日志）。
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
   的 `setSource` 多了 `commentDecorations:` 参数，另加 `applyCommentTagColors(...)`（第 5 步定样式时换成了
   `applyCommentTagAppearance(_:)`，见「方案 · 四」）。装饰描述是一个
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
4. **接上上游。**（已完成）内部生成选项、两个打印器的开关、引擎分离后填进
   线上模型，以及内容面板按 SourceEditor 与标签开关请求它，都已写好；最终的 kind / role 清单已补进
   「方案 · 一」。对着三个上游的分支验证通过（swift-semantic-string 的 `next`、MachOSwiftSection 的
   `feature/comment-structure`、MachOObjCSection 的 `feature/objc-comment-structure-marking`）：
   - Core 新增 `RuntimeInterfaceCommentStructureEngineTests` 5 个：用测试包里的 Swift fixture 和
     libobjc 的 `NSObject` 打印，要了注释表的文本、span 与 identifier 和不要时完全相同；文本里的每条
     注释都落在表里某条注释内、且从注释符号开始；范围层层嵌套；kind 与 role 都在已知清单里，各选项
     该出的 kind 都出现了。`GenerationOptionsTests` 补一条：不带这个键的旧请求按 false 解码。
   - Packages 新增 `InterfaceCommentDecorationsEngineTests` 4 个：在引擎给的真实注释表上，隐藏、
     着色和标签都不出注释，每条注释的符号都藏了，字段树与 case 块都能收起、从行尾折起。
   - 三方都进了各自的 `next` 之后（2026-11-01），五个锁文件（Core、Packages、CommandLine、Debug 与
     Distribution 两个 workspace）里的三条 pin 一次抬齐：MachOSwiftSection `1dcc0c08`、MachOObjCSection
     `774b2baf`、swift-semantic-string `f14caa48`（含 0.6.0），其余 pin 不动。之后用默认的远程依赖、全新
     的构建目录重跑了全量验证。
5. **收尾。**（已完成）`Stubs/VerifyAcrossXcodes.sh` 已补调新接口（随第 2 步）；0009 的决策日志已
   记一行指向本提案。用户实机看过后，样式改成带细边的胶囊、按类别分色（从四个候选里挑的，见决策
   日志），并修掉了编辑器折行时标签把整行画上底色的问题；`CommentDecorationTests` 新增 4 个测试（折行
   的标签逐行画、标签名随标签类别取色、只有描边宽度大于 0 才描边、留白一变就重排），
   `InterfaceCommentDecorationsTests` 新增 1 个（每种 kind 归进哪一类）。

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
| 2026-10-31 | 标签改成带细边的胶囊，按注释说的是什么分色 | 用户嫌原来的样子单调：只有一种淡灰底，圆角也不明显。要圆角、多色、但不抢眼，看过样例再定。先给了一页 HTML 样例，用户又要看真实的，于是在一次性的原型分支 `prototype/comment-tag-styles` 上让 Debug 菜单能在现状和三个候选之间实时切换；用户在真实 interface 上比过后选了「胶囊细边」。分六类：地址、偏移、布局、声明信息、警告、说明；前五类各一个固定色相，说明取主题的注释色。数值改用压暗的正文色，主题的数字色在标签里太抢眼；留白从 4 pt 放到 6 pt，字才不贴着圆头。bridge 因此不再收一组固定的颜色，改读 App 给的外观协议。 |
| 2026-10-31 | 折到下一行的标签逐行画 | 用户实机发现，编辑器开着自动换行时，被折到下一行的标签会把整行都画上底色。原因是一个标签的几个选区矩形被合成了一个外框，而选区在折行处会一直伸到视图边缘。改为同一行内照旧取选区矩形，一旦跨行就逐列量、按行分组，每行一个胶囊，行首行尾的空格不算。复现测试 `aTagTheEditorWrapsIsDrawnRowByRow` 修复前是红的：两个标签只画出两个图层，高度分别是 11 和 24。 |
| 2026-10-31 | 复制出去的是注释原文，已实测 | 用户关心复制与导出能不能拿到注释的原样。导出本来就不经过编辑器：保存 interface、批量导出、CLI 与 MCP 写的都是 `interfaceString`，它与不要注释表时逐字节相同（`RuntimeInterfaceCommentStructureEngineTests`）。复制原先只有反编译的依据，现在用 `CommentDecorationTests.aCopyIsTheSourceAsPrinted` 实测：全选后经编辑器的 `writeSelection(to:types:)` 写进测试自己的剪贴板（不碰用户的），纯文本是原文，`//`、冒号、树形前缀都在，收起的行也完整复制出来，富文本的文字与纯文本相同；唯一多出的是全选带上的文末换行，那是编辑器本来的行为。胶囊是画在图层上的，复制带不走。 |
| 2026-10-31 | 三角上用箭头指针，点下去有反馈 | 用户的两个小要求：鼠标停在展开三角上时，指针要是普通箭头，不要文字输入的 I-beam；点击要有效果。指针用框架现成的 `CursorRectOverrideProvider`（反编译确认它的矩形是 `SourceEditorView` 坐标、加在 I-beam 之后，且滚动时框架不会替它更新，所以由装饰控制器在滚动和三角移位时自己作废），stub 补了这个协议、`CursorRectOverride` 与 `SourceEditorView` 的三个方法，`UsedSymbols.txt` 多了 7 个符号，26.6 与 27.2 都导出。点击效果选了与 macOS 大纲视图一致的三角转动，再加一个很淡的圆形按下效果，两者都很短，不挡操作。测试：`theTrianglesTakeTheArrowPointer` 把编辑器加的光标矩形读回来（临时替换它类上的 `addCursorRect(_:cursor:)`，AppKit 没有读回的接口），确认每个三角都盖着箭头；`clickingATriangleTurnsItAndShowsThePress` 确认点下去三角转到展开的角度、转动有动画、背后有一个在淡出的图层。 |
| 2026-11-01 | 三个上游都进了各自的 `next`，抬 pin | MachOSwiftSection 的注释结构标记以 0084 落地（`1dcc0c08`），swift-semantic-string 发布 0.6.0（`next` 上 `f14caa48`），MachOObjCSection 的标记合进 `next` 并推送（`774b2baf`）。五个锁文件只改这三条 pin，其余不动；包的 edit 模式与临时 workspace 撤掉，改用默认的远程依赖、全新构建目录重跑全量验证：Core、Packages、命令行工具与 App 都编过，Distribution 的锁文件解析通过；全量测试只有满载下的几个计时类测试失败（交叉引用预先准备 2 个、批次取消 1 个、加载指示 100 ms 宽限 1 个），单独重跑全过，bridge 测试只剩基线就有的 2 个滚动条测试。 |
| 2026-11-01 | 实现完成，落地编号 0064 | 落地前先把 `next` 合进功能分支，带进另一会话的「只看导出的 ObjC 声明」；`ContentTextViewModel` 的冲突按 `next` 的 Swift / ObjC 两侧判断改了 `showsExportedOnlyNote`，ObjC 对象被那个选项清空时的说明也画成说明标签。不另写使用指南或实现说明：用户可见的只有 Settings › Editor 的 Comment Tags 开关，设置页已有说明，机制与反编译依据都在本提案里；术语表新增「注释标签」与「注释结构」两条。 |
| 2026-11-02 | 带标签的行加高 4 pt，上下各 2 pt，胶囊大小不变 | 用户实机看了觉得标签叠得太密、干扰正文。原因是胶囊只比整行矮 2 pt：存储属性上方的「字段偏移」与「Type Layout」两行标签几乎连成一块，也贴着上下的代码；而 13 pt 字号的一行只有 16 pt，字本身就占约 12 pt，同样字号下胶囊再缩就压到字。给了三个方向：只加高标签行、所有行加大行距、标签字号调小一号，用户选只加高标签行，代码行不变。原想用框架的 `setLineExpansionEffectForLine(_:height:)`，反编译发现它只能把行压矮，改用零宽 run delegate 撑高（依据见「方案 · 四」的表）。第一版把字体的上伸与下伸各自上取整再交给 run delegate，测出每行多高了 1 pt：编辑器是把两者之和整个上取整，改成传原值后正好高出间距。测试：`SourceEditorOverlayBehaviorTests` 新增 2 个，钉住零宽 run delegate 撑高整行、文字居中、不占宽度，以及行高等于字体上伸加下伸之和上取整（12 到 18 pt 五个字号）；`CommentDecorationTests` 新增 3 个，覆盖带标签的行高出间距、下面的行跟着下移、去掉间距后复原，胶囊的大小与横向位置不变、居中、相邻两行标签的间隔多出 4 pt，以及加高的行行号仍与文字齐平；复制测试补了加高的情形，复制出的仍是原文。`Stubs/VerifyAcrossXcodes.swift` 的探针外观带上 4 pt 间距，26.6 与 27.2 都走一遍加高的排版。验证在 Ultra 上跑（macOS 27.2、Xcode 27.2）：bridge 测试只剩基线就有的 2 个滚动条失败，跨版本探针两版都通过，App（Debug-arm64e）编过。用户确认后收尾。间距是固定的外观值，不进设置，所以不另写使用指南或实现说明；术语无新增。 |
| 2026-11-05 | 标签降噪：不描边，填充统一取淡灰，文字压到代码之下 | 用户实机用了一阵后觉得标签仍然太抢眼。原因有三：一行 Type Layout 拆成五个胶囊，每个都描了细边；标签名和键用饱和的类别色，数值是正文色的 82%，比声明名、类型名还亮；结构体的每个属性上方有两行注释，比代码行还多，样式一亮就压过了代码。先用一页静态对比页（仓库外的一次性样例，深浅两色并排）给了五个更安静的画法：只去边并压暗文字、一行注释一个胶囊、再加淡彩底、一个声明上方的几行注释共用一块圆角底、不画底。用户选了改动最小的第一种，仍是一个事实一个胶囊；字段偏移行尾折叠自带的「…」块按用户的决定保留。新外观见「方案 · 四」。键原先与标签名同色，要让类别色只落在标签名上，`InterfaceCommentDecorations.RunStyle` 与 bridge 的 `SourceEditorBridgingCommentRunStyle` 各加了 `key`，外观协议加了 `keyColor`；限定词（`Address (getter)` 里的 `getter`）仍随标签名。测试：`InterfaceCommentDecorationsTests.runsTakeTheColourOfTheirRole` 补了键与标签名分开的断言，`CommentDecorationTests` 新增 `aKeyTakesTheKeyColourWhateverItsTag`。验证在 Ultra 上跑（macOS 27.2、Xcode 27.2）：Packages 的两个注释装饰套件 13 个测试全过；bridge 测试 36 个，只剩基线就有的 2 个滚动条失败，跑的是产物目录里的重建版 26.6.3（与下载的框架 UUID 相同）；App（Debug-arm64e）编过。颜色是固定的外观值，不进设置，不另写使用指南或实现说明；术语表「注释标签」一条与两份索引按新样子改了措辞。 |
