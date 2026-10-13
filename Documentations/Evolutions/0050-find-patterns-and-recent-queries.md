# 0050 - Find 导航器：查找 pattern 与最近查询

- **状态**: Implemented
- **创建日期**: 2026-10-13
- **最后更新**: 2026-10-13
- **依赖**: AppKitPlus 0.13.0（已发布；AppKitPlus 提案 `draft-find-pattern-search-field`：改名 `NSFindPattern…`、插入闸门、富文本表示）

## 摘要

Find 页的查询框换成 AppKitPlus 的 `NSFindPatternSearchField`：Text 模式下可以按 ⌃⌥⌘P 或放大镜菜单的「Insert Pattern」在文字中间
插入 Digits、Any Word Characters、Email Address 等 12 种 pattern，带 pattern 的查询以正则交给引擎。放大镜菜单同时照 Xcode 加上
「Recent Queries」：每个来源最近 10 条查询，选中即恢复整条查询并搜索，可清空。两样都照 Xcode 27.0 的 Find 导航器做，证据见下文
各条的地址（IDEKit、IDEFoundation、DVTUserInterfaceKit，IDA 库在 `/Volumes/RE/Xcode/27.0/`）。

## 方案

### 依赖

`RuntimeViewerPackages/Package.swift` 的 AppKitPlus-Release 下限抬到 `0.13.0`，四份锁文件同批更新。0.12.0 起两处外观随之变化，
都是 AppKitPlus 有意为之：small 尺寸的过滤框换成 Xcode Find 导航器那个框的几何（RuntimeViewer 里只有 Find 页的查询框是 small）；
macOS 27 之前，所有过滤框在聚焦或过滤生效时的底色改为 Xcode 26 的不透明色。

### 查询框

- `FindViewController.searchField` 改为 `NSFindPatternSearchField`；`searchesImmediatelyAfterInsertingPattern = false`，插入 pattern
  后不搜索，回车才搜（Xcode `-[IDEFindNavigatorQueryParametersController viewDidLoad]` 0x199130）。
- 只有 Text 模式允许插入：`allowsPatternInsertion` 跟着 `FindMode.supportsPatterns` 走（Xcode 只有 Text 查询声明
  `supportsPatterns = true`，`-supportsPatterns` 0x19C9EC）。切换模式时框里已有的 token 保留，与 Xcode 相同。
- 查询从 `findPatternComponents` 读，不读 `stringValue`（token 在那里是 U+FFFC）。

### 查询模型

`FindQuery.text: String` 换成 `FindQuery.term: FindQueryTerm`：macOS 上包着 `NSFindPatternComponents`，其他平台只有文字；
`Codable` 走 components 的 `propertyListRepresentation`，存下来就是 Xcode 查找框写进剪贴板的那种属性列表（文字是字符串，pattern 是
以 `NSFindPatternRegularExpressionKey` 等为键的字典）。两个侧栏层级的 Find 页靠它互相同步，token 不丢。只有文字时的写法不变：
`FindQuery(text:)` 仍在，`FindQueryTerm` 也能直接写成字符串字面量。`FindQuery` 连同各个枚举都成了 `Codable`，供最近查询存盘。

### 交给引擎的查询

没有 token 时与现在完全相同。有 token 时一律以 `.regularExpression` 发出，引擎协议不变，对端是旧版 RuntimeViewer 也能搜：

| 模式 | 正则 |
|------|------|
| Text | 文字转义、token 换成各自的正则（`regularExpressionPattern(escapingText: true)`），再按匹配方式加词边界 |
| Regular Expression | 文字按正则语法原样保留（`escapingText: false`），不加边界 |
| Members | 同 Text；匹配方式选 Regular Expression 时同上一行 |
| 三个类型关系模式 | 同 Text；引擎对正则本来就匹配完整限定名 |

- **词边界沿用 RuntimeViewer 自己的规则**（标识符字符 `[A-Za-z0-9_$]`，非 ASCII 也算标识符字符），不用 Xcode 的 ICU `\b`
  （`IDEBatchFindAbstractFileByFileTextualQuery` 初始化方法里的 `\b(?:%@)` 等四个格式串）：同一个 Matching Word，有没有 token
  意思都一样。包词边界的函数放在 Core 的 `RuntimeTextPattern` 旁边，测试证明它与纯文本匹配的结果一致。
- **偏离 Xcode 的一处**：Xcode 在 Regular Expression 模式下照样转义文字，还套用界面上看不见的匹配方式；这里按正则语法处理。
- 首尾空白照旧去掉，只去第一段与最后一段文字的。
- 跳转后的内容区高亮用同一条正则与 `.regularExpression`。
- 推导写在 `FindQueryTerm.searchText(literalMatchMode:isRegularExpression:)`，`FindQuery` 按模式给出 `textSearchText`、
  `memberSearchText`、`relationshipSearchText`，`FindSession` 发请求与 `FindViewModel` 做高亮都从这里取。包边界的函数是
  `RuntimeTextPattern.regularExpression(_:boundedAs:)`，字符类与引擎逐字节判断标识符的 `isIdentifierByte` 放在一起。

### 放大镜菜单

照 `-findFieldMenu` 0x19C3BC：菜单字号 10；Text 模式下先放「Insert Pattern ⌃⌥⌘P」与分隔线；有历史时放灰色的「Recent Queries」、
缩进一级的历史项、分隔线、「Clear Recents」；什么都没有时只剩灰色的「Recent Queries」。菜单在每次打开时按当时的模式与历史现建
（`NSFilterSearchFieldDelegate.menu(for:)`），建菜单的代码照 `FindModePathControlAdapter` 的样子放在 Application 层，能单独测试：
`FindQueryFieldMenuAdapter` 把自己设成查询框的 delegate，放大镜因此带上菜单的小箭头。

### 最近查询

照 `IDEFindNavigatorQueryHistoryManager`：

- **按来源分、跨启动保存**：键是 `documentState.runtimeEngine.bookmarkScope.bookmarkKey`（与书签同一个），存在 `AppDefaults` 的
  `@ResilientFileStorage` 里（JSON，与书签文件同目录）。Xcode 是每个 workspace 一份，存在 DerivedData 的 `FindNavigator.history`。
- **何时记**：回车发起非空查询时记一条（`-initiateQuery` 0x19BA0C）；最多 10 条，最新在前，相同的移到最前
  （`-addQueryHistoryItem:` 0x197950）。引擎切换、Generation Options 变化、语料补建引起的重搜不记。从菜单选中一条也走同一条路，
  于是它移到最前。「相同」不看 token 的 identifier：同样的 pattern 分两次敲进去，token 各有各的 UUID，仍算同一个查询（比的是
  文字，或 pattern 生成的正则，再加上其余设置）。
- **选中一条**：恢复整条查询——模式、文字与 token、匹配方式、成员种类、大小写、范围——并立即搜索（`-userDidSelectHistoricQuery:`
  0x19C8A8）。菜单是从查询框自己弹出来的，框常常正在编辑，而页面在编辑中不会去改框的内容，所以适配器先把查询的内容放进框里
  （这一步会结束编辑），再交给 view model。
- **标题**：照 `-descriptionForHistoryItem:withFont:inWorkspace:` 0x193D6C 写成 `In <范围>, <模式> <匹配方式> “<查询>”, match case`
  或 `ignore case`，例如 `In Indexed Images, text containing “NSView”, ignore case`；Regular Expression 没有匹配方式就不写。Members
  写成 `members <匹配方式>`，选了成员种类时是 `ObjC Method members <匹配方式>`，正则匹配方式写 `matching regular expression`。
  引号里的 token 用 `NSFindPatternComponents.attributedString(font:textColor:)` 画成胶囊，颜色与编号同框里一样。
- **Clear Recents**：清掉当前来源的历史（`-clearSearchHistory:` 0x19C730），别的来源的不动。

### 测试

- Core（`RuntimeTextPatternBoundaryTests`）：一组带各种邻接字符的文本（`$`、`_`、标点、行尾、两侧的非 ASCII 字符）与查询（含要转义的
  正则语法），四种匹配方式、大小写两种，带边界的正则与纯文本搜索命中位置完全一致；字符类与 `isIdentifierByte` 逐字节一致；包边界
  不增加捕获组，选择分支不会漏到边界外。
- Application：`FindQueryTermTests`（交给引擎的正则：各模式、只去首尾空白、只有 token 的查询、与纯文本同样只命中整个标识符；存储
  格式与往返；同一查询不看 identifier）、`FindRecentQueriesTests`（记录、移到最前、上限 10、空查询不记、各模式的标题、token 画进
  标题、另一个 `AppDefaults` 实例从同一目录读回）、`FindQueryFieldMenuAdapterTests`（菜单的组成、字号、不能插入时不放 Insert
  Pattern、选中与 Clear Recents）、`FindViewModelTests` 新增五条（在测试引擎上用带 token 的查询命中并按同一条正则高亮、只有 Text
  能插入、回车按来源记录、选中后整条恢复并立即搜索、清空只清当前来源）。

### 文档

本提案；`AGENTS.md` 的 UI 组件表加一行 `NSFindPatternSearchField`，写明读 `findPatternComponents`、不读 `stringValue`；同节
「Filter fields…」下加一条说明查询框、正则推导与菜单适配器。

### 验证

macOS 26.7，Xcode 27.0，AppKitPlus 0.13.0（已发布）。

- Core：`RuntimeTextPatternBoundaryTests`、`RuntimeTextPatternTests`、`RuntimeInterfaceTextMatcherTests` 共 24 个用例全过。
- Packages：`swift test --filter 'Find|AppDefaults'`，24 个套件、156 个用例全过，退出码 0；新加的套件与五条 `FindViewModel`
  用例都在其中跑到。
- App：Debug workspace、Debug-arm64e 编译通过，改动的文件没有新警告。被跟踪的 Debug workspace 锁文件本身缺
  `swift-issue-reporting`（与本改动无关），只认锁文件编不了，于是编译时让 Xcode 临时解析，编完把锁文件还原成只改 AppKitPlus 那一条；
  还要加 `-IDEEnableNewPackagePIFBuilder=NO`，否则 helper service 那个 target 报 `Unable to resolve module dependency`，与
  `AGENTS.md` 记的发版归档同一病因。
- 未启动 App 做界面验证：插 pattern、放大镜菜单与最近查询的实际观感还要在 App 里看一遍。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-13 | Created as Draft | 用户：「接入一下AppKitPlus 0.12.0新加的NSSearchPatternField」 |
| 2026-10-13 | 照 Xcode 只在 Text 模式允许插入，闸门补进 AppKitPlus 再发版 | 用户选定（备选：RuntimeViewer 里用子类挡住；所有模式都能插）。Xcode 只有 Text 查询支持 pattern，⌃⌥⌘P 也先问 `supportsPatterns`，AppKitPlus 0.12.0 移植时漏了这道闸 |
| 2026-10-13 | 最近查询一起做 | 用户选定（备选：只做 Insert Pattern，历史另起提案） |
| 2026-10-13 | 最近查询按来源分、跨启动保存 | 用户选定（备选：全 App 共用一份；每个窗口一份、不保存）。与书签同一个来源键，恢复范围时镜像路径一定属于当前来源 |
| 2026-10-13 | 框的类名随 AppKitPlus 改为 `NSFindPatternSearchField` | 用户：「顺便把名字改掉，改成NSFindPatternSearchField」，并选定整组照 DVT 改名 |
| 2026-10-13 | Accepted | 用户：「开工」 |
| 2026-10-13 | 选中最近查询也记一次；「相同」不看 token 的 identifier | 实现时定。Xcode 选中历史项后走 `-initiateQuery`，于是它移到最前；同样的 pattern 分两次敲进去，token 的 UUID 各不相同，按 identifier 比会把同一个查询列两遍 |
| 2026-10-13 | 选中最近查询时，适配器先把内容放进查询框 | 菜单从查询框弹出时框常在编辑，而页面在编辑中不改框的内容（以免打断输入）；不先放进去，框里会留着正在敲的文字 |
| 2026-10-13 | 菜单适配器的测试直接把动作发给菜单项的 target | `swift test` 进程里没有 `NSApp`（临时探针实测），`performActionForItem(at:)` 经它派发、什么也不做 |
| 2026-10-13 | Implemented | AppKitPlus 0.13.0 已发布；验证见「验证」 |
