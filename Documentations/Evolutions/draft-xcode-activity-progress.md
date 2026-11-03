# Draft - 工具栏照 Xcode 显示后台工作的进度：macOS 26 及以前用中间的活动胶囊，macOS 27 用标题区的进度环

- **状态**: Accepted
- **创建日期**: 2026-11-03
- **最后更新**: 2026-11-03
- **所属愿景**: 无
- **实现分支 / PR**: `feature/xcode-activity-progress`（从 `next` 切出）；UIFoundation 一侧是 `feature/toolbar-principal-item-width-ratio`

## 摘要

后台索引、Find 语料、交叉引用这三类后台工作，现在只能到侧栏的 Report 导航里看进度。本提案照 Xcode 的 Activity View 把进度放进工具栏，只做显示进度的部分，不做 scheme、运行目标和 issue 计数。两版 Xcode 的做法不同，各照一版：

- macOS 26 及以前照 Xcode 26：工具栏正中一个胶囊，里面是状态文字和一个进度环。
- macOS 27 照 Xcode 27：进度挪到左边的标题区，画在图标位置。活动结束时，进度环收拢成一个圆角方块，再淡出变回图标。

两版的规格是逆向 Xcode 拿到的，不是照截图调的。

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
| Find 语料 | `Building Searchable Interfaces │ 3 of 10 images` | 这一轮已建好的镜像数（正在建的那个按对象进度计入）÷ 镜像总数 | 同上的形式 |
| 交叉引用 | `Preparing Cross References │ 2 of 5 images` | 同上 | 同上的形式 |

- **一轮的起止**：这一类从无事可做变为有事可做时，一轮开始；回到无事可做时，这一轮结束，即活动完成。
- **在哪里算**：活动在 `RuntimeEngineBackgroundWork` 里每个 Engine 算一次，与 `isWorkInProgress` 并列，所以同一 Engine 的窗口看到的一样。挑选与节流每个窗口各做一份，与 Xcode 每个窗口一个 data source 相同。
- **挑选规则**：照搬 Xcode 的 `ActivityViewReportCoordinator`，即上一节的 4 秒、3 秒和每秒一次。Find 查询正在等的语料构建与交叉引用准备算「用户发起」，立即显示；其余算后台。
- 文字的确切措辞在实现时定，上表是样例。

### macOS 26 及以前：中间的活动胶囊

- **工具栏项**：新增 `.Main.activity`，放在标题后的两个 flexible space 之间，设为 `centeredItemIdentifiers`，`visibilityPriority` 为 high。
- **宽度**：照 Xcode。工具栏宽的 40% 用上面那个私有方法，按「私有 API 归 UIFoundationAppleInternal」的约定封装进 UIFoundation，发版后抬 pin。macOS 15.8 的 dyld cache 里有这个选择子（没有反编译核实），调用前用 `responds(to:)` 判断。
- **布局**：用 Xcode 没有 scheme 选择器时的版式，文字左对齐、环在右侧；胶囊背景照上面 macOS 26 与 macOS 15 两种。
- **空闲时**：显示最近一次活动的结果；从没有过活动时显示 `<来源名>: **Ready** │ <时间>`。

### macOS 27：标题区的进度环

- **不再有中间的胶囊**，与 Xcode 27 相同。
- **标题区**：`TitleToolbarItem` 在文字左边加一个 18×18 的图标槽，进度环画在这里；完成序列结束时，环变回图标。
- **图标**：取标题所指的镜像，用它的种类符号（framework、bundle、dylib），画成 Xcode 工程图标那样的强调色圆角方块加白色符号，好让收拢出的方块与图标接得上。没有选中镜像时，用 App 图标。Xcode 工程图标的确切画法（`IconView` / `DVTIcon`）还要在实现时补一次逆向。
- **第二行**：平时仍显示选中对象的名字，进度只看图标位置的环；鼠标悬停在标题区时，第二行换成活动文字。完成后的结果文字也是悬停时才显示，这一点与 Xcode 对非 scheme 活动的处理相同。
- **字体、颜色、间距**：一并照 Xcode 27。标题 13 pt 粗体，第二行 11 pt 次要色；窗口不在前台时两行都用三级色；文字列用 plusDarker / plusLighter 混合。

### 代码放在哪

- **模型**：`RuntimeViewerApplication` 新建 `Activity/` 目录，放活动的值类型、每个 Engine 的汇总，以及挑选与节流。时间可以注入，测试用虚拟时间。
- **绑定**：`MainViewModel.Output` 加一个活动状态的 `Driver`，由 `MainWindowController` 绑到胶囊或标题区。
- **视图**：放在 `RuntimeViewerUI`，分三块：
  - 26 的进度环，是 `DVTProgressRing` 的移植；
  - 胶囊内容，含按段优先级截断的文字；
  - 27 的标题区进度环。它把 `CollapsibleProgressShape` 的六个可动画量做成一个自绘 layer，形状用 `CGPath` 的布尔运算（macOS 14 起提供）拼出。
- **全部用 AppKit 与 Core Animation**：Xcode 27 这部分是 SwiftUI 写的，但项目规定 SwiftUI 只用于设置页。SwiftUI 的 `spring(response:dampingFraction:)` 换算成 `CASpringAnimation`：mass 1，stiffness (2π / response)²，damping 4π × dampingFraction / response。

### 落地步骤

每一步单独构建通过、相关测试通过后提交。

1. **UIFoundation 的封装**：在 `AppleInternal` trait 下给 `NSToolbar` 加 `.box.preferredPrincipalItemWidthRatio`，配测试、逆向报告、指南与 UIFoundation 自己的提案。快进合进 `main`，发 `0.43.0`。
2. **活动模型**：`RuntimeViewerApplication/Activity/`。三类工作按轮次汇成活动，挑选（用户发起优先、后台 4 秒、至少 3 秒）、每秒一次的节流、文字分段都在这里，由文档对外给出活动状态。配单元测试。
3. **macOS 26 / 15 的中间胶囊**：`RuntimeViewerUI` 里做进度环、按段截断的文字、胶囊视图与工具栏项。抬 UIFoundation 的 pin；`MainWindowController` 在 macOS 27 以下装上胶囊，点击打开 Report 导航。配测试。
4. **macOS 27 的标题区**：先补逆向 Xcode 工程图标的画法，再做收拢形状的自绘 layer、进度环与完成序列，以及 `TitleToolbarItem` 的图标槽、字体和悬停时的活动文字。配测试。
5. **收尾**：用 Debug workspace 完整构建 App，跑各包测试；`AGENTS.md` 与本提案按实际做出的结果更新。

### 验证

- **单元测试**（swift-testing）：
  - 三类活动的汇总、轮次与结果；
  - 挑选规则：用户发起优先、后台 4 秒、至少 3 秒、最近完成的那个；
  - 每秒一次的节流；
  - 文字按段截断；
  - 环的显示值映射；
  - 收拢形状在关键时刻的几何。
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
