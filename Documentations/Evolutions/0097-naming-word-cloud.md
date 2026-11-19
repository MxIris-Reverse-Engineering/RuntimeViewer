# 0097 - 框架的命名词云：类型名、属性名与方法名的词频

- **状态**: Implemented
- **创建日期**: 2026-10-31
- **最后更新**: 2026-11-19
- **所属愿景**: 无
- **实现分支 / PR**: `feature/naming-word-cloud`（worktree `.worktrees/RuntimeViewer-NamingWordCloud`），做完一次合进 `next`

## 摘要

给一个镜像（框架）的命名做词云：把类型名、属性名和方法名拆成单词，按出现次数定字号，一眼看出这个框架的类型多叫 `Manager`、`Service`、`Session` 还是 `Controller`，方法名多以 `set`、`did`、`will` 中的哪个开头。词云开在独立窗口里；点一个词，列出用到它的类型或成员，点一行在主窗口打开。词云能导出成 PNG，词频能导出成 CSV 与 JSON。引擎只多一条读 Find 语料成员的命令，拆词与计数都在 App 一侧。

## 方案

### 1. 四种口径

窗口工具栏里的分段控件切换：

| 口径 | 数什么 | 一个词的次数 |
|---|---|---|
| Type Suffixes | 类型名的最后一个词：`NSLayoutManager` → `Manager` | 以它结尾的类型数 |
| Type Words | 类型名里的每个词：`NSWindowController` → `Window`、`Controller` | 含这个词的类型数 |
| Member Words | 成员名里的每个词：`setNeedsDisplayInRect:` → `set`、`Needs`、`Display`、`Rect` | 含这个词的成员数；可以只看 Properties（ObjC 属性与 Swift 的存储、计算属性）、Methods、Instance Variables（ObjC ivar）或 Enum Cases |
| Method First Words | 方法名的第一个词：`setFrame:` → `set` | 以它开头的方法数 |

- **算哪些类型**：ObjC 的类与协议，Swift 的 enum、struct、class、protocol、typealias，C 的 struct 与 union。嵌套类型按它自己的名字算（`Outer.Inner` 取 `Inner`），泛型参数去掉。类别、extension 与 conformance 条目不是新类型，不算，但它们声明的成员照算。同一个类型的两面只算一次：Swift 类与 Swift 定义的 `@objc` 协议在 ObjC 列表里那一面（`isSwiftClass`、`isSwiftProtocol`）跳过。用户做出来的特化类型与函数体里声明的局部类型不算。
- **成员按条目去重**：同一个条目里，同组、同名（不分大小写，也不管开头的下划线）的成员只算一次。语料只记 Swift 函数的基本名，所以 `insert(_:at:)` 与 `insert(contentsOf:at:)` 都叫 `insert`，算一个；Swift 属性的存储 `_name` 与属性 `name` 也算一个。Swift 的 `init` 与 `subscript` 没有名字，不算；`$` 开头的成员是编译器生成的存储（`$__lazy_storage_$_name` 之类），也不算。
- **不算编译器补上的四个属性**：ObjC 类只要遵循了继承自 NSObject 协议的协议，属性列表里就带着 `hash`、`superclass`、`description`、`debugDescription`。它们不是这个类起的名字，在 AppKit、UIKitCore、UIFoundation、SwiftUICore 的成员名里，单是 `debug` 加 `description` 连着出现就有约两千次，不去掉的话 Member Words 会被它们占满。
- **拆词**：去掉首尾下划线，在 `_`、`:`、`.` 等符号处断开，再按大小写断开。连续的大写字母算一个缩略词，最后一个大写字母留给后面的词（`URLSession` → `URL`、`Session`）；数字跟着前面的字母（`UTF8String` → `UTF8`、`String`）。只有一个字母的词与纯数字丢掉。比较不分大小写；显示时缩略词保持全大写，其余首字母大写，Method First Words 一律小写。
- **三个默认打开的开关**（窗口的 ⚙︎ 菜单）：
  - Remove Prefixes：去掉镜像自己的类名前缀。前缀从这个镜像的类型名里统计出来（AppKit 得到 `NS`，UIKitCore 得到 `UI`），不写死一张表。去掉前缀后再拆词，所以 `NSURLSession` 照样拆成 `URL`、`Session`。
  - Ignore Common Words：去掉 with、for、in、at、by、from、to、of、and 这类虚词。
  - Merge Compound Words：有些词总是成对出现，拆开就变了意思，拆词时当成一个词：`NSTableViewDataSource` 的最后一个词是 `DataSource` 而不是 `Source`，`tableView:cellForRowAtIndexPath:` 里是 `IndexPath`。四种口径都按合并后的词算。
- **复合词预设**：二十个左右，按 AppKit、UIKitCore、UIFoundation、SwiftUICore 的名字里两个词连着出现的频率挑出来。类型名里有 `ViewController`（占 `*Controller` 的 36%）、`GestureRecognizer`（占 `*Recognizer` 的 92%）、`DataSource`（占 `*Source` 的 44%）；成员名里有 `IndexPath`、`TraitCollection`、`HitTest`、`CornerRadius`、`SafeArea`、`ToolTip` 等，再加上 `KeyPath`、`RunLoop`、`TimeZone`、`UserInfo`、`PopUp` 这类 Cocoa 里的固定说法。⚙︎ 菜单的 Compound Words… 打开一个表单，可以增删；增删的结果记在 `AppDefaults` 里，预设本身随 App 更新。

### 2. 数据从哪来

- **类型**来自镜像的对象列表，即侧栏用的那份 `RuntimeEngine.objects(in:)`，不需要语料，窗口一打开就能看。
- **成员**来自 Find 的语料。Swift 的成员要打印过才列得全，而语料已经按种类存着每个成员，共享缓存里的镜像还有盘上缓存。窗口经文档所在 Engine 共享的语料协调器请求这个镜像：`FindCorpusCoordinator.requestBuild(of:isPrioritized: true)`，从 `$runtimeEngineSession` 送来的会话里取。这样窗口与 Find 用的是同一份语料、同一次构建，构建会出现在 Report 导航器里，App 切到后台时也不会被 App Nap 拖慢——协调器替它持有防 App Nap 的 activity。
  - Find 的语料开关（Settings › Search）关着时不建：两种成员口径提示去打开它，两种类型口径照常可用。
  - 镜像还没加载时（从侧栏镜像列表的右键菜单打开），先走侧栏点开镜像的同一条路加载并索引，带进度。
  - 设置里的 transformer 改了、语料重建之后，窗口重新读一遍成员。
- **新增一条 Core 命令**，与 `searchMembers` 并列。它读的是 Core 自己的语料，不属于要另立模块的命令扩展：

  ```swift
  /// The members of `imagePath`'s corpus, object by object, as `options`
  /// show them — `nil` shows every member any options could — or `nil`
  /// when the image has no corpus built.
  public func members(in imagePath: String, shownUnder options: RuntimeObjectInterface.GenerationOptions? = nil) async throws -> [RuntimeObjectMembers]?
  ```

  每个成员只带名字、种类、是否静态与行号，不带声明那一行的文字；对象不带 `children`，所以响应只有名字本身的量级。对端是不认识这条命令的旧版本（例如更早注入的载荷）时，成员口径提示对端版本太旧，类型口径照常可用。
- **跟随文档的生成选项**（`currentMergedGenerationOptions`，与 Find 一致）：内容区藏掉的成员不算；打开 Print Exported Declarations Only 时，未导出的类型（`isNotExported`）也不算。只有一处例外：统计时总是打开 Strip Synthesized Methods 与 Strip Synthesized Ivars。默认选项不藏它们，一个 ObjC 属性会再以 getter、setter 和 `_name` ivar 出现，Method First Words 里的 `set` 会被每个可写属性多算一次。
- 文档换了生成选项或 Engine 时重新计数。计数放在后台做，切换口径不卡界面。

### 3. 窗口

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  Naming Word Cloud  [Type Suffixes|Type Words|Member Words|Method…]        │
│        AppKit                                              ⚙︎ ▾   ⇪ ▾  │          │
├────────────────────────────────────────────────────────┬─────────────────────────┤
│                                                        │ Words         631 words │
│                                                        │ ┌ Word ──────── Count ▾┐│
│          Delegate      View      Provider              │ │ ● View          812  ││
│     Cell    Controller    Manager    Item              │ │ ● Controller    301  ││
│        Button   Layer   Session   Message              │ │ ● Manager       128  ││
│                                                        │ └──────────────────────┘│
│                                                        │ Used By                 │
│                                                        │ Manager — 128 types     │
│                                                        │ ┌ Name ────────── Kind ┐│
│ ▢ Showing 150 of 631 words  ● Classes ● Protocols      │ │ NSLayoutManager class││
│                           ( ✋ │ −  36%  + │ ⤢ )        │ │ NSFontManager   class││
└────────────────────────────────────────────────────────┴─────────────────────────┘
```

（图中的词与数字只是示意。2026-11-19 起是这个样子：第一版把控件做成标题栏下面的一排，右侧两张表没有表头，验收时用户觉得不好看，改成照原生窗口的做法，见决策日志。）

- **全部用 AppKit**：词云是自绘的 `NSView`，自己排版，用 `NSAttributedString` 画字，自己处理悬停与点击；排行表与用法列表是 `NSTableView`，左右分栏与右栏的上下两段是 `NSSplitView`，口径切换是 `NSSegmentedControl`。不用 SwiftUI，也不引入新的第三方依赖。
- **窗口外框照原生窗口**：
  - 统一样式的工具栏（`toolbarStyle = .unified`），标题是 Naming Word Cloud，镜像名放在副标题（`NSWindow.subtitle`），不再把两者拼成一个标题。
  - 工具栏从左到右：口径的分段控件；只在 Member Words 下出现的成员分组下拉（All Members、Properties、Methods、Instance Variables、Enum Cases）；弹性空白；⚙︎ 菜单（`NSMenuToolbarItem`，图标 `gearshape`，标签 Options）；导出菜单（`NSMenuToolbarItem`，图标 `square.and.arrow.up`，标签 Export）；最后是跟着左右分栏分隔线走的分隔项（`NSTrackingSeparatorToolbarItem`，指向窗口里的左右 `NSSplitView` 的第 0 条分隔线），所以分隔线右边那段工具栏正好在右栏上方。控件全在分隔线左边，因为它们都作用于词云。
  - 工具栏只显示图标（`displayMode = .iconOnly`），标签用于无障碍与自定义面板。不允许用户自定义工具栏：项目固定，只有成员分组随口径显隐。
  - 内容区从工具栏下面开始（不用 `fullSizeContentView`），不在工具栏下面垫滚动边缘效果。
  - 原来标题栏下面那一排手搭的控件（`topBar`）删掉。
- **右栏照 RV 主窗口的 Inspector 排**：两段，中间是可拖动的细分隔线，打开时各占一半，分隔线位置随窗口记住。
  - 每段开头一行标题，13pt semibold，与 Inspector 各页的标题同字号；标题行右边是灰色的小字说明。上段标题 Words，右边写当前口径一共多少个词（`631 words`）；下段标题 Used By，下一行是选中词的说明（`Manager — 128 types`），没选词时写 No Word Selected。
  - 两张表都用 `.inset` 样式，带表头，行高用系统默认：排行表两列 Word（前面是类别色圆点）与 Count（右对齐、等宽数字）；用法表两列 Name 与 Kind（类型口径，写 class、protocol、struct 这类种类）或 Declared In（成员口径，写声明它的类型）。选中用系统的选中样式，不另画圆角底。
  - 排行表点表头排序：默认按 Count 从多到少（次数相同按词的字母序），点 Word 按字母序，再点同一个表头反向。排序在 ViewModel 里做，表格只把点了哪个表头送过去。
- **入口**：View 菜单的 Show Naming Word Cloud（文档有当前镜像时可用），以及侧栏镜像列表两页（目录与书签）的右键菜单。一个文档里每个镜像只开一个窗口，再次打开就把它提到前面；窗口随文档关闭，记住大小与位置。
- **词云**：
  - 显示当前口径排名前 N 的词，N 在 ⚙︎ 菜单里选 150、300、500、1,000 或全部，默认 150（2026-11-19 从 500 改回来：打开时要整片缩放进窗口，500 个词缩进去，大半的词只有三四个点高，见决策日志）。已经存过设置的用户沿用自己存的 N。
  - 字号只看次数：最常见的词 120pt，其余按次数的平方根缩小，最小 12pt，所以一个词占的面积大致与次数成正比。
  - **画布比窗口大得多**：画布大小由所有词的总面积决定，词约占四成，AppKit 的 500 个词约为 1,900 × 1,200 到 2,800 × 1,800 点。排版与窗口大小无关：同样的词总是排成同样的图，改变窗口大小只是露出的部分不同。
  - 从画布中心沿螺旋线摆放，大词先放，全部横排。画布按总面积留足了空间，一般都放得下；万一放不下，左下角的状态行写明画了多少、一共多少。状态行垫一块半透明底，词从它下面滚过也看得清。
  - **字体是 SF Mono**（`NSFont.monospacedSystemFont`），按字号加粗：56pt 以上 bold，28pt 以上 semibold，18pt 以上 medium，其余 regular。少数大词撑起画面，大量小词不抢眼。词与词之间留几个点的空隙。
  - **颜色表示这个词最有代表性的那一类名字**，每种口径三类以内：
    - 类型口径：类、协议、值类型（struct、enum、typealias 与 C 的 struct、union）；
    - 成员口径：属性、方法、其他（ObjC ivar 与 Swift 的 enum case）；
    - 方法首词口径：实例方法、类方法（含 Swift 的 static 与 class 方法）。

    「最有代表性」指：这一类名字里用到这个词的比例，比这一类在全部名字里的平均占比高出最多。这一类至少要有 3 个名字用到这个词，否则按多数算。不直接按多数定色，是因为方法比其他成员多得多，按多数的话几乎每个常见的成员词都是方法色。在 AppKit 上，`Delegate`、`DataSource` 落在协议色，`Accessibility`、`Size` 落在属性色，`default`、`register`、`current` 落在类方法色。
  - 三种颜色取自 dataviz 参考色板的前三个色位（浅色 `#2A78D6` / `#EB6834` / `#1BAF7A`，深色 `#3987E5` / `#D95926` / `#199E70`），画布底色取色板配套的 `#FCFCFB` / `#1A1A19`。用色板自带的校验脚本验过：三色两两之间在浅色、深色下都能分开，色弱也能分开。浅色下青色对底色的对比度是 2.74，低于 3:1，由右侧的排行表补足。字号 18pt 以下的词用类别色的 60% 不透明度画，18pt 及以上的满色（2026-11-19 起；原先一律满色）：几百个小字都用饱和色时整片画面很花，降低小字的不透明度后，大词撑起画面，小词退到后面。小词的颜色因此更难分辨，由排行表的圆点补足。悬停与选中的词不论大小都满色。
  - 左下角状态行里有图例，只列当前画面用到的颜色。排行表里每个词前面是对应颜色的圆点，词本身仍是文字色。
  - 选中的词保留自己的颜色，背后垫一块同色浅底并描边；悬停的词只垫浅底。选中不再用强调色，因为颜色已经有了含义。
  - 悬停显示「Manager — 128 types」。
- **浏览**：画布放在 `NSScrollView` 里。
  - **打开时整片词云装进可见区域并居中**：按所有词的外接矩形（四周各留 24 点）缩放，不超过 100%；换口径、开关或 N 之后重新排版时也这样做一次。Zoom to Fit 用同一个外接矩形，而不是整张画布：画布四周本来就留着空，按画布缩放，词云会比可见区域小一圈。2026-11-19 之前是打开时按 100% 显示中心那一块。
  - **画布比可见区域小时居中**：滚动视图的 clip view 换成 RuntimeViewerUI 的 `CenteringClipView`，文档视图在某个方向上比它小时，在那个方向居中，而不是像 `NSClipView` 默认那样贴在左上角；画布外露出的地方用画布底色填满，看不出画布的边。验收时缩小后词云挤在左上角，就是这个原因。
  - **画布右下角一组浮在画布上的控制按钮**（2026-11-19 用户要求加）。从左到右：
    - 抓手（`hand.raised`，开关按钮，打开时换成实心的 `hand.raised.fill`）：打开后只用来平移——点在词上不选中它，悬停不垫底，光标处处是张开的手。拖动本来在哪里都能平移，在词上也一样，抓手只是让点击不再选词。窗口每次打开都是关着的，不记住。
    - 缩小（`minus.magnifyingglass`）、当前缩放比例（如 `36%`，取整到百分之一）、放大（`plus.magnifyingglass`）：每按一次缩放倍数乘或除以 1.25，以可见区域的中心为基准，带动画。点比例回到 100%（原来 ⚙︎ 菜单里的 Actual Size）。缩放到 10% 时缩小按钮变灰，到 400% 时放大按钮变灰。捏合或其他方式改了缩放，比例随之更新。
    - 适合窗口（`arrow.up.left.and.arrow.down.right`）：按词的外接矩形缩放并居中，与打开时一样（原来 ⚙︎ 菜单里的 Zoom to Fit）。
    - 快捷键照「预览」：⌘+ 放大、⌘− 缩小、⌘0 回到 100%、⌘9 适合窗口，在词云窗口是 key window 时有效。
    - 外观：一块圆角的浮层，macOS 26 起是 Liquid Glass（`NSGlassEffectView`），之前是与左下角状态行一样的半透明底（`NSVisualEffectView`）；左下角的状态行跟着用同一种底，两块看起来是一套。按钮是无边框的图标按钮，组与组之间一条细竖线。
    - ⚙︎ 菜单里的 Zoom to Fit 与 Actual Size 随之去掉。
  - 按住任何地方拖拽平移（在词上也一样），触控板与滚轮滚动，双指捏合缩放（10% 到 400%）。按下后移动三个点以上才算拖拽，否则是点选。光标在空白处是张开的手、拖动时握拳、指在词上是手指。在排行表里选中一个词时，画布带动画平移到这个词。
- **右栏的内容**（样子见上文「右栏照 RV 主窗口的 Inspector 排」）：
  - 上段 Words 是全部词的排行表，不只词云画出来的那些。精确比较与无障碍阅读都走它。
  - 下段 Used By 列出选中词的用法。公开的名字排在前面，下划线开头的私有名字排在后面。
  - 在词云或排行表里点一个词都会选中它。点用法里的一行，主窗口打开那个类型，走 `documentState.selectionRouter` 的 `.open(_:in: .focusedTab)`，与侧栏点一行是同一条路；成员行另带 `ContentHighlightRequest`（成员名按整词匹配、取离它的行号最近的一处），像 Find 的成员结果那样滚到那一行并闪一下。
- **状态**：一个状态枚举，取值为加载类型、建成员语料（带进度）、就绪、失败（原因加重试）、没有可数的名字。
- 口径、成员分组、两个开关与 N 记在 `AppDefaults` 里，所有窗口共用，跨启动沿用。

### 4. 导出

Export 菜单里三项，都按当前口径与筛选导出：

- **Export Image…**：PNG，导出整张画布而不只是看得到的那一块，按窗口当前的外观填实背景，最多 2 倍分辨率，超过四千万像素时等比缩小。默认文件名 `AppKit - Type Suffixes.png`。
- **Export Word Counts as CSV…**：一个词一行，列为 `word,count`，包含排行表里的全部词，不只词云画出来的那些。CSV 不放名字：成员口径下一个常见词就对应几千个名字，放进一格会超过 Excel 单格 32,767 字符的上限。
- **Export Word Counts as JSON…**：镜像、口径、筛选与开关，以及每个词的次数和用到它的全部名字（类型带名字与种类，成员另带所属类型），按次数降序，次数相同按字母序。

### 5. 代码落点与测试

（2026-11-18 按 0091、0094、0095、0096 之后的分层改写：草案写成时 ViewModel 还在 `RuntimeViewerApplication` 与 App target 里。）

- **Core**（`RuntimeViewerCore/Search/`）：`RuntimeEngine.members(in:shownUnder:)`，命令 `CorpusMembersCommand`（线上名 `corpusMembers`，关于一个镜像：借用共享缓存镜像的 Engine 交给该镜像的拥有者回答），类型 `RuntimeObjectMembers`。语料仓库的 `members(in:shownUnder:)` 与 `searchMembers` 用同一条可见性规则（`RuntimeInterfaceCorpusEntry.member(at:in:projectedLineTable:)`），存盘的语料照搜索那样读回。测试用 Foundation：没建语料时返回 `nil`；不给选项时，成员搜索找到的成员都在结果里；打开 Strip Synthesized Methods 后访问器不在、属性还在。
- **RuntimeViewerAppCore**（`NamingWordCloud/`）：拆词、前缀统计、复合词预设、四种口径的计数、按「最有代表性」定类别、用法列表、CSV 与 JSON 编码，都是不依赖 UI 的值与函数；窗口的 ViewModel、路由与状态枚举；三种类别色是 `ColorDescriptor` 的新值。设置记在 `AppDefaults`。测试在 `RuntimeViewerAppCoreTests`：拆词的边界情况（缩略词、数字、下划线、选择子、前缀、复合词）、去重与跳过规则、定色、两种编码（含 CSV 转义），以及 ViewModel 的状态与导航。
- **RuntimeViewerAppUI**：类别色的解析（`ColorDescriptor.color`）。
- **RuntimeViewerUI**（`AppKit/WordCloud/`）：`WordCloudLayout` 只接收量好的词尺寸，算出画布大小与每个词的位置，是纯几何计算，测试（`RuntimeViewerAppUITests`）断言不重叠、不出界、同样的输入得到同样的结果；`WordCloudView` 是滚动视图的文档视图，负责画它，以及悬停、点击、选中与拖拽平移，并给出所有词的外接矩形（`wordsBoundingRect`，供打开时与 Zoom to Fit 缩放）。排版放在后台做。`CenteringClipView`（2026-11-19 新增）是让比自己小的文档视图居中的 clip view，不认识词云，任何滚动视图都能用。
- **App**（`NamingWordCloud/`）：`NamingWordCloudWindowController`（统一样式的工具栏、标题与副标题；工具栏的 delegate 是窗口的内容视图控制器）、`NamingWordCloudCoordinator`（导出的存储面板以表单挂在词云窗口上、Compound Words 表单）、`NamingWordCloudViewController`、`NamingCompoundWordsViewController`；`MainCoordinator` 处理 `MainRoute.namingWordCloud(imagePath:)`，按镜像管着这个文档的词云窗口（一个镜像一个，再开就提到前面，主窗口关闭时一起关）。入口两处：View 菜单的 Show Naming Word Cloud（`MainWindowController.showNamingWordCloud(_:)`，侧栏开着镜像时可用），以及镜像列表右键菜单的新动作 `RuntimeImageAction.showNamingWordCloud`——它经 `DocumentState.namingWordCloudRequested` 请求窗口，因为侧栏的 coordinator 够不到主窗口的。
- 不新增 target，不改工程设置，所以 Tuist 描述不用动。落地时 README 的功能列表加一行。

### 6. 落地步骤

1. **Core 读语料成员的命令**（已完成）—— `RuntimeObjectMembers`、`CorpusMembersCommand`、语料仓库的 `members(in:shownUnder:)`、路由声明
   - 行为：`imageWithoutCorpus`、`membersMatchAMemberSearch`、`optionsHideWhatTheyHide`；`SharedCacheRoutingDeclarationTests` 列入新命令
2. **AppCore 的拆词与计数**（已完成）—— 拆词、前缀、复合词、四种口径、去重与跳过、定色、CSV 与 JSON
   - 行为：缩略词与数字的拆法、选择子与下划线、前缀按镜像统计并去掉、复合词合并、虚词去掉、各种跳过与去重、按「最有代表性」定色、CSV 转义、JSON 的形状与排序
3. **RuntimeViewerUI 的排版与画布**（已完成）—— `WordCloudLayout`、`WordCloudView`
   - 行为：不重叠、不出界、确定性、画布按词的总面积定；点到词、点到空白
4. **AppCore 的窗口 ViewModel**（已完成）—— `NamingWordCloudViewModel`、状态、设置、类别色
   - 行为：类型口径一打开就能算；成员口径等语料建好再算；语料开关关着时成员口径给提示；对端太旧时成员口径给提示；换生成选项重算；点用法里的一行在主窗口打开（成员带高亮）；导出的内容
5. **App 的窗口与入口**（已完成，界面待用户看）—— 窗口控制器、view controller、`MainCoordinator` 的窗口管理、View 菜单、镜像列表右键菜单、导出面板、README
   - 行为：App 编得过；一个镜像只开一个窗口；界面效果由用户看
6. **照原生窗口重排**（2026-11-19 验收后加，用户已批准）—— 控件进工具栏、右栏照 Inspector 排、词云打开时缩放居中、画布右下角加控制按钮、小字降低不透明度、默认 N 改为 150。在 `feature/naming-word-cloud` 上做：先把 `next` 合进这条分支（它停在第五步，`next` 之后又跟上了 MachOKitExtensions 2.0.0 与 MachOSwiftSection 0.25.0），再把常驻检出里还没提交的那次布局修复与本提案的改动带过去。那次修复给顶栏加的抱紧优先级随顶栏一起删掉。

   改动地图：

   | 文件 | 动作 | 改什么 | 为什么 |
   |---|---|---|---|
   | `RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/CenteringClipView.swift` | 新增 | `NSClipView` 子类：`constrainBoundsRect(_:)` 在文档视图比自己小的方向上居中，其余照父类夹紧 | 缩小后词云不再贴在左上角 |
   | `RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/CanvasControlsView.swift` | 新增 | 浮在画布上的一组按钮：抓手开关、缩小、缩放比例、放大、适合窗口；给它缩放倍数与范围，它更新比例文字、到头时把按钮变灰；macOS 26 起是 `NSGlassEffectView` 底，之前是 `NSVisualEffectView`。只放按钮，不认识滚动视图，也不用 RxSwift | 用户要在画布上直接缩放与平移 |
   | `RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/FloatingPlatterView.swift` | 新增 | 浮在画布上的圆角底板：macOS 26 起是 `NSGlassEffectView`，之前是 HUD 材质的 `NSVisualEffectView`；内容视图贴满它 | 控制按钮与状态行用同一种底 |
   | `RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/WordCloudView.swift` | 修改 | 新增 `wordsBoundingRect`；新增 `isHandToolActive`（抓手打开时为真：点击不选词，悬停不垫底，光标处处是张开的手；拖动照常平移）；`WordCloudTypography` 加小字的字号界线与不透明度（18pt、0.6），`draw` 按它画，悬停与选中的词满色 | 打开时与适合窗口按词而不是按画布缩放；抓手；小字不抢眼 |
   | `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/NamingWordCloud/NamingWordRankingOrder.swift` | 新增 | 排行表的排序：按次数或按词，正序或倒序；默认按次数倒序 | 表头排序的取值 |
   | `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/NamingWordCloud/NamingWordCloudViewModel.swift` | 修改 | `Input` 加 `rankingOrderChanged`；`Output` 加排好序的 `rankingRows`、`rankingOrder`、`wordCountText`、`usageDetailColumnTitle`；`usageTitle` 在没选词时为 No Word Selected | 排序与右栏的文字归 ViewModel，表格只显示 |
   | `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/NamingWordCloud/NamingWordCloudPreferences.swift` | 修改 | `wordLimit` 默认 500 → 150 | 整片缩进窗口时字要看得清 |
   | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/NamingWordCloud/NamingWordCloudWindowController.swift` | 修改 | `toolbarStyle = .unified`、标题 Naming Word Cloud、副标题镜像名、装上工具栏并以内容视图控制器为 delegate | 原生的窗口外框 |
   | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/NamingWordCloud/NamingWordCloudCoordinator.swift` | 修改 | `configure` 改传镜像名 | 标题与副标题分开 |
   | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/NamingWordCloud/NamingWordCloudViewController.swift` | 修改 | 删 `topBar`；遵循 `NSToolbarDelegate`，用自己的控件做工具栏项；右栏两段的标题行；两张表改成两列带表头，排行表的表头点击送进 ViewModel；滚动视图换 `CenteringClipView`；打开与重排后按 `wordsBoundingRect` 缩放居中；画布右下角放 `CanvasControlsView` 并接上缩放（每次乘除 1.25、以可见区域中心为基准、带动画）、回到 100%、适合窗口与抓手，⌘+ ⌘− ⌘0 ⌘9 四个快捷键；缩放变了就更新比例；⚙︎ 菜单去掉 Zoom to Fit 与 Actual Size；状态行换成与控制按钮同一种底 | 窗口外框、右栏与词云浏览三处的改动都在这里；缩放只动滚动视图，照 11-18 的决定留在视图控制器里 |
   | `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/CenteringClipViewTests.swift` | 新增 | 小文档居中、大文档照常夹紧 | |
   | `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/CanvasControlsViewTests.swift` | 新增 | 比例文字取整、到头时按钮变灰 | |
   | `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/WordCloudLayoutTests.swift` | 修改 | 外接矩形盖住每个放下的词；小字的不透明度；抓手打开时点词不选 | |
   | `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/NamingWordCloudViewModelTests.swift` | 修改 | 排序、右栏文字、默认 N | |
   | `Documentations/Evolutions/0097-naming-word-cloud.md` | 修改 | 本提案（落地时由 `draft-naming-word-cloud.md` 改名） | |

   改了什么：

   ```
   NamingWordCloudWindowController
     NSWindow   ~ toolbarStyle = .unified, title "Naming Word Cloud", + subtitle = image name
     + NSToolbar("NamingWordCloud") ── delegate ──▶ NamingWordCloudViewController

   NamingWordCloudViewController : BaseViewController<NamingWordCloudViewModel>, + NSToolbarDelegate
     - topBar: HStackView
     + toolbar items: measure · memberGroup (Member Words only) · flexibleSpace
     +                options (NSMenuToolbarItem) · export (NSMenuToolbarItem)
     +                trackingSeparator (NSTrackingSeparatorToolbarItem → mainSplitView, divider 0)
     mainSplitView
     ├─ cloud pane
     │    cloudScrollView
     │      + contentView = CenteringClipView                      (RuntimeViewerUI)
     │        documentView = WordCloudView   + wordsBoundingRect, + isHandToolActive
     │  ~ statusPlate → FloatingPlatterView                        (RuntimeViewerUI, same as canvasControls)
     │  + canvasControls: CanvasControlsView                      (RuntimeViewerUI, bottom-right)
     │      hand tool · zoom out · zoom level · zoom in · zoom to fit  ──▶ cloudScrollView.magnification
     └─ sideSplitView (inspector column)
          ~ Words:   + header row · rankingTable  ~ Word | Count, header, sortable
          ~ Used By: + header row · usageTitle · usageTable  ~ Name | Kind / Declared In, header

   NamingWordCloudViewModel                                       (RuntimeViewerAppCore)
     Input   + rankingOrderChanged: Signal<NamingWordRankingOrder>
     Output  + rankingRows: Driver<[NamingWordCloudWord]>          sorted by rankingOrder
             + rankingOrder: Driver<NamingWordRankingOrder>
             + wordCountText: Driver<String>
             + usageDetailColumnTitle: Driver<String>
   + NamingWordRankingOrder
   ~ NamingWordCloudPreferences.wordLimit   default 500 → 150
   ```

   - 行为：`smallerDocumentIsCentered`、`documentSmallerAlongOneAxis`、`largerDocumentIsClampedAsBefore`；`boundingRectCoversEveryPlacedWord`；`wordsBelowEighteenPointsAreTranslucent`；`rankingDefaultsToCountDescending`、`rankingSortsByWordThenReverses`、`equalCountsAreOrderedByWord`；`rankingRowsAndWordCount`、`rankingHeaderClicks`、`usageTitleSaysNoWordSelectedWithoutSelection`、`usageDetailColumnFollowsMeasure`；`defaultWordLimitIs150`；`zoomLevelTextRoundsToWholePercent`、`zoomOutIsDisabledAtMinimumMagnification`、`zoomInIsDisabledAtMaximumMagnification`、`handToolToggles`、`zoomShortcuts`；`handToolClickOnAWordSelectsNothing`
   - 界面（编 App 后用 LookInside 量，再由用户看）：控件都在工具栏里、窗口里没有手搭的控件行；工具栏的分隔项与左右分栏的分隔线对齐；打开时词云居中并整片在可见区域内；画布右下角的按钮能缩小、放大、回到 100%、适合窗口，抓手打开后点词不选，四个快捷键有效；以默认窗口大小打开 AppKit 的 Type Suffixes 时，记下缩放倍数与最小的词在屏幕上的字号，目标不小于 8pt，达不到就报给用户，不自行再改 N

**不做**：命令行与 MCP 输出（以后要做时，把拆词与计数挪进命令行也能链接的无 UI 模块即可）；PDF 与 SVG 导出；多个镜像合成一张词云；旋转摆放的词；单复数合并（`View` 与 `Views` 分开算）。

**已知局限**：

- 不在复合词表里的复合角色词，按最后一个词算：UIKit 内部常见的 `VisualProvider` 记作 `Provider`，要合并就自己加进表里。
- Swift 方法只有基本名，参数标签里的词不计入。
- Swift 的 override 照算，因为生成选项里没有藏它的开关；ObjC 的跟随 Strip Overrides。
- ObjC 协议列表里有别的镜像的协议副本：一个镜像用到的协议都会带一份协议记录，侧栏同样列着它们，所以这些副本也会算进来。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-31 | Created as Draft | 用户想看一个框架的命名习惯——类型名里的 Manager、Service、Session，以及属性名与方法名——并能导出。 |
| 2026-10-31 | 开独立窗口 | 用户选定：现有界面一处不变，窗口开着也能照常在主窗口浏览、跳转。 |
| 2026-10-31 | 四种口径都做 | 用户选定：类型名的最后一个词、类型名的所有词、成员名的所有词、方法名的第一个词。 |
| 2026-10-31 | 点词列出用到它的名字，点一行在主窗口打开 | 用户选定；词云因此能用来查东西，不只是看。 |
| 2026-10-31 | 导出 PNG、CSV 与 JSON；不做 PDF、SVG 与命令行 | 用户选定的范围。 |
| 2026-10-31 | 成员取自 Find 语料，经 Engine 共享的语料协调器请求 | Swift 成员要打印过才列得全；语料已经按种类存着每个成员，还有盘上缓存，另起一套等于把整个镜像再打印一遍。经协调器请求才能与 Find 共用一次构建、出现在 Report 导航器里，并且不被 App Nap 拖慢。 |
| 2026-10-31 | 拆词和计数放在 App 一侧，引擎只多一条读语料成员的命令 | 怎么拆、怎么数是展示层的决定，改口径不必动线上协议；放在引擎一侧就得另立命令扩展模块，并在每个服务 Engine 的进程里各装一次。 |
| 2026-10-31 | 统计时总是隐藏合成的访问器与 ivar | 默认生成选项不隐藏它们，一个 ObjC 属性会再以 getter、setter 与 ivar 出现，Method First Words 里的 `set` 会被每个可写属性多算一次。 |
| 2026-10-31 | 前缀从镜像自己的类型名里统计，不写死前缀表 | Apple 的前缀成百上千，私有框架各有各的；按镜像统计对第三方 App 也成立。 |
| 2026-10-31 | CSV 只放词与次数，名字只进 JSON | Excel 单格上限 32,767 字符，成员口径下一个常见词的名字列表远超这个长度。 |
| 2026-10-31 | 词云只用一种颜色的深浅，加上选中词的强调色 | 颜色不代表任何类别，彩色会被读成有含义；精确比较交给排行表。 |
| 2026-10-31 | 加复合词预设，用户可以增删 | 用户提出 `DataSource` 这类词不该拆开。预设按 Apple 框架名字里两个词连着出现的频率挑；不同框架的习惯不一样（UIKit 内部满是 `VisualProvider`），所以留了增删的入口。 |
| 2026-10-31 | 不算编译器补上的 NSObject 协议四个属性 | 每个遵循协议的 ObjC 类都带着 `hash`、`superclass`、`description`、`debugDescription`；在四个 UI 框架的成员名里，`debugDescription` 一项就出现约两千次。 |
| 2026-10-31 | 界面全部用 AppKit | 用户明确不用 SwiftUI；这也与本仓库的既有规定一致：SwiftUI 只用于设置页。 |
| 2026-10-31 | 画布做得比窗口大得多，拖拽与滚动浏览，排版与窗口大小脱钩 | 用户要求画布要大、能拖拽和滚动查看。字号只看次数、画布按词的总面积定，于是改变窗口大小不必重排，同一组词始终是同一张图；默认词数随之从 150 提到 500。 |
| 2026-10-31 | 加双指缩放与 Zoom to Fit | 画布比窗口大得多时要能一眼看到全貌；`NSScrollView` 自带缩放，代价很小。是 agent 加的，待用户确认是否保留。 |
| 2026-10-31 | `$` 开头的成员不算，去重时忽略开头的下划线 | 原型里，`$__lazy_storage_$_…` 排在 View 一词用法列表的最前面；Swift 属性的存储 `_name` 与属性 `name` 是同一个名字。 |
| 2026-11-01 | 词云字体改用 SF Mono，按字号加粗 | 用户看了原型觉得不好看，要求试 SF Mono。 |
| 2026-11-01 | 改用分类配色，取代 2026-10-31 的「只用一种颜色」 | 用户要加颜色。颜色于是承担含义：表示一个词最有代表性的那一类名字，并配图例。每种口径不超过三类，因为参考色板里只有前三色两两都能分开。 |
| 2026-11-01 | 按「最有代表性」而不是「占多数」定色 | 原型里按多数定色时，成员口径几乎全是方法色：方法比属性与 ivar 多得多。按占比高出平均最多的那一类定色，三种颜色才都会出现，也更能说明一个词属于哪类名字。 |
| 2026-11-18 | Accepted | 用户批准，由 Ultra 上的会话实现。功能分支从 `origin/next` 切出：本机 `next` 上有一个有意没推送的提交，还有一份等用户看过的本地合并，都不该随这条分支推上去。 |
| 2026-11-18 | 三件待定的事按草案原文处理 | 起草时留给用户的三件事，批准时按草案原文、范围最小的做法定下：一、ObjC 的 override 照草案「已知局限」所写，跟随文档的 Strip Overrides，不在 ⚙︎ 里另加开关（起草时的建议是加一个默认打开的开关，因为不去掉时 AppKit 的 `dealloc` 在 Method First Words 里排第六；以后要加只多一个开关）。二、双指缩放与 Zoom to Fit 保留，草案「浏览」一节本来就写着。三、仓库外的一次性原型已经不在两台机器上，不再留底，实现照草案从头写。 |
| 2026-11-18 | 代码落点按现在的分层改写，补落地步骤 | 草案写成之后，ViewModel 全部搬进了 RuntimeViewerAppCore（0091、0096），AppCore 不再用 AppKit 的颜色与图片（0094），目录按功能划分（0095），导航的 `.push` / `.pushHighlighting` 换成了 `SelectionRoute.open(_:in:highlighting:)`。§5 与 §3 的导航一句据此改写，并把实现拆成五步写进新的 §6。 |
| 2026-11-18 | 第一步：命令名 `corpusMembers`，成员行高亮只用成员名 | 命令关于一个镜像，所以由镜像的拥有者回答，与建语料的命令一致。成员不带声明行，点用法里的成员行时，`ContentHighlightRequest` 的 `lineText` 留空：内容区找不到同样的一行时，本来就退到按成员名整词匹配、取离行号最近的一处。对端早于这条命令时，2.1.0 以后的版本都回 `isUnknownCommand`，窗口据此提示对端太旧。 |
| 2026-11-18 | 第二步自定的细节 | 一、复合词预设 18 个：草案点名的 14 个（`ViewController`、`GestureRecognizer`、`DataSource`、`IndexPath`、`TraitCollection`、`HitTest`、`CornerRadius`、`SafeArea`、`ToolTip`、`KeyPath`、`RunLoop`、`TimeZone`、`UserInfo`、`PopUp`），加 `FirstResponder`、`LayoutGuide`、`LineBreak`、`WhiteSpace`。没有原型可以按频率重新统计，所以只加了这几个固定说法，不加以 `Manager`、`Controller` 这类角色词结尾的组合，免得吃掉类型后缀。二、虚词表：and、as、at、by、for、from、in、into、of、on、or、the、to、with。三、类名前缀取两到三个大写字母后面还跟着大写字母的开头，三个字母的候选占到两个字母那个的八成以上才取它（Metal 得 `MTL`，AppKit 的 `NSURL…` 不会把 `NS` 变成 `NSU`）；至少要有三个、且占类型名的五分之一，否则不认前缀。四、局部类型与用户做出来的特化类型的成员也不算，与类型口径一致。五、类型名取 `displayName` 去掉外层类型与泛型参数，只用来拆词；JSON 里的类型名与所属类型写完整的 `displayName`。六、一个词的写法取它最常见的那种，用来决定是不是缩略词。 |
| 2026-11-18 | 第三步自定的细节 | 一、螺旋线是按画布比例拉伸的阿基米德螺线，圈距约 19 点（比最小的词连同间距还矮），步长按弧长约 8 点；碰撞检查把已放下的词按 48 点见方的格子归档，只比附近的。Debug 构建下 500 个词约 1.5 秒，在后台算。二、字号与字重的规则放在 RuntimeViewerUI 的 `WordCloudTypography`，量文字尺寸在主线程，排版在后台。三、画布是自绘的 `NSView`，不继承 `LayerBackedView`：整块画布连底色都在 `draw(_:)` 里画，不用图层属性。四、点在空白处什么也不做，不清掉选中。五、导出 PNG 时先把选中与悬停的底板拿掉，画完再放回。 |
| 2026-11-18 | 第四步自定的细节 | 一、状态枚举 `NamingWordCloudState`：索引镜像、建语料（都带进度）、就绪、不可用（语料开关关着、对端太旧、文档没有后台工作可建语料、没有可数的名字）、失败；加载占位照 `withLoadingPlaceholder` 的规矩，快的读取不闪。二、设置整体存成 `AppDefaults.namingWordCloudPreferences`（一个 `Codable` 值，缺的键读成默认值），窗口经它的 `$` 投影互相同步。三、换口径只在「读不读成员」变了时重读，其余开关、分组与词数只在后台重算。四、成员读法：先问引擎要，没有语料就向文档共享的语料协调器请求优先构建，等它的状态到 built 再取；协调器没接这个请求（这个 Engine 不建语料）时提示不可用，不空等。五、Print Exported Declarations Only 按语言分别作用于类型：ObjC 类型看 ObjC 的开关，Swift 类型看 Swift 的。六、Compound Words 表单单独一个 `NamingCompoundWordsViewModel`，增删直接写回设置；输入能对上某个预设时直接恢复，不管能不能拆成两个词（全小写的 `datasource` 也行），其余单个词拒绝并说明。七、用法点开走 `.focusedTab`。 |
| 2026-11-18 | 第五步自定的细节 | 一、右键菜单的入口经 `DocumentState.namingWordCloudRequested` 请求窗口，照 `startOverRequested` 的先例：镜像列表的 ViewModel 的路由只到侧栏的 coordinator，够不到 `MainCoordinator`。View 菜单的入口直接触发 `MainRoute.namingWordCloud(imagePath:)`，只在侧栏开着镜像时可用。二、词云窗口记住大小与位置时按镜像名分开存（`NamingWordCloud <镜像名>`）：同时开着的几个窗口不能共用一个自动保存名。三、Zoom to Fit 与 Actual Size 只动滚动视图的缩放，留在视图控制器里，不进 ViewModel。四、排行表与用法列表是单列表格、每行左右两个标签，用 `DifferentiableBox` 驱动，cell ViewModel 在 cell 构造闭包里建（行的内容完全由模型决定，用法列表可达数千行）。五、Compound Words 表单里回车是 Add、Esc 是 Done，免得在输入框里按回车就关掉表单。六、导出的存储面板以表单挂在词云窗口上，写入失败时用表单提示原因。 |
| 2026-11-18 | 实现完成，待用户看过后收尾 | 验证在 Ultra 上：每步构建通过、相关测试全过，第一到第四步的新测试各做过变异检查（去掉对应实现会变红）；macOS App 经 Tuist workspace（Debug）编过。最终提交上 Core 包全部测试 1124 个，失败的是交叉引用的「之后加载的镜像会更新分析器」一条和后台索引的三条，单独重跑全过（整包并行时的负载问题，后台索引那几条记忆里早有记录）；Packages 包 1398 个，失败 4 条：标题悬停副标题、Call Hierarchy 超时是基线上本来就红的，`BackgroundWorkProcessActivityTests`、`ReportSharedByEngineTests` 是整包一起跑才红。没做的：界面没有实际操作过（排版、配色、悬停与点选、拖拽和缩放、导出），由用户看。文档：README 功能列表与右键菜单一行已更新；不另写使用指南或实现说明，规则都在类型的文档注释里；没有新术语。草案没有网页版，正式收尾时生成。 |
| 2026-11-19 | 验收时修复窗口布局：顶栏的纵向抱紧优先级提到 750 | 用户第一次验收时，顶栏的控件落在窗口的垂直中间，词云被压成底部约 30 点高的一条。LookInside 实测顶栏被拉到 699 点高：栈视图纵向抱紧的默认优先级是 250，右侧分栏保持面板高度的优先级也是 250，两者打平时，多出的高度给了顶栏。修复后复测，顶栏 24 点，分栏占满其余高度。视图控制器在 App target 里，没有测试 target 能测到它，所以没有回归测试。仓库里别处的栈视图下面要么是不争高度的滚动视图，要么栈本身高度固定，没有同类写法。 |
| 2026-11-19 | 照原生窗口重排，加第 6 步 | 用户看了第一版，觉得词云本身、窗口外框与顶栏、右侧两张表都不好看，选择照原生 macOS 窗口的做法重排：控件进统一样式的工具栏，右栏照 RV 主窗口的 Inspector 排，词云打开时缩放居中。先改提案，用户点头后再实现。上一行加的顶栏抱紧优先级随顶栏一起删掉。 |
| 2026-11-19 | 右栏留在同一个视图控制器的 `NSSplitView` 里，不改用 `NSSplitViewController` 的 inspector 分栏项 | RV 要求每个视图控制器都有自己的 ViewModel，改成分栏控制器加两个子视图控制器，就得把已经实现并测过的 ViewModel 拆成两个。换来的只有工具栏分隔项和收起右栏的按钮，而分隔项用 `NSTrackingSeparatorToolbarItem` 指向普通的 `NSSplitView` 也做得到。收起右栏不做。 |
| 2026-11-19 | 打开时整片词云缩放进可见区域，默认 N 从 500 改回 150 | 词云是用来一眼看全貌的。验收时用户缩放到整片可见（LookInside 读到缩放倍数 0.356），12pt 的小词只剩四点多高。10-31 定下的大画布与拖拽浏览保留，⚙︎ 菜单里仍可选 500 及以上。 |
| 2026-11-19 | 字号 18pt 以下的词用 60% 不透明度，取代 10-31 的「字一律满色」 | 几百个小字都用饱和色时画面很花，这是用户觉得词云不好看的原因之一。当初的顾虑（小字的颜色更难分辨）仍然成立，由排行表的圆点补足。agent 提议，用户确认。 |
| 2026-11-19 | 排行表补上两列与表头排序 | 第 3 节一直写着排行表可排序，第一版做成了没有表头的单列表，也没有排序。 |
| 2026-11-19 | 画布右下角加一组控制按钮：抓手、缩小、缩放比例、放大、适合窗口 | 用户看过第 6 步的初稿后要求在画布上加缩小、放大、自适应与移动的按钮。「移动」按抓手工具做（打开后在词上拖也平移、点击不选词），这是 agent 的理解，用户可以改。缩放与适合窗口有了按钮，⚙︎ 菜单里的 Zoom to Fit 与 Actual Size 去掉；快捷键照「预览」。macOS 26 起按钮浮层用 Liquid Glass，之前用半透明底，状态行随之用同一种底。 |
| 2026-11-19 | 第 6 步获批准并开工 | 用户批准。实现时发现拖动本来在词上也能平移（第五步的实现就是这样，提案原文写成了只拖空白处），所以抓手只改点击：点词不选、悬停不垫底；属性因此叫 `isHandToolActive` 而不是初稿的 `pansOnAnyDrag`。控制按钮与状态行共用的底板单独成 `FloatingPlatterView`。 |
| 2026-11-19 | 第 6 步验收通过 | 用户在 Ultra 上看过新界面，认可。LookInside 实测：打开时词云按词的外接矩形缩放并居中（用户存的 N 是 500，缩放倍数 0.528，最小的词在屏幕上约 6.3pt，低于 8pt 的目标；默认的 150 没有实测，因为改 N 会改用户自己的设置）。LookInside 读到两块浮层底板的高度只等于内容高度（stack view 的上下 edgeInsets 没撑起高度），用户看过实际画面认为没问题，不改。 |
| 2026-11-19 | Implemented，编号 0097 | 六步都已实现并经用户验收，合进 `next`。与方案不同之处都记在上面几行：第 6 步是验收后加的，抓手只改点击（拖动本来在哪里都能平移）。没做的只有 LookInside 实测里「默认 150 词时最小词的屏幕字号」一项，因为要改用户自己的设置，不算后续项。文档：README 的 Naming Word Cloud 一条补上画布按钮与表头排序；不另写使用指南（README 与窗口本身已经说清怎么用）也不另写实现说明（本提案的第 3、5、6 节就是）；术语表加「口径（measure）」一条。 |
