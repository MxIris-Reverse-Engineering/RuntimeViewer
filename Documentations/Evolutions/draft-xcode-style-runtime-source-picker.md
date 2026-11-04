# Draft - 工具栏的来源选择器做成 Xcode 的 scheme 选择器：自绘按钮加导航 popover，Xcode 26 样式下放进活动胶囊

- **状态**: In Progress
- **创建日期**: 2026-11-04
- **最后更新**: 2026-11-04
- **实现分支 / PR**: `feature/xcode-style-runtime-source-picker`（从 `next` 切出）

## 摘要

工具栏里切换运行时来源（Runtime Source）的是一个系统 `NSPopUpButton`，点开是菜单。本提案把它换成 Xcode scheme 选择器的样子：按钮自己画（图标加名字，悬停、按下时有高亮），点开的是 AppKitPlus 的 `NSNavigationPopoverController`——顶上一个过滤框，下面是按主机分节的来源列表，底部一组固定的命令，即 Xcode 点 scheme 时弹出的那种 popover。位置照两版 Xcode：Xcode 26 的样式下，选择器放进工具栏中间活动胶囊的左侧，胶囊外那个独立的选择器去掉；Xcode 27 的样式下仍是工具栏正中的独立项。画法、尺寸与行为逆向 Xcode 26.6 与 27.2 后照搬。

## 方案

### Xcode 的做法

逆向自 Xcode 26.6（17F113）与 27.2（27B52），完整规格与地址见资料卷：`/Volumes/RE/Xcode/26.6/README.md` 的「Scheme picker in the toolbar activity view」，`/Volumes/RE/Xcode/27.2-27B52/README.md` 的「Scheme picker in the middle of the toolbar」与「The scheme picker's popover」。要点如下。

- **选择器本身**：两版都是一个 `DVTPathControl`，一个组件就是图标加名字，鼠标按下就同步弹出 popover。组件被挤窄时标题不加省略号，只裁掉，最后 10 点渐隐。悬停、popover 打开期间画同一种圆角高亮：整个组件那么宽，圆角为高的一半，填充是黑（浅色外观）或白（深色外观）的 5%。两版的差别：
  - Xcode 26 的胶囊里：11 点字，图标 16×16，组件宽 = 标题宽 + 41（左 6、图标、间距 4、右 15），高亮 24 点高；悬停时右侧多一个 8 点的 `chevron.down`。
  - Xcode 27 的正中：大号控件的系统字体（推断 13 点），位图图标 18×18，组件宽 = 6 + 图标 + 4 + 标题 + 6，高亮 28 点高，没有箭头。外层视图高 28，宽在 87 与「组件宽 + 10」之间，选择器左右各内缩 4。
- **Xcode 26 胶囊里的布局**：选择器在 x = 6（旧外观 0），状态文字右对齐。文字可用宽度要先给选择器留出 `max(56, min(选择器想要的宽度, 胶囊宽 × 0.2))`；文字没用完的再全给选择器，最多给到它想要的宽度。同一个活动期间，选择器被挤窄后不再变宽；活动换了、胶囊宽度变了、选中的来源变了才恢复。悬停在被挤窄的选择器上时，它在 0.2 秒内展开到想要的宽度，文字随之重新截断、0.5 秒滑开；离开 0.5 秒后收回。popover 打开期间选择器的位置与宽度冻结。
- **popover**：placeholder 为 Filter，过滤框用过滤图标，不加动画，从组件下方弹出；随内容变高变低、保持顶边。行高 24。每行是自定义视图：勾（SF Symbol `checkmark`，semibold、small，12×12，没勾时也占位）在最左，图标 16×16 在 x = 14，13 点标题从 x = 36 起、尾部截断，整行从行边内缩 25 点；过滤时匹配的字符加粗。宽度取「标题宽 + 36」的最大值，封顶 366，popover 再加 50 点、至少 215。底部命令是控制器的 footer，没有图标和快捷键。Xcode 的过滤是模糊的子序列匹配，按分数裁掉弱的结果，保持各节原顺序；过滤时 footer 仍在。

### 要做的

1. **选择器控件**：`RuntimeViewerUI` 新增一个自绘的 `NSControl`，`RuntimeSourcePicker`。
   - 图标加名字；悬停与 popover 打开期间的高亮照 Xcode 的路径组件画。按下没有单独的样子，Xcode 也没有。
   - 鼠标按下就弹出，所以按住拖进 popover、松开即选也能用。
   - 无障碍上报为弹出按钮。断开时照旧显示「<名字> (Disconnected)」。
2. **popover**：用 `NSNavigationPopoverController`（AppKitPlus 0.18.0 起提供）。
   - 列表按主机分节，节头是主机名，与现在的菜单一样。每行一个来源，用照 `ActivityViewPopoverTableCellView` 做的自定义行（勾、图标、名字），当前来源带勾。当前来源断开时，列表顶上照旧放一行灰掉的它。
   - 底部固定两项：Open File…，以及窗口在离线引擎上时的 Dependency Cache。后者选中后推入下一层，列出可选的 cache（当前的带勾）与 Manage in Settings…，过滤框左侧换成返回钮。
   - 过滤由 RV 自己做（实现 `filterStringDidChange:`）：不分大小写的连续子串匹配，按项目规则不跟随系统语言——控制器自带的过滤用 `localizedCaseInsensitiveContains`，土耳其语下 `uiview` 匹配不到 `UIView`。匹配的字符照 Xcode 加粗。一节里有匹配的行，节头就留着。过滤期间底部命令隐去：AppKitPlus 的 `filteredItems` 不带 footer。
   - 选中来源、Open File…、选中 cache 都接到现有路径上：`MainViewModel` 的 `switchSource` 与 `dependencyCacheSelected`，以及 `NSDocumentController` 的打开面板。
3. **两种样式下的位置**：
   - Xcode 26 的样式：胶囊左侧放选择器，宽度规则、悬停展开、文字右对齐都照 Xcode。点在选择器上弹列表，点在胶囊别处照旧打开 Report 导航。工具栏右侧不再有独立的选择器。
   - Xcode 27 的样式：正中那一项的视图换成选择器，最小、最大宽度照 `IDESchemePickerToolbarView`。
   - 两种样式各用一个选择器实例，与两个标题项的做法相同。两个都绑同一份状态，点哪个就从哪个弹出。
4. **代码放在哪**：
   - `RuntimeViewerUI`：`RuntimeSourcePicker`；Xcode 27 样式的正中项视图 `RuntimeSourcePickerToolbarView`；列表的行 `RuntimeSourcePopoverCellView`；`ToolbarActivityView(showsSourcePicker:)` 管胶囊里的选择器与它的宽度规则。
   - `RuntimeViewerApplication`：列表内容 `RuntimeSourcePickerContent` 与弹出列表的 `RuntimeSourcePopoverAdapter`。
   - App：`MainViewModel` 输出 `runtimeSourcePickerContent`，`MainToolbarController.runtimeSourcePickers` 交出两个选择器，`MainWindowController` 绑定它们并接上适配器。原来只为弹出菜单服务的 `RuntimeSource+.swift` 删掉。

### 落地步骤

每一步单独构建、测试通过后提交；构建与测试在 Ultra 上跑。

1. **逆向**（已完成）：26.6 胶囊里选择器的位置、宽度、悬停与动画；DVTKit 的路径组件在工具栏里的画法；27.2 `IDESchemePickerToolbarView` 的尺寸与工具栏项设置；popover 的条目、footer、宽度与行视图版式。规格写进资料卷 Xcode 26.6 与 27.2（27B52）的 README（两台 Mac 上的副本一致），地址与可信度的标法同前一份提案。
2. **选择器控件**（已完成），配测试：想要的宽度、标题的位置与渐隐、高亮、正中项视图的约束、无障碍。
3. **popover**（已完成）：条目、过滤、选中与推入下一层，配测试（含土耳其语下的过滤）。
4. **接进两种样式**（已完成）：工具栏项、胶囊左侧的选择器与它的宽度规则、点击分区，配测试；删掉 `NSPopUpButton` 那一套。
5. **收尾**（已完成）：
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

### 后续项

- **过滤时保留底部命令**：给 AppKitPlus 的 `NSNavigationPopoverController` 加一个连同 footer 一起设置过滤结果的接口（对应 Xcode 的 `filteredContent`），发版后 RV 改用它。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-04 | Created as Draft | 用户看过工具栏活动显示的实现后，要求把来源选择器换成自绘按钮加 AppKitPlus 的导航 popover，并在 Xcode 26 的样式下照 Xcode 放进活动胶囊 |
| 2026-11-04 | 另起一份提案，不并进 `draft-xcode-activity-progress` | 那份提案只管进度、明确不做 scheme 选择器；这次是新控件加新的弹出列表，要单独逆向 |
| 2026-11-04 | 不做 Recent 一节，列表只按主机分节 | 用户在批准时选定，与草稿的假设一致 |
| 2026-11-04 | 用户批准，开始实现 | |
| 2026-11-04 | 第 1 步完成：规格写进资料卷两版 Xcode 的 README | 27.2 的 IDEKit 与 DVTKit 导出和 IDA 库在本机重新生成（与 Ultra 上的 IDEKit 是同一镜像）：两台 Mac 之间的连接太慢，拷不动数据库 |
| 2026-11-04 | 两种样式各照各的画法：Xcode 26 的胶囊里 11 点字、24 点高亮、悬停出下箭头；Xcode 27 的正中大号字、28 点高亮、没有箭头 | 逆向表明两版 Xcode 的选择器配置与 DVTKit 画法本就不同，照搬各自的 |
| 2026-11-04 | 过滤用不分大小写的连续子串匹配，匹配的字符加粗；不照搬 Xcode 的模糊匹配 | Xcode 用 CodeCompletionFoundation 做子序列匹配并按分数裁掉弱结果，裁剪的阈值只能从开源的 CompletionScoring 推测。来源列表通常只有十几行，子串匹配好预期，也与 RV 其他选择器一致 |
| 2026-11-04 | 过滤期间底部命令隐去 | AppKitPlus 公开的 `filteredItems` 不带 footer，Xcode 则保留；要保留得给 AppKitPlus 加接口，超出本提案，列为后续项 |
| 2026-11-04 | 每节都有主机名节头，与现在的菜单相同；Xcode 只在有 Recent 时才出节头 | 用户选定按主机分节，主机名本身就是有用的信息 |
| 2026-11-04 | popover 设 push 导航；Xcode 27.2 不设层级样式 | Dependency Cache 要推入下一层列出 cache，Xcode 的 scheme 列表只有一层 |
| 2026-11-04 | Xcode 27 样式的工具栏项仍是普通的 `NSToolbarItem`，用 `centeredItemIdentifiers` 居中 | Xcode 把它包进只有一项的 `NSToolbarItemGroup`、用旧的单数 `centeredItemIdentifier`；两者看起来应当一样（推断），现有的居中写法不改 |
| 2026-11-04 | 图标一律按比例缩进图标框：胶囊里 16 点，正中 18 点 | Xcode 27 让符号图标保持自身大小、只把位图画成 18×18；RV 的来源图标有位图也有设备符号，统一画法免得两种图标大小不一 |
| 2026-11-04 | 选择器的「激活」外观跟着窗口是不是 key window 走 | 与标题项一致；Xcode 用它自己的激活外观标志，判据没有逆向 |
| 2026-11-04 | popover 打开时再按一下选择器就关掉它，不重新打开 | 照弹出按钮的习惯；Xcode 在这时是关掉还是重开，逆向定不下，要录屏才知道 |
| 2026-11-04 | 两个包的锁文件把 AppKitPlus 从 0.18.0 抬到 0.20.0 | 下限抬到 0.19.0 后 0.18.0 不再合格；取 App 的 Debug 与 Distribution workspace 已钉的 0.20.0，两边用同一版 |
| 2026-11-04 | 删掉 `RuntimeSource+.swift` | 里面是给原来那个弹出按钮填菜单的辅助代码，本来就没人调用，按钮去掉后更用不上 |
| 2026-11-04 | 「按下即发 action」不写单元测试 | 选择器经 `NSApp` 派发 action，`swift test` 进程里没有 `NSApp`；仓库里其他控件的测试也绕开这一层 |
| 2026-11-04 | 文档：`RuntimeViewerUsingAppKit/AGENTS.md` 那一节改名为「The Toolbar's Activity Display and Runtime Source Picker」并补上选择器与列表，根 `AGENTS.md` 的依赖下限改为 AppKitPlus 0.19.0，术语表新增「来源选择器」；离线模式使用指南、设置页 Offline Files 的说明和几处代码注释里的「引擎菜单」改为来源选择器的列表；不另写使用指南与实现说明 | 选择器没有调用方要遵守的契约；宽度规则写在 `ToolbarActivityView` 的文档注释里、由测试守着，逆向规格在资料卷，不必另写一份 |
| 2026-11-04 | 实现完成，待用户看过后收尾 | 验证都在 Ultra（macOS 27.2，Xcode 27.2）上跑。`RuntimeViewerPackages` 从空构建目录编译通过；全量 780 个测试中 4 个失败：两个是测试里拿 CGFloat 跟整数算式比较的写法问题（已改），`FindCrossReferenceTests` 的 Call Hierarchy 满载超时是 `next` 上已有的，`ViewModelBaseTests` 的 100 毫秒计时满载时抖动；相关的 10 组单独重跑，80 个全部通过。App 用 Debug workspace（Debug-arm64e，不签名）编译通过，`RuntimeViewerCommandLine` 编译通过，各处锁文件没被改写。没做界面验证：两种样式下的样子、悬停展开的动画、弹出列表的位置与过滤，留给用户目视 |
