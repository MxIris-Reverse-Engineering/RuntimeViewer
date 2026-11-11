# 2026-11-11 Reveal in Sidebar Navigator 把对象行留在钉住的分组标题或顶栏下面

**调查日期：** 2026-11-11
**修复落地：** 本日。滚动到行的逻辑搬进 `StatefulOutlineView.selectRowBringingIntoView(_:)`，改按「没有被遮住的区域」判断与居中，
见「修复」。回归测试 `StatefulOutlineViewRevealTests`（`RuntimeViewerApplicationTests`）
**所属分支：** `next`（经 `fix/reveal-below-pinned-rows`）
**Severity：** Minor —— 揭示的那一行被选中了，但看不见，用户还得自己滚一下
**触发场景：** 用户反馈：在侧栏对象列表里 Reveal in Sidebar Navigator，选中的「CAFrameRateRange」停在分节标题「C Struct」下面，被它和
分页切换栏挡住。macOS 27.2

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 揭示或跟随选中后，选中行停在列表顶端被钉住的分节标题下面、顶部的工具栏与分页切换栏下面，或底部的过滤栏下面；从列表下方揭示前几个对象时，它们停在顶栏下面 |
| **影响范围** | 侧栏对象列表的 Reveal in Sidebar Navigator（菜单、⇧⌘J、内容区右键菜单）、从 Inspector 或历史选中对象时侧栏的跟随、过滤结束后恢复选中。macOS 26 起列表在栏下延伸，栏下的部分才会挡住；分节标题从对象列表按种类分节（2026-06-19）起就会浮动 |
| **根因** | 「行是否已在屏幕上」用的是整个 `visibleRect` 里的行，可 `visibleRect` 包括裁剪视图内容边距下的部分（各栏所在）和浮动分组行盖住的那一条，于是被盖住的行也算可见、不滚动。需要滚动时，UIFoundation 的 `scrollRowToVisible(_:animated:scrollPosition:)` 在整个 `visibleRect` 里居中、并把滚动位置截在文档顶边 0，不认内容边距，前几行就停在顶栏下面 |
| **Status** | **Fixed** |

---

## 根因

侧栏的列表从 macOS 26 起在栏下延伸（提案 0052）：工具栏与分页切换栏、底部的过滤栏都浮在列表上，`NavigatorScrollViewLayout`
把它们盖住的高度写进裁剪视图的 `contentInsets`。对象列表按种类分节，分节标题是浮动的分组行，节在顶栏下面滚动时，标题钉在顶栏正下方。

`selectRowBringingIntoView(_:)` 原来先看 `box.visibleRowIndexes`（UIFoundation，即 `rows(in: visibleRect)`）里有没有这一行，有就不滚动。
裁剪视图的边界一直延伸到栏下，所以被顶栏、底栏或钉住的标题盖住的行，都在 `visibleRect` 里。测试里量到的一例：行顶在顶栏下沿往下 4 pt，
被 28 pt 高的标题盖住，判断照样认为它在屏幕上。

真要滚动时，UIFoundation 按整个 `visibleRect` 的高度居中，再把目标位置截在 `[0, 文档高度 − 可见高度]`。有内容边距时，裁剪视图能滚到
`−contentInsets.top`，截在 0 就让列表回不到真正的顶端：揭示第一个对象时它停在 y = 38，顶栏与标题要盖到 88。

## 修复

`StatefulOutlineView.selectRowBringingIntoView(_:)`（侧栏对象页与过滤结束后的恢复选中共用，原来各有一份）：

- 「没有被遮住的区域」是裁剪视图边界减去上下内容边距，顶部再减去这一行所在节的标题高度——列表的分组行浮动时，取这一行最外层祖先
  （分组项）那一行的高度；行本身是分组行时不减。
- 行完全在这片区域里就不滚动，照旧只选中。否则让行在这片区域里居中，目标边界交给 `NSClipView.constrainBoundsRect(_:)` 截断：它认
  内容边距，允许滚到文档顶边之上，前几行因此能出到顶栏下面。
- 滚动后照旧强制布局，再选中，保持 2026-08-05 定下的「先滚动、再选中」的顺序。

## 横向排查

用到「先滚动再选中」的还有 Find 范围选择弹窗（`FindScopeChooserViewController` 的 `revealedImagePath`）：那是表单里的普通表格，
不在栏下、没有分组行，不受影响。Find 与 Report 两页的结果列表虽然浮动分组行，但不由程序滚动到某一行。

## 验证

- **回归测试** `StatefulOutlineViewRevealTests`：离屏窗口里一个分节、分组行浮动的大纲视图，上方 52 pt 的栏、下方 44 pt 的栏由真实的
  `NavigatorScrollViewLayout` 排版。四个用例：行在钉住的标题下（顶栏下沿往下 4 pt）、行在顶栏下（往上 10 pt）、行在底栏下、从列表
  下方揭示第一个对象，都断言行完整落在没有被遮住的区域里；第五个用例断言没被遮住的行不触发滚动。
- **修复前后**（Ultra，macOS 27.2，Xcode 27.2）：搬迁后、修复前的提交上前四个断言失败、第五个通过；修复后五个都通过，连同
  `StatefulOutlineView`、`NavigatorScrollViewLayout` 与侧栏两组 ViewModel 的套件共 97 个测试通过。
- 没有在 App 里目视；浮动标题的实际高度与分组行的 `rect(ofRow:)` 是否一致，测试看不出来，以截图里标题紧贴分页切换栏为准。
