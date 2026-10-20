# Draft - Inspector 类层级改为时间线式的对象列表

- **状态**: In Progress
- **创建日期**: 2026-10-20
- **最后更新**: 2026-10-20
- **实现分支 / PR**: `feature/inspector-class-hierarchy-timeline`（从 `next` 切，并回 `next`）

## 摘要

Inspector「Class」页的 Hierarchy 现在是一个 Label，里面是用换行拼起来的类名：既看不出每一级是
ObjC 还是 Swift、在哪个镜像，也点不了。改成和 Relationships 页一样的行（`RuntimeObjectCellView`：
语言图标、类名、所在镜像），从被查看的类开始逐级列到根类。相邻两级的图标之间画一条带箭头的竖线，
连成一条时间线；点一行跳到那个类。

```
Hierarchy                         Hide
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

## 方案

**引擎（RuntimeViewerCore）**

- `RuntimeTypeRelationshipsResolver` 加一个只走父类链的扁平遍历 `superclassChain(of:)`。跨镜像、
  跨 ObjC / Swift 的解析与 materialize 规则照搬 Find 导航器的 Ancestor Types：不为此新建 section；
  定义某一级的镜像没被索引时，那一级只有名字（`object == nil`），遍历也停在那里。它不收协议，
  按「最近的父类在前」排成一列，同样有环检测和深度上限。
- 新增 Core 命令 `runtimeObjectSuperclassChain`，对外是
  `RuntimeEngine.superclassChain(for:) -> [RuntimeRelationshipNode]`，登记进
  `registerBuiltInHandlers`。线上只是多一条命令；旧的 `runtimeObjectHierarchy` 不动，命令行工具仍用它。
- 对端是不认识这条命令的旧版本（例如更早注入的载荷）时，请求会失败：经 socket 是「No handler
  registered for …」，经 XPC 措辞不同。App 对取消以外的任何失败都退回旧命令拿到的名字，除第一行外
  都按「未解析」显示。

**App**

- `InspectorClassViewModel` 的状态改为 `.loaded([InspectorClassHierarchyCellViewModel])`：第一行是
  被查看的对象本身，后面是父类链的每一级。新增的 cell ViewModel 与 `InspectorRelationshipsCellViewModel`
  同款，只有一个 `Appearance`：20pt 图标、12pt 类名、10pt 镜像名；两者的对象行由同一个
  `RuntimeObjectCellAppearance.inspectorRow(for:)` 构造。未解析的一级照 Find 导航器的样式显示：
  问号、灰色类名、没有镜像名；问号是与其他级同尺寸的灰色徽标。
- 点击：行有对象、且不是当前对象时，执行 `selectionRouter.trigger(.push(object))`，与 Relationships
  一致；未解析的行点了没有反应。
- 视图：Hierarchy 折叠区里放一个 `SelfSizingTableView.scrollableNavigationListTableView()`
  （与 Relationships 同款：不抢焦点、不画选中），cell 用 `RuntimeObjectCellView`。时间线由一个自定义的
  `NSTableRowView` 来画：每一行在图标上方画「进来」的那段，末端是指向这一级的箭头；图标下方画「出去」
  的那段。第一行没有进来的那段，最后一行没有出去的那段。线的 x 取 cell 里图标的实际中线，颜色用
  `tertiaryLabelColor`，随深浅色变化。行间距加大，留出画箭头的空间。
- 加载占位换成 `SkeletonPlaceholderView.runtimeObjectList`。`classHierarchy` 预设没有人用了，删掉它，
  并同步 `RuntimeViewerUsingAppKit/AGENTS.md` 里提到它的那句。
- 折叠区内容左右不再缩进 8pt，留白交给表格的 inset 样式，图标与 Relationships 页的行对齐。折叠时内容
  同时隐藏。

**测试**

- Core：AppKit 的 ObjC 类（`NSButton` → `NSControl` → `NSView` → `NSResponder` → `NSObject`）和接 ObjC
  父类的 Swift 类（`NSScrollPocket: NSView`）各测一条，验证顺序、解析出的对象，以及未索引的那一级
  保留了名字。
- Application：ViewModel 生成 cell ViewModel 的顺序与第一行；对端不支持新命令时的回退。

**没有询问就采用的假设**

- 顺序沿用现在的：被查看的类在最上面，箭头朝下指向父类（「继承自」）。若要反过来（根类在上、箭头
  指向子类），只需反转数组和箭头方向。
- 不为这一页去临时索引未索引的镜像。这与 Ancestor Types 一致，也避免选中一个类就触发 Foundation、
  AppKit 这类大镜像的索引。
- 「Hierarchy」标题与 Hide/Show 保留。

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
4. **验证**：Core 与 Packages 的全量测试、App 构建。

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
