# 主题外观配置（Theme Settings Panel）设计

## 背景与动机

此前内容视图的语法高亮主题是「单一硬编码」的：`RuntimeViewerApplication/Theme/ThemeProfile.swift`
里只有一个 `XcodePresentationTheme`，所有颜色用 `#colorLiteral(light:dark:)` 写死，按
`SemanticType` 分组返回；它存在 `AppDefaults.themeProfile`（RxSwift `@UserDefault`）里，用户除了
工具栏的字号 +/- 之外无法做任何调整。

目标：在「设置」中新增一个主题面板，对标 CodeEdit 的 Theme 设置——以主题列表 + 预览的形式呈现，
支持自定义颜色编辑；并把现有的 Xcode 配色转为一个内置「预设（preset）」。

## 范围决策（已与需求方确认）

1. **功能层级**：预设选择 + 颜色自定义编辑。不做主题文件的导入/导出，也不做模糊搜索；自定义主题
   直接随 `Settings` 的 JSON 一起持久化。
2. **外观模型**：保持「单一自适应主题」。每个主题的每个色槽都内置 light + dark 两个颜色，渲染时走
   `NSUIColor(light:dark:)`，跟随 General 里的外观开关自动换色。**不**采用 CodeEdit 的「浅/深独立
   主题、跟随系统切换」模型。
3. **内置预设**：仅把现有 Xcode 配色转为一个只读内置预设 `Settings.Theme.Preset.xcode`。

## 总体架构

把主题从 `AppDefaults` 迁入 `Settings` 系统，与 General/Indexing 等设置页共用同一套机制
（`@Observable Settings` + `@Codable` JSON 自动持久化 + `@AppSettings` 绑定）。数据流：

```
ThemeSettingsView (SwiftUI, @AppSettings(\.theme))
        │ 选择 / 编辑颜色 / 字号
        ▼
Settings.theme  (@Observable @Codable → settings.json 自动保存)
        │ withObservationTracking 桥接成 Rx Observable（与 transformerObservable 同款）
        ▼
ContentTextViewModel.themeObservable  →  ResolvedTheme (ThemeProfile)
        │ combineLatest 重新渲染 + 绑回 $theme（背景色）
        ▼
SemanticString.attributedString(for: ThemeProfile)  →  内容高亮实时刷新
```

要点：
- 字号改为**全局**设置 `Settings.theme.fontSize`（不再绑在单个主题上），工具栏 +/- 直接读写它，
  范围 clamp 到 8…32。
- 内置预设由代码定义、不进 JSON；只有用户自定义预设（`customPresets`）被持久化。
- 编辑内置预设走 CodeEdit 行为：内置只读，需先「Duplicate」成自定义副本再编辑。

## 数据模型（`RuntimeViewerSettings`，纯数据，不依赖 Semantic）

新增 `Settings+Theme.swift`：

- `Settings.Theme`：`selectedPresetID` / `fontSize` / `customPresets`，外加 `builtinPresets`、
  `allPresets`、`selectedPreset` 等派生属性。
- `Settings.Theme.Preset`（`Identifiable, Hashable, Sendable`）：`id` / `name` / `isBuiltin` + 9 个
  色槽（`background` / `selection` / `text` / `keyword` / `typeName` / `declaration` /
  `comment` / `number` / `error`）。
- `Settings.Theme.Style`（`Hashable, Sendable`）：`light` / `dark` 两个颜色 + `isBold` / `isItalic`。
- `Settings.Theme.ColorValue`（`Hashable, Sendable`）：可 Codable 的 sRGB 分量（`red/green/blue/alpha`，
  取值 0…1）。

并在 `Settings.swift` 注册 `@Default(Theme.default) var theme`（带 `didSet { scheduleAutoSave() }`）
与 `load()` 中的 `theme = decoded.theme`。

> **MetaCodable 坑点**：`@Codable` 宏把 Codable 实现生成到独立的 `@__swiftmacro_…` 文件里，那里按
> **字面写法**引用类型名。嵌套类型在该文件的作用域里不可见，因此 `Preset` / `Style` 内引用
> `Style` / `ColorValue` 时**必须用全限定名** `Settings.Theme.Style` / `Settings.Theme.ColorValue`，
> 否则报 `cannot find 'Style' in scope`。这与 `Settings+Types.swift` 中 `Indexing` 的注释一致。

## 渲染层（`RuntimeViewerApplication`）

- 新增 `Theme/ThemePreset+ThemeProfile.swift`：`ResolvedTheme`（持有选中的 `Settings.Theme.Preset` +
  全局 `fontSize`）实现 `ThemeProfile`。
  - `style(for:)` 把 `SemanticType` 映射到 9 个色槽，分组与旧硬编码主题完全一致。
  - `font(for:)` 用 monospaced 字体，`isBold → .semibold`，`isItalic` 通过 font descriptor 的
    italic 符号特征叠加（平台分支处理 AppKit / UIKit 的可选性差异）。
  - `ColorValue.nsuiColor` 用 sRGB 构造（AppKit 走 `srgbRed:`），`Style.nsuiColor` 走
    `NSUIColor(light:dark:)`。
  - `ResolvedTheme.fallback` = Xcode 预设 @ 13pt，作为初值与无 `Settings` 平台（UIKit/Catalyst）的兜底。
- `ThemeProfile.swift`：协议精简为只读（移除 `set`、`fontSizeSmaller/Larger`、`Codable` 约束），并删除
  死代码 `AnyThemeProfile` 与 `XcodePresentationTheme`（其配色已平移进 `Preset.xcode`）。
- `ContentTextViewModel`：用 `themeObservable`（`withObservationTracking` 监听 `Settings.theme`，发出
  `ResolvedTheme`）替换 `appDefaults.$themeProfile`，并把它 `bind(to: $theme)`，让背景色也随主题/颜色
  编辑实时刷新。
- `AppDefaults`：移除 `themeProfile` 字段。
- `MainViewModel`（app target）：字号 +/- 改写 `Settings.shared.theme.fontSize` 并 clamp。

## 设置面板 UI（`RuntimeViewerSettingsUI`）

新增 `Components/ThemeSettingsView.swift`（`#if os(macOS)`），并在 `SettingsRootView` 的
`SettingsPage` 枚举插入 `case theme`（图标 `paintpalette`，位于 General 之后）。

- **主题列表**：`ForEach(theme.allPresets)` → `ThemeRow`：选中勾 + 名称（内置标 "Built-in"）+ 一排配色
  预览小方块（按当前 `colorScheme` 取 light/dark 变体）+ `⋯` 菜单（Set as Active / Edit… / Duplicate /
  Delete；内置项无 Edit/Delete）。点行即选中。
- **字号**：`Stepper` 绑 `$theme.fontSize`（8…32）。
- **颜色编辑 Sheet**（`ThemeDetailsView`，仅自定义主题）：顶部 `Light | Dark` 分段控件切换正在编辑的
  变体；中部实时预览（用 SwiftUI `Text` 按当前变体的色槽手绘一段示例签名，自带预览，避免 SettingsUI
  反向依赖 Application）；下部 `Form` 列出各色槽的 `ColorPicker`（token 类附 B/I 开关）。draft 改动通过
  `onChange(of:)` 实时回写 `customPresets`，所以选中主题时正在编辑的颜色会即时反映到打开的文档。
- SwiftUI `Color` ↔ `ColorValue` 转换通过 `NSColor(color).usingColorSpace(.sRGB)` 完成（仅 macOS）。

## 迁移与兼容

- 旧的 `themeProfile` UserDefault 直接弃用；新系统默认选中 Xcode 预设，视觉零变化。**未**迁移用户之前
  用工具栏调过的字号（重置回默认 13pt）——属可接受的轻微回退。
- 所有新文件都在 SPM 包内（按目录自动纳入编译），**无需改动 Xcode 工程文件**。

## 文件清单

新增：
- `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Theme.swift`
- `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Theme/ThemePreset+ThemeProfile.swift`
- `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift`

修改：
- `RuntimeViewerSettings/Settings.swift`（注册 `theme` 字段 + `load()`）
- `RuntimeViewerSettingsUI/SettingsRootView.swift`（注册 `.theme` 页）
- `RuntimeViewerApplication/Theme/ThemeProfile.swift`（精简协议 + 删死代码）
- `RuntimeViewerApplication/AppDefaults.swift`（移除 `themeProfile`）
- `RuntimeViewerApplication/Content/ContentTextViewModel.swift`（主题来源换为 `Settings`）
- `RuntimeViewerUsingAppKit/Main/MainViewModel.swift`（字号改写 `Settings`）

## 构建验证

通过同级 `../MxIris-Reverse-Engineering.xcworkspace` 用 XcodeBuildMCP CLI 构建（Debug）：
`RuntimeViewerApplication`、`RuntimeViewerSettingsUI`、完整 `RuntimeViewer macOS` 三个 scheme 均编译/
链接通过。

## 后续可做（未纳入本次范围）

- 主题文件的导入/导出（`.json`），以便分享与备份。
- 编辑颜色时对 `themeObservable` 做去抖，减少颜色拖拽期间内容管线的重复 interface 拉取。
- 把 `selectionBackgroundColor` 真正接到文本视图的选区高亮（目前协议保留但内容视图未消费）。
- 追加更多内置预设（如 Default Light/Dark、Solarized 等）。
