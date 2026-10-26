# Draft - 侧边栏过滤框换成 Xcode 导航区的文字 token 框

- **状态**: In Progress
- **创建日期**: 2026-10-26
- **最后更新**: 2026-10-27
- **所属愿景**: 无
- **实现分支 / PR**: `feature/sidebar-filter-text-tokens`（worktree `.worktrees/RuntimeViewer-SidebarFilterTextTokens`）
- **依赖**: AppKitPlus 提案 0062《`NSFilterTokenField` 补齐 Xcode 导航区的文字 token》（AppKitPlus 仓库
  `Documentations/Evolutions/0062-filter-token-field-text-tokens.md`），已随 AppKitPlus 0.18.0 发布

## 摘要

侧边栏有六处过滤框：镜像列表的目录页与书签页、对象列表的列表页与书签页、Find 页底部、Report 页。它们现在都是
`NSFilterSearchField`，只能按「包含这段文字」过滤。本提案把它们换成 AppKitPlus 的 `NSFilterTokenField`，照 Xcode 导航区
（例如 Project 导航器）的过滤框来做：

- 输入的文字回车后变成 token；
- 点 token 的键半边，可以在 Contains / Does Not Contain / Begins With / Ends With 之间切换；
- 输入 `loo*`、`*loo` 直接得到 Begins With、Ends With，含 `*` 或 `?` 的文字按通配符匹配；
- 所有 token 加上正在输入的文字都要满足；
- 过滤图标的菜单里记着最近用过的过滤条件。

这次只改文字过滤：Filter Scope、Match Case、Filter Mode 以及各页现有的开关都不变。实现依赖 AppKitPlus 0.18.0，那一版补上
值的前后缀标记等三项接口。

## 方案

**过滤条件模型**（`RuntimeViewerApplication`，各平台通用）。新类型 `NavigatorTextFilter` 装着两样东西：token 对应的条件
`terms`，以及还没变成 token 的文字 `typedText`。每个条件由一种比较方式和一个值组成，比较方式有 Contains、Does Not Contain、
Begins With、Ends With 和 Like（通配符）。

- **解析**照 Xcode 的 `DVTFilterExpressionForTextBySplittingIntoSubexpressions`：
  - 按空格切段，`\ ` 表示一个真正的空格；
  - 不含 `*`、`?`、`\` 的段是 Contains；
  - `*x` 是 Ends With，`x*` 是 Begins With（x 里没有别的特殊字符时）；
  - 其余含特殊字符的段是 Like，值原样保留；
  - 另加一个 Xcode 没有的写法：`!x` 表示 Does Not Contain（理由见假设）。

  正在输入的文字按同一套规则解析。
- **匹配**照 Xcode 27.0 DVTFoundation 的 `_predicateForTextExpression:`：
  - Contains 同时忽略大小写和变音符号（`localizedStandardContains`），Does Not Contain 是它的反面；
  - Begins With、Ends With 忽略大小写，但区分变音符号；
  - Like 是忽略大小写的通配符匹配，值的两端各补一个 `*`。

  所有条件都要满足，正在输入的文字解析出的条件也算在内。对象列表打开 Match Case 时，各种比较一律区分大小写。

**macOS 接入层**（`RuntimeViewerApplication` 里只在 AppKit 下编译的部分，照 `FindQueryFieldMenuAdapter` 的做法）。新类
`NavigatorTextFilterFieldAdapter` 负责配置一个 `NSFilterTokenField`，并充当它的 delegate：

- **字段配置**：
  - 一个标题为空的 token 类型，所以键半边只有箭头；
  - Contains（默认）、Does Not Contain（exclusion，显示 `≠`）、Begins With（后缀 `⋯`）、Ends With（前缀 `⋯`）进字段的比较方式
    列表；Like 不进列表，所以 Like token 没有菜单；
  - 不显示 ALL / ANY（`operatorDisplayMode = .never`）；
  - 打开最近过滤，不提供补全。
- **文字与 token 互转**：`tokensForString:` 用上面的解析器，把回车、Tab、逗号与粘贴得到的文字变成 token。
  `editingStringForToken:` 给出能解析回同一个 token 的文字：`loo`、`loo*`、`*loo`、`!loo`；Like 原样给出；值里的空格写成 `\ `。
- **报告与清空**：过滤一有变化，就交出一个 `NavigatorTextFilter`。ViewModel 自己清空过滤时（在侧栏中显示一个被过滤掉的对象），
  由接入层清空字段。
- **最近过滤**：按页面种类各存一份，共四份：镜像列表（目录页与书签页共用）、对象列表（列表页与书签页共用）、Find 结果、Report。
  跨启动保存在 `AppDefaults`，与 Find 的最近查询放在同一处。当前的过滤条件不恢复。具体做法：
  - 存的是字段的 `encodedState`，放在 `AppDefaults.navigatorFilterFieldStates`，按页面种类分键。字段只能经它读写最近过滤。
  - 页面建好时读回，随即清空字段。存下时正在用的那个过滤因此进入最近过滤，和换掉一个过滤时一样。
  - token 一变就存。另外任何菜单动作之后也存一次，因为字段菜单里的 Clear Recents 不通知 delegate。
  - 同组的另一个页面存了新列表时，字段为空、也没在编辑的页面会接过来；有过滤的页面留着自己的列表，等下次建页面时再读。
    同组几个页面都改过时，以最后存的为准。

**ViewModel**。四类页面的过滤输入从字符串改成 `NavigatorTextFilter`，涉及 `SidebarRootViewModel.Input.searchString`、
`SidebarRuntimeObjectViewModel.Input.searchString`、`FindViewModel.Input.filterString`、`ReportViewModel.Input.filterString`。
iOS 的两个页面把搜索栏的文字包成只有 `typedText` 的过滤条件。macOS 的过滤框在停止输入 0.2 秒后才报告文字，所以两个侧边栏
ViewModel 里那段 150 ms 的合并延迟挪到 iOS 的 ViewController 里，写成 `RuntimeViewerApplication` 里的
`coalescingKeystrokes()`，两个 iOS 页面共用。

**各页的匹配**。每个条件都只比对一行自己的名字，再按各页现有的树规则决定显示哪些行：

- **对象列表**：一个对象「自身通过」，指它通过 Filter Scope、且名字满足所有条件。它自身或任一后代通过，它就显示，这与 Filter
  Scope 现在的保留规则相同。Filter Mode 选了 Fuzzy 或 Ifrit 时，正在输入的文字照旧按名字树做模糊匹配、排序和加粗；token 仍按
  上面的比较方式匹配。
- **镜像列表**：按路径判断。对 Contains、Begins With、Ends With、Like，路径上任一节点（镜像自己或它所在的某一级目录）的名字满足
  即可；对 Does Not Contain，路径上每个节点都必须不包含。一个目录在它下面有镜像通过时显示。只有一个 Contains 条件时，效果与现在
  一样：名字匹配的目录显示整棵子树。
- **Find 结果**：一行「自身匹配」改为它的文字满足所有条件，其余树规则不变。
- **Report**：一行的标题满足所有条件、并符合「只看进行中」开关时保留；分类在还有子行时保留。与现在相同。

**界面**：

- 六处的 `NSFilterSearchField` 换成 `NSFilterTokenField`，仍放在原来的 `NavigatorFilterControlBar` 里。
- Match Case 与 Report 的时钟按钮仍用 `addFilterButton` 加在框里。
- 结果树按需加载时，Find 页照旧禁用过滤框。
- 工具提示不变；Find 页顶部的查询框不在本次范围内。
- 删掉对象列表里的 `clearedSearchStringRelay`：它原本用来在清空文字后补发空串；现在设置 `filterTokens` 本身就会通知 delegate。
- Find 页给搜索框设的 `sendsWholeSearchString` 是搜索框才有的属性，随之去掉；token 框本来就等输入停顿 0.2 秒再报告。

**依赖**。`RuntimeViewerPackages` 对 AppKitPlus-Release 的下限从 0.13.0 抬到 0.18.0。受跟踪的四份锁文件只改这一条 pin：Debug 与
Distribution 两个 workspace、`RuntimeViewerPackages`、`RuntimeViewerCommandLine`。普通 workspace 的锁文件不进 git。

**测试**（`RuntimeViewerApplicationTests`）：

- 解析器：Xcode 的各种写法、`\ `、`!x`、空白；
- 比较方式：大小写、变音符号、Match Case；
- 四条管线：各自的匹配与树规则，包括镜像列表的否定条件、对象列表与 Filter Scope 叠加；
- 接入层：字段配置、token 与条件互转、编辑串往返、清空、最近过滤的保存与恢复；
- 现有用到文字输入的测试改用新的输入类型；
- `SidebarFilterPerformanceBaselineTests` 与 `SidebarFilterRelayMaterializationTests` 保持通过。

**文档**：

- `RuntimeViewerUsingAppKit/AGENTS.md` 的视图对照表与「过滤框」一节：侧边栏页面的过滤栏改用 token 框和接入层，选择器里的过滤框
  仍是 `NSFilterSearchField`；
- 提案索引与文档索引。

**影响**：AppDefaults 多一个保存最近过滤的键；最低系统版本不变；iOS 的行为变化见下面的假设。

**落地步骤**（每步构建与相关测试通过后单独提交）：

1. 过滤条件模型 `NavigatorTextFilter`：解析、比较、组合，以及它们的测试。**已完成（2026-10-26）**：
   `RuntimeViewerApplication/NavigatorTextFilter.swift`，`NavigatorTextFilterTests` 13 个测试（含参数化的 31 个用例）通过。
2. 四类 ViewModel 改收 `NavigatorTextFilter`，四条管线按新规则匹配。macOS 现有的 `NSFilterSearchField` 与 iOS 的搜索栏先把文字
   包成只有 `typedText` 的过滤条件。更新现有测试，补上新规则的测试。**已完成（2026-10-26）**：四类 ViewModel 的输入与状态
   统一叫 `filter`；对象列表的管线让 Filter Scope 与全部条件落在同一个对象上（见决策日志），镜像列表的管线按路径判断，Find 与
   Report 逐行比对。新增 `SidebarRuntimeObjectTextFilterTests`，镜像列表、Find、Report 的现有套件各补了多条件的用例。
   `RuntimeViewerApplicationTests` 635 个测试里 634 个通过；没过的那一个是 `RuntimeBackgroundIndexingAlwaysIndexEngineTests`
   在整套并行时的 120 秒超时，这个套件单独重跑全部通过，与本改动无关。macOS 与 iOS 两个 App 都编译通过。
3. 等 AppKitPlus 0.18.0 发布：依赖下限抬到 0.18.0（锁文件只改这一条）；写 macOS 接入层 `NavigatorTextFilterFieldAdapter`
   （含最近过滤的保存）与它的测试；六处过滤框换成 token 框，删掉 `clearedSearchStringRelay`；150 ms 的合并延迟挪到 iOS 的
   ViewController。**已完成（2026-10-27）**：
   - AppKitPlus 0.18.0 已发布。下限抬到 0.18.0，四份受跟踪的锁文件只改这一条 pin。
   - 接入层 `NavigatorTextFilterFieldAdapter` 写在 `RuntimeViewerApplication` 里只在 AppKit 下编译的部分，配
     `NavigatorTextFilterFieldAdapterTests` 11 个测试。
   - 最近过滤存在 `AppDefaults.navigatorFilterFieldStates`。为此给 `Data` 补上宽松解码，`ResilientFileStorageTests` 加了一例。
   - 六处过滤框换成 token 框，删掉 `clearedSearchStringRelay`。150 ms 的延迟改由两个 iOS 页面经 `coalescingKeystrokes()` 套用。
   - 相关的 10 个套件、122 个测试通过，macOS 与 iOS 两个 App 都编译通过。没有启动 App 做界面核对。
4. 文档：`RuntimeViewerUsingAppKit/AGENTS.md`；提案收尾。

没有询问就采用的假设：

- **范围**是侧边栏的六处。Find 范围选择表单、特化类型选择器、批量导出的镜像选择，这三个弹出界面里的过滤框不换。
- **多段输入**（`foo bar`）回车后变成两个 token，过滤效果相同。Xcode 会合成一个「foo AND bar」的复合 token，菜单是 AND / OR；
  AppKitPlus 没有复合 token。
- **加一个 `!x` 写法**表示 Does Not Contain。Xcode 没有这个写法：双击它的 Does Not Contain token 只还原成 `x`，再回车就悄悄变成
  Contains。名字里不会出现 `!`，这个写法不会误伤。
- **命中片段不加粗**，只有对象列表的 Fuzzy / Ifrit 模式照旧加粗。Xcode 会加粗，但做这件事要改四类页面的单元格，还要为成千上万行
  的列表重新测性能，另立提案。
- **最近过滤跨启动保存，当前过滤不恢复**。Xcode 按 workspace 保存并恢复整个过滤状态，RuntimeViewer 的窗口没有对应的持久身份，
  而且换镜像时对象列表页会重建。
- **iOS** 搜索栏里的文字也按同一套规则解析：`foo bar` 从「包含这串文字」变成「两段都要包含」。
- **实现顺序**：AppKitPlus 的提案先实现。本提案不依赖新接口的第 1、2 步同时做，第 3 步等 AppKitPlus 0.18.0 发布后再做。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-26 | Created as Draft | 用户要把侧边栏的过滤框换成 `NSFilterTokenField`，支持 Xcode 那样的搜索 |
| 2026-10-26 | 只做文字 token，与 Filter Scope 无关 | 用户明确，要复刻的是 Xcode 导航区过滤框的文字比较（Contains / Does Not Contain / Begins With / Ends With），不是控制台那种按「类型:值」筛选的 token |
| 2026-10-26 | 行为照 Xcode 27 Project 导航器的逆向结论 | 解析、比较方式、组合规则与显示都有汇编依据，记录在 `/Volumes/RE/Xcode/27.2/README.md` 的「Navigator text filter tokens (2026-10-26)」一节；27.0 与 27.2 相同 |
| 2026-10-26 | 先补 AppKitPlus 再接入 | AppKitPlus 0.17.0 画不出 `loo ⋯` / `⋯ loo`，Begins With / Ends With 的 token 会和 Contains 长得一样；通配符 token 会带菜单；双击还原会丢掉比较方式。用户选择先补齐、发布 0.18.0，而不是先接入、以后再补 |
| 2026-10-26 | 方案拆成四个落地步骤；第 1、2 步不等 AppKitPlus 发版 | 模型、管线与 ViewModel 不用 AppKitPlus 的新接口，现有过滤框先把文字包成过滤条件就能编译、能测；只有接入层和界面替换需要 0.18.0 |
| 2026-10-26 | 用户批准，开始实现 | 在 `feature/sidebar-filter-text-tokens` 上实现，先做第 1、2 步 |
| 2026-10-26 | 对象列表上，Filter Scope 与文字条件要落在同一个对象上 | 原先 Filter Scope 按子树、输入的文字按「自身加所有后代的名字」各判各的，一个结构体会因为它嵌套的类名字对上而留下，那个类本身却又被 Filter Scope 藏起来；现在一个对象要同时通过 Filter Scope 与全部条件，它或某个后代通过才保留，与 Xcode 逐个条目判断一致 |
| 2026-10-26 | 150 ms 的合并延迟在第 2 步仍留在 ViewModel，挪到第 3 步 | 第 2 步时 macOS 的过滤框还是搜索框，每次按键都会报告；等换成 token 框、由它停顿 0.2 秒再报告时再拿掉，第 2 步的输入节奏不变 |
| 2026-10-27 | AppKitPlus 的提案编为 0062，发布 0.18.0，开始第 3 步 | 用户审过 AppKitPlus 的实现后决定直接发版 |
| 2026-10-27 | 最近过滤存字段的 `encodedState`，读回后清空字段 | 字段只能经 `encodedState` 与 `restoreState(from:)` 读写最近过滤。读回会连当前过滤一起带回，清空字段正好让它进入最近过滤，当前过滤也就不恢复，与方案一致 |
| 2026-10-27 | 任何菜单动作之后补存一次 | 字段菜单里的 Clear Recents 只清列表，不通知 delegate。只在 token 变化时存的话，清掉的列表会在下次建页面时回来。以后 AppKitPlus 若在最近过滤变化时通知 delegate，这一条就可以去掉 |
| 2026-10-27 | 同组的另一个页面存了新列表时，只有字段为空、也没在编辑的页面接手 | 接手要先恢复再清空字段，会冲掉正在用的过滤。目录页与书签页、列表页与书签页是同时开着的，这样多数时候它们看到的是同一份列表 |
| 2026-10-27 | 收到存储的变化通知后重新读一次，不用通知里带的值 | 存储先写入、后在自己的队列上发通知，通知可能晚于页面自己的下一次保存；拿旧值去比，空着的页面会把自己存过的旧状态当成别处的接过来 |
| 2026-10-27 | 150 ms 的延迟写成 `RuntimeViewerApplication` 里的 `coalescingKeystrokes()`，两个 iOS 页面共用 | 原来那段「必须用 `delay`、不能用 `debounce`」的说明只需留一处；放在包里，iOS 工程也不用新增文件 |
| 2026-10-27 | 受跟踪的锁文件是四份，不是方案原写的三个 workspace | 普通 workspace 的锁文件不进 git；`RuntimeViewerPackages` 与 `RuntimeViewerCommandLine` 两个包各有一份，照以往抬 AppKitPlus 下限时的做法一起改 |
| 2026-10-27 | 给 `Data` 补上 `LenientlyDecodable` | `ResilientFileStorage` 要求值能宽松解码。读不出来的一份状态只丢它自己的键，不影响别的页面种类 |
