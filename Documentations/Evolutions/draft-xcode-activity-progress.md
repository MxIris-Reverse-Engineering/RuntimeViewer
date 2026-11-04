# Draft - 工具栏照 Xcode 显示后台工作的进度：Xcode 26 式的中间胶囊与 Xcode 27 式的标题区进度环，可在设置里切换

- **状态**: In Progress
- **创建日期**: 2026-11-03
- **最后更新**: 2026-11-03
- **所属愿景**: 无
- **实现分支 / PR**: `feature/xcode-activity-progress`（从 `next` 切出）；UIFoundation 一侧是 `feature/toolbar-principal-item-width-ratio`，已作为 UIFoundation 提案 0034 随 `0.43.0` 发布

## 摘要

后台索引、Find 语料、交叉引用这三类后台工作，现在只能到侧栏的 Report 导航里看进度。本提案照 Xcode 的 Activity View 把进度放进工具栏，只做显示进度的部分，不做 scheme、运行目标和 issue 计数。两版 Xcode 的做法不同，各照一版：

- Xcode 26 的样式：工具栏正中一个胶囊，里面是状态文字和一个进度环。
- Xcode 27 的样式：进度挪到左边的标题区，画在图标位置，工具栏正中改放切换引擎的弹出按钮。活动结束时，进度环收拢成一个圆角方块，再淡出变回图标。

用哪种样式在设置 › General 里选，默认 Automatic 按系统：macOS 27 起用 Xcode 27 的样式，以前用 Xcode 26 的。两版的规格是逆向 Xcode 拿到的，不是照截图调的。

## 方案

### Xcode 的做法

完整规格与地址见本机资料卷：`/Volumes/RE/Xcode/26.6/README.md` 的「Toolbar activity view」一节（Xcode 26.6，17F113），以及 `/Volumes/RE/Xcode/27.2-27B52/README.md` 的「Activity progress in the window title」一节（Xcode 27.2，27B52）。要点如下。

**Xcode 26 的中间胶囊**（`IDEKit.ActivityView`）

- **宽度与位置**：工具栏宽的 40%，最小 160，最大 2000（优先级 450），用 `centeredItemIdentifier` 居中。40% 靠 AppKit 私有方法 `-[NSToolbar setPreferredPrincipalItemWidthRatio:]` 实现。
- **高度与背景**：macOS 26 上高 24，背景是工具栏自带的玻璃底板，Xcode 不画。macOS 15 上高 22，背景是一个禁用的 textured rounded 按钮。
- **状态文字**：11 pt、`labelColor`，由几段拼成，段间用 ` │ `（U+2502）分隔，结果词加粗，例如 `Build **Succeeded** │ Today at 19:33`；空闲时是 `NibKit: **Ready** │ Today at 19:33`。放不下时按各段的优先级整段丢掉，还放不下才尾部截断。没有 scheme 选择器时，文字左对齐。
- **进度环**（`DVTProgressRing`）：
  - 外形：16 pt 大小，在胶囊右缘内 12 处；线宽 2、半径 7，从 12 点钟方向起。
  - 颜色：轨道 `tertiaryLabelColor`，弧 `controlAccentColor`。
  - 动画：进度变化走 0.6 秒 easeOut；进度不确定时，半圈弧每秒转一圈；环的出现和消失是 0.5 秒淡入淡出。
- **多个活动**：一次只显示一个，其余体现为环里的计数，最多显示 9。挑选顺序是用户发起的优先，后台活动要跑满 4 秒才显示；当前活动至少显示 3 秒才换；界面每秒最多刷新一次。
- **完成**：文字原地换成结果，进度环 0.5 秒淡出。

**Xcode 27 的标题区**（`IDEActivityWindowTitleView`，SwiftUI）。中间的胶囊不再显示活动。

- **布局**：左边是 18×18 的图标槽，右边是文字列。第一行是工程名，13 pt 粗体；有活动时多出第二行活动文字，11 pt、等宽数字、中间截断，段间用 ` • `。
- **进度环**：20×20，画在图标槽里，取代图标。
  - 外形：线宽 20/7 ≈ 2.86，弧两端是圆头。
  - 颜色：轨道 `.fill.secondary`，弧为强调色。
  - 显示值是 0.05 + 完成度 × 0.77，满了才画满圈。
  - 动画：进度变化用 spring（response 0.5，damping 0.85）；不确定时 0.33 的弧每秒转一圈；进度倒退时整环多转一圈。
  - 两个以上活动时，环中间显示计数。
- **完成序列**：
  - 0 秒：弧走满，轨道淡出。
  - 0.35 秒：中间的洞合拢成实心的强调色圆盘，四角同时长出，成为圆角 5.2 pt 的连续圆角方块。
  - 0.45 秒：方块变透明，工程图标淡入。
  - 新活动开始时倒放回去。成功、失败、取消在环上看起来一样，只有文字不同。
- **挑选与节流**：与 Xcode 26 是同一套代码。

### 显示哪些活动

Report 导航里的三类后台工作，在一个 Engine 上每类算一个活动，对应 Xcode 的一个 activity report。

| 活动 | 进行中的文字 | 进度 | 完成后的文字 |
|---|---|---|---|
| 后台索引 | `Indexing │ 12 of 48 images` | 这一轮所有批次里已结束的镜像数 ÷ 镜像总数 | `Indexing **Succeeded** │ Today at 19:33`；有镜像失败时是 Failed，被取消时是 Canceled |
| Find 语料 | `Building Searchable Interfaces │ 3 of 10 images` | 这一轮已建好的镜像数（正在建的那个按对象进度计入）÷ 镜像总数 | `Searchable Interfaces **Built** │ …` |
| 交叉引用 | `Preparing Cross References │ 2 of 5 images` | 同上 | `Cross References **Prepared** │ …` |

- **一轮的起止**：这一类从无事可做变为有事可做时，一轮开始；回到无事可做时，这一轮结束，即活动完成。
- **在哪里算**：活动在 `RuntimeEngineBackgroundWork` 里每个 Engine 算一次，与 `isWorkInProgress` 并列，所以同一 Engine 的窗口看到的一样。挑选与节流每个窗口各做一份，与 Xcode 每个窗口一个 data source 相同。
- **挑选规则**：照搬 Xcode 的 `ActivityViewReportCoordinator`，即上一节的 4 秒、3 秒和每秒一次。插队请求的语料构建（Find 搜索等着的镜像、侧栏正显示的镜像）与手动索引算「用户发起」，立即显示；其余算后台。交叉引用全部算后台：查询要用的镜像是在引擎进程里按需准备的，协调器并不知道。
- **失败与取消**：一轮里有镜像失败就是 Failed，否则有被取消的就是 Cancelled，否则成功；拼写与 Report 导航一致（Cancelled）。
- 文字的确切措辞在实现时定，上表是样例。

### Xcode 26 的样式：中间的活动胶囊

- **工具栏项**：新增 `.Main.activity`，放在标题后的两个 flexible space 之间，设为 `centeredItemIdentifiers`，`visibilityPriority` 为 high。切换引擎的弹出按钮排在胶囊右边那个 flexible space 之后，与改动前的位置相同。
- **宽度**：照 Xcode。工具栏宽的 40% 用上面那个私有方法，按「私有 API 归 UIFoundationAppleInternal」的约定封装进 UIFoundation，发版后抬 pin。macOS 15.8 的 dyld cache 里有这个选择子（没有反编译核实），调用前用 `responds(to:)` 判断。
- **布局**：用 Xcode 没有 scheme 选择器时的版式，文字左对齐、环在右侧；胶囊背景照上面 macOS 26 与 macOS 15 两种。
- **空闲时**：显示最近一次活动的结果；从没有过活动时显示 `<来源名>: **Ready** │ <时间>`。

### Xcode 27 的样式：标题区的进度环

- **中间不再是胶囊**，改放切换引擎的弹出按钮（Runtime Source），设为 `centeredItemIdentifiers`，两侧各一个 flexible space，宽度取它自己的。Xcode 27 在这个位置放 scheme 与运行目标，RV 里与之对应的就是切换引擎。右侧那排按钮的位置不变。
- **标题区**：`TitleToolbarItem` 在文字左边加一个 18×18 的图标槽，进度环画在这里；完成序列结束时，环变回图标。
- **图标**：取标题所指的镜像，用它的种类符号（framework、bundle、dylib），照 Xcode 工程图标的画法画成一个单色字形：13 pt、medium、large，按对齐矩形居中在 18×18 的槽里、对齐到像素，比槽大的字形照 Xcode 超出槽位、不裁（Xcode 的工程图标约 19.5 pt），整个字形填一种颜色——bundle 用 `systemBrown`（与 Xcode 的 Swift package 图标同色），其余用 `systemBlue`（与 Xcode 的工程图标同色）。没有选中镜像时，用 App 自己的符号 `runtimeviewer`（照 Xcode 工程图标的样子：同一个圆角方框，里面换成 App 图标的放大镜；自绘的 SF Symbol），同样画成 `systemBlue` 的单色字形。收拢出的强调色方块是进度形状本身，它淡出、字形淡入，最后只剩字形（逆向结论见资料卷「The project icon in the window title」一节）。
- **第二行**：平时仍显示选中对象的名字，进度只看图标位置的环；鼠标悬停在标题区时，第二行换成活动文字。完成后的结果文字也是悬停时才显示，这一点与 Xcode 对非 scheme 活动的处理相同。
- **字体、颜色、间距**：一并照 Xcode 27。标题 13 pt 粗体，第二行 11 pt 次要色；窗口不在前台时两行都用三级色；文字列用 plusDarker / plusLighter 混合。

### 在设置里切换样式

- **设置项**：设置 › General 新增 Toolbar 一节，Activity Style 有三个选项：Automatic、Xcode 26、Xcode 27。存为 `Settings.General.toolbarActivityStyle`（`Settings.ToolbarActivityStyle`），旧的设置文件没有这一项，读出来是 Automatic。
- **Automatic** 按系统选：macOS 27 起是 Xcode 27 的样式，以前是 Xcode 26 的。两种样式在每个支持的系统上都能选，标题区的进度环只用到 macOS 14 起的 API。
- **立即生效**：已打开的窗口当场换过去。`MainViewModel` 经 `Observable.tracking` 跟着这一项，输出换算过 Automatic 的样式；`MainToolbarController.apply(activityStyle:)` 换居中项与宽度比例，再给 `NSToolbar.itemIdentifiers`（macOS 15 起可写）新的一组项，由 AppKit 对照已有的项做差异，两种样式共有的项原地不动。工具栏还没向 delegate 要过项时只记下样式，等它来要。
- **标题项有两个**：Xcode 26 样式用原来的 `TitleToolbarItem`（`.Main.title`），Xcode 27 样式用带活动的那个（`.Main.activityTitle`），由工具栏按样式换上。标题、副标题两边都绑；活动状态两边都给，不在工具栏里的那个不做动画，所以换样式时直接显示当前的进度。

### 代码放在哪

- **模型**：`RuntimeViewerApplication` 新建 `Activity/` 目录，放活动的值类型、每个 Engine 的汇总（`RuntimeEngineActivityReporter`）、挑选（`ActivityReportSelector`）与每个窗口的展示器（`ToolbarActivityPresenter`，含节流）。时间可以注入，测试用 RxSwift 的 `HistoricalScheduler` 推进虚拟时间。显示用的值类型 `ToolbarActivityState` 与文字分段放在 `RuntimeViewerUI`，因为视图在那里，而它在依赖链的下层。
- **绑定**：`MainViewModel.Output` 加活动状态与样式两个 `Driver`，由 `MainWindowController` 绑到胶囊、标题区与工具栏控制器。
- **视图**：放在 `RuntimeViewerUI`，分三块：
  - 26 的进度环，是 `DVTProgressRing` 的移植；
  - 胶囊内容，含按段优先级截断的文字；
  - 27 的标题区进度环。它把 `CollapsibleProgressShape` 的六个可动画量做成一个自绘 layer，形状用 `CGPath` 的布尔运算（macOS 14 起提供）拼出。
- **全部用 AppKit 与 Core Animation**：Xcode 27 这部分是 SwiftUI 写的，但项目规定 SwiftUI 只用于设置页。SwiftUI 的 `spring(response:dampingFraction:)` 换算成 `CASpringAnimation`：mass 1，stiffness (2π / response)²，damping 4π × dampingFraction / response。

### 落地步骤

每一步单独构建通过、相关测试通过后提交。

1. **UIFoundation 的封装**（已完成）：在 `AppleInternal` trait 下给 `NSToolbar` 加 `.box.preferredCenteredItemWidthRatio`，配测试、逆向报告、指南与 UIFoundation 自己的提案。快进合进 `main`，发 `0.43.0`。
2. **活动模型**（已完成）：`RuntimeViewerApplication/Activity/`。三类工作按轮次汇成活动，挑选（用户发起优先、后台 4 秒、至少 3 秒）、每秒一次的节流、文字分段都在这里，每个窗口的 `ToolbarActivityPresenter` 给出活动状态。配单元测试。
3. **macOS 26 / 15 的中间胶囊**（已完成）：`RuntimeViewerUI` 里做进度环、按段截断的文字、胶囊视图与工具栏项。抬 UIFoundation 的 pin；`MainWindowController` 在 macOS 27 以下装上胶囊，点击打开 Report 导航。配测试。
4. **macOS 27 的标题区**（已完成）：先补逆向 Xcode 工程图标的画法，再做收拢形状的自绘 layer、进度环与完成序列，以及 `TitleToolbarItem` 的图标槽、字体和悬停时的活动文字。配测试。
5. **收尾**（已完成）：用 Debug workspace 完整构建 App，跑各包测试；`AGENTS.md` 与本提案按实际做出的结果更新。
6. **看过后补的两项**（已完成）：Xcode 27 的样式下切换引擎的弹出按钮居中；两种样式做成设置，已打开的窗口当场切换。配设置的测试。

### 验证

- **单元测试**（swift-testing）：
  - 三类活动的汇总、轮次与结果；
  - 挑选规则：用户发起优先、后台 4 秒、至少 3 秒、最近完成的那个；
  - 每秒一次的节流；
  - 文字按段截断；
  - 环的显示值映射；
  - 收拢形状在关键时刻的几何。
- **实际跑过的**（2026-11-03，JH's Mac Studio Ultra，macOS 27.2，Xcode 27.2）：新增 7 组共 45 个测试（`ActivityRunTrackerTests`、`ActivityReportSelectorTests`、`ToolbarActivityStateTests`、`ToolbarActivityPresenterTests`、`ToolbarActivityViewTests`、`TitleActivityIndicatorTests`，以及原有的 `TitleToolbarItemOverflowTests`）全部通过；`RuntimeViewerPackages` 全量 748 个测试只有 `FindCrossReferenceTests` 的一个用例在满载下等待超时，这组单独跑在本分支与 `next` 上都通过；App 用 Debug workspace 编译通过，锁文件没被改写；`RuntimeViewerCommandLine` 编译通过。
- **看过后补的两项**（同日同机）：`RuntimeViewerSettingsTests` 的 43 个测试全部通过，含新增的 `SettingsToolbarActivityStyleTests`；App 用 Debug workspace 编译通过，锁文件没被改写。换样式与居中的效果没有在界面上验证。
- **一次没查明的崩溃**：把改动波及的 10 组既有测试合起来跑，本分支 8 次里测试进程崩过 1 次（信号 11，没有留下崩溃报告），`next` 上 4 次都没崩；单独跑各组都过。新代码里订阅三个协调器的回调一律经 `Task { @MainActor in … }` 回到主线程，没找到会在后台线程碰主线程状态的路径，暂时归为偶发。
- **目视验收由用户来做**。逆向留下几项只有录屏才能定：Xcode 27 图标槽与文字的间距、方块从强调色变透明是渐变还是跳变、几处默认动画曲线。需要时请用户录一段 Xcode 26 与 27 构建的过程。

### 没有询问就采用的假设

- **只显示三类后台工作**：前台的加载（打开镜像、读离线文件）不进胶囊，内容区本来就有加载遮罩。
- **点击的行为**：点击胶囊或标题区的进度，打开侧栏的 Report 导航，那里有逐项进度和取消。Xcode 的活动列表 popover、环里的取消按钮、标题区的下拉箭头都不做。
- **文字用英文**，与 App 其余界面一致。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-03 | Created as Draft | 用户要求照 Xcode 26 与 27 的 Activity View 在工具栏显示进度，只要进度部分。动笔前逆向了两版 Xcode，规格存在本机资料卷 |
| 2026-11-03 | macOS 27 用标题区的进度环，macOS 26 与 15 用中间的胶囊 | 各照对应版本的 Xcode。macOS 15 上没有 Xcode 27 可参照 |
| 2026-11-03 | macOS 27 标题区的第二行平时仍是选中对象的名字，悬停时才显示活动文字 | 后台索引可能持续几分钟，这期间不该遮住导航的上下文；进度由图标位置的环表达 |
| 2026-11-03 | macOS 27 标题区常驻当前镜像的种类符号，画成 Xcode 工程图标的样式 | 收拢出的圆角方块要有图标接上；不然动画结束后图标位置收起，标题会左移一次 |
| 2026-11-03 | 胶囊空闲时显示最近一次的结果，从没有过活动时显示 Ready | 与 Xcode 26 相同 |
| 2026-11-03 | 补上五个落地步骤 | 方案已定，按依赖顺序拆成各自能构建通过的步骤：UIFoundation 先发版，RuntimeViewer 才能用上那个封装 |
| 2026-11-03 | 用户批准，开始实现 | 用户批准时一并同意了 UIFoundation 的那次发版 |
| 2026-11-03 | UIFoundation 的封装叫 `preferredCenteredItemWidthRatio`，随 `0.43.0` 发布（UIFoundation 提案 0034） | 用公开 API 的说法 centered item。macOS 27.2 实测：比例算出的宽度小于胶囊的最小宽度 160 时，AppKit 整个丢掉比例、胶囊取最大宽度，与 26.6 反汇编的读法相反；对本提案只影响工具栏窄于 400 点的窗口 |
| 2026-11-03 | 插队请求的语料构建算用户发起，交叉引用全部算后台 | 语料协调器只知道一次请求是不是插队，分不出是 Find 搜索还是侧栏显示的镜像，两者都是用户正看着的东西；交叉引用的按需准备发生在引擎进程里，协调器无从得知。为此语料协调器多记一项「插队请求的镜像」 |
| 2026-11-03 | 完成文字是 Indexing Succeeded、Searchable Interfaces Built、Cross References Prepared，失败、取消是 Failed、Cancelled | 照 Xcode「名词 + 结果」的形式；Succeeded 只配得上动作名，所以后两类换成 Built、Prepared。Cancelled 与 Report 导航的拼写一致 |
| 2026-11-03 | 显示用的值类型放进 `RuntimeViewerUI`，胶囊做成 `NSControl` 子类 | 视图在 `RuntimeViewerUI`，它在 `RuntimeViewerApplication` 的下层、也不依赖 RxSwift；点击由 App 一侧经 RxCocoa 的 `rx.controlEvent` 接上 |
| 2026-11-03 | 标题区图标改为单色字形，不画方块 | 补的逆向表明 Xcode 的工程图标是自定义符号 `doc-project` 填 `systemBlue`，没有底板；收拢出的方块是进度形状本身。批准时选的「常驻当前镜像的种类符号」不变，只是方块那半句的前提不成立，照 Xcode 改；bundle 用棕色，因为 Xcode 给 Swift package 的 `shippingbox` 用棕色 |
| 2026-11-03 | 标题区几处动画用近似实现，写明在案 | 项目规定 SwiftUI 只用于设置页，标题区用 Core Animation 重做：SwiftUI 的弹簧换成 `CASpringAnimation(perceptualDuration:bounce:)`，用叠加动画模拟 SwiftUI 打断时的平滑衔接；收拢形状的连续圆角用 UIKit 的连续曲线，半径超出它能画的范围时改用圆弧；方块的填充从强调色到透明做成整层淡出；计数与副标题的出现、消失只做淡入淡出，没有 SwiftUI 那一点模糊，副标题行出现时标题上移不做动画；图标槽与文字的间距取 SwiftUI 默认的 8，未与 Xcode 实测比对 |
| 2026-11-03 | 活动文字只在悬停时进副标题行，标题项的宽度只在悬停期间按 20 点的台阶变宽 | 照批准的「平时不换，悬停才显示」；Xcode 让宽度只增不减、按 20 点取整，是为了每秒刷新的文字不抖动工具栏，悬停期间照做 |
| 2026-11-03 | 实现完成，待用户看过后收尾 | 五个落地步骤都已完成并推送。全量测试唯一的失败（`FindCrossReferenceTests` 的 Call Hierarchy 用例满载时等待超时）在 `next` 上全量跑同样出现，是基线已有的。文档：`RuntimeViewerUsingAppKit/AGENTS.md` 新增「The Toolbar's Activity Display」一节，根 `AGENTS.md` 的依赖下限改为 UIFoundation 0.43.0，术语表新增「活动」；没有可配置的东西，不写使用指南；实现要点在 `AGENTS.md` 与本提案里，不另写实现说明。目视验收、以及与 Xcode 录屏的逐帧比对留给用户 |
| 2026-11-03 | Xcode 27 的样式下，切换引擎的弹出按钮放在工具栏正中 | 用户看过后指出它没有居中。Xcode 27 把 scheme 与运行目标放在中间，活动挪进标题区后中间空着，RV 里与之对应的是切换引擎；它右边加一个 flexible space，右侧那排按钮留在原处 |
| 2026-11-03 | 两种样式做成设置（General › Toolbar › Activity Style），默认 Automatic 按系统 | 用户要求，因为有人偏好 Xcode 26 的样式。每个系统都能选，标题区的进度环只用到 macOS 14 起的 API；改了当场作用于已打开的窗口，用 macOS 15 起可写的 `NSToolbar.itemIdentifiers` 换项 |
| 2026-11-03 | 标题项做成两个，各管一种样式，不让一个标题项在运行时切换 | `TitleToolbarItem` 带不带活动在初始化时定，布局与宽度测量都按它分支，运行时切换要改这些，还会碰到防止长标题把按钮挤进溢出菜单的那几项设置。两个实例由工具栏按样式换上，绑定两边都接。文档：`RuntimeViewerUsingAppKit/AGENTS.md` 那一节改为两种样式可切换；设置页自带说明，不写使用指南；没有新术语 |
| 2026-11-04 | Xcode 26 样式下切换引擎的按钮改放进活动胶囊左侧，按钮本身换成自绘的 scheme 选择器加导航 popover，由 [`0070-xcode-style-runtime-source-picker`](0070-xcode-style-runtime-source-picker.md) 决定 | 用户看过后指出 Xcode 26 的 scheme 选择器就在活动胶囊里；那份提案逆向了选择器与弹出列表，本提案「切换引擎的弹出按钮排在胶囊右边」那句不再成立 |
| 2026-11-04 | Activity Style 加第四项 Classic：工具栏回到加活动显示之前的样子，不显示进度 | 用户要能用回原来的工具栏；与来源选择器一起在 [`0070-xcode-style-runtime-source-picker`](0070-xcode-style-runtime-source-picker.md) 里做 |
| 2026-11-04 | 没有选中镜像时，标题图标从 App 图标的图片改为 App 自己的符号 `runtimeviewer`，照其他字形画成 `systemBlue` 单色 | 用户要求不用 App 图标的图片，改画一个 App 自己的 SF Symbol；这样标题里的图标都是同一种单色字形。符号照 App 图标的镜片圆环加放大镜自绘，三档小号母版（Ultralight / Regular / Black）可插值，尺寸与线粗取系统 `circle` 与 `magnifyingglass.circle` 的实测值，模板写法照 Private Symbols 的夹具；放在 App 的 `Assets.xcassets`，由 `RuntimeViewerSymbols.runtimeViewer` 取用。文档：`Resources/AGENTS.md` 记下它与 App 图标要一起改 |
| 2026-11-04 | `runtimeviewer` 改成学 Xcode 工程图标：外圈从镜片圆环换成 `doc-project` 的圆角方框（两圈轮廓原样取自 XCOrganizer 导出的 Xcode 27 模板），里面是 App 图标的放大镜，居中；`doc-project` 里实心的内衬方块和锤子不要 | 用户看过后要求像 Xcode 那样带方框。Xcode 标题里的工程图标是空心方框加锤子，所以只取外框。左右边距改成对称，好让标题把方框居中；`doc-project` 的右边距比左边宽 |
| 2026-11-04 | 标题图标不再裁到 18 pt 的槽位：`TitleDocumentIcon` 的图以槽位为中心对称放大到装下整个字形，进度环视图按图标原尺寸居中显示（`contentsGravity` 从 `resizeAspect` 改为 `center`），不再缩放 | 用户看到方框版 App 符号在标题里线条发细。原因：方框在标题配置下约 19.2 pt，18 pt 的画布切掉了外缘，方框线只剩一半粗。从用户的截图量得 Xcode 的工程图标是 39×39 像素（2 倍屏 19.5 pt）、方框线 3 像素，可见 Xcode 让它超出槽位；进度环本来就超出槽位 1 pt，容器层不裁边。回归测试：比槽位宽的字形要整个画出来、且对齐框居中 |
