# Draft - 工具栏的来源选择器做成 Xcode 的 scheme 选择器：自绘按钮加导航 popover，Xcode 26 样式下放进活动胶囊

- **状态**: Accepted
- **创建日期**: 2026-11-04
- **最后更新**: 2026-11-04
- **实现分支 / PR**: `feature/xcode-style-runtime-source-picker`（从 `next` 切出）

## 摘要

工具栏里切换运行时来源（Runtime Source）的是一个系统 `NSPopUpButton`，点开是菜单。本提案把它换成 Xcode scheme 选择器的样子：按钮自己画（图标加名字，悬停、按下时有高亮），点开的是 AppKitPlus 的 `NSNavigationPopoverController`——顶上一个过滤框，下面是按主机分节的来源列表，底部一组固定的命令，即 Xcode 点 scheme 时弹出的那种 popover。位置照两版 Xcode：Xcode 26 的样式下，选择器放进工具栏中间活动胶囊的左侧，胶囊外那个独立的选择器去掉；Xcode 27 的样式下仍是工具栏正中的独立项。画法、尺寸与行为逆向 Xcode 26.6 与 27.2 后照搬。

## 方案

### Xcode 的做法

下面是从 IDEKit 的头文件与 Swift 接口读出的结构，行为细节在落地第 1 步逆向确认。

- **Xcode 26**：活动胶囊 `ActivityView` 左侧就是 scheme 选择器（一个 `DVTPathControl`）。选择器在时，状态文字右对齐（已逆向，见资料卷 26.6 的「Toolbar activity view」一节）。选择器的宽度分几种情形（`SchemePickerInteractionBasedWidth`：锁定、悬停、常规的首选宽度与两个最小宽度、不显示），悬停时展开（`expandHoveredSchemePicker(to:)`、`PathControlAnimation`），离开后延时收回（`delayedSchemePickerHoverEnded`），另有一个按活动记住的夹紧宽度（`perActivityClampedSchemePickerWidth`）。
- **Xcode 27**：选择器挪到工具栏正中（`IDESchemePickerToolbarView`，一个 `DVTPathControl` 加最小、最大宽度约束），活动搬去标题区。
- **popover**：两版都由 `SchemePickerViewController` 弹出。条目是带 `isSelected` 的 `SchemePickerPopoverItem`，每行用自定义的 `ActivityViewPopoverTableCellView` 画：勾、图标、标题，过滤时标出匹配的部分。过滤由选择器自己做。列表分 Recent 与 All 两节，底部是 Edit Scheme… 等命令与 Clear Recent。

### 要做的

1. **选择器控件**：`RuntimeViewerUI` 新增一个自绘的 `NSControl`（暂名 `RuntimeSourcePicker`）。
   - 图标加名字；悬停、按下、popover 打开期间的高亮照 Xcode 的路径组件画。
   - 鼠标按下就弹出，所以按住拖进 popover、松开即选也能用。
   - 无障碍上报为弹出按钮。断开时照旧显示「<名字> (Disconnected)」。
2. **popover**：用 `NSNavigationPopoverController`（AppKitPlus 0.18.0 起提供）。
   - 列表按主机分节，节头是主机名，与现在的菜单一样。每行一个来源，用照 `ActivityViewPopoverTableCellView` 做的自定义行（勾、图标、名字），当前来源带勾。当前来源断开时，列表顶上照旧放一行灰掉的它。
   - 底部固定两项：Open File…，以及窗口在离线引擎上时的 Dependency Cache。后者选中后推入下一层，列出可选的 cache（当前的带勾）与 Manage in Settings…，过滤框左侧换成返回钮。
   - 过滤由 RV 自己做（实现 `filterStringDidChange:`），按项目规则不跟随系统语言：控制器自带的过滤用 `localizedCaseInsensitiveContains`，土耳其语下 `uiview` 匹配不到 `UIView`。一节里有匹配的行，节头就留着。
   - 选中来源、Open File…、选中 cache 都接到现有路径上：`MainViewModel` 的 `switchSource` 与 `dependencyCacheSelected`，以及 `NSDocumentController` 的打开面板。
3. **两种样式下的位置**：
   - Xcode 26 的样式：胶囊左侧放选择器，宽度规则、悬停展开、文字右对齐都照 Xcode。点在选择器上弹列表，点在胶囊别处照旧打开 Report 导航。工具栏右侧不再有独立的选择器。
   - Xcode 27 的样式：正中那一项的视图换成选择器，最小、最大宽度照 `IDESchemePickerToolbarView`。
   - 两种样式各用一个选择器实例，与两个标题项的做法相同。两个都绑同一份状态，点哪个就从哪个弹出。

### 落地步骤

每一步单独构建、测试通过后提交；构建与测试在 Ultra 上跑。

1. **逆向**：上节「行为细节」的几项——26.6 胶囊里选择器的位置、宽度、悬停与动画；DVTKit 的路径组件在工具栏里的画法；27.2 `IDESchemePickerToolbarView` 的尺寸与工具栏项设置；popover 的条目、footer、宽度与行视图版式。规格写进资料卷 Xcode 26.6 与 27.2（27B52）的 README，地址与可信度的标法同前一份提案。
2. **选择器控件**，配测试：布局、按下即发 action、悬停状态、无障碍。
3. **popover**：条目、过滤、选中与推入下一层，配测试（含土耳其语下的过滤）。
4. **接进两种样式**：工具栏项、胶囊左侧的选择器与它的宽度规则、点击分区，配测试；删掉 `NSPopUpButton` 那一套（`SwitchSourceToolbarItem.popUpButton`、`restoreEngineMenuSelection()` 等）。
5. **收尾**：
   - AppKitPlus 的下限从 0.18.0 抬到 0.19.0：0.19.0 修了显示过 `NSIconView` 的窗口永不释放的泄漏，导航 popover 正是这种窗口。同步根 `AGENTS.md` 的依赖下限一段。
   - 改写 `RuntimeViewerUsingAppKit/AGENTS.md` 的「The Toolbar's Activity Display」一节。
   - 在 [`draft-xcode-activity-progress`](draft-xcode-activity-progress.md) 的决策日志记一行：Xcode 26 样式下选择器的位置改由本提案决定。
   - 用 Debug workspace 完整构建 App，跑各包测试。

### 没有询问就采用的假设

- **不做 Recent 一节**：RV 的来源不多，又已按主机分节；Xcode 的 Recent 是给几十个 scheme 准备的。
- **不加新命令**：Open File… 从「打开过离线文件才出现」改为总在底部；Attach to Process 仍只在工具栏按钮上。
- **popover 当菜单用**：和现在的 `NSMenu` 一样，由 `MainWindowController` 在视图层弹出，不走路由，也不另建 ViewModel；列表内容由 `MainViewModel` 的输出算出，选择回到它的 `Input`。
- **macOS 15 上同样换**，用 Xcode 26 在旧外观下的尺寸。
- **目视验收由用户来做**。逆向定不下的动画（悬停展开的曲线与时长等）需要时请用户录一段 Xcode 26 与 27 的操作过程，以录屏为准。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-04 | Created as Draft | 用户看过工具栏活动显示的实现后，要求把来源选择器换成自绘按钮加 AppKitPlus 的导航 popover，并在 Xcode 26 的样式下照 Xcode 放进活动胶囊 |
| 2026-11-04 | 另起一份提案，不并进 `draft-xcode-activity-progress` | 那份提案只管进度、明确不做 scheme 选择器；这次是新控件加新的弹出列表，要单独逆向 |
| 2026-11-04 | 不做 Recent 一节，列表只按主机分节 | 用户在批准时选定，与草稿的假设一致 |
| 2026-11-04 | 用户批准，开始实现 | |
