# 0010 - 把接口导出成图片

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-08-15
- **最后更新**: 2026-08-15
- **所属愿景**: 无
- **关联提案**: [0009](0009-content-editor-engine-selection.md)（内容视图编辑器选型）
- **实现分支 / PR**: 待定
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

把当前正在看的接口渲染成一张带主题配色的图片（PNG），用于贴进 issue、笔记、聊天。
现有的 Exporting 流程只产出文本文件。

本提案需要拍板的是**用哪条渲染路径**：从生成侧已有的 `NSAttributedString` 自己排版（方案 A），
还是借 `SourceEditorView` 的截图 API 做到所见即所得（方案 B）。两者的差别不只是工作量，
还决定了这个功能**是否要求用户装 Xcode**。

## 动机

分享一段接口目前只能复制文本。粘到 issue 或聊天里之后：配色没了、缩进经常被吃掉、
超长的协议列表折行位置随对方的窗口宽度乱变。截图能解决，但手动截图要先把窗口调到合适宽度、
滚到合适位置，超过一屏的类型根本截不全。

现有的 Exporting 流程（`RuntimeViewerUsingAppKit/Exporting/`）产出 `.h` / `.swift` 文本文件，
没有图片这一档。

**命名注意**：现有导出流程里的 "Image" 指的是 **Mach-O image**
（`BatchExportingImageSelectionViewController` 选的是要导出哪些镜像）。图片这一档不能复用
这个词，否则同一个流程里 "Image" 有两个意思。本提案用 **Snapshot** 指代图片产物。

## 前期调研

### 现状代码

- 文本导出：`RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewModel.swift`，
  产出格式由 `ExportFormat`（`.directory` / `.singleFile`）决定。
- 内容面板已经持有渲染好的富文本：`ContentTextViewModel.RenderedInterface` 同时带
  `semanticString` 与 `attributedString`（0009 落地时加的）。
- 行号绘制的现成代码在 `ContentLineNumberRulerView.swift`（243 行，`NSRulerView` 子类），
  是 `NSTextView` 那条路径用的。

### `SourceEditor` 提供的截图 API（均已确认导出 dispatch thunk）

```swift
func editorViewSnapshots(in: [__C.CGRect]) -> [__C.NSImage]?
func finalImageHeight(for: Swift.Range<Swift.Int>) -> CoreGraphics.CGFloat
func snapshotLineRange(for: Swift.Range<Swift.Int>) -> Swift.Range<Swift.Int>?
func snapshotPadding() -> CoreGraphics.CGFloat
func unfoldingEditorView() -> SourceEditor.SnapshotSourceEditorView
```

配套的 `SnapshotSourceEditorView` 是 `SourceEditorView` 的子类：

```swift
class SnapshotSourceEditorView: SourceEditor.SourceEditorView {
    weak var otherEditor: SourceEditor.SourceEditorView?
    @objc init(frame: __C.CGRect, sourceEditorView: SourceEditor.SourceEditorView)
    func mirrorScrollState()
    func forceViewportLayout()
    override func snapshotLineRange(for: Swift.Range<Swift.Int>) -> Swift.Range<Swift.Int>?
}
```

也就是说框架自己的做法是：**照着现有编辑器造一个镜像视图，强制它布局任意视口，再分块截图**
—— `editorViewSnapshots` 收一个 rect 数组正是为了分块。

### 关键反证：`editorViewSnapshots` 内部就是 `cacheDisplay`

反汇编确认它调用的是
`bitmapImageRepForCachingDisplayInRect:` + `cacheDisplayInRect:toBitmapImageRep:`，
然后 `NSImage.initWithSize:` / `addRepresentation:` / `drawInRect:fromRect:operation:fraction:`。

**这正是本项目已经踩过的那条离屏渲染路径**（见 0009「离屏判据不可靠」）：它抓不到 Metal
图层。实测 minimap 的缩略文本走 `MinimapMetalLinesLayer`，`cacheDisplay` 抓出来是空白。
所以方案 B 即使做出来，也必须在截图时关掉 minimap，且**不能假设所见即所得对每个图层都成立**。

### 未验证的推测

- `forceViewportLayout()` 能否一次性布局整份文档（十万行级）**未验证**。`editorViewSnapshots`
  收 rect 数组这一点暗示框架自己也是分块的，但分块的边界由谁决定没查。
- `SnapshotSourceEditorView` 的重建成本**未验证**。它是 `SourceEditorView` 的子类，
  而 `SourceEditorView` 有第二个 designated init（`init(frame:sourceEditorScrollViewClass:)`），
  子类的两个 `@objc init` 都得声明对，否则按 0009 记录的第三条规律，会在**释放时**崩。

## 提议方案

### 方案 A（推荐）—— 从已有的 `NSAttributedString` 自己排版

内容面板已经持有 `renderedInterface.attributedString`。把它放进一个固定宽度的
TextKit 容器排版，量出总高，画进位图，写 PNG。行号、内边距、背景色自己画。

**优点**

- **不依赖 SourceEditor**。没装 Xcode 的用户、关掉开关的用户都能用；`NSTextView` 那条路径
  也一样能用。这是决定性的一条 —— 导出是个正经功能，不该只对开了 opt-in 开关的人存在。
- 输出可控：宽度、边距、是否带行号、是否带文件名页眉，全是我们自己的参数，
  不受编辑器当前窗口宽度和滚动位置影响。
- 没有私有 API，不受 Xcode 版本漂移影响。

**缺点**

- 拿不到编辑器特有的视觉：折叠状态、scope guides、当前行高亮、sticky header。
- 行号要自己画（但 `ContentLineNumberRulerView` 已有可复用的度量逻辑）。

### 方案 B —— 借 `SourceEditorView` 的截图 API

按框架自己的路子：`unfoldingEditorView()` 造镜像视图 → `forceViewportLayout()` →
`editorViewSnapshots(in:)` 分块截图 → 拼接。

**优点**

- 所见即所得：折叠状态、scope guides、mark separators 原样进图。

**缺点**

- **只在启用了 SourceEditor 时可用**，功能的存在与否取决于一个 opt-in 开关，
  设置面板要为此解释一堆前提。
- 要重建 `SnapshotSourceEditorView`，含两个 `@objc` designated init，是 0009 记录过的
  「写错只在释放时崩」的高风险类别。
- 底层是 `cacheDisplay`，本项目已有它渲染结果与真实窗口不一致的实测记录。

### 非目标

- **不做 PDF / SVG**。先只做位图，矢量输出是另一件事。
- **不做批量导出成图片**。`BatchExporting` 是按镜像批量产文本文件的流程，图片按张分享，
  批量产出几千张 PNG 没有使用场景。
- **不做自定义水印 / 装饰边框**。产物就是接口本身。
- **不改生成器**。图片内容与文本导出内容一致，不为图片单独调整格式。

## 详细设计

（待方案确定后填写。方案 A 的骨架：）

```swift
/// Renders a themed picture of an interface. Deliberately independent of which content view
/// is in use — it takes the attributed string the generator already produced.
struct InterfaceSnapshotRenderer {
    struct Options {
        var width: CGFloat
        var showsLineNumbers: Bool
        var scale: CGFloat          // 1 for @1x, 2 for @2x
        var padding: NSEdgeInsets
    }

    func render(_ attributedString: NSAttributedString, theme: ThemeProfile, options: Options) throws -> NSBitmapImageRep
}
```

## 替代方案考量

**直接对内容面板 `cacheDisplay` 截一张。** 只能截到可见区域，超过一屏的类型截不全 ——
而值得分享的接口基本都超过一屏。否。

**把文本渲染成 HTML 再截图。** 要引入一个渲染引擎（WebKit）和一套 CSS 主题映射，
为一个导出功能引入的复杂度不成比例。否。

**用系统的 `NSAttributedString` → PDF 再转位图。** 多绕一层，且 PDF 的分页会在意料之外的
位置切断代码。否。

## 影响

### 用户可见变化

内容面板新增一个导出图片的入口（菜单项 + 右键菜单），产出一张 PNG。
现有的文本导出流程与快捷键不变。

### 可发现性

菜单项放在现有 Export 附近。**不设默认开关** —— 它是一个动作，不是一个模式。
若采纳方案 B，则在没有启用 SourceEditor 时该菜单项需要禁用并说明原因，
这本身就是方案 A 更好的一个理由。

### 数据与配置兼容

新增几条导出偏好（宽度、是否带行号），走现有 `@UserDefault(key: ExportingDefaultsKey…)`
的模式，缺键时用默认值，不影响已有偏好。

### 平台与最低版本

不变。方案 A 无新增依赖；方案 B 沿用 0009 已有的「需要 Xcode」约束，不引入新的。

### 发布

无新增 entitlement 或隐私清单条目。不影响公证与 Sparkle。

## 落地步骤

1. 拍板方案 A / B。
2. 渲染器本体 + 单元测试（给定文本与主题，输出尺寸与若干采样点颜色符合预期）。
3. 接入内容面板的菜单项与保存面板。
4. 导出偏好落到 `ExportingDefaultsKey`。
5. 收尾：判断是否需要配套实现说明；登记新术语（Snapshot）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-15 | Created as Draft | 起因是 0009 落地过程中查到 `SourceEditorView` 有成套的截图 API。查证后发现其底层是 `cacheDisplay`，与本项目已记录的离屏渲染不可靠是同一条路径，因此提出不依赖该框架的方案 A 并推荐之。 |
