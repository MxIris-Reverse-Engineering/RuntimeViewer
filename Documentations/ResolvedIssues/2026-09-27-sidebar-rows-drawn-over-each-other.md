# 2026-09-27 侧栏对象列表两行叠在一起：AppKit 的行高估算把行留在了旧位置

**调查日期：** 2026-09-27
**修复落地：** 本日，`RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/StatefulOutlineView.swift` 覆写
`delegate`，每次 delegate 变化后关掉行高估算；开关来自 UIFoundation 0.37.0（`AppleInternal` trait 下的
`NSTableView.box.estimatesRowHeights`），UIFoundation 下限同批抬到 0.37.0。回归测试 `StatefulOutlineViewRowGeometryTests`
**所属分支：** `next`（main 仍钉 UIFoundation 0.15.x，用不上这个开关）
**Severity：** Major —— 列表内容画错：两行画在同一个位置、文字叠在一起；不丢数据，但看到的对象名不可信
**触发场景：** 用户反馈 ——「有个很严重的UI bug，经常会在RuntimeObjectList这里看到错位……我在发现这个之前用了
jump to swift implementation，我之前在筛选完也会碰到这个问题，不能100%复现」。截图里 `AppKit._NSValueRepresentable`
与 `AppKit._SelfOrRawValueInitializable` 两行画在同一个位置

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 对象列表（按种类分组）滚到靠后位置之后，筛选、整表重载或展开一个嵌套类型，再一滚动，就有两行画在同一个位置。是否出现取决于列表停在哪、上方有多少行从没显示过，所以看起来随机 |
| **影响范围** | 侧栏对象列表（`SidebarRuntimeObjectViewController`，按种类分组时）。三个条件缺一不可：行高不一致（source list 样式下分组行上方的间距就够了）、列表里有可展开条目（嵌套类型）、在上方大部分行没显示过的靠后位置发生重载或展开 |
| **根因** | AppKit 的私有行高估算：行高不一致的 view-based 表格对没测量过的行按估算高度排布，边测边修正估算；修正时已经摆好的行视图不会被挪回去。`-[NSOutlineView setDelegate:]` 每次 delegate 变化都会把估算重新打开，而 RxCocoa 的 delegate 代理会自己重设 delegate |
| **系统版本** | 15.5（24F74）、26.6.2（25G83）、27.0（26A428）用同一个复现程序实测，行为与错位数都一致；私有开关在 14.7 到 26.3 的 cache 里都在 |
| **Status** | **Fixed** —— `StatefulOutlineView` 在每次 delegate 变化后关掉估算 |

---

## 根因

地址来自 AppKit 27.0（26A428）的反编译，均已对照汇编。完整的逆向记录在 UIFoundation 的
`Researchs/AppKit-NSTableView-RowHeightEstimation-Internals.md`。

### 估算从哪里来

- 表格的行几何存在 `NSTableRowHeightData` 里：没算过真实高度的行，按 `_estimatedRowHeight` 排布；算过的记进
  `_cachedRows`。是否估算由它的 `_automaticallyEstimatesRowHeights` 位（`+0x48` 字节的 `0x10`）决定，读写入口是
  `-[NSTableView _estimatesRowHeights]`（0x185B42F08）与 `-_setEstimatesRowHeights:`（0x185B42F30）。
- **谁打开它：** `-[NSOutlineView setDelegate:]` 在 delegate 真正变化时以 `_setEstimatesRowHeights:YES` 收尾
  （0x184F752D8 尾调用）。AppKit 里没有别的地方打开或关闭它。
- **什么时候批准：** 应用配置 `NSTableViewCanEstimateRowHeights` 不是 `NO`（默认对所有 App 都是 `YES`）、表格是
  view-based、且行高可能不一致（`-_supportsVariableHeightRows`，0x184FA3AD0）。对象列表的 delegate 经 RxAppKit
  的 sections 适配器实现了 `outlineView(_:isGroupItem:)`，又是 source list 样式，满足第一条分支，所以一设 delegate
  就开始估算。
- **为什么绑定后关一次不够：** RxCocoa 的 `DelegateProxy` 在装 forward delegate 时会 `reset()` —— 先把 delegate 设成
  `nil` 再设回代理自己，好让 AppKit 重新查一遍 `respondsToSelector:`。侧栏的 `rx.setDelegate(self)` 就会走到这里。
  每一次重设都会让 AppKit 再打开估算。

### 估算为什么会叠行（实测）

- **行高确实不一致。** source list 样式、`rowHeight` 24：普通行 24 pt，分组行 19 pt，除第一个外每个分组行上方还有
  13 pt 间距，不属于任何行的 rect。
- **估算会在中途变。** `rect(ofRow:)` 对没测量过的行返回估算位置，而且这个答案会随其它行被测量而移动：1,192 行的
  列表里连续两次查第 700 行，一次 16811.32、一次 16867.54，中间只查过别的行。
- **叠行的过程。** 列表跳到靠后位置时（跳过去，而不是一路滚过去），上方大部分行从没被测量。这时 `reloadData()` 或
  展开一个条目，下一次布局先按估算摆好一部分可见行、再在中途修正估算，已经摆好的行视图不会被挪回去。此时它们彼此
  一致，看不出问题；再一滚动，按修正后位置摆进来的行就画在它们上面：两个行视图 y 几乎相同、标题不同。偏差就是估算
  误差，这次记录到的在 0.1 pt 到 72 pt 之间。
- **必须有可展开条目。** 同样的分组、同样的行数、没有任何带子项的条目时，开不开估算都从不错位（每 50 个、每 10 个、
  每 3 个条目带一个子项都会错位，一个都没有则从不错位）。对象列表总有嵌套类型，这个条件总成立。
- **和用户描述的两个场景对上。** 筛选时每次按键都会整表重载（`didChangeFiltering` → `reloadData()`）；跳转到远处的
  对象会展开它的上层类型、再把它滚到可见位置。两者都是「在靠后位置重载或展开」。

确定性的复现序列（复现程序里，列表加载完并布局之后执行），三个系统版本结果一致：

| 序列 | 估算开（修复前） | 估算关（修复后） |
|---|---|---|
| 滚到 y 20000 → `reloadData()` → 滚到 y 20100 | 叠行 | 正常 |
| 同上，每一步之后同步布局 | 叠行 | 正常 |
| 滚到 y 27800 → 展开那里的一个条目（带不带动画都一样）→ 往上滚 100 | 叠行 | 正常 |

随机会话（在筛选框里打字、清空、跳到远处的对象、整表重载、展开收起、滚动，每个会话 240 步）：估算开着时 7 个种子
全部出现错位；每次 delegate 变化后关掉估算，7 个里 6 个干净，剩下一个见「已知限制」。

### 试过但放弃的办法

| 办法 | 结果 |
|---|---|
| `floatsGroupRows = false` | 只挡住重载那条路径，挡不住展开 |
| 每次结构变化后把每一行的 `rect(ofRow:)` 都查一遍 | 挡住大部分路径；但表格在 `reloadData()` 里已经摆过行时，这一查引发的修正反而**制造**错位（键盘把选中移到末行后重载时出现） |
| 重载后 `noteHeightOfRows(withIndexesChanged:)`、`tile()`、`layoutSubtreeIfNeeded()` | 没有作用 |
| delegate 实现 heightOfRow、所有行返回同一高度 | 没有作用：分组行上方的 13 pt 间距还在，行高仍不一致 |
| 应用级默认值 `NSTableViewCanEstimateRowHeights = NO` | 有效，但对进程里**所有**表格生效，且第一次读取后缓存到进程结束 |

---

## 修复

- **`StatefulOutlineView` 覆写 `delegate`，在 `didSet` 里 `box.estimatesRowHeights = false`。** 开关的封装放在
  UIFoundation：`AppleInternal` trait 下的 `NSTableView.box.estimatesRowHeights`，两个私有 selector 都存在才读写，
  否则读回 `nil`、赋值什么也不做 —— 哪天 AppKit 去掉这对方法，丢的是这个修复，不是崩溃。决策记录见 UIFoundation 的
  提案 0026（`Documentations/Evolutions/0026-table-view-row-height-estimation.md`），用法与契约见它的指南
  `Documentations/TableViewRowHeightEstimation.md`。
- **为什么放在 delegate 的 setter 里。** AppKit 在 `setDelegate:` 里打开估算，这里在同一次调用返回之前关掉，中间没有
  任何行按估算摆放。这个时机是必需的，不是顺手：切换开关只丢弃行几何，**既不 reload、也不挪动已经显示的行视图**。
  实测在估算摆好的行已经显示时关掉估算，可见的 27 行全部错位 56 pt，布局一次、`noteHeightOfRows` 都不恢复，
  `tile()` 反而开始叠行，只有 `reloadData()` 能摆正。放在 setter 里，估算从来不会在有行显示时处于打开状态。
- **代价。** 关掉估算后每次重载都要算一遍全部行高：1.4 万行的列表，`reloadData()` 加布局 27–34 ms，估算时是
  22–32 ms；1,192 行测不出差别。delegate 重设（先 `nil` 再设回，与 RxCocoa 的 `reset()` 相同）加布局，开不开这个
  修复都在 13–60 ms 之间，没有可测差别。
- **覆盖范围。** 侧栏的对象列表和镜像列表都用 `StatefulOutlineView`，一起生效。镜像列表没有分组行、也不自定义行高，
  所有行一样高，估算与真实行高一致，按上面的机制不会错位（没有单独测）；关掉估算对它只是重载时多算一遍行高。
- **展开 / 收起动画保留**（用户决定：「动画先保留」）。

### 已知限制

关掉估算后，曾在一段有另一个复现程序同时运行的时间里，连续 4 次观察到：带动画地收起一个条目后，下方的分组行停在
比 `rect(ofRow:)` 低 24 pt 的位置，之后再滚动就有一行画在它上面。此后相同条件下重跑 50 余次（包括与另一个复现程序
并行、在动画期间卡住主线程）都没有再出现；不带动画的收起、以及估算开着时，从未出现过。记为与时序相关、未确认。
遇到时可以给 `expandItem` / `collapseItem` 包一层零时长的 `NSAnimationContext`：在出现过的那几次里都能避开。

---

## 横向排查

找的是同一模式：会估算行高（行高不一致）、有可展开条目、列表长到能停在「靠后」位置的 `NSOutlineView`。

| 列表 | 判断 | 处理 |
|---|---|---|
| 侧栏对象列表、侧栏镜像列表（`StatefulOutlineView`） | 对象列表就是本问题；镜像列表同类 | 本次修复覆盖 |
| 后台索引弹窗（`BackgroundIndexingPopoverViewController`，`OutlineView`，`usesAutomaticRowHeights`，可展开，最多几百行） | 用同形状的列表实测（506 行，三种行高，active 全部展开、history 的 batch 折叠，高 320 pt）：靠后位置重载 18 处、展开 history batch 20 处、折叠 active batch 7 处，估算开着也全部正常 | 不改 |
| 特化面板（`SpecializationViewController`，source list 的 `OutlineView`） | 只列一个类型的泛型参数，几行，停不到「靠后」 | 不改 |
| 批量导出的镜像选择、类型选择器、Inspector 的导航列表（都是 `NSTableView`） | 没有可展开条目。依据是上面的对照：同形状的分组列表去掉所有子项后，估算开着也从不错位；普通表格本身没有单独测 | 不改 |

---

## 验证

- **回归测试** `StatefulOutlineViewRowGeometryTests`（`RuntimeViewerApplicationTests`）。夹具与对象列表同构：
  `StatefulOutlineView`、source list 样式、`rowHeight` 24，经 RxAppKit 的 sections 适配器绑定，之后
  `rx.setDelegate` 让代理重设 delegate（与侧栏相同）；9 个分组共 1,192 行，从第三组起每 10 个节点带 4 个嵌套类型。
  - 「a reload far down the list draws no row over another」：在 y 17000 到 27000 之间每隔 500 滚过去、重新发布同一份
    sections（适配器以 `reloadData()` 回应，和每次筛选按键一样）、再滚 100，收集叠在一起的行对。修复前失败
    （9 对，例如 `Type 1.139 / Type 1.138`），修复后通过。
  - 「expanding a nested type right after a jump far down the list draws no row over another」：y 26500、27000、
    27500、28000 四个位置，每个位置一个新列表：滚过去、展开屏幕上一个带嵌套类型的节点、往上滚 100。修复前四个全部
    失败（各 1 对，例如 `Type 5.11 / Type 5.12`），修复后通过。每个位置都用新列表，是因为在同一个列表上连续扫描时，
    前面的步骤会让后面的位置都不再出错（实测：最初的扫描版本在修复前也通过）。这四个位置都在列表最后 2,200 pt
    以内；临时去掉修复后实测，y 23000 到 26000 之间的五个位置即使是新列表也不出错，所以不取它们。
  - 同一次运行里 `StatefulOutlineViewAutosaveTests`、`StatefulOutlineViewTrackingLoopTests` 照常通过。
- **构建方式：** 与前几次一样用 `USING_LOCAL_DEPENDENCIES=1` 在独立的 scratch 目录里编。上面的红绿对照做在
  UIFoundation 发版之前，测试临时指向那份改动；提交的这一版在本地检出的 UIFoundation 0.37.0 上重新编译，
  `RuntimeViewerPackages` 全部测试通过。没有做按远程 pin 解析的构建。
- **复现程序**（一次性，不入库）：上面的确定性序列与随机会话，在 15.5、26.6.2、27.0 三台机器上用同一个二进制跑，
  修复前后的结论一致。
- 真实 App 里的确认由用户运行 Debug 构建完成。
