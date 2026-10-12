# Draft - 接入 AppKitPlus 的过滤框、过滤栏与弹出式路径控件

- **状态**: In Progress
- **创建日期**: 2026-10-11
- **最后更新**: 2026-10-12

## 摘要

AppKitPlus 从 0.8.0 起带 `NSPopUpPathControl`（Xcode jump bar 背后的 DVTKit `DVTPathControl` 的移植），0.9.0 起带
`NSFilterSearchField` 与 `NSFilterTokenField`（Xcode 导航器与控制台过滤框 `DVTSearchField` / `DVTFilterTokenField` 的移植）。
RuntimeViewer 自己维护着同类的东西：Find 导航器的模式路径用的是自写的 `PopUpPathControl`（`RuntimeViewerUI`，见
[0029](0029-find-navigator.md) §4.2），五处过滤栏用的是 UIFoundation `FilterUI` trait 里的 `FilterSearchField`。本提案把它们
换成 AppKitPlus 的控件，删掉自写的路径控件。0.10.0 又带来 `NSFilterControlBar`（Xcode 导航器底部那条过滤栏 `DVTFilterControlBar`
的移植）与栏上的按钮 `NSFilterControlBarItem`：侧栏各页、Find、Report 底部那四条手搭的过滤栏换成它，框外的按钮换成 item。
AppKitPlus 升到 0.10.1：0.10.1 是为这次接入发的修复版，栏上的 item 原先会洗掉符号的颜色（见「过滤栏」）。`NSFilterTokenField` 这次不接：
RuntimeViewer 没有现成的 token 框，放在哪里都是一套新的过滤设计，另起提案。

## 方案

**依赖**

- `RuntimeViewerPackages/Package.swift`：AppKitPlus-Release 的下限 `0.4.2` → `0.10.1`；`uiFoundationTraits` 去掉 `FilterUI`
  （RuntimeViewer 只用到其中的 `FilterSearchField`，侧栏模糊搜索用的是独立的 fuzzy-search 包）；`RuntimeViewerApplication`
  与它的测试 target 显式依赖 AppKitPlus。
- 被跟踪的四份锁文件（Debug / Distribution 两个 workspace、`RuntimeViewerPackages`、`RuntimeViewerCommandLine`）只把
  appkitplus-release 从 0.8.0 改到 0.10.1。

**路径控件**：Find 导航器顶部的 `Find ▸ Text ▸ Containing` 换成 `NSPopUpPathControl`，打开 `selectsComponentsOneAtATime`
——AppKitPlus 为查找导航器模式条留的模式：各段是独立的选项，菜单不带子菜单。

- `NSPopUpPathControl` 从一棵条目树推出路径，ViewModel 输出的却是 `[FindModePathComponent]`。新增
  `FindModePathControlAdapter`（`RuntimeViewerApplication/Find`，与 `FindResultsPresentation` 同理：规则放在视图控制器之外，
  好做离屏测试）：一次建好整棵树（`Find` → 各模式 → 各模式的匹配方式），条目始终是同一批对象——控件按指针比较条目。强调色
  走委托的 `titleColorFor`，Members 菜单里 Regular Expression 前的分隔线走条目的 `groupIdentifier`。ViewModel 不动。
- 控件在用户选中时会先把自己的 `selectedItem` 换成选中的条目，再通知委托。适配层在 `didSelect` 里把它还原成 ViewModel
  最后给出的路径，再把选择交给 ViewModel。这样从 Text 换到 Members 时，界面不会先闪出缺了第三段的 `Find ▸ Members`；路径
  仍只由 ViewModel 决定，与原控件「只报告选择」的语义一致。
- `Find` 这一段：委托拒绝为它弹菜单，也拒绝选中它。与原控件的差别：它在悬停时会高亮（AppKitPlus 没有「纯文本段」），控件
  禁用时标题会变暗。
- 删除 `RuntimeViewerUI/AppKit/PopUpPathControl.swift` 与 `PopUpPathControlTests`，控件本身的行为由 AppKitPlus 的测试负责。

**过滤栏**：四条导航器底栏——侧栏镜像列表、侧栏对象列表、Find 结果过滤、Report——原先是分隔线下一个 `HStackView`（或单独一个
过滤框）加手写的边距，换成 `NSFilterControlBar`。

- 页面自己的 `NSFilterSearchField` 交给栏当 `filterField`，栏贴住左右与底边，高度用栏的 intrinsic 高度（边距在里面）。分隔线
  保留，贴在栏的上沿。控件尺寸设在栏上：栏接手框、改尺寸时都会改框的尺寸与字体，所以页面对框的其余设置写在栏之后。
  四条栏一律 large。侧栏两页与 Report 起初沿用原来的尺寸（macOS 26 起 extraLarge），换上 AppKitPlus 的控件后显得太大，改回 large（见决策日志）。
- 框外的按钮换成 `NSFilterControlBarItem`，框里的开关（Match Case、时钟）照旧留在框里，Xcode 也是这样分的：
  - 侧栏对象列表的「过滤模式」：菜单列出各个 `FilterMode`，最多一个打勾，点打勾的那项取消。原先是 `RuntimeViewerUI` 的
    `ItemPopUpButton`（下拉按钮拿菜单第 0 项当脸），换成同一位置的 `ChoiceFilterControlBarItem`（`NSFilterControlBarItem` 的子类，
    菜单与图片由它自己管，菜单以下拉的脸开头），`ItemPopUpButton` 删除。顺带修掉一个旧问题：启动时恢复的模式在菜单里打了勾，按钮却仍是普通图标，
    要点一次才变强调色。
  - 侧栏对象列表的「过滤范围」：不设菜单，按下由栏上的按钮发 action；按钮就是 popover 的锚点，原样交给 `.scope(sender:)` 路由。
  - Report 的「操作」：原先每次点击现建一份菜单再弹出，换成常驻的菜单交给 item（栏以下拉方式弹出、从不改动菜单，菜单以一个
    空的脸开头），Cancel All 与
    Clear History 的可用状态改由 ViewModel 的输出直接设到菜单项上。
- **生效时的强调色**：原先过滤模式生效时换成分层着色（hierarchical）的强调色符号、过滤范围生效时设按钮的 `contentTintColor`。item
  没有着色属性，只能换图；可 AppKitPlus 0.10.0 的栏按钮给符号配字号时整个替换了图片原有的符号配置，颜色被洗掉（探针：套完字号后
  红色像素 53 → 0）。按用户的选择在 AppKitPlus 修（字号叠在图片自己的配置上，带复现测试），发成 0.10.1，RuntimeViewer 钉它。
  生效时传强调色的图：过滤模式用分层着色（hierarchical），过滤范围用单色调色板（palette），即原先 `contentTintColor` 的样子。
- 栏里的框不画焦点环（栏接手框时关掉，与 Xcode 的栏类一致）；macOS 27 起 large 与 extraLarge 下框与按钮各自上 Liquid Glass。

**过滤框**：`FilterSearchField` → `NSFilterSearchField`，五处——侧栏镜像列表、侧栏对象列表（Match Case 开关）、Find 结果
过滤、Report 导航器（只看进行中的时钟开关）、批量导出的镜像选择（Match Case 开关）。过滤开关改用
`addFilterButton(with:alternateImage:toolTip:accessibilityLabel:)`，删掉加在开关上的 SnapKit 约束：AppKitPlus 自己排布开关，
要求调用方不改它们的 frame。

另外三处普通搜索框也换成 `NSFilterSearchField`：

- Find 查询框：`usesFilterAppearance = false`，保留放大镜与 AppKit 的取消按钮。搜索中的进度改用框自带的 `progress`，删掉
  原先叠在框内的 `NSProgressIndicator`。Xcode 这里是 `IDEProgressSearchField`，继承链
  `DVTFindPatternSearchField` → `DVTSearchField`（读本机 Xcode 27 的 IDEKit 类元数据与 DVTUserInterfaceKit 导出头文件确认），
  正是 `NSFilterSearchField` 移植的那个类。
- Custom Scopes 表单的过滤框、特化类型选择弹窗的搜索框：都是在列表上方过滤这个列表。

**没有询问就采用的假设**

- 字体跟 AppKitPlus 走：它在设 `controlSize` 时把字体换成该尺寸的系统字体（数字等宽），与 Xcode 一致。原先显式设了字号的
  地方起初保留原字号，侧栏镜像列表与 Find 结果过滤框这两处后来去掉了（见决策日志）；侧栏对象列表、Report、批量导出原本没设，继承的是 UIFoundation 默认的 11pt，换后随控件尺寸变化。
- 高度跟 AppKitPlus 走：与同尺寸的 `NSSearchField` 等高，不再是 UIFoundation 写死的值（large 24、extraLarge 30），侧栏
  底部的过滤栏可能因此变高。
- Find 查询框的描边方式没有逆向（Xcode 的 `DVTFindPatternSearchField` 怎么设 `DVTSearchFieldCell` 的描边模式），先用
  AppKitPlus 的默认值：聚焦或有文字时描边。
- 0.8.0 → 0.9.0 没有破坏性改动，其余行为修正逐条对照（见决策日志）。0.9.0 → 0.10.0 只有新增。
- 批量导出表单那一行（两个带文字的弹出按钮加过滤框）不换成过滤栏：它不是导航器底栏，两个弹出按钮显示着当前选的值，换成只有
  图标的 item 就看不到了。
- 栏的高度、边距照 AppKitPlus（新设计下框高加 16，即 large 44、extraLarge 52；以前的外观下框高加 5、至少 27），所以 macOS 15
  上这几条栏比原先手写的 8 点上下边距更薄，那是 Xcode 在新设计以前的样子。
- 分隔线保留，栏不放进 split view 的底部附件：Xcode 27 让列表滑到栏下面、靠滚动边缘效果淡出，那要把栏放进侧栏 split view item
  的底部附件，而侧栏是多页导航、每页一条栏，换页时附件得跟着换，另起。

**验证**：`RuntimeViewerApplicationTests`，新增 `FindModePathControlAdapterTests`（离屏 `NSPopUpPathControl`）与
`ChoiceFilterControlBarItemTests`；编译 `RuntimeViewer macOS`。外观与点击要人在 App 里看：AppKitPlus 自己的提案里这两个过滤框仍是 In Progress，还没和 Xcode 逐像素
比对，macOS 27 上的点击路径也没实测。

2026-10-11 第一轮（0.9.0：过滤框与路径控件）的结果（macOS 27.2、Xcode 27.2）：

- `RuntimeViewerApplicationTests` 全量 446 个测试、75 个套件通过，含新增的 6 个；跑前跑后用户 Debug 设置文件的 SHA 不变。
- `RuntimeViewer-Debug.xcworkspace` 的 `RuntimeViewer macOS`（Debug，连同作为 target 依赖的 Catalyst helper 与模拟器载荷）
  编译通过，改动的文件没有警告。
- 四份锁文件都能按改过的内容直接解析，解析后没有被改写：`RuntimeViewerPackages` 冷编时 SwiftPM 未改写锁文件；App 构建带
  `-disableAutomaticPackageResolution`，Debug 锁文件构建前后 SHA 不变，Distribution 的那份与它逐字节相同；
  `RuntimeViewerCommandLine` 跑 `swift package resolve` 后不变。
- 没做：在运行中的 App 里看外观、点菜单与开关（需要用户）；Distribution workspace 的 Release 归档。

2026-10-11 第二轮（0.10.0：过滤栏）的结果：

- `RuntimeViewerApplicationTests` 全量 450 个测试、76 个套件通过，含新增的 `ChoiceFilterControlBarItemTests` 4 个；跑前跑后
  用户 Debug 设置文件的 SHA 不变。
- 复用第一轮的 SwiftPM 构建目录，先删掉其中记着 0.9.0 的 `workspace-state.json` 再构建（第一次重新解析时连 GitHub 断了一次，
  原样重跑通过）；四份锁文件构建前后 SHA 不变。
- `RuntimeViewer-Debug.xcworkspace` 的 `RuntimeViewer macOS`（Debug，`-disableAutomaticPackageResolution`，复用第一轮的
  DerivedData）编译通过，按锁文件取到 AppKitPlus 0.10.0；改动的文件没有警告，锁文件 SHA 不变。
- 抬到 0.10.1 后重跑：`RuntimeViewerPackages` 从刚发布的 GitHub Release 下载 0.10.1 的产物并按清单校验和验过，450 个测试全过；
  App 编译通过、取到 0.10.1；四份锁文件、用户 Debug 设置文件的 SHA 都不变。
- 没做：在运行中的 App 里看四条栏与玻璃、点 item 的菜单与过滤范围的 popover（需要用户）。
- AppKitPlus 的修复：`testSymbolsKeepTheirOwnColours` 修复前两种配置（分层、调色板）都失败，失败原因是渲染出的红色像素为 0、
  尺寸断言照常通过；修复后通过，同一测试类其余 14 条照常通过。AppKitPlus 全量 3514 条只有 1 条失败
  （`NSConfigurationHostMarkingTests` 里与指针相关的一条，单独跑整组通过）；未改动的 0.10.0 基线全量同样有 1 条失败，是另一条
  （`NSAnimationTests` 里计时相关的一条）——全量运行时测试之间有偶发干扰，与这次修复无关。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-11 | Created，直接 In Progress | 用户原话：「接入AppKitPlus0.9.0的NSFilterSearch/TokenField，还有NSPopUpPathControl」。方案在对话里列出，并写明唯一的待定问题答完即开工 |
| 2026-10-11 | token 框这次不接 | 用户选定（备选：侧栏「过滤范围」改用 token；批量导出的镜像选择改用 token）。RuntimeViewer 没有现成的 token 框。侧栏的过滤范围（种类白名单加泛型 / 特化三态）是最贴近的落点，但它要求同类条件取「或」、不同类取「且」，token 框自带的「全部 / 任一」开关表达不了，需要另行设计 |
| 2026-10-11 | 基于 `next`，PR 合回 `next` | Find / Report 导航器与自写的路径控件只在 `next` 上（Find navigator 那次 PR 合进的是 `next`） |
| 2026-10-11 | 另外三处搜索框一并换掉 | 未单独询问，在对话里列为默认、用户未反对。Find 查询框外叠一个进度圈，正是 AppKitPlus 文档点名由 `progress` 取代的写法；另两处都是列表上方的过滤框 |
| 2026-10-11 | `ReportViewModelTests` 里「过滤栏没碰过时大纲照常显示」那条测试改用 `NSFilterSearchField` | 它刻意用页面上真实的过滤框类型，复现 [0030](0030-report-navigator.md) 2026-10-01 修过的「过滤栏没碰过之前大纲一直为空」。控件换了而测试不跟着换，测的就不再是页面上那个框。改后通过，说明新控件的 `rx.stringValue` 同样在用户输入之前什么都不发 |
| 2026-10-11 | AppKitPlus 0.9.0 的六条行为修正逐条对照，RuntimeViewer 都不受影响 | 按钮 configuration、`isPreviousRowSelected` / `isNextRowSelected`、列表与空状态 configuration（含 macOS 27.2 上 source list 选中行不再加粗）在代码里都没有用到；「layer-backed 视图上的 `menu` 现在能打开」一条，RuntimeViewer 的右键菜单全都设在大纲视图上，不在 layer-backed 视图上。0.8.0 → 0.9.0 的发布说明没有 Breaking 一节 |
| 2026-10-11 | 锁文件手工只改 appkitplus-release 一条，不跑 `UpdatePackagesScript.sh` | 那个脚本会把三个 workspace 的全部 pin 推到最新，混进与本提案无关的版本变化。手工改的这一条经 SwiftPM 与 Xcode 解析都被原样接受（见「验证」） |
| 2026-10-11 | AppKitPlus 0.9.0 → 0.10.0，四条导航器底栏换成 `NSFilterControlBar`，框外的按钮换成 `NSFilterControlBarItem` | 用户原话：「AppKitPlus升级到0.10.0，用上NSFilterControlBar，把原本的按钮换成NSFilterControlBarItem」。框里的开关不算「原本的按钮」：它们本来就在框里，Xcode 的栏也只把菜单按钮放在框外 |
| 2026-10-11 | item 生效时的强调色：修 AppKitPlus、发 0.10.1，RuntimeViewer 照常传强调色的图 | 用户选定（备选：RuntimeViewer 把带颜色的符号自己画成普通图片交给 item；改用实心图标表示生效）。探针确认 0.10.0 的栏按钮套字号时整个替换了图片的符号配置、颜色被洗掉，而 item 没有着色属性。修复在 AppKitPlus 的 `fix/filter-control-bar-item-symbol-colors` 分支，复现测试修复前两种配置都失败、修复后通过 |
| 2026-10-11 | 批量导出表单那一行不换成过滤栏 | 未单独询问，在对话里列为默认、用户未反对。它不是导航器底栏，两个弹出按钮显示着当前的匹配方式与匹配对象，换成只有图标的 item 就看不到了 |
| 2026-10-11 | `ItemPopUpButton` 换成新的 `ChoiceFilterControlBarItem`（`NSFilterControlBarItem` 的子类）后删除 | 它唯一的用处就是过滤模式按钮。子类让 item 直接放进栏的 `leadingItems`，菜单、打勾与换图都在它里面，视图控制器的写法与原先一样；新增 `ChoiceFilterControlBarItemTests` |
| 2026-10-11 | 分隔线保留，栏不放进 split view 的底部附件 | 未单独询问，在对话里列为默认、用户未反对。底部附件挂在 split view item 上，侧栏却是每页一条栏的多页导航，另起 |
| 2026-10-11 | AppKitPlus 0.10.1 发布，RuntimeViewer 的下限与四份锁文件抬到 0.10.1 | 用户批准发版（原话：「发」）。照 AppKitPlus 的发版指南：修复（f4581b3）与 `chore(release): 0.10.1`（726f64c）快进合进 AppKitPlus 的 `main`，`publish-release.sh` 先演练再发布（发布仓库 `Release 0.10.1` 654ff81，产物 SHA-256 `e5c9305e…`），最后推 `main` |
| 2026-10-12 | 四条过滤栏一律 `large`，侧栏两页与 Report 不再在 macOS 26 起用 `extraLarge` | 用户原话：「把extraLarge全部改成large，换了AppKitPlus的控件后large足够了，extraLarge太大了」。`extraLarge` 是沿用旧过滤框的尺寸；AppKitPlus 的框与同尺寸的 `NSSearchField` 等高，栏再加上下边距（large 44、extraLarge 52），不再是 UIFoundation 写死的框高（large 24、extraLarge 30） |
| 2026-10-12 | 侧栏镜像列表与 Find 结果过滤框不再手动设 13pt 字体，跟随 `large` 的字体 | 用户原话：「换，现在字体太大了」，Find 那处由用户自己去掉。手设的字体写在设尺寸之后，会盖掉 AppKitPlus 按尺寸挑的字体；侧栏那两行是 2025-10 配 `extraLarge` 加的。侧栏同一处 macOS 26 起清空占位文字的那行，用户也一并删掉了 |
| 2026-10-12 | 过滤栏 item 的菜单改由 AppKitPlus 以下拉 `NSPopUpButton` 的方式弹出，第 0 项是不列出的脸：`ChoiceFilterControlBarItem` 与 Report 的操作菜单各自以一个空项开头；AppKitPlus 发 0.11.0，RuntimeViewer 的下限与四份锁文件抬到 0.11.0 | 用户反馈：过滤模式的菜单弹出后把 item 整个盖住（截图），Xcode 的菜单在按钮上方；原来的 `ItemPopUpButton` 是下拉 `NSPopUpButton`，没有这个问题。AppKitPlus 0.10.0–0.10.2 自己按固定位置把菜单弹在按钮下方，窗口在屏幕底部时被系统推回来盖住按钮。用户选定「换成 PopUpButton，跟 Xcode 一样」，第 0 项归按钮（备选：AppKitPlus 覆写私有方法让整份菜单照旧显示），照 Xcode 先往下弹、放不下再往上（备选：照 `ItemPopUpButton` 设 `preferredEdge = .minY` 先往上）。修复与复现测试在 AppKitPlus（过滤栏提案同日一行）；`ChoiceFilterControlBarItemTests` 改为只看脸之后列出的项，另加一条测脸本身（修改前 5 条全红，修改后全绿）。用户批准发版（原话：「可以，发版吧」）：修复（72e3215）与 `chore(release): 0.11.0`（d897910）快进合进 AppKitPlus 的 `main`，`publish-release.sh` 先演练再用 Xcode 26.6 发布（发布仓库 `Release 0.11.0` a8bdf92，产物 SHA-256 `3ab18e12…`），最后推 `main`。破坏性变更（菜单第 0 项不再列出）写在 0.11.0 的发布说明里，所以升次版本号 |
