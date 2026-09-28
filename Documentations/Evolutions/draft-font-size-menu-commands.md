# Draft - 字号调整从工具栏挪到 View 菜单

- **状态**: In Progress
- **创建日期**: 2026-09-28
- **最后更新**: 2026-09-28

## 摘要

主窗口工具栏上原有两个字号按钮（`textformat.size.smaller` / `.larger`），占了两个工具栏位，又是低频操作。改成
菜单栏 **View** 菜单里的三条命令：**Increase Font Size**（⌘+）、**Decrease Font Size**（⌘-）、新增的 **Reset Font
Size**（⌘0），工具栏上不再展示。调整的仍是全局的 `Settings.theme.fontSize`，Settings › Theme 里的字号 Stepper 不变。

## 方案

- **工具栏**：`MainToolbarController` 删掉 `fontSizeSmallerItem` / `fontSizeLargerItem`、两个 identifier，以及默认 /
  允许列表与 `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` 里的分支。工具栏不允许用户自定义
  （`allowsUserCustomization = false`），没有需要迁移的已存布局。
- **菜单**：`MainMenuController` 把 `MainMenu.view()` 换成 `viewMenuItem()`，在 UIFoundation 标准 View 菜单的
  Enter Full Screen 之后插入一条分隔线和三项命令，图标沿用原按钮的 SF Symbol，Reset 用 `textformat.size`。
- **动作**：三项的 action 是 `MainWindowController` 上的 `increaseFontSize(_:)` / `decreaseFontSize(_:)` /
  `resetFontSize(_:)`，沿 responder chain 送到 key 文档窗口，与 Export、Reveal in Sidebar Navigator 同一条路。动作
  只把事件推进三个 `PublishRelay`，接到 `MainViewModel.Input` 上。
- **逻辑**：`MainViewModel` 的输入由 `fontSizeSmallerClick` / `fontSizeLargerClick` 改名为 `decreaseFontSize` /
  `increaseFontSize`，8–32 的上下限与 120 ms 节流原样保留（按住快捷键会自动重复）。新增 `resetFontSize`，把字号设回
  `Settings.Theme.default.fontSize`（13），不节流。

**未经询问采用的假设：**

- 快捷键与系统 Format › Font › Bigger / Smaller 相同，用 `+` / `-`。`+` 在美式键盘上要按 ⇧⌘=；单按 ⌘= 不触发。
  不另加 ⌘= 的别名：隐藏的菜单项不参与快捷键匹配（Apple 文档 `NSMenuItem.isHidden`），别名只能是一条看得见的重复项。
- 没有文档窗口为 key 时（例如只有设置窗口在前），三项置灰，不另做 App 级的处理。
- 不按上下限置灰 Increase / Decrease：到了边界再按只是无效果。
- 已确认同名 action 不会被内容区先截走：Xcode 27 的 `SourceEditor` / `SourceModel` / `SourceModelSupport` /
  `_CodeCompletionFoundation` 二进制里没有 `increaseFontSize` / `decreaseFontSize` / `resetFontSize` 字符串（只有
  `setFontSize:`），macOS 27.0 的 AppKit ObjC 头文件导出里也没有。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-28 | Created，直接 In Progress | 用户原话：「把字体增大和缩小挪到 MainMenu 快捷键那边，不要在 Toolbar 展示」；方案在对话里获批 |
| 2026-09-28 | 放在 View 菜单，不新建 Editor 菜单 | App 没有 Editor 菜单，为三项命令新开一个顶层菜单不划算 |
| 2026-09-28 | 加 Reset Font Size（⌘0） | 用户在方案确认时同意加上 |
| 2026-09-28 | 动作挂在 `MainWindowController`，不做 App 级控制器 | 上下限与节流已在 `MainViewModel`，沿用现有菜单动作的 responder chain 写法，改动最小 |
