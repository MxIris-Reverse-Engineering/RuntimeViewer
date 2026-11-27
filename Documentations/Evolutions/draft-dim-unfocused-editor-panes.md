# Draft - 没有焦点的编辑栏变暗

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-27
- **最后更新**: 2026-11-27
- **所属愿景**: 无
- **关联提案**: [0076 编辑器分栏](0076-editor-panes.md)（焦点栏的来历）、[0092 编辑栏的路径栏](0092-editor-jump-bar.md)（路径栏在非焦点栏里的样子）
- **实现分支 / PR**: `feature/dim-unfocused-editor-panes`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

编辑区分成多栏时，照 Xcode 27.2 的「Dim unfocused editor panes」，只有焦点栏照常显示，其余各栏里的 interface
变暗；点进哪一栏，哪一栏就亮。变暗不是透明度、遮罩或滤镜，而是把主题里的每个颜色在 OKLCH 里重算一遍：按颜色的
对比级别把亮度和色度乘一个系数（背景亮度 ×0.94 深色 / ×0.98 浅色、色度 ×0.85；当前行与选区亮度 ×0.95 /
×0.975、色度 ×0.9；文字与语法色亮度、色度都 ×0.9），色相与不透明度不变，系数与规则全部来自对 Xcode 的逆向。
范围是 interface 本身——两种显示方式（重建的 SourceEditor 与内置 `NSTextView`）的文字、语法色、背景、当前行、
选区、行号与 SourceEditor 基础主题里其余颜色；标签栏与路径栏保持现在的非焦点样式，镜像页、起始页这类不用主题的
内容不变。只有一栏时从不变暗，窗口是否在前台不影响，切换没有动画。Settings › Theme 新增开关 Dim Unfocused Editor
Panes，默认开，与 Xcode 一样。

## 动机

0076 引入多栏以后，用户靠什么分辨焦点栏：

- **标签栏显示时**，非焦点栏的标签整条降到 55% 不透明（`EditorPaneTabBarView.unfocusedTabAlpha`，
  `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/EditorArea/EditorPaneViewController.swift:337-345`）。
- **标签栏只在某一栏有第二个标签时才显示**（`EditorPaneViewModel.Output.isTabBarHidden`）。每栏只有一个标签时——
  分栏对照两个类型的最常见用法——能分辨焦点的只剩路径栏的标题颜色：非焦点栏用 `secondaryLabelColor`
  （`EditorJumpBarAdapter.isPaneFocused`，`RuntimeViewerPackages/Sources/RuntimeViewerAppUI/EditorArea/JumpBar/EditorJumpBarAdapter.swift:53`、`:158`）。
  这一行 11 pt 的小字离正文很远，看正文时察觉不到。
- 结果是在两栏之间对照阅读时，按 ⌘F、⌥-点击开到下一栏、Go Back 这类以焦点栏为准的命令，用户事先不知道会落到
  哪一栏。

Xcode 27 的回答是整栏变暗：没有焦点的编辑栏里，源码的文字、背景、当前行、选区都按同一套规则变暗，一眼就分得出
哪一栏在接收输入。用户要求照做。

## 前期调研

### Xcode 27.2 怎么做的（逆向，27B52）

结论与地址全部记在 `/Volumes/RE/Xcode/27.2-27B52/README.md` 的「Dimmed unfocused editor panes (2026-11-27)」
一节，焦点来源在同一文件的「Editor panes」§5 与「Editor panes — visuals」§3。要点（[D] 为反编译核实，[I] 为推断）：

- **开关**：`DVTWorkspaceThemeManager.dimUnfocusedEditorPanes`（DVTUserInterfaceKit），默认值键
  `DVTWorkspaceDimUnfocusedEditorPanes`，注册的默认值是 YES；设置界面在工作区主题编辑器里，文案「Dim unfocused
  editor panes」；setter 通知所有观察者，立刻全局生效。[D]
- **焦点来源**：IDEKit 给每个编辑栏的内容视图设 `dvt_activeState`（是最后激活的那一栏为 1，否则 2）。窗口是否 key、
  first responder 在哪都不参与。只有一栏时它永远是最后激活的，所以从不变暗。[D]（单栏的结论为 [I]）
- **效果是重算颜色**：`DVTWorkspaceThemeManager.colorTheme(for:)`（0x2CC2D8）为非焦点栏里的视图取主题状态
  `.inactive`，每个颜色经 `DVTOpaqueColor.applyingStateAppearance(as:in:)`（0x1DC590）：
  `L′ = clamp(L × kL, 0, 1)`，按新的 L 把色度裁进色域，再 `C′ = max(0, C × kC)`；色相与不透明度不变。没有
  `alphaValue`、遮罩视图、层或 `CAFilter`。[D]
- **系数**（按 `DVTColorRecipe.ContrastLevel`；浅深两列取主题配方自己的明暗，不看视图的 `NSAppearance`）：[D]

  | 级别 | kL 浅色 | kL 深色 | kC |
  |---|---|---|---|
  | 背景（0） | 0.98 | 0.94 | 0.85 |
  | 填充（1–5，当前行是 2、选区是 5） | 0.975 | 0.95 | 0.90 |
  | 文字（6–10，正文与全部语法色） | 0.90 | 0.90 | 0.90 |

- **经典主题**（`Default (Dark)` 这类 `.xccolortheme`）先转成同一套配方：语法色、不可见字符、光标先压到背景上存成
  不透明色，所以总会变暗；选区与当前行保留主题里的 alpha，只有 alpha 为 1 时才变暗。[D]
- **范围**：源码编辑器的全部颜色（文字、语法色、背景、当前行、选区、光标、不可见字符、scope guide、折叠条、
  minimap 背景、gutter 边线）与编辑器背后的背景视图。**标签栏与路径栏不受这个开关影响**，它们按栏与窗口的状态
  用自己的系统颜色。不用主题色的编辑器（IB 画布、图片与 Quick Look 预览）内容不变。导航区、调试区永远不暗。[D]
- **没有动画**：状态变化同步走到 `setNeedsLayout` / `setNeedsDisplay`，路径上没有 `NSAnimationContext`、
  `animator()` 或 `CATransaction`；唯一的延迟是 IDEKit 把焦点栏的更新推到下一轮 run loop。[D]
- 没静态定下来的：具体主题下的最终 RGB（要按公式算）、Xcode 色域裁剪用的具体算法、半透明色压平在哪个色彩空间里做。
  本提案对这两处的做法见「详细设计」，标为推测。

### RuntimeViewer 现状

- **焦点栏**：`EditorArea.focusedPaneID`。键盘焦点进入哪一栏，哪一栏就成为焦点栏
  （`EditorAreaViewController.viewDidAppear` 观察窗口的 `firstResponder`，`paneReceivedKeyboardFocus` →
  `.focusEditorPane`）；点在栏里没有视图接住的地方也一样（`EditorPaneViewController.mouseDown` →
  `backgroundClicked`）。和 Xcode 的「最后激活的一栏」是同一个概念：焦点离开编辑区（比如点侧栏）时它不变。
- **每栏一个内容协调器**：`EditorAreaCoordinator.makePane(_:)` 为每一栏建 `ContentCoordinator(documentState:editorPaneID:)`，
  它建的 `ContentTextViewModel` 带着自己所在栏的 `editorPaneID`
  （`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentTextViewModel.swift:132-156`）。
  iOS 的协调器不传，取当时的焦点栏；iOS 只有一栏。
- **主题**：`Settings.Theme.Preset` 的每个颜色槽是 `Style`，带浅色与深色两个 `ColorValue`（sRGB 分量与 alpha，
  `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Theme.swift:93-125`）。`ResolvedTheme`
  （`RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Theme/ThemePreset+ThemeProfile.swift:21`）把预设解析成随外观
  变化的 `NSColor(light:dark:)`，`==` 比较预设与字号。
- **内容区从哪拿主题**：两种内容视图都建一个 `ContentTextRenderer(interfaces:)`
  （`RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Content/ContentTextRenderer.swift:43`），它的 `theme` 默认取
  全局的 `resolvedThemeStream`，构造器已经留了 `themes:` 注入口；`renderedText` 在主题每次变化时在后台重新上色。
  - SourceEditor：`ContentSourceEditorViewController.applyCurrentTheme()`（`:392-425`）把主题经
    `SourceEditorThemeConversion` 写进框架自带的 `Default (Dark|Light)` 主题字典的副本，交给
    `bridge.applyTheme`，背景色另外交给 bridge、内容容器与加载遮罩，注释标签的颜色交给
    `applyCommentDecorations`。
  - `NSTextView`：`ContentTextViewController`（`:163-190`）用 `renderedText` 的整串属性文字，背景、行号栏、选区
    属性从 `theme` 取。
- **SourceEditor 基础主题里 RuntimeViewer 没有覆盖的颜色**：`SourceEditorThemeConversion` 只写 28 个语法色、背景、
  选区与当前行。框架自带主题里另有光标（`DVTSourceTextInsertionPointColor`）、不可见字符、`DVTSourceTextBlockDimBackgroundColor`、
  markup 的十种颜色、七种滚动条标记、指令指针与控制台颜色（按 `Default (Dark).xccolortheme` 逐键核对），这些在非
  焦点栏里也要变暗才和 Xcode 一致。
- **行号与 gutter**：重建的 SourceEditor（钉住的 27.2.0-alpha.2，`SourceEditor/MarginAccessories/SourceEditorGutter.swift`
  中 `SourceEditorGutterMarginContentView`）用主题的 `plainTextColor` 乘 0.35 不透明度画行号，gutter 背景取主题的
  `backgroundColor`——两者都从主题来，主题变暗它们就跟着变暗，不需要另做。
- **NSTextView 路径的代价**：主题一变，`renderedText` 就把整篇 interface 重新上色一次（后台队列，超过 100 ms 显示
  加载遮罩，`delayedRendering`）。焦点切换因此会让这一路重新上色。这一路只在 Intel 切片与不链接 SourceEditor 的
  构建里用，官方构建在 Apple 芯片上走 SourceEditor。

## 提议方案

1. **颜色变换**放进 RuntimeViewerAppUI：新类型 `UnfocusedEditorPaneDimming` 把一个 sRGB 颜色换到 OKLCH，按级别
   （背景 / 填充 / 文字）与明暗乘 Xcode 的系数，裁进 sRGB 色域再换回来；半透明的文字色先压到未变暗的背景上。
   `Settings.Theme.Preset` 上的 `dimmedForUnfocusedEditorPane()` 按 Xcode 对经典主题的规则逐槽套用：背景用背景级；
   选区与当前行用填充级，且只在 alpha 为 1 时变；八个文字槽压平后用文字级；粗体斜体不动。
2. **`ResolvedTheme` 多一个变暗的变体**：`dimmedForUnfocusedEditorPane()` 返回由变暗后的预设解析出的主题，并带
   `isDimmedForUnfocusedEditorPane` 标志，`==` 把它算进去。
3. **`ContentTextRenderer` 多一个输入** `isDimmed: Driver<Bool>`，默认 `.just(false)`：为真时 `theme` 与
   `renderedText` 用变暗的主题。iOS 的调用点不变。
4. **设置**：`Settings.Theme.dimsUnfocusedEditorPanes`，默认 `true`；Settings › Theme 的字号那一节加开关
   Dim Unfocused Editor Panes，只在 macOS 显示（iOS 只有一栏）。
5. **哪一栏变暗由 AppCore 判断**：`ContentTextViewModel.Output.isEditorPaneDimmed` = 编辑区有一栏以上、焦点栏不是
   自己所在的栏、且开关打开。
6. **App 接线**：两种内容视图把 `isEditorPaneDimmed` 交给渲染器；SourceEditor 那一路在主题变暗时，让
   `SourceEditorThemeConversion` 把基础主题里 RuntimeViewer 没覆盖的颜色也按同样的规则变暗。

焦点切换时整条链路都是现成的：`focusedPaneID` 一变，每一栏的 `isEditorPaneDimmed` 跟着变，渲染器发出新主题，
内容视图照「主题变了」的老路重新上色。不加动画，与 Xcode 一致。

### 非目标

- **标签栏与路径栏不改。** Xcode 的这个开关不影响它们；RuntimeViewer 现有的非焦点样式（标签 55% 不透明、路径栏
  标题 `secondaryLabelColor`）保留。把标签栏改成 Xcode 那张按「选中 / 栏焦点 / 窗口前台」取色的表是另一件事。
- **不用主题的内容不变暗**：镜像页、起始页（空标签）、Load Frameworks 页与加载遮罩以外的系统控件。Xcode 里不读
  主题色的编辑器同样不变。
- **侧栏、Inspector、工具栏不暗**，与 Xcode 一样只作用于编辑栏。
- **窗口失去前台不触发变暗**，也不让已变暗的栏复原。
- **不加切换动画。**
- **不移植 Xcode 的工作区主题体系**（OKLCH 配方、对比级别与色调、`.focused` 状态的增色）：RuntimeViewer 的预设
  相当于 Xcode 的经典主题，只照搬经典主题经过的那一步变换。
- **不优化 NSTextView 路径的重新上色**：焦点切换在这一路上和改主题一样整篇重新上色；它只在非官方构建与 Intel 上用。
- **iOS 与 visionOS 不显示开关**：只有一栏，永远不会变暗；设置字段在所有平台都存在，只是不显示。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Theme/UnfocusedEditorPaneDimming.swift` · `UnfocusedEditorPaneDimming`、`UnfocusedEditorPaneDimming.ContrastLevel`、`UnfocusedEditorPaneDimming.ColorScheme`、内部的 `OklchColor` | 新增 | sRGB ↔ OKLab ↔ OKLCH 换算；按级别与明暗乘系数；按新亮度把色度裁进 sRGB 色域；`flattened(_:over:)` 压平半透明色 | Xcode 的变换本身，所有用到的地方共用这一份 | 1 |
| 同上 · `extension Settings.Theme.Preset` 的 `dimmedForUnfocusedEditorPane()` | 新增 | 逐槽套用：背景→背景级；选区、当前行→填充级（alpha 为 1 时）；八个文字槽→压平后文字级；保留粗体斜体、`id`、`name`、`isBuiltin` | Xcode 对经典主题的规则 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Theme/ThemePreset+ThemeProfile.swift` · `ResolvedTheme` | 修改 | 加 `isDimmedForUnfocusedEditorPane`、`dimmedForUnfocusedEditorPane()`；`==` 比较这个标志 | 渲染器与内容视图用同一个主题值传递「变暗与否」，SourceEditor 那一路靠标志决定要不要变暗基础主题 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/UnfocusedEditorPaneDimmingTests.swift` | 新增 | 第 1 步的行为测试 | 系数、规则与色域 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Content/ContentTextRenderer.swift` · `ContentTextRenderer.init(interfaces:themes:isDimmed:)` | 修改 | 新参数 `isDimmed: Driver<Bool> = .just(false)`；`theme` 与 `renderedText` 改用 `combineLatest(themes, isDimmed)` 得出的主题 | 两种内容视图都从这里拿主题，一处接入两路生效 | 2 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/ContentTextRendererTests.swift` | 修改 | 第 2 步的行为测试 | | 2 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Theme.swift` · `Settings.Theme.dimsUnfocusedEditorPanes` | 新增 | `@Default(true) public var dimsUnfocusedEditorPanes: Bool` | 开关；放在 `theme` 分支下，`accessPersistedValues()` 已经读 `theme`，不需改 | 3 |
| `RuntimeViewerPackages/Tests/RuntimeViewerSettingsTests/` 中 `Settings.Theme` 的解码测试（新增文件 `ThemeDimmingSettingTests.swift`） | 新增 | 旧的 `settings.json`（没有这个键）解出 `true`；改了能存回 | 兼容已有设置文件 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift` | 修改 | 字号那一节加 `Toggle("Dim Unfocused Editor Panes", isOn: $theme.dimsUnfocusedEditorPanes)`，`#if os(macOS)` | 设置入口，位置对应 Xcode 的主题设置 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentTextViewModel.swift` · `Output.isEditorPaneDimmed` | 修改 | `documentState.$editorArea` 映射出「一栏以上且焦点不在本栏」，与 `Observable.tracking` 读出的开关合并，`distinctUntilChanged` | 「哪一栏该暗」是应用逻辑，放在可测试的 ViewModel 里 | 3 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/ContentTextViewModelEditorPaneDimmingTests.swift` | 新增 | 第 3 步 ViewModel 的行为测试 | | 3 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentSourceEditorViewController.swift` | 修改 | 建渲染器时传 `isDimmed: output.isEditorPaneDimmed`；`currentTheme` 改存 `ResolvedTheme?`；`applyCurrentTheme()` 在主题变暗时让转换一并变暗基础主题 | SourceEditor 那一路接入 | 4 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentTextViewController.swift` | 修改 | 建渲染器时传 `isDimmed: output.isEditorPaneDimmed` | NSTextView 那一路接入 | 4 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/SourceEditorThemeConversion.swift` · `themeDictionary(from:basedOn:baseThemeDimming:)` | 修改 | 新参数 `baseThemeDimming: UnfocusedEditorPaneDimming.ColorScheme?`：非 `nil` 时先用下一行的函数把基础主题变暗，再照旧写入主题的颜色 | 光标、不可见字符、markup、滚动条标记这些键 RuntimeViewer 不覆盖，不变暗就和 Xcode 不一致 | 4 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Theme/UnfocusedEditorPaneDimming+ColorTheme.swift` · `UnfocusedEditorPaneDimming.dimmedColorTheme(_:colorScheme:)` | 新增 | 把 `.xccolortheme` 字典里每个颜色值按键的级别变暗（generic RGB 读入、sRGB 里计算、generic RGB 写回） | App target 没有单元测试 target，放进 AppUI 才能在 AppUITests 里测；只在 macOS 编 | 4 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/UnfocusedEditorPaneColorThemeDimmingTests.swift` | 新增 | 第 4 步基础主题变暗的行为测试 | | 4 |
| `RuntimeViewerUsingAppKit/AGENTS.md`（编辑区一节） | 修改 | 一句话：非焦点栏的 interface 用变暗的主题，判断在 `ContentTextViewModel.Output.isEditorPaneDimmed`，新的主题化内容照此接入 | 以后加进编辑栏的主题化内容不会漏掉 | 5 |
| `Documentations/Evolutions/draft-dim-unfocused-editor-panes.md` 与 `.html`、`Documentations/Evolutions/README.md`、`Documentations/README.md` | 新增 / 修改 | 本提案、网页版与两份索引 | | 5 |

## 架构图

改了什么：

```text
RuntimeViewerSettings
  Settings.Theme
+   dimsUnfocusedEditorPanes: Bool            (default true)

RuntimeViewerSettingsUI
  ThemeSettingsView
+   Toggle "Dim Unfocused Editor Panes"       (macOS only)

RuntimeViewerAppCore
  ContentTextViewModel
    editorPaneID
    Output
+     isEditorPaneDimmed: Driver<Bool>        = panes > 1 && focusedPaneID != editorPaneID && setting

RuntimeViewerAppUI
+ UnfocusedEditorPaneDimming                  (OKLCH factors, gamut clip, flatten)
+   extension Settings.Theme.Preset.dimmedForUnfocusedEditorPane()
+   dimmedColorTheme(_:colorScheme:)          (.xccolortheme dictionary, macOS only)
  ResolvedTheme
+   isDimmedForUnfocusedEditorPane: Bool
+   dimmedForUnfocusedEditorPane() -> ResolvedTheme
  ContentTextRenderer
~   init(interfaces:themes: + isDimmed: Driver<Bool> = .just(false))

RuntimeViewerUsingAppKit
  ContentSourceEditorViewController
~   ContentTextRenderer(interfaces:isDimmed:)
~   applyCurrentTheme()  -> SourceEditorThemeConversion(+ baseThemeDimming:)
  ContentTextViewController
~   ContentTextRenderer(interfaces:isDimmed:)
  SourceEditorThemeConversion
~   themeDictionary(from:basedOn: + baseThemeDimming:)  -> UnfocusedEditorPaneDimming.dimmedColorTheme
```

焦点切换的数据流：

```text
click / Move Focus to Next Editor Pane
  └─ window.firstResponder enters pane B
       └─ EditorAreaViewModel.paneReceivedKeyboardFocus
            └─ selectionRouter .focusEditorPane(B)
                 └─ DocumentState.editorArea.focusedPaneID = B
                      ├─ pane A: ContentTextViewModel.isEditorPaneDimmed  false -> true
                      │    └─ ContentTextRenderer.theme  -> ResolvedTheme.dimmedForUnfocusedEditorPane()
                      │         ├─ SourceEditor: SourceEditorThemeConversion(baseThemeDimming: .dark/.light)
                      │         │                  -> bridge.applyTheme / applyBackgroundColor
                      │         └─ NSTextView:   renderedText rebuilt in the dimmed theme
                      └─ pane B: isEditorPaneDimmed  true -> false  (same path, undimmed theme)
```

## 详细设计

### 颜色变换

```swift
/// Xcode 27.2's "Dim unfocused editor panes": the colours of a pane without the focus, recomputed in
/// OKLCH (RE notes "Dimmed unfocused editor panes", `DVTOpaqueColor.applyingStateAppearance(as:in:)`).
public enum UnfocusedEditorPaneDimming {
    /// Which of Xcode's contrast levels a colour is dimmed at: its factors depend on it.
    public enum ContrastLevel: Sendable {
        /// The editor background (Xcode's level 0).
        case background
        /// Fills drawn over the background: the current line, the selection (levels 1–5).
        case fill
        /// Text and every syntax colour (levels 6–10).
        case text
    }

    /// The scheme of the theme a colour belongs to — the light or the dark variant of a slot —
    /// which picks the lightness factor, as Xcode reads the theme's own scheme and not the view's appearance.
    public enum ColorScheme: Sendable {
        case light
        case dark
    }

    /// `color` as an unfocused pane draws it: lightness × kL clamped to 0…1, chroma clipped to the
    /// sRGB gamut at the new lightness, then × kC; hue and opacity kept.
    public static func dimmed(_ color: Settings.Theme.ColorValue, level: ContrastLevel, colorScheme: ColorScheme) -> Settings.Theme.ColorValue

    /// `color` composited over the opaque `background`, with opacity 1: how a translucent text colour
    /// looks once drawn, which Xcode's conversion of a classic theme stores before dimming.
    public static func flattened(_ color: Settings.Theme.ColorValue, over background: Settings.Theme.ColorValue) -> Settings.Theme.ColorValue
}
```

系数表照搬 Xcode（见「前期调研」），写成 `ContrastLevel` 与 `ColorScheme` 上的 `switch`，不放成可配置项：

| `ContrastLevel` | `lightnessFactor` `.light` | `.dark` | `chromaFactor` |
|---|---|---|---|
| `.background` | 0.98 | 0.94 | 0.85 |
| `.fill` | 0.975 | 0.95 | 0.90 |
| `.text` | 0.90 | 0.90 | 0.90 |

- **OKLab 换算**用 Björn Ottosson 的标准矩阵：sRGB 分量先去伽马（`c ≤ 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)^2.4`），
  线性 sRGB → LMS → 立方根 → OKLab；OKLCH 的 `C = √(a² + b²)`、`h = atan2(b, a)`。逆变换反过来，最后把分量夹到 0…1
  （浮点误差）。Xcode 的 `DVTOklchColor` 是否用同一组矩阵没有逆向核实 [推测：OKLCH 只有这一种公开定义]。
- **色域裁剪**：亮度变了以后，在该亮度与色相下用二分法找 sRGB 色域内的最大色度（区间 0…0.5，32 次，判据是线性
  sRGB 三个分量都在 `-1e-9 … 1 + 1e-9` 内），`chroma = min(chroma, maximumChroma)`，再乘 `chromaFactor`。
  Xcode 的 `withLightness`（0x1C71A8）用的具体算法没逆向 [推测：结果都是色域边界上的同一点，差别只在求解精度]。
  `ColorValue` 是 sRGB 分量，所以只裁 sRGB，不考虑 P3。
- **压平**在 gamma 编码的 sRGB 里按 alpha 混合（`result = color × α + background × (1 − α)`，alpha 置 1）。这是
  AppKit 把半透明文字画到不透明背景上的混合方式，所以焦点栏里看起来不变；Xcode 的 `flattened(over:)` 在哪个空间
  混合没逆向 [推测]。

### 预设的变暗规则

```swift
extension Settings.Theme.Preset {
    /// The preset an unfocused editor pane draws in, by the rules Xcode 27.2 applies to a classic theme:
    /// the background at the background level; the selection and the current-line highlight at the
    /// fill level, only while opaque; every text slot flattened over the undimmed background, then at
    /// the text level. Font traits, the identifier and the name are kept.
    package func dimmedForUnfocusedEditorPane() -> Settings.Theme.Preset
}
```

- 每个 `Style` 的 `light` 用 `.light` 一列、`dark` 用 `.dark` 一列；文字槽压平时用同一列未变暗的背景。
- 选区与当前行 alpha 小于 1 时原样保留（Xcode 把经典主题的这两项存成带透明度的覆盖色，只有 alpha 为 1 才变暗）。
  内置的 Xcode 预设选区是不透明的，会变暗。
- 背景不压平；alpha 小于 1 的背景照样变暗、保留 alpha。

### `ResolvedTheme`

```swift
public struct ResolvedTheme: ThemeProfile, @unchecked Sendable {
    /// Whether this is the theme of an editor pane without the focus (`dimmedForUnfocusedEditorPane()`).
    public let isDimmedForUnfocusedEditorPane: Bool

    /// This theme as an editor pane without the focus draws it; itself when it is already that.
    public func dimmedForUnfocusedEditorPane() -> ResolvedTheme
}
```

- 内部构造器 `init(preset:fontSize:isDimmedForUnfocusedEditorPane:)`；公开的 `init(preset:fontSize:)` 与
  `init(settings:)` 不变，标志为 `false`。
- `preset` 存变暗后的预设，`==` 改为预设、字号与标志三者都相等。

### `ContentTextRenderer`

```swift
/// - Parameter isDimmed: whether the pane draws in the theme of an editor pane without the focus
///   (`ResolvedTheme.dimmedForUnfocusedEditorPane()`); never by default.
public init(interfaces: Driver<ContentInterface>, themes: Observable<ResolvedTheme>? = nil, isDimmed: Driver<Bool> = .just(false))
```

`sharedThemes` 之后加一级：`Observable.combineLatest(sharedThemes, isDimmed.asObservable().distinctUntilChanged())`
映射成主题，再 `share(replay: 1, scope: .whileConnected)`；`theme` 与 `renderedText` 都从这一级取。

### 设置

```swift
public struct Theme: Sendable {
    /// Whether an editor pane without the focus draws its interface dimmed, as Xcode's
    /// "Dim unfocused editor panes" does. On by default, as there.
    @Default(true)
    public var dimsUnfocusedEditorPanes: Bool
}
```

- 在 `theme` 分支下，`Settings.accessPersistedValues()` 已经读 `theme`（`Settings.swift:92`），
  `SettingsPersistenceTests` 比较的是顶层键，都不需要改。
- 设置页文案用 RuntimeViewer 设置页的标题式大写（「Show Welcome Window at Launch」「Use Fixed Port」），写成
  Dim Unfocused Editor Panes；不加脚注。

### `ContentTextViewModel`

```swift
public struct Output {
    /// Whether the pane showing the content draws it dimmed: the editor area has more than one pane,
    /// another one has the focus, and Settings › Theme's Dim Unfocused Editor Panes is on.
    public let isEditorPaneDimmed: Driver<Bool>
}
```

```swift
let editorPaneID = editorPaneID
let isAnotherPaneFocused = documentState.$editorArea.asDriver()
    .map { $0.panes.count > 1 && $0.focusedPaneID != editorPaneID }
let dimsUnfocusedEditorPanes = Observable<Bool>
    .tracking { MainActor.assumeIsolated { trackedSettings.theme.dimsUnfocusedEditorPanes } }
    .asDriver(onErrorJustReturn: true)
let isEditorPaneDimmed = Driver.combineLatest(isAnotherPaneFocused, dimsUnfocusedEditorPanes) { $0 && $1 }
    .distinctUntilChanged()
```

`Observable.tracking` 按 `ContentTextViewModel` 现有的写法，在 `init` 里取一次 `settings`（见该文件 `transformerObservable`
旁的注释）。

### SourceEditor 基础主题

```swift
/// - Parameter baseThemeDimming: the scheme of `baseTheme` to dim its own colours in — those the
///   profile does not overwrite — for an editor pane without the focus; `nil` keeps them.
static func themeDictionary(from themeProfile: ThemeProfile, basedOn baseTheme: NSDictionary, baseThemeDimming: UnfocusedEditorPaneDimming.ColorScheme?) -> NSDictionary?
```

- `ContentSourceEditorViewController.applyCurrentTheme()` 传 `currentTheme?.isDimmedForUnfocusedEditorPane == true ? (isDark ? .dark : .light) : nil`。
- 非 `nil` 时，先交给 AppUI 的 `UnfocusedEditorPaneDimming.dimmedColorTheme(_:colorScheme:)` 把副本里每个值是四个数字
  （`"r g b a"`，generic RGB，与 `themeString(for:)` 写入的空间相同）的键变暗，再照旧写入主题的颜色（主题的颜色已经
  变暗，不会变两次）：
  - 背景级：`DVTSourceTextBackground`、`DVTConsoleTextBackgroundColor`。
  - 填充级，只在 alpha 为 1 时：`DVTSourceTextCurrentLineHighlightColor`、`DVTSourceTextSelectionColor`、
    `DVTConsoleTextSelectionColor`、`DVTSourceTextBlockDimBackgroundColor`、`DVTMarkupTextBackgroundColor`、
    `DVTMarkupTextBorderColor`、`DVTDebuggerInstructionPointerColor`。
  - 文字级，先压到未变暗的 `DVTSourceTextBackground` 上：其余所有颜色键，以及 `DVTSourceTextSyntaxColors` 的每个值。
  - 字体、`DVTLineSpacing`、`DVTFontAndColorVersion` 不是四个数字，不动。
  前两类里光标、不可见字符、语法色的归类出自 Xcode 对经典主题的转换 [D]；markup、滚动条标记、控制台与指令指针在
  Xcode 的转换里另有出处没逆向，按「底色是填充、其余是前景」归类 [推测]。
- 注释标签（`applyCommentDecorations`）、bridge 的背景色、内容容器与加载遮罩的背景都取 `currentTheme`，已经是
  变暗的颜色，不需另做。宏展开的内嵌视图（`InlineExpansionView`）里的编辑器用同一份主题（`apply(_:lineNumberFont:)`），
  跟着变暗；它的标题与关闭按钮用系统的 `tertiaryLabelColor`，不变，与标签栏一样不属于主题。

### 时机

焦点栏一变就同步发出（Driver 在主线程），不推迟到下一轮 run loop，也不加动画。SourceEditor 换主题会整体重新排版
（Xcode 同样如此）；NSTextView 那一路整篇重新上色，大的 interface 超过 100 ms 会短暂出现加载遮罩（见非目标）。

## 替代方案考量

- **给非焦点栏盖一层半透明遮罩，或降低整栏的 `alphaValue`。** 是 Xcode 不用的做法：遮罩把标签栏、路径栏一起盖暗，
  看起来像是被禁用了；降 `alphaValue` 会让窗口背景透出来，而编辑栏铺在工具栏与滚动边缘效果下面（0089），透出来的
  是模糊层。遮罩还要处理点击穿透，macOS 27 上挡在控件前面的兄弟视图会让控件收不到点击。否。
- **对内容层加 Core Image 滤镜（亮度、饱和度）。** 调的是合成后的像素，不是主题色，结果和 Xcode 的逐色变换不同
  （同一个系数作用在背景和文字上）；还要处理层的合成与滚动边缘效果的捕获。否。
- **只在 `SourceEditorThemeConversion` 里变暗主题字典。** NSTextView 那一路、bridge 的背景色、内容容器与注释标签
  都拿不到变暗的颜色，要在四五处各自变暗。在 `ResolvedTheme` 这一层变暗，所有从主题取色的地方一次到位，字典只
  补它独有的键。否。
- **照搬 Xcode 的工作区主题体系**（对比级别 + 色调的配方、`.focused` 状态的增色、按状态解析）。RuntimeViewer 的
  预设相当于 Xcode 的经典主题，Xcode 自己也是把经典主题转成配方后只套这一步；引入整套体系远超这次的需要。否。
- **由编辑栏视图控制器沿视图层级把状态推给内容视图**（Xcode 的 `dvt_activeState` 做法）。RuntimeViewer 的内容
  ViewModel 已经知道自己在哪一栏，在 ViewModel 里判断能测、也合 MVVM-C；沿视图层级推要么让编辑栏认识每种内容视图，
  要么让内容视图向上找祖先。否。

## 影响

### 用户可见变化

- 编辑区有两栏以上时，没有焦点的各栏里的 interface 变暗：文字、语法色、背景、当前行、选区、行号都按 Xcode 的
  系数变暗，焦点栏照常。点进一栏（或用 Move Focus to Next Editor Pane）它立刻复原，原来的焦点栏立刻变暗。
- Settings › Theme 多一个开关 Dim Unfocused Editor Panes，默认开；关掉后所有栏都照常显示。
- 没有失效的操作习惯：标签栏与路径栏的样子不变，只有一栏时什么都不变。

### 可发现性

默认开，与 Xcode 注册的默认值一样：用户一分栏就看到效果，不需要先知道有这个功能。觉得干扰的用户在 Settings ›
Theme 关掉，位置与 Xcode（主题设置里）对应。

### 数据与配置兼容

`settings.json` 的 `theme` 分支多一个键 `dimsUnfocusedEditorPanes`。没有这个键的旧文件解出 `true`；旧版本 App
读到新文件时忽略这个键，其余设置照常。不需要迁移。

### 平台与最低版本

最低系统版本不变。设置字段在所有平台都有，开关只在 macOS 显示；iOS 与 visionOS 只有一栏，`isEditorPaneDimmed`
永远是 `false`。macOS 15 与 26、27 行为相同（变换不依赖任何系统 API）。

### 发布

不需要新的权限、entitlement 或隐私清单条目；不影响公证与 Sparkle。

## 落地步骤

1. **颜色变换与 `ResolvedTheme` 的变暗变体**（已完成） —— 改动地图第 1–4 行
   - 行为：`oklabMatchesTheReferenceValuesForSRGBRed`
   - 行为：`oklabRoundTripReturnsTheSameSRGBColor`
   - 行为：`backgroundLightnessScalesByPointNineFourInDarkAndPointNineEightInLight`
   - 行为：`fillLightnessScalesByPointNineFiveInDarkAndPointNineSevenFiveInLight`
   - 行为：`textLightnessScalesByPointNine`
   - 行为：`chromaScalesByTheLevelsFactor`
   - 行为：`hueAndOpacityAreKept`
   - 行为：`chromaIsClippedToTheSRGBGamutAtTheNewLightness`
   - 行为：`flattenedComposesOverTheBackground`
   - 行为：`opaqueSelectionAndCurrentLineTakeTheFillFactors`
   - 行为：`translucentSelectionAndCurrentLineStayUnchanged`
   - 行为：`presetBackgroundTakesTheBackgroundFactors`
   - 行为：`translucentTextIsFlattenedOverTheUndimmedBackgroundFirst`
   - 行为：`everyTextSlotIsDimmed`
   - 行为：`fontTraitsIdentifierAndNameAreKept`
   - 行为：`dimmedThemeIsNotEqualToTheUndimmedOne`
   - 行为：`dimmingADimmedThemeReturnsItUnchanged`
   - 行为：`dimmedThemeDrawsTheDimmedPresetsColors`
2. **渲染器接受 `isDimmed`**（已完成） —— 第 5–6 行
   - 行为：`themeIsDimmedWhileIsDimmedIsTrue`
   - 行为：`themeReturnsToNormalWhenIsDimmedTurnsOff`
   - 行为：`rendererWithoutIsDimmedIsNeverDimmed`
   - 行为：`renderedTextIsRebuiltInTheDimmedTheme`
3. **设置与 ViewModel 的判断**（已完成） —— 第 7–11 行
   - 行为：`dimsUnfocusedEditorPanesIsOnForSettingsWrittenBeforeIt`
   - 行为：`dimsUnfocusedEditorPanesRoundTripsThroughTheSettingsFile`
   - 行为：`aSinglePaneIsNeverDimmed`
   - 行为：`aPaneIsDimmedWhileAnotherPaneHasTheFocus`
   - 行为：`focusingThePaneUndimsIt`
   - 行为：`theFocusedPaneOfSeveralIsNotDimmed`
   - 行为：`turningTheSettingOffUndimsEveryPane`
4. **App 接线与 SourceEditor 基础主题**（已完成，手工验收待用户） —— 第 12–16 行
   - 行为：`colorThemeColorsAreDimmedByTheirKeysLevel`
   - 行为：`otherColorsAreDimmedAsText`
   - 行为：`translucentColorThemeTextIsFlattenedOverTheBackground`
   - 行为：`translucentColorThemeFillsStayUnchanged`
   - 行为：`fontsLineSpacingAndVersionAreLeftAlone`
   - 手工验收（交给用户目视）：两栏左右分开、各开一个类型，点左栏右栏变暗、点右栏左栏变暗；只有一栏时不变；
     关掉开关两栏都正常；深浅外观各看一次。
5. **文档**（已完成） —— 第 17–18 行：`RuntimeViewerUsingAppKit/AGENTS.md` 加一句；提案改为实现后的样子，两份索引更新。

构建与测试按远程编译走（包测试过 `queued-build`，App 与 bridge 测试用 Tuist 或 Debug workspace，见项目 `AGENTS.md`）。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要：调用方契约只有 `isEditorPaneDimmed` 与渲染器的 `isDimmed`，写在类型注释里；
  系数与出处在 `UnfocusedEditorPaneDimming` 的注释和 RE 笔记里。
- **有没有引入新术语** —— 预计没有：「编辑栏」「焦点栏」已在用。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-27 | Created as Draft | 用户要求照 Xcode 27 让多栏时没有焦点的编辑栏变暗。先逆向 Xcode 27.2：变暗是 OKLCH 里按对比级别重算主题色，系数、经典主题的规则、范围（不含标签栏与路径栏）、焦点来源与无动画均已核实，方案照此设计 |
| 2026-11-27 | Accepted | 用户批准，开始实现；实现放在功能分支 `feature/dim-unfocused-editor-panes`（worktree `.worktrees/RuntimeViewer-DimUnfocusedEditorPanes`） |
| 2026-11-27 | 基础主题的变暗挪进 AppUI | 提案原以为桥接测试 target 编进了 App 的 `SourceEditorThemeConversion.swift`，实际它只编 bridge 框架，App target 也没有单元测试 target。改为 AppUI 的 `UnfocusedEditorPaneDimming.dimmedColorTheme(_:colorScheme:)`（只在 macOS 编），在 AppUITests 里测，转换只调用它；行为清单换成实际的测试名，原来的「主题色不变暗两次」「不变暗时原样」两条由转换的写法保证（先变暗基础主题再写入已变暗的主题色；`nil` 时不调用），不另测 |
| 2026-11-27 | 宏展开内嵌视图不另做 | `InlineExpansionView` 里的编辑器用同一份主题，跟着变暗；标题与关闭按钮用系统的 `tertiaryLabelColor`，与标签栏一样不属于主题，不变 |
| 2026-11-27 | 验证改用本地依赖模式 | next 的锁文件钉的 MachOSwiftSection（947d5321）用到 MachOKitExtensions 还没发版的 `recordsFunctionAddressReferences`（最新 tag 3.3.0 没有），按锁文件编包或 App 在 next 上同样失败，与本提案无关。本次在 Ultra 上用 `USING_LOCAL_DEPENDENCIES=1` 原地编包、用 `TuistScript.sh --local-dependencies` 编 App |
| 2026-11-27 | 实现完成，待用户看过后收尾 | 五步都已提交。Ultra 上验证：包的相关测试（四个测试 target 里的十个套件，含全部新增测试）通过，Tuist workspace 编 `RuntimeViewer macOS`（Debug，关签名）通过，均为本地依赖模式。文档：`RuntimeViewerUsingAppKit/AGENTS.md` 的编辑栏一节加了一条，说明新的主题化内容要从渲染器的主题取色；不需要另写使用指南或实现说明（契约在类型注释里，系数与出处在 `UnfocusedEditorPaneDimming` 的注释和 RE 笔记里）；没有新术语。界面目视（两栏切换、深浅外观）交给用户 |
