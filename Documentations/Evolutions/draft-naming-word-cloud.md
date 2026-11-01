# Draft - 框架的命名词云：类型名、属性名与方法名的词频

- **状态**: Draft
- **创建日期**: 2026-10-31
- **最后更新**: 2026-10-31
- **所属愿景**: 无
- **实现分支 / PR**: 批准后从 `next` 切 `feature/naming-word-cloud`

## 摘要

给一个镜像（框架）的命名做词云：把类型名、属性名和方法名拆成单词，按出现次数定字号，一眼看出这个框架的类型多叫 `Manager`、`Service`、`Session` 还是 `Controller`，方法名多以 `set`、`did`、`will` 中的哪个开头。词云开在独立窗口里；点一个词，列出用到它的类型或成员，点一行在主窗口打开。词云能导出成 PNG，词频能导出成 CSV 与 JSON。引擎只多一条读 Find 语料成员的命令，拆词与计数都在 App 一侧。

## 方案

### 1. 四种口径

窗口顶部的分段控件切换：

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
┌ AppKit — Naming Word Cloud ─────────────────────────────────────────────────┐
│ [Type Suffixes | Type Words | Member Words | Method First Words]  ⚙︎ ▾  Export ▾ │
├────────────────────────────────────────────┬────────────────────────────────┤
│                                            │ Word              Count        │
│       Delegate      View                   │ View                812        │
│   Cell    Controller     Manager           │ Controller          301        │
│      Item   Button   Layer   Session       │ Manager             128  ← 选中 │
│                                            ├────────────────────────────────┤
│                                            │ Manager — 128 types            │
│ Showing 142 of 1,034 words                 │ NSLayoutManager                │
│                                            │ NSFontManager  …               │
└────────────────────────────────────────────┴────────────────────────────────┘
```

（图中的词与数字只是示意。）

- **全部用 AppKit**：词云是自绘的 `NSView`，自己排版，用 `NSAttributedString` 画字，自己处理悬停与点击；排行表与用法列表是 `NSTableView`，左右分栏是 `NSSplitView`，口径切换是 `NSSegmentedControl`，⚙︎ 与 Export 是下拉的 `NSPopUpButton`。不用 SwiftUI，也不引入新的第三方依赖。
- **入口**：View 菜单的 Show Naming Word Cloud（文档有当前镜像时可用），以及侧栏镜像列表两页（目录与书签）的右键菜单。一个文档里每个镜像只开一个窗口，再次打开就把它提到前面；窗口随文档关闭，记住大小与位置。
- **词云**：
  - 显示当前口径排名前 N 的词，N 在 ⚙︎ 菜单里选 150、300、500、1,000 或全部，默认 500。
  - 字号只看次数：最常见的词 120pt，其余按次数的平方根缩小，最小 12pt，所以一个词占的面积大致与次数成正比。
  - **画布比窗口大得多**：画布大小由所有词的总面积决定，词约占四成，AppKit 的 500 个词约为 1,900 × 1,200 到 2,800 × 1,800 点。排版与窗口大小无关：同样的词总是排成同样的图，改变窗口大小只是露出的部分不同。
  - 从画布中心沿螺旋线摆放，大词先放，全部横排。画布按总面积留足了空间，一般都放得下；万一放不下，左下角的状态行写明画了多少、一共多少。状态行垫一块半透明底，词从它下面滚过也看得清。
  - **字体是 SF Mono**（`NSFont.monospacedSystemFont`），按字号加粗：56pt 以上 bold，28pt 以上 semibold，18pt 以上 medium，其余 regular。少数大词撑起画面，大量小词不抢眼。词与词之间留几个点的空隙。
  - **颜色表示这个词最有代表性的那一类名字**，每种口径三类以内：
    - 类型口径：类、协议、值类型（struct、enum、typealias 与 C 的 struct、union）；
    - 成员口径：属性、方法、其他（ObjC ivar 与 Swift 的 enum case）；
    - 方法首词口径：实例方法、类方法（含 Swift 的 static 与 class 方法）。

    「最有代表性」指：这一类名字里用到这个词的比例，比这一类在全部名字里的平均占比高出最多。这一类至少要有 3 个名字用到这个词，否则按多数算。不直接按多数定色，是因为方法比其他成员多得多，按多数的话几乎每个常见的成员词都是方法色。在 AppKit 上，`Delegate`、`DataSource` 落在协议色，`Accessibility`、`Size` 落在属性色，`default`、`register`、`current` 落在类方法色。
  - 三种颜色取自 dataviz 参考色板的前三个色位（浅色 `#2A78D6` / `#EB6834` / `#1BAF7A`，深色 `#3987E5` / `#D95926` / `#199E70`），画布底色取色板配套的 `#FCFCFB` / `#1A1A19`。用色板自带的校验脚本验过：三色两两之间在浅色、深色下都能分开，色弱也能分开。浅色下青色对底色的对比度是 2.74，低于 3:1，由右侧的排行表补足。字一律满色，不用深浅表示次数：次数已经由字号表示，再降透明度只会让颜色难以分辨。
  - 左下角状态行里有图例，只列当前画面用到的颜色。排行表里每个词前面是对应颜色的圆点，词本身仍是文字色。
  - 选中的词保留自己的颜色，背后垫一块同色浅底并描边；悬停的词只垫浅底。选中不再用强调色，因为颜色已经有了含义。
  - 悬停显示「Manager — 128 types」。
- **浏览**：画布放在 `NSScrollView` 里，打开时显示中心那一块。按住空白处拖拽平移，触控板与滚轮滚动，双指捏合缩放（10% 到 400%），⚙︎ 菜单里有 Zoom to Fit 与 Actual Size。按下后移动三个点以上才算拖拽，否则是点选。光标在空白处是张开的手、拖动时握拳、指在词上是手指。在排行表里选中一个词时，画布带动画平移到这个词。
- **右侧**：
  - 上半是全部词的排行表（词、次数），可排序。精确比较与无障碍阅读都走它。
  - 下半列出选中词的用法，分两列：类型口径是类型名与种类，成员口径是成员名与声明它的类型。公开的名字排在前面，下划线开头的私有名字排在后面。
  - 在词云或排行表里点一个词都会选中它。点用法里的一行，主窗口打开那个类型，走 `documentState.selectionRouter` 的 `.push`，与侧栏点一行是同一条路；成员行用 `.pushHighlighting`，像 Find 的成员结果那样滚到那一行并闪一下。
- **状态**：一个状态枚举，取值为加载类型、建成员语料（带进度）、就绪、失败（原因加重试）、没有可数的名字。
- 口径、成员分组、两个开关与 N 记在 `AppDefaults` 里，所有窗口共用，跨启动沿用。

### 4. 导出

Export 菜单里三项，都按当前口径与筛选导出：

- **Export Image…**：PNG，导出整张画布而不只是看得到的那一块，按窗口当前的外观填实背景，最多 2 倍分辨率，超过四千万像素时等比缩小。默认文件名 `AppKit - Type Suffixes.png`。
- **Export Word Counts as CSV…**：一个词一行，列为 `word,count`，包含排行表里的全部词，不只词云画出来的那些。CSV 不放名字：成员口径下一个常见词就对应几千个名字，放进一格会超过 Excel 单格 32,767 字符的上限。
- **Export Word Counts as JSON…**：镜像、口径、筛选与开关，以及每个词的次数和用到它的全部名字（类型带名字与种类，成员另带所属类型），按次数降序，次数相同按字母序。

### 5. 代码落点与测试

- **Core**：`members(in:shownUnder:)` 命令与 `RuntimeObjectMembers` 类型。语料仓库判断成员在给定选项下是否可见，复用 `searchMembers` 里的那段投影逻辑。测试用测试 bundle 的 fixture：没建语料时返回 `nil`；打开 Strip Synthesized Methods 后访问器不在结果里；选项为 `nil` 时与 `searchMembers` 看到的成员一致。
- **RuntimeViewerApplication**：拆词、前缀统计、四种口径的计数与用法列表、CSV 与 JSON 编码，都不依赖 AppKit；另有窗口的 ViewModel。测试覆盖拆词的边界情况（缩略词、数字、下划线、选择子、前缀）、去重与跳过规则，以及两种编码（含 CSV 转义）。
- **RuntimeViewerUI**：`WordCloudLayout` 只接收量好的词尺寸，算出画布大小与每个词的位置，是纯几何计算，测试断言不重叠、不出界、同样的输入得到同样的结果；`WordCloudView` 是滚动视图的文档视图，负责画它，以及悬停、点击、选中与拖拽平移。排版放在后台做，几百个词的排版要几百毫秒。
- **App**：`NamingWordCloud/` 下的 coordinator、窗口与 view controller；`MainMenuController` 与两处右键菜单的菜单项；导出用的存储面板放在 coordinator 里。
- 不新增 target，不改工程设置，所以 Tuist 描述不用动。落地时 README 的功能列表加一行。

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
