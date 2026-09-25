# Draft - 运行时对象列表的图标加 tooltip

- **状态**: In Progress
- **创建日期**: 2026-09-25
- **最后更新**: 2026-09-25

## 摘要

侧栏、Open Quickly、Inspector 的 Relationships / Specializations、泛型特化的类型选择器，这些列表共用
`RuntimeObjectCellView`，每行最多三个图标：主图标（对象种类）、第二图标（另一面的角标）、第三图标（泛型 /
特化）。它们全靠一两个字母加颜色区分：ObjC 类和 Swift 类都是 `C`，只差颜色；Swift 的 extension 和
conformance 都是 `Ex`；粉、蓝、橙三种 `C` 角标各有含义，界面上却无从得知。本提案给三个图标位都加上
tooltip，用 UIFoundation 的自定义 tooltip 样式显示（圆角，字号取 UIFoundation 预设的 12pt），同一行
标题与副标题的 tooltip 也统一成这个样式。

## 方案

**文案与图标在同一处决定。** `RuntimeObjectIcon` 新增 `tooltip(for:)`（直接用
`RuntimeObjectKind.description`）、`secondaryTooltip(for:)`、`tooltipForGeneric`、`tooltipForSpecialized`。
`secondaryIcon(for:)` 与 `secondaryTooltip(for:)` 共用私有的 `secondaryBadge(for:)`，三个标记的优先级只写
这一处，图标与文案不可能选到不同的角标。

| 图标 | tooltip |
|------|---------|
| 主图标 | `RuntimeObjectKind.description`，如 `Swift Class`、`Swift Struct Conformance` |
| 粉 `C`，ObjC 类一侧 | `Implemented in Swift (@objc @implementation)` |
| 粉 `C`，Swift extension 一侧 | `Implements an Objective-C Class (@objc @implementation)` |
| 蓝 `C` | `Also Listed as a Swift Class` |
| 橙 `C` | `Also Listed as an Objective-C Class` |
| `G` | `Generic Type` |
| `Sp` | `Specialized Generic Type` |

**数据与视图。** `RuntimeObjectCellAppearance` 增加 `primaryTooltip` / `secondaryTooltip` /
`tertiaryTooltip`，初始化器改由 `@MemberwiseInit(.public)` 生成；四个 cell ViewModel（Sidebar、Inspector
两个、类型选择器）填入。`RuntimeObjectCellView` 把它们设到三个图标的 `toolTip` 上，三个图标与两个标签都挂
`view.customTooltipStyle = .runtimeObjectCell`（FrameworkToolbox 的 `@dynamicMemberLookup` 转发到
`view.box`）：在 `.default` 预设上只把圆角改为 8，字号用预设自带的 12pt。

**为什么基于 `.default`，而不是在 `.system` 上只设圆角。** 只要设了圆角，UIFoundation 就把系统的毛玻璃背景换成普通
layer；这时若样式不给背景色，AppKit 会用私有的 `toolTipColor` 平涂（`-[NSToolTipManager
_drawToolTipBackgroundInView:]`，见 UIFoundation `Researchs/AppKit-NSToolTipManager-Internals.md` §3.2），
而那个颜色是配毛玻璃用的。`.default` 自带实心背景、细边框与轻阴影。

**安装 hook。** `AppDelegate.applicationDidFinishLaunching` 调 `CustomToolTipManager.install()`，与
`NSToolbarItemViewerOverflowFix.install()` 同属一次性安装。不装它，单个视图上的样式不生效。它 isa-swizzle
的是整个进程共用的 `NSToolTipManager.shared`，但全局样式保持 `.system`，其余 tooltip 的外观不变。

**依赖。** UIFoundation 的 `AppleInternal` trait 早已开启（`GlassEffectReplicaView` 出自同一模块），tooltip
API 自 UIFoundation 0.12.0 起就在。`RuntimeViewerPackages` 对 UIFoundation 的最低版本从 `0.34.0` 抬到
`0.36.1`，原因是下一节的 `Label` 修复。

**不做。** 标签栏、导航历史菜单、minimap 浮层里的同款图标不加 tooltip；UIKit 版不动。

**标题与副标题的 tooltip 修在 UIFoundation。** UIFoundation 0.36.0 及以前，`Label` 只在 `stringValue` 的
setter 里把文字同步成 tooltip（`syncStringValueToolTip`），而 cell view 设标题、副标题一直走
`attributedStringValue`。AppKit 的 `attributedStringValue` setter 不经过 `stringValue`，所以这两个标签从
5ccddf15（2026-05-16 为它们打开这个开关）起就从没有过 tooltip。这一点起初没能反查（本机 AppKit 导出的
`NSControl.h` 没列出 `_NSControlValueAccessing` 协议声明的属性，拿不到实现地址，`runtime-viewer-cli` /
`objc-section` 也都未安装），最后由 UIFoundation 的回归测试实测确认：`LabelToolTipTests` 里「attributed
string 成为 tooltip」一条，在没有修复的 `Label` 上失败。UIFoundation 0.36.1 让 `Label` 同样同步
`attributedStringValue`；RuntimeViewer 抬 pin 后不再手动设这两个 `toolTip`，两个多余的
`syncStringValueToolTip = true`（本就是默认值）也删掉了。

连带变化：RuntimeViewer 里另外三处用 `attributedStringValue` 设文字的 `Label` 也会开始显示自身文字的 tooltip——
侧栏根列表的标题（`SidebarRootTableCellView`）、泛型特化面板的说明（`SpecializationViewController`）、后台索引
弹出框的计数（`BackgroundIndexingPopoverViewController`）。不想要的可以在该标签上关掉 `syncStringValueToolTip`。

**验证。** `RuntimeObjectIconTests` 钉住文案：每种 kind 的文案互不相同、每种角标的文案、没有角标就没有文案、
两个标记同时出现时文案跟着粉色角标走。三个 cell ViewModel 各一条「图标带着对应 tooltip」，侧栏另有一条
「同时是泛型和特化时，图标与文案都取特化」。UIFoundation 0.36.1 的 `LabelToolTipTests` 修复前失败、修复后
通过，UIFoundation 全部测试（swift-testing 173 个、XCTest 9 个）与全 trait 构建通过。RuntimeViewer 抬 pin 后
`RuntimeViewerApplicationTests` 全部 218 个通过，Debug 设置文件的 SHA 前后一致；App（`RuntimeViewer.xcworkspace`、
`RuntimeViewer macOS`、Debug、arm64）编译通过，包与 App 实际解析到的都是 UIFoundation 0.36.1，改动的文件没有新
警告。图标 tooltip 的样式经用户在 App 里看过；改为依赖 0.36.1 之后的标题 tooltip 还没有人工复看。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-25 | Created as Draft | 用户：「给RuntimeObjectIcon加一下tooltip」；`RuntimeObjectCellAppearance` 里的三个 tooltip 字段是用户先加的 |
| 2026-09-25 | 用 UIFoundationAppleInternal 的 `customTooltipStyle`，加圆角、加大字号 | 用户：「tooltip用UIFoundationAppleInternal里面的customTooltipStyle，加圆角和加大字体」 |
| 2026-09-25 | 样式基于 `.default`，13pt、圆角 8 | 只设圆角会丢掉系统毛玻璃、落到私有 `toolTipColor` 平涂，见「方案」；两个数值是提议值，用户认可 |
| 2026-09-25 | 文案与图标同处决定，第二图标的优先级只写一处 | 与 [draft-objc-implementation-class-badge](draft-objc-implementation-class-badge.md) 收拢 `secondaryIcon(for:)` 同一理由：互斥规则只该有一处实现 |
| 2026-09-25 | 标题与副标题标签的 tooltip 也用同一样式 | 用户：「可以，一起改」 |
| 2026-09-25 | Accepted，随即 In Progress | 用户：「可以，一起改，先这样吧」 |
| 2026-09-25 | 标题与副标题的 tooltip 在 cell 里显式设置，不再依赖 `syncStringValueToolTip` | 实现时发现该同步只挂在 `stringValue` 的 setter 上，标题却走 `attributedStringValue`，是否生效无法反查确认。用户：「标题加上吧」。副标题同一个问题、当初也是一起打开的，一并处理 |
| 2026-09-25 | 字号回到 `.default` 自带的 12pt，只保留圆角 8；`view.box.customTooltipStyle` 简写为 `view.customTooltipStyle` | 用户看过实际效果后自行微调：「我微调了一下，可以了」「那个可以走dynamicMemberLookup，可以省掉box」 |
| 2026-09-25 | 根因修在 UIFoundation：`Label` 同步 `attributedStringValue`（用户本地改动，未发版） | cell 里的显式设置保留到抬 pin 为止，保证用已发版的 UIFoundation 构建时标题也有 tooltip |
| 2026-09-25 | 发布 UIFoundation 0.36.1（`Label` 修复 + `LabelToolTipTests`），最低版本抬到 `0.36.1`，删掉 cell 里手动设 tooltip 的代码 | 用户：「UIFoundation的更改还没发版，你发一版然后把手动设置tooltip的代码删掉」。测试先在未修复的 `Label` 上失败、修复后通过，顺带实测确认了 AppKit 的 `attributedStringValue` setter 不经过 `stringValue` |
