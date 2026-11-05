# 2026-11-05 标题一长，工具栏正中的选择器被挤到右边：居中项要等前面的项分完剩余宽度才定位置

**调查日期：** 2026-11-05
**修复落地：** 本日。`TitleToolbarItem` 的视图换成一个不设宽度上限的外层视图，原来的标题容器连同 2026-10-02 的四项尺寸设置
放在它里面，见「修复」。回归测试 `ToolbarCenteredItemTests`（`RuntimeViewerApplicationTests`）；`TitleToolbarItemOverflowTests`
里量标题宽度的那条断言改为量标题容器
**所属分支：** `next`（经 `feature/toolbar-centered-item-keeps-its-place`）
**Severity：** Minor —— 不丢功能，但选择器随标题长短左右移动，长标题时被推到右侧按钮组旁边
**触发场景：** 用户反馈：Xcode 27 样式下选中 UIKitCore 里一个名字很长的类型，工具栏正中的运行时来源选择器被左侧的标题挤向右侧。
选择器应当固定在中间、优先级最高，标题不能把它挤走。macOS 27.2

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 标题或副标题较长时，正中的「My Mac (Mac Catalyst)」离开中间，一直被推到离右侧按钮组约 5 pt 的地方；标题同时被截断 |
| **影响范围** | 两种照 Xcode 的工具栏样式都有：Xcode 27 样式正中的来源选择器，Xcode 26 样式正中的活动胶囊（保持 40 % 的宽度，整体右移）。Classic 样式没有居中项，不受影响 |
| **根因** | NSToolbar 给带居中项的分区排版时，先给每项最小宽度，余下的在「居中项前面那组 / 居中项 / 后面那组」之间平分，各组最多长到自己的最大宽度，之后才定居中项的位置：放得下就居中，前面那组长过了居中项的起点就把它往后推。标题的最大宽度是文字宽度（2026-10-02 为了不让标题占满空白而加的上限），文字一长，前面那组就把余下的空间全部拿走 |
| **系统版本** | macOS 27.0（26A428）反编译并对照汇编；27.2（26B123）的同名函数逐指令比对无差异；26.6.2 的工具栏同样不走 principal 路径。测试在 macOS 27.2 上跑 |
| **Status** | **Fixed** |

---

## 根因

地址来自 macOS 27.0（26A428）的 AppKit，IDA 库 `/Volumes/DyldSharedCaches/macOS/27.0/AppKit+SceneHosting.i64`（经副本打开）；
27.2 的地址取自本机的 dyld shared cache，把地址、立即数与寄存器名归一后逐行比对，下列函数没有差异。

| 函数 | 27.0 | 27.2 |
|---|---|---|
| `-[NSToolbarView _layoutDirtyItemViewersAndTileToolbarAndRecalculateKeyViewLoop:]`（direct 方法） | 0x1858F2604 | 0x18AD08A1C |
| `+[NSToolbar newToolbarLayout]`（direct 方法） | 0x1858AC484 | 0x18ACC3CA0 |
| `-[NSToolbarView layout:visualCenterXForCenterItems:]` | 0x1858FA8DC | 0x18AD10C04 |
| `-[NSBarLayout _centerRectGivenItems:leadingItems:trailingItems:inRect:]` | 0x1855365C8 | 0x18AA36F90 |
| `-[NSBarLayout _layoutSectionOfItems:inRect:requiresTrueCenterLayout:]` | 0x185535A20 | 0x18AA363E8 |
| `-[NSBarLayout _maxWidthOfItems:…constrainsSearchItems:]` 的 block | 0x185537AC8 | 0x18AA384B4 |
| `-[NSBarLayout _calculateLayoutOfItems:inRect:sharesLeadingEdge:sharesTrailingEdge:]` | 0x185535DB0 | 0x18AA36778 |

### 工具栏怎么摆居中项

- `NSToolbarView` 有三类 `NSBarLayout`：侧栏追踪分隔符之前的、检查器追踪分隔符之后的、两者之间的。`isNavigational` 的项
  （导航分段控件和标题都是）被挪到侧栏追踪分隔符之后。居中项所在的中间分区里，它前面的项（导航、标题、flexible space）是
  一组，它后面的项（flexible space、右侧按钮）是另一组。
- `-[NSBarLayout _centerRectGivenItems:leadingItems:trailingItems:inRect:]` 定居中项的宽度和位置，伪代码：

  ```
  free = W - cMin - lMin - tMin                 // 每项先拿最小宽度
  std  = standardCenterWidth                    // preferredPrincipalItemWidthRatio > 0 时为 ceil(ratio × 工具栏宽)，否则 -1
  if cMin <= std && (std <= cMax || 居中项里有 flexible space) { c = min(std, cMin + free); cTarget = c } else { cTarget = cMax }
  loop:                                         // 注水，三组平分
    n = [l != lMax] + [c != cMax] + [t != tMax]; share = free / n
    l, c, t 各加一份 share，各自不超过 lMax、min(cMax, cTarget)、tMax
    until free <= 0.5 || share <= 0.5 || 没有一组再长
  x = vc - c / 2
  x = max(x, rect.x + l)                        // 前面那组太宽：往后推
  x = min(x, rect.maxX - t - c)                 // 后面那组太宽：往前推
  ```

  算 `lMax` / `tMax` 时，flexible space 和**视图测出的最大宽度达到 10000 点的项按最小宽度计**（block 0x185537AC8）。
- 之后 `_layoutSectionOfItems` 把前面那组排进 `[rect.x, x)`、后面那组排进 `[x + c, rect.maxX)`，组内由
  `_calculateLayoutOfItems` 分配，可拉伸的项先于 flexible space 长到最大宽度（2026-10-02 的文档已记）。
- **视觉中心 `vc`**（`layout:visualCenterXForCenterItems:`）：从居中项往前、往后各找第一个分区位置不是 −1 的项，即两条追踪分隔符，
  取它们对应的分栏 divider 位置的中点。不是窗口中线，与红绿灯无关；找不到分隔符时退回工具栏视图的中线。

### 为什么是标题

标题的最大宽度是文字宽度，前面那组的 `lMax` 随文字变长。文字短时，标题很快长到最大宽度，前面那组停止增长，余下的空间没人要，
居中项留在 `vc`；文字一长，每一轮注水前面那组都拿一份，居中项到 `cMax` 后余下的全归它，于是 `l = W - c - tMin`，
`x = rect.maxX - tMin - c`：居中项贴到后面那组，标题在剩下的空间里截断。截图里选择器与右侧按钮组之间那约 5 pt，是两者的玻璃
底板比视图宽一圈的结果（推断）。

### 先前的笔记读错了路径

`/Volumes/RE/Xcode/26.6/README.md` 与 UIFoundation 的 `Researchs/AppKit-NSToolbar-CenteredItemWidthRatio-Internals.md` 曾写，居中项由
`-[NSBarLayout _principleRectGivenItems:…]` 摆放，「以视觉中心居中，一侧不够才横移」。工具栏到不了这个函数：
`+[NSToolbar newToolbarLayout]` 把每个工具栏布局的 `centerIsPrincipal` 设成 NO（26.6.2 的 0x1856A1DF0 也是），整个 AppKit 里只有
Touch Bar 把它设成 YES；同一函数里的 `requiresTrueCenterLayout` 也只有 Touch Bar 写。两处笔记本日已更正。UIFoundation 指南里那条
「26.6 的反汇编读出来是取最小宽度、27.2 实测却是作废」的矛盾也就此解开：读的是 Touch Bar 的路径。

---

## 修复

让标题项的视图测出 10000 点的最大宽度。前面那组在注水时就按标题的最小宽度算，不再增长，居中项留在 `vc`；排版时标题照常先于
flexible space 拿空间，一直延伸到居中项左边，文字超长就截断在那里。

| 部分 | 做法 | 为什么 |
|---|---|---|
| item 的视图 | 新的 `ItemView`，不设任何宽度上限 | 测量时工具栏以优先级 200 把它拉到 10000 点，没有约束拦着 |
| 标题容器 | 原来的 `ContainerStackView`，四项尺寸设置不变，贴在 `ItemView` 的 leading、top、bottom，trailing `<=` | 文字、截断、最小宽度、悬停的行为都和原来一样 |
| 容器拉向外层宽度 | `width == ItemView.width`，优先级 150 | 让容器和它原先作为 item 视图时一样宽：有空间时停在自己的最大宽度（文字宽度，优先级 250）。优先级必须低于 200，否则测量时它把 `ItemView` 也拉回文字宽度，item 又有了最大宽度 |
| 空白处的点击 | `ItemView.hitTest(_:)` 命中自己时返回 `nil` | 外层视图占了原先属于 flexible space 的空白；点在那里应当和点在 flexible space 上一样落到工具栏 |

没采用的办法：

- **打开 `requiresTrueCenterLayout`。** 只有 Touch Bar 的路径读它；而且中间分区的布局每次重新组装都由 `newToolbarLayout` 新建，
  强行设上也会被重置。
- **按几何关系动态限制标题宽度**（算出居中项的起点，减去标题的起点）。要在 App 里复刻 `vc` 公式与各项的内边距，每次缩放窗口、
  拖分隔线都要重算，算错就又被挤走。
- **`preferredPrincipalItemWidthRatio`、`visibilityPriority`、`compressedMinSize`、把居中项包进单项 `NSToolbarItemGroup`**：都挡不住
  前面那组吞掉余下的空间，后两者只影响溢出菜单。

---

## 横向排查

找的是同一模式：居中项前后、宽度会随内容变的项。

| 位置 | 项 | 判断 |
|---|---|---|
| 居中项前面 | 导航分段控件 | 宽度固定，最小等于最大，不会增长 |
| 居中项前面 | 两个标题项（Xcode 26 / Classic 共用的、Xcode 27 的） | 本问题，同一个类，一次修好 |
| 侧栏分区 | 切换侧栏、返回按钮 | 在侧栏追踪分隔符之前，属于另一个布局，不参与 |
| 居中项后面 | 右侧各图标按钮、分享按钮 | 宽度固定 |
| Classic 样式 | 标题后面的来源弹出按钮 | 没有居中项，不走这条路径；标题的外层视图现在占了原先属于 flexible space 的空白，文字位置不变 |

App 里只有主窗口这一个工具栏；窗口标题是隐藏的，没有系统的标题视图参与。

---

## 验证

- **回归测试** `ToolbarCenteredItemTests`：1400 pt 宽的离屏窗口，`NSSplitViewController` 带 200 pt 的侧栏与 200 pt 的检查器，
  工具栏在两条追踪分隔符之间依次是导航分段控件、标题、flexible space、居中项、flexible space、4 个按钮。两种样式各跑一遍：
  Xcode 27 样式是带活动环的标题加来源选择器，Xcode 26 样式是普通标题加 40 % 宽的活动胶囊。
  - 「with a short title the centered item sits midway between the sidebar and the inspector」：短标题时居中项的中点在两条
    divider 的中点（700 pt），误差 1.5 pt 以内。这是前提校验，也证实了上面 `vc` 的公式。
  - 「a long title or subtitle leaves the centered item where a short one does and is cut short before it」（两种样式 × 长标题 /
    长副标题）：居中项的中点与宽度和短标题时相同，长文本被截断，标题容器的右边缘不越过居中项的左边缘。
  - 「a click between the title and the centered item goes to neither of them」：标题与居中项之间的一点，命中的视图既不在标题项里，
    也不在居中项里。
- **修复前后**（在 Ultra 上跑，macOS 27.2，Xcode 27.2 27B52；修复前的一轮是把 `TitleToolbarItem.swift` 退回修复前的版本、测试不变）：

| 代码状态 | 结果 | 关键数据 |
|---|---|---|
| 修复前 | 长标题的 4 个用例全红，其余通过 | Xcode 27 样式：选择器中点 700.0 → 957.5 pt；Xcode 26 样式：胶囊中点 700.0 → 758.0 pt，宽度不变 |
| 修复后 | 两个 suite 的 6 个测试全部通过 | 长标题时居中项的中点与宽度和短标题时相差不到 0.5 pt |
| 去掉 `ItemView.hitTest(_:)` | 点击测试在两种样式下都红 | 点击落在 `ItemView` 上，即标题项里 |
| 容器拉向外层宽度的优先级改成 250 | 长标题的 4 个用例全红 | 数值与修复前完全相同：item 又以文字宽度为最大宽度 |

- 两轮运行都没有工具栏的测量警告（「view was automatically measured…」），也没有约束冲突。
- `TitleToolbarItemOverflowTests` 修复前后都通过；其中「a title that fits is shown at its full width and no wider」原先量的是
  item 的视图，现在量标题容器——修复后 item 的视图本来就比文字宽。

- 真实 App 里的确认（两种样式下切换长短不同的对象、拖动侧栏分隔线、在标题旁的空白处拖动窗口）由用户运行 Debug 构建完成。
