# PR #127 代码审查记录 — 2026-10-27

审查对象：PR #127（`feature/sidebar-filter-text-tokens` → `next`，提案
[0060-sidebar-filter-text-tokens](../Evolutions/0060-sidebar-filter-text-tokens.md) 的四步实现：侧栏六处过滤框换成 Xcode
导航区那种文字 token 框），head `744395d1`，基线 `next` `4a052583`。

**经过**
1. `/code-review xhigh` 交回 15 条发现，没有阻塞合并的问题。每条都回到代码与 git 历史复核，按四问作答：能否复现、基线上有没有、
   值不值得修、以前修过没有。
2. 用户批准：修 PR127.1、2、3、4、5、9、13，PR127.5 连同横向排查找到的特化类型选择器一处；PR127.7 改为输入途中忽略、token
   仍与 Xcode 一致；PR127.8 只让 Find 结果的过滤框不按逗号切 token；PR127.11 以后单独做；其余记为不修。要修的问题都先写了
   修复前失败的测试。
3. PR127.1 的复现测试在修复前没有出现审查所说的后果，改判为误报，没有改代码，只留下钉住这一结论的测试。PR127.5 的子进程测试
   在修复前以退出码 1 失败，把审查时按 CoreFoundation 规则推出的结论坐实了。

**约定**
- ID 为 `PR127.<N>`，按审查交回的顺序。
- 四问里的「基线」是 `next` `4a052583`，本 PR 的分叉点。

## 条目

| ID | 问题 | 严重度 | 处理 |
|---|---|---|---|
| PR127.1 | 打字途中的菜单动作让每个页面存一次状态；读字段的值会不会把正在输入的文字变成 token | False positive | 不修：测试证实文字不受影响（`768e9d1d`）；回归测试 `menuActionWhileEditingLeavesTheTypedText` |
| PR127.2 | 切换 Filter Mode 不重新过滤 | Minor | 已修（`d3625a32`）：view model 自己监听 Filter Mode；测试 `changingTheFilterModeFiltersAgain` |
| PR127.3 | Fuzzy / Ifrit 下，正在输入的 token 写法被当成普通文字模糊匹配 | Minor | 已修（`d3625a32`）：`passInputs(for:filterMode:isCaseSensitive:)`；测试 `filterModeAppliesTokenSyntaxInTypedText` |
| PR127.4 | 值以 `!` 开头的 Contains token，编辑后变成 Does Not Contain | Minor | 已修（`8cd0f3ab`）：`\!x` 写法；往返测试各补一例 |
| PR127.5 | 比较跟随系统语言，土耳其语下 `uiview` 找不到 `UIView` | Major | 已修（`8cd0f3ab`）：比较不带 locale；子进程测试 `comparisonsDoNotFollowTheUsersLanguage`；特化类型选择器同类一处一并改 |
| PR127.6 | 最近过滤「最后写的赢」，Clear Recents 可能不生效 | Minor | 不修：等 PR127.11 |
| PR127.7 | 单独一个 `*` 什么都不匹配，打字途中列表变空 | Minor | 已修（`8cd0f3ab`）：输入途中忽略，token 不变；测试 `loneAsteriskBeingTypedFiltersNothing` |
| PR127.8 | 逗号立刻切出 token，过滤不了带逗号的文字 | Minor | 已修，只限 Find 结果（`768e9d1d`）：`endsTokensAtCommas: false`；测试 `commasEndTokensOnlyInFieldsOfNames` |
| PR127.9 | 对象列表重新加载后过滤条件被清空，框里的 token 却还在 | Major | 已修（`d3625a32`）：重新加载保留过滤条件；测试 `filterSurvivesAReload` |
| PR127.10 | 每次菜单动作，所有过滤框都打包一次状态 | Nit | 不修：开销在微秒级，随 PR127.11 消失 |
| PR127.11 | 接入层在绕 AppKitPlus 缺的两个接口 | — | 以后单独做 |
| PR127.12 | 镜像列表管线每个节点复制一次数组；每次比较取一次 `Locale.current` | Nit | 后一半随 PR127.5 消失，前一半不修 |
| PR127.13 | 管线的 `nameMatcher` 有默认值；`matchesScopeRecursively` 只剩测试在用 | Nit | 已改（`2223d4dc`） |
| PR127.14 | `coalescingKeystrokes()` 与批量导出页的延迟写法重复 | Nit | 不修 |
| PR127.15 | 输入里的 `filter` 是 `Driver`，规范要求 `Signal` | Nit | 不在本 PR 修 |

## PR127.1 — 打字途中的菜单动作（误报）

- **问题**：审查认为，`saveState()` 在任何菜单动作之后都读 `encodedState`，而 AppKitPlus 0.18.0 的 `_state` 读
  `objectValue` 时没有像 `_currentFieldItems` 那样套上 `_accessingFieldObjectValueDuringTokenAddition`，它自己的注释又写着
  「编辑中读 `objectValue` 可能把正在输入的文字变成 token」，于是打字时按 ⌘C 之类，半截文字会变成 token、混进最近过滤。
- **复现**：`menuActionWhileEditingLeavesTheTypedText`：字段放进窗口、开始编辑、逐字键入 `NSVi`，发出
  `NSMenu.didSendActionNotification`，再观察一秒（越过字段 0.2 秒的输入停顿）。修复前的结果：没有 token，字段编辑器里仍是
  `NSVi`，只多了一次保存。存进去的半截文字只是状态里 `objectValue` 的一个字符串，读回时恢复再清空；最近过滤只收 token，它不会
  进去。
- **为什么判误报**：审查说的后果不发生。AppKitPlus 那个标志位防的是加 token 时读值引起的重复变化报告（调用方随后就要设新值），
  不是防文字变成 token。没有加「编辑中不保存」：它还得配一次「编辑结束时再存」才不丢 Clear Recents，为一个不存在的问题添复杂度。
- **基线**：没有，接入层是本 PR 新加的。
- **历史**：AppKitPlus 的 `_state` 自 2026-10-10 移植（AppKitPlus `b9d3dbf`）起照 DVT 的 `-_state` 写，没有改过。
- **何时重新审视**：那条测试变红时——AppKit 或 AppKitPlus 改成读 `objectValue` 会提交字段编辑器里的文字；或输入法组字
  （marked text）途中触发菜单动作出了问题。

## PR127.2 — 切换 Filter Mode 不重新过滤

- **问题**：视图在 Filter Mode 变化时经 `combineLatestFirstResult` 把同一个过滤条件再发一次，view model「过滤条件与 Match Case
  都没变就返回」的判断把它挡掉，`scheduleRefilter()` 不执行，别处也不监听 Filter Mode。Contains 模式下输入 `View` 后切到
  Fuzzy，列表停在旧结果，直到下一次按键。
- **复现**：`changingTheFilterModeFiltersAgain`：输入 `NSVwLyr`（没有名字连续包含这几个字母，Contains 下列表为空），再把
  Filter Mode 设成 Fuzzy Search；修复前列表一直为空。
- **基线**：有。审查说基线上「只是排序不同」不对：Contains 与模糊匹配在基线上筛出的集合本来就不同。
- **修法**：view model 订阅 `appDefaults.$filterMode`，先 `distinctUntilChanged` 再 `skip(1)`（它订阅时会连发两次当前值），
  变化即重新过滤。视图里的 `filterModeDidChange` 与重发写法删掉；只有它在用的 `SharedSequence` 扩展
  （`combineLatestFirstResult`、`combineLatestSecondResult`）一并删除。
- **历史**：重发写法是 2025-11-30 实现过滤引擎时（`bd880222`）专为切换模式加的；2026-02-25 的 `eedcff17` 加了相等判断，
  让它悄悄失效。此后没有任何测试切换过 Filter Mode，所以八个月没人发现。

## PR127.3 — 模糊模式下正在输入的 token 写法

- **问题**：Filter Mode 为 Fuzzy 或 Ifrit 时，`typedText` 原样交给模糊匹配。输入 `!Private` 或 `NS*`，名字里没有 `!`、`*`，
  停顿后整个列表变空；回车变成 token 后又按比较方式出了结果，输入时看到的与回车后对不上。
- **复现**：`filterModeAppliesTokenSyntaxInTypedText`：Fuzzy 下输入 `NS* !Window`，修复前列表为空。
- **基线**：没有，基线上这些字符没有特殊含义。
- **修法**：新增 `SidebarRuntimeObjectFilterPipeline.passInputs(for:filterMode:isCaseSensitive:)`：有 Filter Mode 时，输入
  文字里的普通片段组成模糊查询，带写法的片段与 token 一起按比较方式匹配。view model 与管线测试都从这里取输入，测试不再自己
  抄一份 view model 的逻辑。
- **历史**：新代码。

## PR127.4 — 值以 `!` 开头的 Contains token 编辑后变成相反条件

- **问题**：`editingString(for:)` 对 Contains 原样返回值，解析器却把以 `!` 开头的片段读成 Does Not Contain。输入 `!foo*` 得到
  Begins With "!foo"，在 token 菜单里改成 Contains，双击编辑再回车，就成了 Does Not Contain "foo"。审查说「无法表达开头的
  `!`」不完全对：`\!foo` 原本会解析成能匹配字面 `!foo` 的通配符条件，只是不算 Contains。
- **复现**：往返测试补了 Contains "!loo"（`NavigatorTextFilterTests`）与 Contains "!foo"（`NavigatorTextFilterFieldAdapterTests`），
  修复前都失败。
- **基线**：没有。
- **修法**：解析器把 `\!x`（x 为普通文字）读成 Contains `!x`；编辑串对以 `!` 开头、长度大于 1 的 Contains 值写成 `\!…`。
- **历史**：新代码。提案给 `!x` 写法的理由是「名字里不会出现 `!`」，对 Find 结果不成立（过滤的是代码，有 `!=`、`as!`），提案的
  假设一节已补上 `\!` 写法。

## PR127.5 — 比较跟随系统语言

- **问题**：所有比较都带 `locale: .current`。系统语言为土耳其语或阿塞拜疆语时，忽略大小写按该语言把 I 配 ı、İ 配 i，输入
  `uiview` 找不到 `UIView`，`nsimage` 找不到 `NSImage`。只看区域格式（如 `en_TR`）的不受影响。
- **复现**：`comparisonsDoNotFollowTheUsersLanguage`：子进程测试，在子进程里经 argument domain 把语言设成土耳其语，不影响别的
  测试；Contains、Begins With、Ends With 各对 `UIView` 测一次。修复前子进程以退出码 1 退出——它用退出码 2 表示语言没能切过去，
  这次不是。
- **基线**：没有，是本 PR 引入的回归：基线上对象列表（`FilterEngine`）、Find、Report 用的都是不带 locale 的 `.caseInsensitive`。
- **修法**：比较不带 locale，忽略大小写与变音符号照旧。这与 Xcode 的 `localizedStandardContains` 有出入，但代码里的名字不是
  用户语言里的词。PR127.12 里每次比较取一次 `Locale.current` 的开销随之消失。
- **横向排查**：特化类型选择器（`SpecializationTypePickerViewModel`）自 2026-05-14 的 `b8a5f9d2` 起用
  `localizedCaseInsensitiveContains`，基线上就有同样的问题，一并改成不带 locale 的 `range(of:options:)`。它在 App target 里，
  App 唯一的单元测试 target 是 `RuntimeViewerSourceEditorBridgeTests`，测不到它，所以这一处没有测试。
  `RuntimeViewerUsingAppKit/AGENTS.md` 的过滤框一节加了一条：过滤名字不用跟随语言的比较。
- **历史**：新代码。

## PR127.6 — 最近过滤「最后写的赢」（不修）

- **问题**：一是有过滤条件的页面不接收别处的变化，之后一改 token 就把自己的旧列表写回去；二是刚读入状态、还没保存过的页面，
  它的 `encodedState` 必定与 `lastSyncedState` 不同（读入后清空字段，会把当时的过滤挪进最近过滤），所以别的窗口点 Clear
  Recents 时，它在同一轮菜单通知里也会写一次带旧列表的状态，谁赢取决于通知的先后。
- **为什么不修**：Clear Recents 很少用，后果只是列表回来。彻底解决要靠 PR127.11 的 AppKitPlus 接口：只同步最近过滤，不碰
  当前的过滤。接入层的文档注释写明了「最后保存的页面说了算」是有意的设计。
- **基线**：没有。
- **何时重新审视**：做 PR127.11 时一并解决。

## PR127.7 — 单独一个 `*` 让列表变空

- **问题**：解析器把单独的 `*` 读成值为空的 Ends With，什么都不匹配（与 Xcode 一致，有测试钉着）。名字列表里只在先打 `*` 时
  闪空一下；Find 结果里更常见：过滤 `NSString *` 时第二个片段就是单独的 `*`，结果一直为空，而基线上是字面匹配。
- **复现**：`loneAsteriskBeingTypedFiltersNothing`，修复前失败。
- **基线**：没有。
- **修法**（用户选定）：`typedTerms` 去掉值为空的条件，输入途中单独的 `*` 不参与过滤；回车生成的 token 仍与 Xcode 一样匹配不到
  任何东西。
- **历史**：新代码，有意与 Xcode 对齐。

## PR127.8 — 逗号立刻切出 token

- **问题**：`NSTokenField` 默认用逗号切 token，接入层没改。名字里很少有逗号，但 Find 结果是代码，参数列表全是逗号，打字过滤不了
  带逗号的文字；基线的搜索框接受逗号。
- **复现**：`commasEndTokensOnlyInFieldsOfNames`：两个字段放进窗口逐字键入 `String,`，修复前 Find 结果那个也切成了 token。
- **基线**：没有，属能力上的倒退。
- **修法**（用户选定）：接入层加 `endsTokensAtCommas`（默认 `true`），Find 结果传 `false`，把字段的 `tokenizingCharacterSet`
  设为空；回车、Tab 与粘贴照样生成 token，测试覆盖了回车。名字列表保持 Xcode 的行为。
- **历史**：新代码，提案有意把逗号列为切分键。

## PR127.9 — 重新加载后过滤条件被清空

- **问题**：`reloadData()` 把 view model 的过滤条件置空却不通知视图：框里的 token 还在，列表已经全部列出；之后切一下 Match Case，
  `combineLatest` 又把旧条件悄悄套回去。这比审查说的更容易碰到：后台索引每完成一批，引擎都会广播 `.fullReload`，对象列表随之
  重新加载。
- **复现**：`filterSurvivesAReload`：过滤后调 `scheduleReload()`，等列表换成新的单元格；修复前列表全部列出，`filter` 为空，
  `isFiltering` 为 false。
- **基线**：有，基线上清空的是搜索文字，框里同样留着字。
- **修法**：重新加载时保留过滤条件，由紧随其后的 `scheduleRefilter()` 套用到新列表。
- **历史**：这个清空从对象列表最早的实现（当时的 `SidebarImageViewModel`）就有，那时只在第一次加载时执行；后台索引加了每批一次
  的重新加载之后，它才会在用户正在过滤时触发。没有修过，此前也没有登记。

## PR127.10 — 每次菜单动作打包一次状态（不修）

- 每个窗口最多六个接入层，每次菜单命令各做一次 `NSKeyedArchiver` 打包。状态只有几个 token 与最多十条最近过滤，开销在微秒级，
  只有状态变了才写文件。做了 PR127.11，全局菜单监听本身就会去掉。

## PR127.11 — 接入层在绕 AppKitPlus 缺的接口（以后单独做）

- AppKitPlus 的 `NSFilterTokenField` 没有读写最近过滤的接口，Clear Recents 也不通知 delegate；接入层因此监听全局菜单通知，
  并用「恢复整个状态再清空」的办法读入列表。提案决策日志（2026-10-27）已写明这是权宜之计。
- 用户定为以后单独做：AppKitPlus 加读写最近过滤的属性与最近过滤变化的回调，发版、抬下限之后，删掉全局菜单监听与
  `isTakingUpSavedState`，PR127.6、PR127.10 随之解决。

## PR127.12 — 镜像列表管线的两处开销

- `PathState.satisfiedInclusions` 即使值不变也被写一次，每个节点触发一次数组复制（写时复制）。镜像列表只有几千个节点，又在后台
  线程跑，代价很小，不改。每次比较取一次 `Locale.current` 的那一半随 PR127.5 消失。

## PR127.13 — 管线的 `nameMatcher` 默认值（已改）

- `verdicts` 与 `apply` 各自给 `nameMatcher` 默认 `.empty`：调用方只给其中一步传，单元格就会存下空的条件，下一次特化插入时
  显示本该藏起来的子项。现有调用都传了，风险只在以后。两个默认值去掉，测试改为显式传 `.empty`；只剩测试在用的
  `matchesScopeRecursively(_:)` 删掉，测试改用 `matchesRecursively(scope:nameMatcher:)`。

## PR127.14 — `coalescingKeystrokes()` 与批量导出页重复（不修）

- 批量导出的镜像选择（`BatchExportingImageSelectionViewModel`）有同样的「非空延迟 150 ms、清空立即放行」写法，作用于 `String`，
  基线上就有，当初是照侧栏抄的。合并要为 `isEmpty` 抽一个协议，两处各几行，不值得。

## PR127.15 — 输入里的 `filter` 是 `Driver`（不在本 PR 修）

- `RuntimeViewerUsingAppKit/AGENTS.md` 规定 view model 的 `Input` 由 `Signal` 组成。对象列表、Find、Report 这三处在基线上就是
  `Driver`（当时叫 `searchString` / `filterString`），本 PR 只改了名字。改成 `Signal` 会改变初值的语义（对象列表靠
  `Driver.combineLatest` 合并两路输入），应当单独做一次全仓库整理。
