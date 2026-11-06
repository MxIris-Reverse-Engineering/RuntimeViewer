# 0074 - 内容面板接入 SourceEditor 现成的四项阅读功能

- **状态**: Implemented
- **实现分支**: `feature/source-editor-reading-aids`
- **创建日期**: 2026-11-06
- **最后更新**: 2026-11-06

## 摘要

内容面板用的是我们自己复刻的 SourceEditor（钉住 26.6.3），框架里还有几项现成的阅读功能没有接上。
这份提案接四项：切回一个对象时回到上次读到的位置；新增 Editor ▸ Code Folding 菜单；从 Find
导航器打开一条文本命中时，内容面板的查找栏带上同一个查询并高亮全部命中；点一个标识符，界面里
同名的其他位置一起高亮。改动只在 bridge、内容面板与主菜单，框架本身不动。

## 方案

下面关于框架的事实，都读自复刻版 26.6.3 tag 上的源码；注明了地址的，是源码注释里写的
Xcode 26.6 原版地址。

### 1. 记住阅读位置

**现状**：bridge 每次换文本都换一个新的 data source。折叠状态由 `FoldStateCache` 按文本记住，
滚动位置却没有记录。实测发现，换 data source 时视图会保留滚动视图原来的偏移，并不会回到顶部：
第一次打开的界面停在上一个界面滚到的位置，切回的界面也停在别处。

**框架提供的接口**：`SourceEditorView.scrollStateForStateRestoration()` 返回可见区顶部所在的行，
以及这一行内的偏移。`applyScrollState(_:defer:)` 传 `defer: true` 时先记下这个位置，等下一次布局
完成（`layoutManager(_:didFinishLayoutInContentView:)`）再滚过去。

**做法**：
- `FoldStateCache` 改为同时保存折叠状态和滚动位置。键不变，仍按文本计算，改名以反映新的内容。
- `setSource` 在 unfold 之前保存当前状态。换上新文本、恢复折叠之后，用 `defer: true` 设滚动
  位置：显示过的文本回到上次的位置，其余文本回到顶部。顶部取 `currentScrollState()` 在什么都没
  布局时给的值：第 0 行，偏移为 `-contentView.layoutMargins.top`。
- **带着 Find 命中打开时，既不恢复也不回顶部。** 命中的定位（`revealCharacterRange`）是异步
  到达的，延迟执行的滚动可能排在它之后，把定位冲掉。`ContentTextViewModel` 的 Output 新增
  `highlightsFirstRender`，说明第一次渲染之后会不会跟着定位；内容面板据此给 `setSource` 的
  `restoresScrollPosition` 参数，只影响第一次渲染。

### 2. 折叠命令进菜单

**框架提供的接口**：`SourceEditorView` 实现了这些 `@objc` 动作：
- `fold:`（0x382C18），折叠当前位置所在的结构。光标隐藏后，当前位置就是点击的位置。
- `unfold:`、`unfoldAll:`。
- `foldAllComments:`、`unfoldAllComments:`。

`validateUserInterfaceItem` 根据 `foldingController.allowsFoldingCodeStructures`（默认 `true`）
启用它们。

**做法**：在主菜单的 Navigate 之后加一个 Editor 菜单，里面放 Code Folding 子菜单。位置、标题、
图标与快捷键都照 Xcode。Xcode 的定义在 `IDEPegasusSourceEditor.xcplugindata` 里，命令是
`CmdDefinition.Fold` 等，菜单是 `MenuDefinition.CodeFolding`，挂在 `MenuDefinition.Editor` 下，
26.6 与 27.2 相同：

| 菜单项 | 动作 | 快捷键 | 图标 |
|--------|------|--------|------|
| Fold | `fold:` | ⌥⌘← | `rectangle.compress.vertical` |
| Unfold | `unfold:` | ⌥⌘→ | `rectangle.expand.vertical` |
| Unfold All | `unfoldAll:` | 无 | 同 Unfold |
| Fold Comment Blocks | `foldAllComments:` | ⌃⇧⌘← | 同 Fold |
| Unfold Comment Blocks | `unfoldAllComments:` | ⌃⇧⌘→ | 同 Unfold |

菜单项不设 target，动作沿响应链送达；内容面板不是焦点时，菜单项自动变灰。RV 现在没有用到这几个
快捷键。

App 看不到框架的类型，所以选择器由 bridge 的 `@objc` 协议 `SourceEditorBridgingCodeFoldingCommands`
命名。没有类型遵循它，`SourceEditorView` 自己实现了这些方法；测试逐个核对这些选择器在
`SourceEditorView` 上都有实现，框架将来改了名字，测试就会失败。Editor 菜单只在带 SourceEditor 的
构建里出现（`SourceEditorBridgeFactory.isAvailable`），用 `NSTextView` 的构建里它的命令无处可用。

**不加 Fold / Unfold Methods & Functions**：它们折叠的是 `.subroutine` 区域，也就是函数体，而
生成的接口里没有函数体。

### 3. 查找栏带上搜索词

**现状**：从 Find 导航器打开一条文本命中后，内容面板只定位到这一处，并用 `showCallout` 闪一下。

**框架提供的接口**：
- `findQuery` 是一个 `TextFindQuery`：查询文本、是否区分大小写、`TextFindPattern`。
- 用 `.showFindInterface` 调 `performTextFinderAction`，会打开查找栏，并以 `.All` 模式显示
  全部命中。

**匹配方式一一对应**（`RuntimeInterfaceSearchMatchMode` → `TextFindPattern`）：

| Find 导航器 | 查找栏 |
|-------------|--------|
| containing | contains |
| matchingWord | matchesWord |
| startingWith | startsWith |
| endingWith | endsWith |
| regularExpression | regularExpression |

带 pattern 的查询本来就以正则交给引擎，`ContentHighlightRequest.query` 里存的就是那个正则，
原样传过去。

**做法**：
- **只对文本命中做。** `ContentHighlightRequest` 加一个标记 `showsQueryInFindBar`，Find 的
  `.textMatch` 结果设上；成员搜索与交叉引用跳转仍然只定位，不打开查找栏。
  `ContentTextViewModel` 的 Output 新增 `findBarQuery`（`ContentFindBarQuery`），在同一处命中的
  `highlightRange` 之前发出；命中在文本里没找到时也照样发出。
- **bridge 新增 `showFindInterface(query:pattern:isCaseSensitive:)`**。匹配方式用 bridge 自己的
  `SourceEditorBridgingFindPattern` 表示，因为 bridge 的公开 API 不能出现 SourceEditor 的类型。
- **焦点留在原处。** 框架的 `present(_:)`（0x3DD7F0 一带）最后会把查找栏设为第一响应者。如果
  照这样，在 Find 结果里用方向键逐条浏览就会被打断，所以 bridge 打开查找栏后，把第一响应者还给
  原来的视图。
- **先设查询、开查找栏，再定位到点开的那一处。** 开查找栏时，框架会选中离插入点最近的一处命中，
  之后的定位会把选中改回点开的那一处。

**已知的副作用与差异**：
- 设查询会写系统的查找剪贴板（`pushFindConfigurationForFindQuery`）。之后在其他 App 里按 ⌘G
  也会查这个词，这是 macOS 的惯例。
- 两边的匹配不完全一致。框架把 matchesWord 写成 ICU 的 `\b(?:…)\b`（`TextFindQuery.regularExpressionPattern`），
  而引擎的标识符边界把 `$` 也算作词的一部分（`RuntimeTextPattern.regularExpression(_:boundedAs:)`）；
  不区分大小写时，框架对所有字母折叠大小写，引擎的字面搜索只折叠 ASCII 字母。名字里带 `$` 或
  非 ASCII 字母时，查找栏的命中可能与 Find 导航器略有出入。

### 4. 高亮同名出现

**框架提供的接口**：
- `selectedSymbolHighlightDelay` 默认是 `nil`，即不工作；设了值才开启。开启后，插入点停稳这么久，
  `SelectedSymbolHighlight` 就向 language service 要这个符号的全部引用。引用多于一处时，按主题的
  `symbolHighlightColor` 画在文字底下，而且只画单行的范围。
- `SourceModelLanguageService.referencesToSymbolAtPosition` 自己不找引用，只转给 `hostExtension`
  （`LanguageServiceHostExtension`）；没有 host extension 就返回空。在 Xcode 里，回答这个问题的是
  IDE 上层。

**做法**：
- bridge 实现一个 host extension，在每个新建的 language service 上设置，位置与现在设
  `nodeTypeAdjuster` 的地方相同。`hostExtension` 是 weak 属性，所以由 bridge 持有它。
- 它是 `SymbolOccurrenceProvider`，`referencesToSymbolAtPosition` 这样找：
  - 取该位置的 token（`tokenRangeAtPosition`），只处理 `.identifier` token。查找返回的是插入点
    之后那个字符所在的 token，点在名字最后一个字母的右半边时，插入点落在名字之后；所以该位置
    不是标识符时，再看它前一个字符。
  - 在全文找文字相同的位置，只留下框架也切成同一个 `.identifier` token 的那些（注释、字符串和
    更长名字的一部分都排除），作为结果返回。不区分标识符的细类，同名的属性和方法会一起高亮。
  - 一个名字最多找 5000 处：框架只画可见的那些，这个上限避免在很长的接口里查一个很常见的短名字
    时卡住主线程。
- 协议里有两项没有默认实现：`provideDiagnostics` 回 `nil`，`cancelProvideDiagnosticsRequest`
  留空。其余几项用协议的默认实现，都返回空。
- 延迟定为 0.25 秒。这是我们自己定的，没有查 Xcode 用的值。
- 主题转换不用改：`symbolHighlightColor` 由背景色和一个固定的蓝色混合得到。
- 双击选中一个词（选区非空）时不高亮，这与框架本身的行为一致。

### 不在范围内

- `NSTextView` 后备面板。
- 设置开关：四项默认都开，不加设置项。

### 测试

每项的回归测试都放在 `RuntimeViewerSourceEditorBridgeTests`，并先确认不接时测试失败：
- `ScrollPositionRestorationTests`：换一份文本再换回来，回到原处；第一次显示的文本从顶部开始；
  传「不恢复」时不滚，交给之后的定位。
- `CodeFoldingCommandsTests`：协议里的每个选择器 `SourceEditorView` 都实现了，也都启用；Fold 与
  Unfold All 经响应链送到编辑器后能执行，折叠状态随之改变。
- `FindInterfaceTests`：查找栏打开、全部命中显示、命中数正确，匹配方式和大小写设置照传，查找栏
  已经开着时也换上新查询，第一响应者不变。测试结束时把系统查找剪贴板恢复原样。
- `SymbolOccurrenceTests`：经 language service 查到的就是同名的完整标识符；插入点在名字之后也
  算；关键字没有结果；插入点停稳后高亮层出现。

框架的延迟工作用 `DispatchQueue.main.asyncAfter`，而测试本身是主队列上的一个任务，只转 run loop
时这些工作排不上。所以 harness 的等待改成在两次布局之间挂起。

`ContentTextHighlightTests` 与 `FindViewModelTests` 是包测试，覆盖 ViewModel 的两个新输出（查找栏
查询在定位之前发出、只有文本命中才发出、第一次渲染之后有没有定位），以及 Find 导航器给哪种
命中设标记。

### 文档

落地时在 0009 的「未完成」一节加一句，指向本提案。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-06 | Created as Draft | 盘点了复刻版 26.6.3 里内容面板还没用上的功能，用户从中选定这四项 |
| 2026-11-06 | 其余功能暂不接 | 括号配对高亮：光标已隐藏，用户看不到它的触发点。打印：App 目前整体禁用打印。行号栏图标与行内批注：需要引擎先提供数据，另立提案。补全、Vi、重命名等：都是编辑功能，只读界面用不上。框架的跳转候选列表与 Callers：框架自己从不调用，是留给 Xcode 上层的 |
| 2026-11-06 | 用户批准，开始实现 | 功能分支从 `origin/next` 切出，而不是本地 `next`：本地 `next` 上有另一会话尚未推送的 Tuist 合并，不应随这条分支推上远端；提案随功能分支的第一个提交走 |
| 2026-11-06 | 第一次显示的界面一律从顶部打开 | 实测发现换 data source 时视图保留滚动视图的偏移，新打开的界面会停在上一个界面滚到的位置；这本是既有的毛病，与「记住阅读位置」是同一件事，一并修掉。带着 Find 命中打开时照旧不动，交给定位 |
| 2026-11-06 | Editor 菜单只在带 SourceEditor 的构建里出现 | 用 `NSTextView` 的构建里这些命令没有响应者，菜单只会一直是灰的 |
| 2026-11-06 | 命中在文本里没定位到时，查找栏照样打开 | 查询本身仍然有用：读者能在查找栏里看到这个对象里还有哪些匹配 |
| 2026-11-06 | 插入点紧挨在名字之后也算点在名字上；一个名字最多找 5000 处；不分标识符细类 | 点在名字最后一个字母右半边时插入点落在名字之后，框架查到的是后面的标点；上限避免主线程卡住；同名的属性和方法一起高亮，与按文字找同名的定位一致 |
| 2026-11-06 | 四项放进同一个实现提交 | 四项改的是 bridge、内容面板和测试 harness 里的同一批文件，分开提交就得把同一个文件拆成好几版 |
| 2026-11-06 | 测试的等待改成在两次布局之间挂起 | 高亮同名出现的端到端测试第一次没过：框架用 `DispatchQueue.main.asyncAfter` 安排查询，而测试本身是主队列上的任务，只转 run loop 时轮不到它。这是测试环境的问题，App 里不受影响 |
| 2026-11-06 | 实现完成，待用户看过后收尾 | 在 Ultra（macOS 27.2，Xcode 27.2）上验证。bridge 测试共 53 个，新增的 14 个全过，只有基线本来就挂的两个滚动条测试失败。逐项去掉功能后重跑，新测试都会变红；例外是关键字那个反例，以及只检查框架自身动作的 Fold 响应链测试。包测试 51 个全过，Tuist 构建 App 通过。框架用的是 Ultra 上已有的 26.6.4 下载，因为经 ssh 取不到 26.6.3；两版之间只改了 `MinimapMetalLinesLayer.swift`。真实 App 里的界面没有手动看过。不需要另写使用指南或实现说明，没有新术语 |
| 2026-11-06 | In Progress → Implemented，编号 0074 | 用户批准收尾，与同日加的 Settings › Editor › Display › Insertion Point 开关（记在 [0009](0009-content-editor-engine-selection.md) 的决策日志）一起推上 `next`。落地前没有重跑验证：`origin/next` 在验证之后没有新提交，合并结果与验证过的代码一致，之后只改了文档。不配使用指南：四项都是界面上看得见的行为，菜单项与快捷键照 Xcode，没有要另外说明的用法；也不另写实现说明，框架行为的依据与地址都在本提案的方案一节。没有新术语要进术语表。 |
