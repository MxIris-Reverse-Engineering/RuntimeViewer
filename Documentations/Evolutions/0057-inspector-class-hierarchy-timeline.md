# 0057 - Inspector 的类与协议层级：时间线式的对象列表与继承树

- **状态**: Implemented
- **创建日期**: 2026-10-20
- **最后更新**: 2026-10-20
- **实现分支 / PR**: `feature/inspector-class-hierarchy-timeline`（从 `next` 切，并回 `next`）
- **配套文档**: 无（理由见决策日志 2026-10-20 的 Implemented 一行）

## 摘要

Inspector「Class」页的 Hierarchy 现在是一个 Label，里面是用换行拼起来的类名：既看不出每一级是
ObjC 还是 Swift、在哪个镜像，也点不了。改成和 Relationships 页一样的行（`RuntimeObjectCellView`：
语言图标、类名、所在镜像），从被查看的类开始逐级列到根类。相邻两级的图标之间画一条带箭头的竖线，
连成一条时间线；点一行跳到那个类。

```
Hierarchy
  [C]  NSButton
   │   AppKit
   ▼
  [C]  NSControl
   │   AppKit
   ▼
  [C]  NSView
   │   AppKit
   ▼
  [?]  NSObject           ← 定义它的镜像没被索引：问号图标、灰色名字、不可点
```

协议也有同样的 Hierarchy 页（实现中追加的范围）。一个协议可以继承多个协议，所以用 Outline 显示：被查看的
协议是根，下面是它继承的协议，每个再展开它自己继承的，与 Find 导航器的 Ancestor Types 是同一棵树。

```
Hierarchy
▾ [Pr] NSURLSessionDataDelegate
  ▾ [Pr] NSURLSessionTaskDelegate
    ▾ [Pr] NSURLSessionDelegate
        [Pr] NSObject
```

## 方案

**引擎（RuntimeViewerCore）**

- `RuntimeTypeRelationshipsResolver` 加一个只走父类链的扁平遍历 `superclassChain(of:)`。跨镜像、
  跨 ObjC / Swift 的解析与 materialize 规则照搬 Find 导航器的 Ancestor Types：不为此新建 section；
  定义某一级的镜像没被索引时，那一级只有名字（`object == nil`）。再往上的各级取自最后一个已索引的类
  自己的 ObjC 类数据：它沿父类指针一路记到根类，不管父类所在的镜像有没有被索引（继承 NSObject 的
  Swift 类看它 ObjC 的那一面）。这些级在已索引的镜像里找得到的照常解析成对象，找不到的只有名字；
  名字是 Swift 类的 ObjC 运行时名（`_TtC…`）时解码成 Swift 的写法。没有 ObjC 那一面的纯 Swift 类
  记不下更多，就停在未解析的那一级。它不收协议，按「最近的父类在前」排成一列，同样有环检测和深度上限。
- 新增 Core 命令 `runtimeObjectSuperclassChain`，对外是
  `RuntimeEngine.superclassChain(for:) -> [RuntimeRelationshipNode]`，登记进
  `registerBuiltInHandlers`。线上只是多一条命令；旧的 `runtimeObjectHierarchy` 不动，命令行工具仍用它。
- 对端是不认识这条命令的旧版本（例如更早注入的载荷）时，请求会失败：经 socket 是「No handler
  registered for …」，经 XPC 措辞不同。App 对取消以外的任何失败都退回旧命令拿到的名字，除第一行外
  都按「未解析」显示。

**App**

- `InspectorClassViewModel`（后改名 `InspectorHierarchyViewModel`，见「协议层级」）的状态改为
  `.loaded([InspectorHierarchyCellViewModel])`：第一行是被查看的对象本身，后面是父类链的每一级。新增的
  cell ViewModel（最初叫 `InspectorClassHierarchyCellViewModel`）与 `InspectorRelationshipsCellViewModel`
  同款，只有一个 `Appearance`：20pt 图标、12pt 类名、10pt 镜像名；两者的对象行由同一个
  `RuntimeObjectCellAppearance.inspectorRow(for:)` 构造。未解析的一级照 Find 导航器的样式显示：
  问号、灰色类名、没有镜像名；问号是与其他级同尺寸的灰色徽标。
- 点击：行有对象、且不是当前对象时，执行 `selectionRouter.trigger(.push(object))`，与 Relationships
  一致；未解析的行点了没有反应。
- 视图：页面结构与 Relationships、References、Specialization 页一致——顶部是「Hierarchy」页面标题
  （13pt semibold、`labelColor`，贴安全区顶部、左右缩进 8pt），下方 8pt 处是一个
  `SelfSizingTableView.scrollableNavigationListTableView()`（与 Relationships 同款：不抢焦点、不画选中），
  左右贴边、由表格的 inset 样式留白，cell 用 `RuntimeObjectCellView`。不再有折叠区和 Hide/Show。时间线由一个自定义的
  `NSTableRowView` 来画：每一行在图标上方画「进来」的那段，末端是指向这一级的箭头；图标下方画「出去」
  的那段。第一行没有进来的那段，最后一行没有出去的那段。线的 x 取 cell 里图标的实际中线，颜色用
  `tertiaryLabelColor`，随深浅色变化。行间距加大，留出画箭头的空间。
- 加载占位换成 `SkeletonPlaceholderView.runtimeObjectList`，位置同 Relationships 页（标题下 12pt、左右
  缩进 8pt）。`classHierarchy` 预设没有人用了，删掉它，并同步 `RuntimeViewerUsingAppKit/AGENTS.md` 里
  提到它的那句。原来的折叠区视图（`InspectorClassHierarchyView`、`InspectorDisclosureView`）只有这一页在用，
  一并删掉。

**协议层级（实现中追加）**

- 引擎：`RuntimeTypeRelationshipsResolver.refinedProtocolTree(of:)` 直接用 Ancestor Types 的协议遍历
  （`ancestorNodes(of:path:)`）：ObjC 协议、Swift 协议都行，Swift 协议继承的 ObjC 协议也在树里；同一个协议从
  几条路径到达就出现在几处，与 Xcode、Find 导航器一致。新 Core 命令 `runtimeObjectRefinedProtocolTree`，对外是
  `RuntimeEngine.refinedProtocolTree(for:) -> [RuntimeRelationshipNode]`。旧版本对端不认识它时，页面只显示协议本身。
- Inspector：协议也有 Hierarchy 页，排在第一位，与类的 Hierarchy 页是同一个页签（切换类与协议时用户选中的页签
  保持不变）。页面结构同 Class 页：「Hierarchy」页面标题、下方是自适应高度的 Outline（`SelfSizingOutlineView`），
  根是被查看的协议，全部展开；行仍用 `RuntimeObjectCellView`，与 Class、Relationships 页的行一致。点一行跳到那个
  协议，只有名字的行和根点了不跳转。
- 两页共用一个 ViewModel（`InspectorClassViewModel` 改名为 `InspectorHierarchyViewModel`，按对象种类取父类链
  或协议树）和一个 cell ViewModel（`InspectorClassHierarchyCellViewModel` 改名为 `InspectorHierarchyCellViewModel`，
  多了 `children` 和按路径生成的标识，可作 Outline 节点）。

**测试**

- Core：AppKit 的 ObjC 类（`NSButton` → `NSControl` → `NSView` → `NSResponder` → `NSObject`）和接 ObjC
  父类的 Swift 类（`NSScrollPocket: NSView`）各测一条，验证顺序、解析出的对象，以及未索引的那一级
  保留了名字；未索引的中间级之后接着列（`NSPersistentUIKeyedUnarchiver`、`AppKit._MultiShadowLayer`）。
  协议树测 ObjC 协议（`NSTableViewDelegate` 的两层）与 Swift 协议（`AppKit.MenuItemBase`，标准库协议未索引）。
- Application：ViewModel 生成 cell ViewModel 的顺序与第一行；对端不支持新命令时的回退；协议是唯一的根、
  继承的协议逐层挂在下面（`NSURLSessionDataDelegate` 的三层）。

**没有询问就采用的假设**

- 顺序沿用现在的：被查看的类在最上面，箭头朝下指向父类（「继承自」）。若要反过来（根类在上、箭头
  指向子类），只需反转数组和箭头方向。
- 不为这一页去临时索引未索引的镜像。这与 Ancestor Types 一致，也避免选中一个类就触发 Foundation、
  AppKit 这类大镜像的索引。
- 原先假设「Hierarchy」标题与 Hide/Show 保留；用户看过实现后改为去掉 Hide/Show、标题与其他页对齐（见决策日志）。

## 落地步骤

1. **引擎**：`RuntimeTypeRelationshipsResolver.superclassChain(of:)`、Core 命令 `runtimeObjectSuperclassChain` 与
   `RuntimeEngine.superclassChain(for:)`，以及 Core 测试。**已完成（2026-10-20）**：`RuntimeSuperclassChainTests`
   覆盖 ObjC 链、Swift 类接 ObjC 父类、未索引的 `NSObject`、根类，以及经 socket 与 XPC 两种连接调用这条命令。
2. **对象行**：cell ViewModel、`InspectorClassViewModel` 的新状态与对旧对端的回退、点击跳转；Hierarchy 折叠区换成
   `RuntimeObjectCellView` 的表格，加载占位换成 `runtimeObjectList`，删掉 `classHierarchy` 预设并同步
   `RuntimeViewerUsingAppKit/AGENTS.md`，折叠区内容不再左右缩进；以及 Application 测试。**已完成（2026-10-20）**：
   `InspectorClassViewModelTests` 覆盖行的顺序与对象、未索引镜像的对象、只有名字的一级、旧对端（`ScriptedPeer`
   只答旧命令）与点击；App 侧只做了改动文件的类型检查，完整构建留到第 4 步。
3. **时间线**：自定义 `NSTableRowView` 画竖线与箭头，行间距随之加大。**已完成（2026-10-20）**：行视图
   `InspectorClassViewController.HierarchyTimelineRowView` 在 `drawBackground(in:)` 里画，竖线 1.5pt、对齐设备
   像素，箭头 7×5pt，离图标 3pt；行间距 16pt（Relationships 页是 10pt）。App 没有测试 target，这一步只做了
   类型检查，画出来的样子要在 App 里看。
4. **验证**：Core 与 Packages 的全量测试、App 构建。**已完成（2026-10-20，macOS 26.7、Xcode 27.0）**：App 用 Debug
   workspace 以 Debug-arm64e 构建通过；Core 全量约 850 个测试有 3 个失败，Packages 全量 594 个有 2 个失败，全是
   这台机器上已知的旧问题——两个按 macOS 27 写的用例（`NSSmartNamingSuggestion`、Relationships 快照缺
   `_DefaultScopeRegistration`），以及三个满载时偶发的用例（后台索引批次取消、侧栏点击镜像切换文档、Always
   Index 按 Engine 停派发）。三个偶发用例单独重跑都通过；用户的 Debug 设置与书签文件在测试前后 SHA 不变。
5. **协议层级·引擎**（追加）：`refinedProtocolTree(of:)`、Core 命令 `runtimeObjectRefinedProtocolTree` 与
   `RuntimeEngine.refinedProtocolTree(for:)`，以及 Core 测试。**已完成（2026-10-20）**：Core 测试并入
   `RuntimeInspectorHierarchyTests`（原 `RuntimeSuperclassChainTests`，与父类链共用一个已索引 AppKit 的引擎），
   覆盖 ObjC 协议的两层树、Swift 协议里未索引的标准库协议只有名字、类没有协议树，以及经 socket 与 XPC 调用。
6. **协议层级·界面**（追加）：ViewModel 与 cell ViewModel 改名并支持协议树，新的 `InspectorProtocolViewController`
   （Outline），Inspector 的页签配置；以及 Application 测试。**已完成（2026-10-20）**：cell ViewModel 多了 `children`
   与按路径生成的 `identifier`，相等按标识（同一个协议出现在几处就是几个节点），遵循 `OutlineNodeType`；协议页用
   `SelfSizingOutlineView` 包在 `SelfSizingScrollView` 里，配置同导航列表（不抢焦点、不画选中、inset 样式），每次
   加载完全部展开；页签配置用 `TabConfiguration.Hierarchy`（`.superclasses` / `.refinedProtocols`）区分两页，
   `TabKind.classHierarchy` 与路由 `.classHierarchy` 改名 `.hierarchy`。`InspectorHierarchyViewModelTests` 加了协议树
   三层嵌套、旧对端只列协议本身、点继承的协议跳转。App 增量构建通过，协议页没在 App 里看过。
7. **验证**（追加）：Core 与 Packages 的全量测试、App 构建。**已完成（2026-10-20）**：App 增量构建通过；最终
   代码上 Core 全量 3 个失败、Packages 全量 597 个里 2 个失败，与第 4 步是同一批已知问题；用户的 Debug 设置与
   书签文件 SHA 不变。三个满载偶发的用例这次没有再单独重跑：机器负载太高，用户要求先停下、自己在 App 里看。

每一步都能单独构建、单独验证。第 2 步同时改 ViewModel 和视图，因为状态类型一变，旧视图就编不过。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-20 | Created as Draft | Class 页的层级只是一段换行拼接的类名，观感差且不能导航；改为与 Relationships 页一致的对象行，并在各级之间画时间线式的箭头 |
| 2026-10-20 | 父类链复用 Ancestor Types 的解析规则，新增一条扁平的 Core 命令；不去解析 `hierarchy(for:)` 返回的打印名字 | 打印出来的名字无法可靠地还原语言和定义它的镜像；Ancestor Types 已经解决了跨镜像、跨语言的父类解析，对未索引的镜像也有明确的「只留名字」规则 |
| 2026-10-20 | 放弃同日提出的「给层级文字加行距、加大标题下间距」 | 整块改成对象列表后，那套针对纯文本的间距调整不再适用 |
| 2026-10-20 | 用户批准，开始实现 | 状态改为 Accepted，在 `feature/inspector-class-hierarchy-timeline` 上实现 |
| 2026-10-20 | 方案拆成四个落地步骤 | 精简提案原本没有落地步骤；按「每一步都能单独构建、单独验证」拆分 |
| 2026-10-20 | 旧对端的回退对取消以外的任何失败生效，不只认 `RuntimeNetworkRequestError.isUnknownCommand` | 那个判断只认 socket 上的回复；注入载荷经 XPC 连接时，未知命令报的是另一种错误，只认它就会在这些对端上只剩第一行 |
| 2026-10-20 | 未解析的一级用灰色「?」徽标（`RuntimeObjectIcon` 的 IDE 风格徽标），不用 Find 导航器的 SF Symbol 问号 | 行里其他级都是 20pt 的徽标，同尺寸同形状的灰色徽标让时间线的竖线对准、观感一致；`RuntimeObjectCellView` 会把 SF Symbol 染成强调色，用它还得给 cell 加着色参数 |
| 2026-10-20 | Relationships 与层级的对象行共用 `RuntimeObjectCellAppearance.inspectorRow(for:)` | 两处要的是同一种行，原先构造代码只在 Relationships 的 cell ViewModel 里，抽出来避免复制一份 |
| 2026-10-20 | 折叠时内容同时隐藏，不只把高度压成 0 | 加载占位压不扁，不隐藏会在标题下方继续画出来 |
| 2026-10-20 | 每一级至少 30pt 高，即名字下面带镜像名的那种行的高度 | 只有名字的一级本来只有一行字高，箭头会短一截；旧对端回退时除第一行外全是这种行，整条时间线会变得局促 |
| 2026-10-20 | 实现完成，待合并 | 四个落地步骤都已完成。文档：提案、`RuntimeViewerUsingAppKit/AGENTS.md`（加载占位预设）与 0016 的覆盖表随代码更新；不另写使用指南或实现说明（只是界面变化，做法提案已写清），没有新术语。界面效果尚未在 App 里看过 |
| 2026-10-20 | 去掉折叠区与 Hide/Show，「Hierarchy」改成与 Relationships、References、Specialization 页一致的页面标题 | 用户看过实现后要求标题的字号、颜色与位置和其他 Inspector 页对齐，也不需要折叠；页面结构照 Relationships 页，两个折叠区视图随之删除，「折叠时隐藏内容」那条决定一并作废 |
| 2026-10-20 | 父类链遇到未索引的一级不再停下：再往上的各级用最后一个已索引类的 ObjC 类数据里记的名字接着列，能解析的照常是对象，未索引的只有名字、点了不跳转 | 用户决定。旧的文字版靠运行时元数据能列到根类，而后台索引默认关闭，看自家 App 的类时父类所在的框架常常没被索引，停在那里会比原来少几级；类数据本来就记着整条链，接着列不需要索引任何镜像 |
| 2026-10-20 | Swift 类的父类是导入的 ObjC 类、又没被索引时，那一级用它的 ObjC 运行时名（如 `CALayer`） | 与再往上从 ObjC 类数据里接出来的名字写法一致；Swift 表里打印出的名字在这种情况下不比运行时名更好读 |
| 2026-10-20 | 范围追加：协议也加 Hierarchy 页，用 Outline 显示继承树 | 用户要求。协议可以继承多个协议，层级是一棵树而不是一条链；Find 导航器的 Ancestor Types 已经能对协议建这棵树，引擎直接复用 |
| 2026-10-20 | 协议树的行用 `RuntimeObjectCellView`（两行：名字与镜像），不用 Find 导航器的单行结果行 | 与同在 Inspector 里的 Class、Relationships 页的行保持一致；复用的是 Find 的协议遍历和 Outline 的绑定方式 |
| 2026-10-20 | 类与协议共用一个 Hierarchy 页签和一个 ViewModel，视图各一个 | 两页的取数、加载占位、点击跳转、旧对端回退完全相同，只有取哪种层级和怎么画不同；同一个页签让用户在类与协议之间切换时停在原来的页签上 |
| 2026-10-20 | Implemented，编号 0057：随本次合并进入 `next` | 用户在 App 里看过之后以 `/finish-feature` 收尾。七个落地步骤全部完成；偏离原方案之处都已在上面各行记下（标题与 Hide/Show、接着列未索引的父类、追加协议层级）。编号取各远端分支上已有的最大号 0056 加一。没做完的项：无。配套文档：不另写使用指南或实现说明——这是 Inspector 里的界面变化，用法一看便知，做法与取舍都在本提案里；代码侧的约定只改了 `RuntimeViewerUsingAppKit/AGENTS.md` 里加载占位预设那两句。没有新术语要登记进 `Glossary.md`。最终代码上的全量测试只有本机已知的旧失败；三个满载偶发的用例在加入协议层级之后没有再单独重跑 |
