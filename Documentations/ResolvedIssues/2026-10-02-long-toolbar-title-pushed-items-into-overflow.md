# 2026-10-02 标题一长，工具栏右侧的按钮全进了溢出菜单：AppKit 用优先级 200 测 item 的最小宽度

**调查日期：** 2026-10-02
**修复落地：** 本日。`TitleToolbarItem` 从 `MainToolbarController` 挪到
`RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/TitleToolbarItem.swift`（标识符改为初始化参数），加上四项尺寸设置，
见「修复」。回归测试 `TitleToolbarItemOverflowTests`（`RuntimeViewerApplicationTests`）
**所属分支：** `next`。这个类在 `main` 上与 `next` 逐字相同；但 `main` 的 `RuntimeViewerApplicationTests` 不直接依赖
`RuntimeViewerUI`，测试搬过去要补这条依赖
**Severity：** Major —— 标题一长，Runtime Source 切换和其后所有按钮都进了 `»` 溢出菜单，每次都要多点一层
**触发场景：** 用户反馈 ——「这个toolbar item的title和subtitle太长了会把右边的item全部挤掉……我已经降低了抗压缩等级」

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 主窗口工具栏的标题或副标题较长时，右侧的 Runtime Source 弹出按钮和其后所有按钮都进了 `»` 溢出菜单；标题本身完整显示，不截断 |
| **影响范围** | 主窗口工具栏（App 里只有这一个工具栏），标题或副标题宽于「窗口宽度减去其它 item」时 |
| **根因** | NSToolbar 不看 view 当前的尺寸：它在一个独立的布局引擎里以优先级 200 把 view 压到 0 宽，解出最小宽度，再**只按各 item 的最小宽度**决定谁进溢出菜单。label 的水平抗压缩是 `.defaultLow`（250），高于 200，整段文字就成了 item 的最小宽度。用户已经降过的这一档恰好还在门槛之上 |
| **系统版本** | macOS 15.8.1、26.6、27.0 的 AppKit 测量逻辑一致（反编译并对照汇编）；测试在 27.0（26A428）上跑 |
| **Status** | **Fixed** |

---

## 根因

地址来自 macOS 27.0（26A428）的 AppKit，IDA 库 `/Volumes/DyldSharedCaches/macOS/27.0/AppKit-20261002.i64`（同目录原来的
`AppKit.i64` 两次打开都在解包后崩溃，本次重建；崩溃留下的解包文件挪到了 `AppKit.residue-20261002-1853` / `-1854`）。
26.6 与 15.8.1（`/Volumes/DyldSharedCaches/macOS/15.8.1/AppKit.i64`，本次新建）的同名函数逻辑相同。标注了 26.6 的几条
只在 26.6 上看过。

### 工具栏怎么测一个自定义 view

- 没有显式设置 `minSize` / `maxSize`（macOS 12 起已废弃）的 item，`-[NSToolbarItem minSize]`（0x184FC73EC）调 direct 方法
  `-[NSToolbarItem _itemViewMinSize:maxSize:stretchesContent:]`（0x184FD5578）现算。direct 方法不在 Objective-C 方法表里，
  导出的头文件看不到它。
- 它既不读 view 的 frame，也不调 `fittingSize`：新建一个 `NSISEngine`，放进 view 子树的约束，解两次——
  - 最小宽度：加 `width == 0`，优先级 **200**，约束标识符 `fittingSizeHCompression`（block 0x1858D6AB8）；
  - 最大宽度：常量改成 10000，优先级同样 **200**（block 0x1858D6CAC）。
- 所以测最小宽度时，子树里优先级高于 200 的约束都不让步：抗压缩 250 的 label 保持整段文字的宽度。
- **测出的最小宽度恰好是 0 时另有退路：** 工具栏认为测不出来，打出 `WARNING <…> -> view was automatically measured but had
  an ambiguous height or width and the view's frame size had a zero height or width`，改用 view 当前的 frame 同时当最小和
  最大尺寸。view 还没布局过时 frame 是 0，item 就被定成 0 宽。
- 结果由 `-[NSToolbarItemViewer _configureViewerSize]` 加上 viewer 的内边距缓存；实际布局时
  `-[NSToolbarItemViewer declaredLayoutConstraints]` 用一条优先级 997 的 `width ==` 把分到的宽度钉在 view 上（这两条看的是 26.6）。

### 谁进溢出菜单

`-[NSBarLayout _visibleItems:inRect:]`（0x18553713C）按工具栏内部的顺序累加各 item 的**最小宽度**；第一个放不下的
（除非它的 `compressedMinSize` 放得下）和之后的所有 item 进溢出菜单。不看最大宽度，也不会为了腾地方压缩别的 item。
标题排在右侧按钮之前、最小宽度又是整段文字，于是先把预算用完；文字比窗口还宽时，连标题自己也进了溢出菜单。

### 剩余宽度怎么分（26.6）

`-[NSBarLayout _calculateLayoutOfItems:inRect:sharesLeadingEdge:sharesTrailingEdge:]`（26.6：0x185444FBC）先给每个 item
它的最小宽度，剩下的依次分给：没到 clipping 尺寸的、没到首选尺寸的、能拉伸到最大宽度的 item，再是几类特殊 item 与窗口
标题，**flexible space 排最后**。所以只要最大宽度等于文字宽度，空间够时标题就完整显示。

### 系统自己的标题

unified 工具栏里系统画的窗口标题（`NSToolbarTitleView`）：`minSize` 宽 160 pt（`_minimumInlineWindowTitleWidth` 为默认的
-1 时取 160，0x18599BD24），`compressedMinSize` 宽 8 pt（0x18599BD18）。这里只作参照，没有照搬。

---

## 修复

`TitleToolbarItem` 现在有四项尺寸设置，缺一不可（「验证」里逐项去掉过）：

| 设置 | 值 | 去掉它会怎样 |
|---|---|---|
| 两个 label 的水平抗压缩 | 199（低于 200） | 最小宽度又是整段文字，按钮全被挤走 |
| 容器的最小宽度（`width >=`，required） | 左右内边距 + 一个只放「…」、与标题同字体的 label 的宽度，随标题字体更新 | 只降抗压缩时，测出的最小宽度恰好是 0（容器 8 pt 的左内边距没有撑住，原因没深究），走上面的退路，标题被定成 0 宽 |
| 纵向文字 stack 的水平 hugging | 198（低于 label 的 199） | 纵向 `NSStackView`（`.leading` 对齐）按自己的 hugging 优先级把每个 label 的右边缘拉向自己的右边缘；默认 250 时把较宽的 label 压到和较窄的一样宽。实测长标题被压到副标题「NSControl」的宽度，旁边空着四百多 pt |
| 容器的最大宽度（`width <=`，优先级 250） | 左右内边距 + 较宽 label 的宽度 | stack 的 hugging 降到 200 以下后，测最大宽度时没有别的约束能把 item 停在文字宽度，标题会占满按钮留下的全部空间（实测 467 pt 宽，文字 54 pt） |

- **最小宽度按批准的方案取「只剩省略号」**，不留可读的一截：窗口很窄时标题缩到「…」，右侧按钮优先保留。
- **类挪进 `RuntimeViewerUI`** 是为了能写测试：App target 没有单元测试 target。`StatefulOutlineView` 的测试也放在
  `RuntimeViewerApplicationTests`。App 侧只剩 `TitleToolbarItem(itemIdentifier: .Main.title)`；`insets` 保留为 public，改它会同步
  更新上下限。
- 顺带消掉了一条原本就有的警告：修复前，item 插入工具栏时标题还是空字符串，那次测量已经得到 0 并打出上面那条 WARNING。

---

## 横向排查

找的是同一模式：工具栏里由自定义 view 决定宽度、宽度随内容变化、内容的抗压缩高于 200 的 item。App 里只有主窗口这一个工具栏。

| item | 判断 | 处理 |
|---|---|---|
| `TitleToolbarItem` | 本问题 | 已修 |
| `SwitchSourceToolbarItem`（`NSPopUpButton`） | 宽度随菜单里最长的运行时源名字变化，抗压缩是控件默认的 750；机制相同，名字很长时也会把后面的按钮挤进溢出菜单 | 不改：没有反馈，弹出按钮按最长项定宽是常见做法。真要改，办法相同：抗压缩降到 200 以下并给一个最小宽度 |
| 导航分段控件、各图标按钮、分享按钮 | 宽度固定，不随内容变化 | 不涉及 |

---

## 验证

- **回归测试** `TitleToolbarItemOverflowTests`：800 pt 宽的离屏窗口，unified 工具栏里依次是标题 item、flexible space、6 个按钮；
  长文本是 12 段 `NSToolbarItemViewerOverflowFix `，远宽于窗口。
  - 「a long title or subtitle leaves every button on the toolbar」（标题、副标题各一例）：6 个按钮都在 `NSToolbar.visibleItems` 里。
  - 「a long title or subtitle takes the room the buttons leave and is cut short there」：长文本那个 label 的 frame 窄于它的
    intrinsic 宽度（被截断），且标题 view 与第一个按钮之间的空白小于 40 pt。
  - 「a title that fits is shown at its full width and no wider」：短标题时没有 label 被截断，标题 view 不比「内边距 + 较宽 label」宽。
  - 截没截断直接看 label 自己（frame 对 intrinsic 宽度）。最初拿一个不进工具栏的同配置 item 的 `fittingSize` 当对照，结果它也被
    stack hugging 带偏：2649 pt 的文字测成 54 pt。
- **逐项去掉的对照**（同一份测试，每次只改一处）：

| 代码状态 | 失败的测试 | 关键数据 |
|---|---|---|
| 原代码（四项都没有） | 按钮、长标题、短标题 | 6 个按钮全进溢出菜单；短标题 view 70 pt 宽（文字 54 + 内边距 8 = 62，多出的 8 pt 来源没查） |
| 去掉「抗压缩 199」 | 按钮、长标题 | 6 个按钮全进溢出菜单 |
| 去掉最小宽度 | 长标题、短标题 | 测量警告 10 条；标题与按钮之间空 461 pt；短标题的 label 只剩 4 pt |
| 去掉 stack hugging 198 | 长标题、短标题 | 空 409 / 418 pt；「NSControl」只显示 48.5 / 54 pt |
| 去掉最大宽度 | 短标题 | 标题 view 467 pt 宽，文字 54 pt |
| 修复后 | 无 | 长文本显示 471 pt（全文 2649 / 2132.5 pt），与第一个按钮间空 12 pt（item 间距）；没有测量警告 |

- 同一次运行里 `StatefulOutlineViewAutosaveTests`、`StatefulOutlineViewRowGeometryTests`、`StatefulOutlineViewTrackingLoopTests`
  照常通过（4 个 suite、11 个测试）；`~/Library/Application Support/RuntimeViewer-Debug/settings.json` 的 SHA 前后一致。
- **构建方式：** 包按远程依赖、在独立 scratch 目录（`/Volumes/DerivedData/Agents.noindex/claude/SwiftPM/RuntimeViewerPackages-next`）
  里编译和测试；被跟踪的 `RuntimeViewerPackages/Package.resolved` 已过期（钉的 MachOSwiftSection 早于 Core 用到的 API），测试期间
  临时移走，结束后还原。App 用 `RuntimeViewer.xcworkspace`、scheme `RuntimeViewer macOS`、Debug，加 `-disableAutomaticPackageResolution`
  按工作区锁文件钉的版本编译，成功，锁文件未被改写。
- 真实 App 里的确认由用户运行 Debug 构建完成。
