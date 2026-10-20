# 2026-10-20 启动后侧栏分隔线拖不动：镜像目录页的分隔线被当成竖线，把侧栏钉在最小宽度

**调查日期：** 2026-10-20
**修复落地：** 本日，`next`
**Severity：** Medium —— 启动后侧栏宽度拖不动，一直停在最小值；切到别的 tab 再切回来才恢复
**触发场景：** 用户反馈 ——「刚启动的第一个 navigator 为啥拖不动，就是展示 image 那个，别的 navigator 拖动没问题，切到别的再切回来第一个也可以拖了」。「拖」指侧栏与内容区之间的分隔线。macOS 26.7，Debug 构建

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 启动后侧栏停在镜像目录页时，拖侧栏与内容区之间的分隔线，宽度不变，侧栏停在最小宽度 300。切到书签、Find 或 Report 页再切回来，就能拖了 |
| **影响范围** | 启动时随窗口一起装进去的那一页：镜像目录页（`SidebarRootViewController`）底部的 `bottomSeparatorView`。同一写法——左右钉满、`height == 1` 的 `NSBox` 分隔线——还有书签页（同一个基类）、对象列表页、Report 页各 1 条，Find 页 3 条，筛选范围弹窗 2 条；实测只有启动时就在窗口里的那一页中招 |
| **根因** | 窗口恢复时，AppKitPlus 的导航栏在推入侧栏根页面的导航项时调了 `layoutSubtreeIfNeeded`，窗口在分栏还没给侧栏宽度时先跑了一轮约束更新。分隔线此时 bounds 为 0，AppKit 按布局引擎里它的宽 0、高 1 判它为竖线，装上 `NSBox.width == 1 Hug:750 CompressionResistance:750` 的固有尺寸约束；之后没有任何东西让它失效，这条 750 的抱紧压过了拖动分隔线 |
| **不是什么** | 不是 `NavigatorScrollViewLayout`：撤销它给这一页做的 scroll pocket 登记，照样拖不动。也不是因为分隔线被隐藏：取消隐藏并重绘，照样拖不动 |
| **系统版本** | macOS 26.7 实测。macOS 26 之前的堆叠布局、macOS 27 都没有在真机上验证 |
| **Status** | **Fixed** —— 新增 `HorizontalSeparatorView`（RuntimeViewerUI），不报告固有宽度；macOS 26 起这些分隔线不再加进视图层级 |

---

## 复现与定位

全部在用户本机的 Debug 产物里做（`dev.JH.RuntimeViewer`，CrossReferences worktree 10-19 16:39 的 Tuist 构建，侧栏代码与 `next` 相同），用 `lldb --batch -p` 挂上进程求值，不动真实鼠标；每次启动前还原备份的偏好、`settings.json` 与 AppStorage，结束后核对未变。

1. **复现回路。** 启动后对分栏调 `setPosition(408, ofDividerAt: 0)`：侧栏 300 → 仍是 300。切到书签页后同样的调用：300 → 400；切回镜像目录页再调：→ 350。与用户描述一致。
2. **拦路约束的优先级。** 给侧栏的 arranged view 临时加一条 `width == 408`：优先级 490、500、510、749 时被压住，751、999 时生效——拦路的是一条 750 的约束。拖动分隔线用的优先级低于 750，所以拖不动。
3. **它不在常规的地方。** 侧栏、内容区、检查器三个面板与整个窗口里，横向、优先级在 700 到 999 之间的显式约束只有 `NSTabView.width >= 0 @750`（不限制变宽，停掉它也不解锁）；`NSSplitView` 自己的约束只有 1000、261、250 三档；抱紧优先级 ≥ 750 的固有尺寸只有加载圈 `NSProgressIndicator`（只居中，降它的优先级也不解锁）；用 751 强行拉宽后，没有任何视图新违反自己的固有尺寸。
4. **从布局引擎里找到它。** `window.perform("_layoutEngine")` 取出 NSISEngine，`value(forKey: "constraints")` 列出全部 1086 条约束。`NSContentSizeLayoutConstraint` 的优先级不在 `priority` 属性里，只写在描述的 `Hug:` / `CompressionResistance:` 里；按这个过滤，侧栏里只有一条：`NSBox:0x….width == 1 Hug:750 CompressionResistance:750`，就是 `bottomSeparatorView`。而这个盒子此刻自己报告的固有尺寸是 `(-1, 1)`、横向抱紧 250——引擎里那条是旧的。
5. **确认就是它。** 只对这个盒子调 `invalidateIntrinsicContentSize()`，`setPosition(408)` 立刻生效（308 → 408）。
6. **排除。** 撤销 `NavigatorScrollViewLayout` 把 tab 切换器的栏登记为这一页顶部 scroll pocket 容器的那次登记，不解锁。锁住时把分隔线取消隐藏、排版并重绘，引擎里那条约束原样不动，仍不解锁。另一条分隔线（内容区与检查器之间）照常能挪，说明内容区没有被压到极限。
7. **别的页面。** 切到书签、Find、Report 页，它们的分隔线在引擎里都没有宽度方向的固有尺寸约束。

## 根因

AppKit 26.7（`/Volumes/DyldSharedCaches/macOS/26.7/`，cache UUID `f48d7ca66feb3c8794a0876fbd318dcd`，与本机运行中的一致），反编译均已对照汇编。

### 分隔线怎么判断横竖

`NSBox` 的固有尺寸交给它的 visual provider，分隔线的是 `NSBoxSeparatorVisualProvider`（Swift 写的）。`-[NSBoxSeparatorVisualProvider intrinsicContentSize]`（0x18501F334）与 `isFixedWidth`（0x18501F2BC）都先调同一个求朝向的函数（0x18501F0E0）：

- 盒子 bounds 的宽或高大于 5：高大于宽就是竖线，缓存起来；
- 两边都不大于 5（还没排过版时就是 0 × 0）：取布局引擎里这个盒子的 `nsli_widthVariable` / `nsli_heightVariable` 当前值（`valueForVariable:`），两者不等时，高不小于宽就是竖线，缓存起来；
- 否则用缓存值，从没缓存过就当横线。

竖线的固有尺寸是 `(1, -1)`，`isFixedWidth` 为真，于是 `-[NSBox _contentHuggingDefault_isUsuallyFixedWidth]` 让横向的默认抱紧优先级是 750。

**之后没有任何东西让它失效。** `-[NSBox setFrameSize:]`（0x184B21D30）只调 super 和 `_layoutContentViewIfLegacy`；`-[NSBox layout]`（0x184B23888）与 provider 的 `layout`（0x18501F5B4）只管分隔线自己的子视图；`updateConfiguration:` 只存配置，`customConfigurationDidChange` 是空函数。朝向本身是每次被问时现算的，所以盒子排版之后会如实报告横线，可引擎里那条固有尺寸约束只在视图失效固有尺寸、或重新进入窗口时才重建。

### 启动时谁先问了它

在 lldb 下启动 App，在缓存朝向的那条指令（0x18501F144）和比较引擎宽高处（0x18501F1D4）下自动继续的断点：这个盒子前三次被判时引擎里宽 0、高 1，判为竖线；之后宽 300，判为横线。第一次的调用栈（从下往上）：

```
NSDocument restoreDocumentWindowWithIdentifier:… → Document.makeWindowControllers → MainCoordinator.init
  → … SidebarNavigationController setViewControllers:animated:          （侧栏根页面）
  → AppKitPlus -[NSNavigationController _pushViewController:transition:]
  → -[NSNavigationBar _pushNavigationItem:animated:duration:]
  → -[NSBar _transitionToContainer:transition:duration:]
  → -[NSBar _updateTrailingViewWithItemContainer:]
  → -[NSView layoutSubtreeIfNeeded]
  → -[NSWindow updateConstraintsIfNeeded] → … → -[NSBox updateConstraints]
  → _updateContentSizeConstraints → -[NSBox intrinsicContentSize]
```

那一刻窗口与分栏还没按真实尺寸排过版，分隔线左右钉满的那一页在引擎里是 0 宽，`height == 1` 却已经生效。

### 为什么切一次 tab 就好，别的页没事

切走时 `NSTabView` 把这一页移出窗口，切回来再放进去，固有尺寸约束按当时的朝向（横线）重建。书签、Find、Report 页的视图在第一次被选中时才加载、装进已经排好版的窗口，它们的分隔线第一次被问时引擎里已经有侧栏宽度，判的就是横线。

### 时间线

- AppKitPlus 这段 `layoutSubtreeIfNeeded` 从 2026-08-17（`a1ed12b`，导航栈 0010）就在。
- 2026-10-15 的 `ec669315`（[0052](../Evolutions/0052-xcode-navigator-overlay-bars.md)）把四个页面的分隔线在 macOS 26 起隐藏起来；隐藏不是触发条件（见「复现与定位」第 6 条），只是让它在 macOS 26 上完全没有用处还留在布局里。
- 10-15 之前的构建是否也会这样锁住，手头没有旧构建，没有验证。

## 修复

- **`HorizontalSeparatorView`（`RuntimeViewerUI/AppKit/HorizontalSeparatorView.swift`）**：UIFoundation `Box` 的子类，`setup()` 里设 `boxType = .separator`，覆写 `intrinsicContentSize` 返回 `(noIntrinsicMetric, 1)`。不论 AppKit 把它判成什么朝向，引擎里都不会有宽度方向的固有尺寸约束；绘制仍走 AppKit 自己的分隔线，排版之后按 bounds 判为横线。
- **`HorizontalSeparatorView.makeForStackedNavigatorLayout()`**：macOS 26 起返回 `nil`，之前返回新类型。四个页面基类的 6 条分隔线都由它创建，macOS 26 起不加进视图层级、不建约束——那里列表从栏底下穿过，由边缘效果代替分隔线；隐藏的视图照样参与布局，所以不再「建了再隐藏」。对象列表页空列表提示的底部上限原本挂在分隔线顶上，macOS 26 起改挂在过滤栏顶上（低 1 点，`priority(.high)` 的 `≤` 约束，只在提示文字很长时起作用）。
- **筛选范围弹窗**的两条分隔线在所有系统上都显示，直接换成 `HorizontalSeparatorView()`。
- 规则写进 `RuntimeViewerUsingAppKit/AGENTS.md`：视图对照表加一行，并新增「Never lay a plain separator box across a pane」一段；「Navigator Pages Run Under Their Bars」一节里「从 macOS 26 隐藏分隔线」改为「不加进层级」。`RuntimeViewerPackages/Sources/AGENTS.md` 把这个覆写列为看似可删、实则不可删的行为之一。

没有采用的写法：

- **给普通 `NSBox` 显式设低横向抱紧优先级**：要看 AppKit 生成被误判的那条约束时用不用显式值。在运行中的 App 里设优先级会顺带重建约束（旧约束直接消失），没法单独验证；覆写固有尺寸则不依赖这一点。
- **启动后对分隔线调一次 `invalidateIntrinsicContentSize()`**：依赖时机，哪一页、哪一轮排版之后调都说不准。
- **换成不是 `NSBox` 的自绘细线**：会失去 AppKit 分隔线自己的绘制（颜色、外观、像素对齐）。

## 验证

- **回归测试** `HorizontalSeparatorViewTests`（`RuntimeViewerApplicationTests`，2 个用例）。夹具：屏幕外 1000 × 600 的窗口里一个分栏（侧栏最小 200、内容区最小 300，holding priority 261 / 250），侧栏里一页，页内一条左右钉满、高 1 的分隔线；这一页先以 0 宽排一次版（模拟启动时那一轮），再铺满侧栏；用 `setPosition(_:ofDividerAt:)` 挪分隔线。
  - 「a horizontal separator … leaves the divider free」：通过。变异检验：去掉 `intrinsicContentSize` 覆写后失败——内容区有 792 点，侧栏却停在 208（最小 200 加玻璃内边距 8）。
  - 「a plain separator box … holds the divider」：前提校验，断言普通 `NSBox` 在同样条件下锁住分隔线、对它 `invalidateIntrinsicContentSize()` 之后又能挪，证明夹具确实复现了这把锁、锁就来自这个盒子。AppKit 哪天不再这样误判，它会失败，提示上一个用例已经证明不了什么。
  - 夹具本身踩过一个坑：给窗口设 `contentViewController` 时，窗口取这个视图控制器的视图当前尺寸；视图还是 0 时窗口缩到两个面板的最小宽度（508 × 26），任何分隔线都挪不动，两个用例一个空过、一个误报失败。先给分栏视图设好 1000 × 600 再装进窗口。
  - 同一次运行里 `NavigatorScrollViewLayoutTests` 与 `TabSwitcherBarSafeAreaTests` 照常全过：3 个套件 17 个测试，原始退出码 0（JHs-Mac-Studio，macOS 26.7，Xcode 27.0 的 `swift build` / `swift test`）。
- **真实 App**：修复后用 `./TuistScript.sh build --configuration Debug`（agent 自己的 `TUIST_SCRIPT_ROOT`，Xcode 27.0）编出 App，按同一份备份状态启动，重跑「复现与定位」第 1 条的回路：启动后停在镜像目录页时，侧栏里一个 `NSBox` 都没有，引擎里也没有分隔线的宽度约束，`setPosition` 把侧栏从 308 拉到 408、再挪回 308 都照做。没有做人手拖动的目视验收。

## 另外观察到、与本文无关

修复后启动时侧栏仍是 308，没有恢复成保存的宽度（用户偏好里分栏自动保存的是 471.5）。修复前同样是 308，最初以为也是这把锁造成的；锁去掉之后照旧，所以是另一个问题，没有调查。

## 局限

- 回归测试测的是 RuntimeViewerUI 的 `HorizontalSeparatorView` 与照抄的层级，不是 App target 里的页面类：App 没有测试 target。「macOS 26 起不加分隔线」只在真实 App 里核对过。
- macOS 26 之前（堆叠布局，分隔线显示）没有在真机上验证。

## 同类

- 全工程的 `NSBox` 分隔线都已改走 `HorizontalSeparatorView`：`grep` 只剩它自己的 `boxType = .separator`。
- 同一类陷阱的识别方法：分栏某一侧拖不动、切换内容后又好了，先用 749 / 751 两档的探针约束确认拦路优先级，再从引擎的 `constraints` 里按 `Hug:` 过滤固有尺寸约束，和视图自己报告的 `intrinsicContentSize` 对照。
