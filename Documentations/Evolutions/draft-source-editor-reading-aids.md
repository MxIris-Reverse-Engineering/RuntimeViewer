# Draft - 内容面板接入 SourceEditor 现成的四项阅读功能

- **状态**: Accepted
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
滚动位置却没有记录。所以后退、切回一个对象时总从顶部开始；换主题或字号重新渲染时，预计也会
跳回顶部（实现时实测）。

**框架提供的接口**：`SourceEditorView.scrollStateForStateRestoration()` 返回可见区顶部所在的行，
以及这一行内的偏移。`applyScrollState(_:defer:)` 传 `defer: true` 时先记下这个位置，等下一次布局
完成（`layoutManager(_:didFinishLayoutInContentView:)`）再滚过去。

**做法**：
- `FoldStateCache` 改为同时保存折叠状态和滚动位置。键不变，仍按文本计算，改名以反映新的内容。
- `setSource` 在 unfold 之前保存当前状态。换上新文本、恢复折叠之后，再用 `defer: true` 恢复
  滚动位置。
- **带着 Find 命中打开时不恢复。** 命中的定位（`revealCharacterRange`）是异步到达的，延迟执行的
  恢复可能排在它之后，把定位冲掉。`ContentTextViewModel` 知道这次渲染有没有待定位的命中，由它
  给 `setSource` 一个参数，决定是否恢复。

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
- **只对文本命中做。** `ContentHighlightRequest` 加一个标记，Find 的 `.textMatch` 结果设上；
  成员搜索与交叉引用跳转仍然只定位，不打开查找栏。
- **bridge 新增一个方法**，参数是查询文本、匹配方式和是否区分大小写。匹配方式用 bridge 自己的
  类型表示，因为 bridge 的公开 API 不能出现 SourceEditor 的类型。
- **焦点留在原处。** 框架的 `present(_:)`（0x3DD7F0 一带）最后会把查找栏设为第一响应者。如果
  照这样，在 Find 结果里用方向键逐条浏览就会被打断，所以 bridge 打开查找栏后，把第一响应者还给
  原来的视图。
- **先设查询、开查找栏，再定位到点开的那一处。** 开查找栏时，框架会选中离插入点最近的一处命中，
  之后的定位会把选中改回点开的那一处。

**已知的副作用与差异**：
- 设查询会写系统的查找剪贴板（`pushFindConfigurationForFindQuery`）。之后在其他 App 里按 ⌘G
  也会查这个词，这是 macOS 的惯例。
- 引擎的 matchingWord 用自己的标识符边界。框架的 matchesWord 用什么边界，实现时读源码核对。
  两者不一致时，查找栏的命中数可能与 Find 导航器略有出入。

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
- 它的 `referencesToSymbolAtPosition` 这样找：
  - 取该位置的 token（`tokenRangeAtPosition`），只处理标识符类的 token；
  - 在全文找文字相同的位置，留下框架同样切成同类、同长度 token 的那些，作为结果返回。
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
- 换一份文本再换回来，滚动位置回到原处；传「不恢复」时，停在定位的那一处。
- Code Folding 的几个动作经响应链送到编辑器后能执行，执行后折叠状态改变。
- 设查询后：查找栏打开，命中数正确，第一响应者没有变。
- host extension 返回同名 token 的范围；插入点停稳后，symbol highlight 层可见。

`ContentTextViewModel` 输出的「本次渲染带待定位命中」用包测试覆盖。

### 文档

落地时在 0009 的「未完成」一节加一句，指向本提案。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-06 | Created as Draft | 盘点了复刻版 26.6.3 里内容面板还没用上的功能，用户从中选定这四项 |
| 2026-11-06 | 其余功能暂不接 | 括号配对高亮：光标已隐藏，用户看不到它的触发点。打印：App 目前整体禁用打印。行号栏图标与行内批注：需要引擎先提供数据，另立提案。补全、Vi、重命名等：都是编辑功能，只读界面用不上。框架的跳转候选列表与 Callers：框架自己从不调用，是留给 Xcode 上层的 |
| 2026-11-06 | 用户批准，开始实现 | 功能分支从 `origin/next` 切出，而不是本地 `next`：本地 `next` 上有另一会话尚未推送的 Tuist 合并，不应随这条分支推上远端；提案随功能分支的第一个提交走 |
