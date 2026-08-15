# 0009 - 内容视图编辑器选型：继续 NSTextView 还是改用 Xcode SourceEditor

- **状态**: Accepted（采纳方案 B）
- **作者**: JH
- **创建日期**: 2026-08-15
- **最后更新**: 2026-08-15
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: 待定
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

内容视图（显示 interface 文本的那个主面板）目前基于 `NSTextView` + TextKit 2，行号靠自绘
ruler，跳转靠 `NSAttributedString` 的 `.link` 属性。本提案给出两个方案并请求裁决：

- **方案 A —— 继续 NSTextView**：在现有实现上增量补齐缺失能力（代码折叠、sticky header、
  查找栏、⌘-hover 高亮），全部自己写。
- **方案 B —— 改用 Xcode 私有 `SourceEditor` 框架**：运行时从用户已安装的 Xcode 加载
  `SourceEditor` 等 7 个框架，用手写的 `.swiftinterface` 子集调用，直接获得 Xcode 编辑器
  的全部能力与观感。

方案 B 的可行性已通过独立 spike 实测确认（渲染、Xcode 原版语法高亮、⌘-hover 下划线、
⌘-click 符号解析、性能对比全部跑通），**但它引入一个新的硬约束：用户必须安装 Xcode**。
这个约束是否可接受，是本提案唯一需要决策者拍板的问题。

## 动机

### 现状

| 能力 | 实现位置 | 状态 |
|---|---|---|
| 文本渲染 | `ContentTextView.swift`（10 行，`NSTextView` 子类） | 可用 |
| 语法高亮 | 生成侧产出 `NSAttributedString`，`ContentTextViewController.swift:103-104` 直接灌进 `textStorage` | 可用，且是**语义级**高亮 |
| 行号 | `ContentLineNumberRulerView.swift`（243 行自绘 `NSRulerView`） | 可用 |
| 类型跳转 | `.link` attribute 携带 `RuntimeObject`，`ContentTextViewController.swift:145` 取出 | 可用，但视觉是链接样式 |
| 代码折叠 | — | **缺失** |
| Sticky structure header | — | **缺失** |
| 查找栏 | — | **缺失** |
| Scope guides / 缩进参考线 | — | **缺失** |
| ⌘-hover 符号下划线 | — | **缺失** |
| Minimap | `RuntimeViewerUI` | 可用（自己实现） |

### 卡在哪里

1. **缺失的能力都不便宜**。代码折叠要自己做折叠区间计算与行映射；sticky header 要维护滚动
   位置到结构层级的映射；查找栏要自己做 UI 与 TextKit 2 的高亮联动。每一项都是数百行起步，
   且都要在 TextKit 2 上重新验证边界情况。

2. **「和 Xcode 一样的跳转手感」自己写不出来**。当前实现能跳转，但视觉是 `.link` 的链接样式；
   Xcode 的 ⌘ 按下时符号下划线 + 手型光标 + 松开消失，是编辑器内部与命中测试、光标管理、
   重绘节流耦合的效果，靠外部叠加做不到等价。

3. **大文档滚动会掉帧**。TextKit 2 的惰性布局把成本推到滚动时：5MB 文档下最坏一帧 25.08 ms，
   超出 60 fps 的 16.7 ms 预算（实测数据见下）。

## 前期调研

以下每条都是本次实测或反汇编查证的结论，**未标注「推测」的都已验证**。

### 框架依赖链是干净的

`SourceEditor.framework` 只依赖 `_CodeCompletionFoundation` 与系统框架，**完全不依赖
DVTFoundation / IDEKit**（`otool -L` 查证）。这是 Apple 为内部的 SourceEdit.app 抽出来的结果。
最小可用集合 7 个，都在 `/Applications/Xcode.app/Contents/SharedFrameworks/`：

```
SourceEditor  SourceModel  SourceModelSupport  SymbolCache
SymbolCacheSupport  SymbolCacheIndexing  _CodeCompletionFoundation
```

`SourceEditorSwiftSupport` 需要 `SourceKitSupport`，那是代码补全 / 语义服务，纯展示用不到。

### 框架开启了 library evolution

导出符号中有 1515 个 property descriptor 与 2218 个 dispatch thunk（`nm -gU` + demangle 统计）。
这意味着调用方通过重建的接口访问时走 resilient 路径，**Xcode 升级改动内部布局不会导致崩溃**；
只有 API 真被改名或删除才会断，且表现为 dyld 找不到符号，而非内存布局错乱。

### 但不提供任何可 import 的模块

框架内没有 `.swiftmodule`、`.swiftinterface`、头文件。ObjC 那条捷径也走不通：
`SourceEditorView` 暴露给 ObjC 运行时的只有 `NSResponder` 的动作方法，`dataSource` / `delegate` /
`init` 全是纯 Swift；`SourceEditorDataSource` 直接继承 `_TtCs12_SwiftObject`，一个 `@objc` 方法都没有。

**结论**：必须手写 `.swiftinterface` 子集。可行性已验证 —— 见「详细设计」。

### spike 实测结论

独立测试程序（不接入本仓库）已验证：

| 验证项 | 结果 |
|---|---|
| 文本渲染 | 通过 |
| 语法高亮 | 与 Xcode Default (Dark) 完全一致 |
| ⌘-hover 符号下划线 | 通过，开启即有，无需额外代码 |
| ⌘-click 符号解析 | 通过，返回精确 token 范围 |
| 编译 / 链接 | 零错误，接口子集约 130 行 |

### 性能实测

同一份文本分别灌进两个引擎，测装载、首屏、逐页滚动 120 页。
**对比对 SourceEditor 不公平**：它在装载时完成了词法分析与语法着色，而 `NSTextView`
装的是纯文本、零高亮。

1MB / 20581 行：

| 指标 | NSTextView (TextKit 2) | SourceEditor |
|---|---|---|
| 装载 | **11.0 ms** | 90.4 ms |
| 首屏可见 | 11.1 ms | **0.8 ms** |
| 滚动 p50 | 5.48 ms | **3.67 ms** |
| 滚动 p95 | 11.85 ms | **6.57 ms** |
| 滚动最坏帧 | 16.02 ms | **7.69 ms** |

5MB / 98541 行：

| 指标 | NSTextView (TextKit 2) | SourceEditor |
|---|---|---|
| 装载 | **18.4 ms** | 384.1 ms |
| 首屏可见 | 11.3 ms | **0.8 ms** |
| 滚动 p50 | 5.49 ms | **4.29 ms** |
| 滚动最坏帧 | **25.08 ms**（掉帧） | **9.43 ms** |

要点：

- SourceEditor 的**首屏耗时不随文档增大而变化**，恒定 0.8 ms。
- 5MB 时 TextKit 2 最坏帧 25.08 ms 会掉帧，SourceEditor 9.43 ms 稳在预算内。
- 代价是装载：5MB 需要 384 ms，因为它把全量 tokenize 与着色都做了。

**两项数据明确标记为不可信**：

- `fullLayout` 不可比 —— TextKit 2 惰性布局，报告的文档高度是估算值（1495029 对
  SourceEditor 的 1507905），那 28 ms 并未真正布局 98000 行，账在滚动时还。
- **内存不可信** —— 滚 120 页后 TextKit 2 +619 MB、SourceEditor +1748 MB，两边都异常。
  已验证不是绘制缓存（关闭 `displayIfNeeded` 后数字几乎不变），判断为离屏窗口无内存压力、
  缓存从不回收所致。**绝对值不可用**；相对比例 SourceEditor ≈ TextKit 2 的 2.8 倍值得警惕，
  **落地前必须在真实 App 内复测**。

### ⌘-click 的真实入口（反汇编查证）

`SourceEditorViewCodeNavigationHandler` 看似是跳转入口，**实则是 Vim 模式专用**：
IDA 交叉引用显示，读取 `codeNavigationHandler` ivar 的调用方全部是 `Vi*CommandHandler`
（`ViJumpToDefinitionCommandHandler`、`ViShowQuickHelpCommandHandler` 等）。

`SourceEditorView.mouseDown(with:)` 反编译后只做两件事：

```
遍历 eventConsumers → handleMouseEvent(event, in: view)   // 返回 true 即消费
否则 → selectionController.handleMouseEvent(_:in:)
```

**框架不自带 ⌘-click 检测**，那部分逻辑在使用方（Xcode 自己、SourceEdit.app 自己）。
但框架提供了难的部分：

```swift
sourceEditorView.positionAtPoint(_ point: CGPoint) -> SourceEditorPosition?
dataSource.tokenRangeAtPosition(_:) -> (SourceEditorTokenType?, Range<SourceEditorPosition>)?
```

另外 `enableCmdClickMultiCursor` 默认为 `true`，会把 ⌘-click 当作多光标手势吃掉，必须设为 `false`。

### 重建接口：先查 dump，不要从符号表反推

用 RuntimeViewer 自己导出的 dump（`/Volumes/RE/SourceEdit/Xcode/26.5/<Framework>/SwiftInterfaces/`，
每个类型一份 `.swiftinterface`）**直接给出**下面三条规律的答案：超类、枚举 case 的声明顺序、
protocol requirement 及其 PWT 偏移，另加 struct 字段布局与 initializer 完整签名。

本次落地时没有先查 dump，改从 `nm -gU` + demangle 反推，代价是两个错误结论：把 NSObject
派生的 `SourceEditorGutter` 声明成 Swift 根类（只在释放时崩，查了一下午），以及断言
`LayoutOverrideProviderPriority` 的 case 顺序不可恢复（dump 第一行就写着 low/medium/high）。

**注意版本错配**：现有 dump 出自 Xcode 26.5.0，而实际链接与运行时加载的是 26.6，
`SourceEditor` 二进制 UUID 不同。已核对的声明两版一致，对不上时以会被实际加载的二进制为准。

### 重建接口的三条机械规律（dump 均可直接回答）

1. **protocol requirement 顺序** —— RuntimeViewer 自己导出的 dump 已带 PWT（protocol witness
   table）偏移，且按 witness table 顺序排列（`0x8, 0x10, 0x18…`）。照抄即可；**偏移出现跳跃
   就说明漏了 requirement**，这是现成的自检条件。

2. **类的超类必须写对，尤其是「是否 NSObject 派生」** —— 这条是三条里最难查的。写错了对象**构造正常、调用全部正常，只在释放时崩**：Swift 对它认为的根类走原生 release，而真实对象需要走 ObjC dealloc 链。崩溃表现为跳到垃圾地址、没有可用调用栈；只要那个实例活到进程结束，这个 bug 就完全不显形（本次就是这样在一次「通过」的 spike 里潜伏下来的）。

   dump 里直接写着（`class SourceEditorGutter: __C.NSObject`）。没有 dump 时的退路是看框架有没有导出 `_OBJC_CLASS_$__TtC…` 符号，`Stubs/AuditClasses.sh` 回答这个。

   **不要用 `@objc deinit` 当判据。** Darwin 上每个 Swift 类的 deinit 都暴露成 `dealloc`，真实的 `.swiftinterface`（如 SwiftUI 的）里大量没有继承任何东西的类也带 `@objc deinit`，它不携带信息。已实测：给一个超类写错的类加上 `@objc deinit` **不能**阻止崩溃，只有改对超类才行。

3. **符号导出形式决定声明写法** —— 三种情况：

   | 二进制中的形式 | interface 写法 |
   |---|---|
   | 有 `Tj` dispatch thunk | 普通 `public var` / `public func` |
   | 只有直接符号（`…F` 结尾） | 必须标 `final` |
   | `let` 存储属性 | 同上，标 `final` |

   写错的表现是链接期 `Undefined symbols: dispatch thunk of …`，照提示改即可。本次踩到三次
   （`SourceEditorTheme.name`、`SourceEditorDataSource.tokenRangeAtPosition`、
   `SourceEditorView.contentView`）。

### 主题不需要自己实现

框架内置具体类型 `SourceEditorTheme`，同时 conform `SourceEditorColorTheme` 与
`SourceEditorFontTheme`：

```swift
SourceEditorTheme(name: String, dictionary: [String: AnyHashable], fontSizeModifier: Int)
```

`dictionary` 即 `.xccolortheme` plist 内容，框架 Resources 里自带 Default (Dark)/(Light)。
因此两个 theme protocol 只需写**空声明**，conformance 由框架提供，本侧不产出 witness table。
RuntimeViewer 要用自己的配色，构造等价 dictionary 即可。

## 提议方案

### 方案 A —— 继续 NSTextView，增量补齐

保持 `ContentTextView` / `ContentTextViewController` 现有结构，逐项自建缺失能力。

**做什么**：代码折叠（折叠区间计算 + 行映射 + 折叠指示器绘制）、sticky header（滚动位置到
结构层级的映射 + 悬浮视图）、查找栏（UI + TextKit 2 高亮联动）、⌘-hover 高亮（`NSTrackingArea` +
修饰键监听 + 命中测试 + 临时属性）。

**优点**

- 无新增外部依赖，用户无需安装 Xcode。
- 全部代码可控、可调试、可测试，出问题能自己修。
- 不涉及私有 API，无版本漂移风险，无 entitlement 变更。
- 现有语义级高亮与 `.link` 跳转继续有效，不用改造。

**缺点**

- 工作量大且分散：四项能力各自数百行起步，且都要在 TextKit 2 上处理边界情况。
- ⌘-hover 的手感做不到与 Xcode 等价（这是本提案的起因之一）。
- 大文档滚动掉帧问题无解 —— 那是 TextKit 2 惰性布局的固有代价，除非自己换布局引擎。

### 方案 B —— 改用 SourceEditor

把内容视图换成 `SourceEditorView`，运行时从用户已安装的 Xcode 加载框架。

**做什么**：仓库内维护 stub framework（两个纯文本文件）；把编辑器实现隔离进可选加载的
bundle；实现 ⌘-click 的 event consumer 并接到现有的类型跳转逻辑；把现有 ThemeProfile
转成 `.xccolortheme` 等价 dictionary。

**优点**

- 一次性获得全部缺失能力：代码折叠、sticky header、查找栏、scope guides、⌘-hover、
  mark 分隔符、invisibles、overscroll、软换行、Vim 模式。
- 观感与手感与 Xcode 完全一致（已实测）。
- 大文档滚动不掉帧，首屏恒定 0.8 ms。
- 自研代码量远小于方案 A —— 主要成本是接口重建，而重建是机械的、有自检条件的。

**缺点**

- **硬约束：用户必须安装 Xcode**。这是本提案唯一真正需要决策的点。
- **由此派生出两套实现并存的维护成本** —— 因为必须提供降级路径（见「运行时加载策略」），
  现有 `NSTextView` 实现不能删除，两条代码路径要长期共存并各自验证。这是方案 B 最容易被
  低估的成本：它不是「A 或 B」，而是「A，外加一个更好的 B」。若能接受「未安装 Xcode 时
  内容视图能力降级」，这条成本就是必付的。
- 依赖私有 API，Xcode 大版本升级可能改名或删除接口（library evolution 保证不会静默错乱，
  但会 dyld 报错）。
- 需要新增 `com.apple.security.cs.disable-library-validation` entitlement。
- 内存开销待复测（见上文，2.8 倍的相对差异尚未在真实环境证实）。
- 框架不可随应用分发，只能运行时加载。

### 非目标

- **不使用 `SourceModel` 做语法高亮**。它是纯 ObjC 的词法分析器，靠 `.xclangspec` 猜测；而
  RuntimeViewer 现有高亮来自 MachOSwiftSection 的语义 token，携带真实类型信息，改用词法
  高亮是**倒退**。若采纳方案 B，仍应把语义信息喂给 SourceEditor，而非让它自己 tokenize。
- 不引入代码补全（需要 `SourceKitSupport`，且对只读的 interface 展示无意义）。
- 不做编辑功能。内容视图是只读的，本提案不改变这一点。
- 不改动生成侧（MachOSwiftSection / 语义 token 产出）。

## 详细设计

仅针对方案 B；方案 A 沿用现有结构，无新增设计。

### stub framework 布局

仓库内只放两个纯文本文件，不含任何 Apple 二进制：

```
Stubs/SourceEditor.framework/
├── SourceEditor.tbd                            ← tapi stubify 生成的符号列表
└── Modules/
    └── SourceEditor.swiftmodule/               ← 目录，不是二进制文件
        └── arm64-apple-macos.swiftinterface    ← 手写子集
```

`.swiftinterface` 头部声明编译标志，编译器会自动将其编入 module cache，**无需预先编译出
二进制 `.swiftmodule`**：

```
// swift-interface-format-version: 1.0
// swift-module-flags: -target arm64-apple-macos14.0 -enable-library-evolution -swift-version 5 -module-name SourceEditor
```

`tapi` 位于 `$(xcrun -f tapi)`（toolchain 内）。`.tbd` 与 `.swiftinterface` 均为文本，可提交。

### 最小接口子集（已验证可编译可运行）

```swift
public protocol SourceEditorLanguage {}
public protocol SourceEditorColorTheme {}    // 空声明：conformance 由框架提供
public protocol SourceEditorFontTheme {}

public struct SourceEditorFormattingOptions {
  public init()
}

public struct SourceEditorPosition {
  public init(line: Swift.Int, col: Swift.Int)
  public var line: Swift.Int { get set }
  public var col: Swift.Int { get set }
}

@_hasMissingDesignatedInitializers public class SourceEditorTheme
    : SourceEditor.SourceEditorColorTheme, SourceEditor.SourceEditorFontTheme {
  public init(name: Swift.String, dictionary: [Swift.String : Swift.AnyHashable], fontSizeModifier: Swift.Int)
  deinit
}

@_hasMissingDesignatedInitializers public class SourceEditorDataSource {
  public init(usingMutableString: Foundation.NSMutableString,
              language: SourceEditor.SourceEditorLanguage?,
              formattingOptions: SourceEditor.SourceEditorFormattingOptions)
  public var string: Swift.String { get set }
  public final func tokenRangeAtPosition(_ position: SourceEditor.SourceEditorPosition)
      -> (SourceEditor.SourceEditorTokenType?, Swift.Range<SourceEditor.SourceEditorPosition>)?
  deinit
}

@_hasMissingDesignatedInitializers @objc public class SourceEditorView : AppKit.NSView {
  @objc override dynamic public init(frame: CoreGraphics.CGRect)
  public final var contentView: SourceEditor.SourceEditorContentView { get }
  public var dataSource: SourceEditor.SourceEditorDataSource { get set }
  public var colorTheme: SourceEditor.SourceEditorColorTheme { get set }
  public var fontTheme: SourceEditor.SourceEditorFontTheme { get set }
  public var enableCmdClickMultiCursor: Swift.Bool { get set }
  public func addEventConsumer(_ consumer: SourceEditor.SourceEditorViewEventConsumer)
  public func positionAtPoint(_ point: CoreGraphics.CGPoint) -> SourceEditor.SourceEditorPosition?
  @objc deinit
}
```

`SourceModelSupport` 侧只需 13 行，用于取现成的语言实例：

```swift
public struct SourceModelEditorLanguage : SourceEditor.SourceEditorLanguage {
  public static let swift: SourceModelSupport.SourceModelEditorLanguage
  public static let objc: SourceModelSupport.SourceModelEditorLanguage
}
```

### 装配

```swift
let dataSource = SourceEditorDataSource(
    usingMutableString: NSMutableString(string: text),
    language: SourceModelEditorLanguage.swift,        // 或 .objc
    formattingOptions: SourceEditorFormattingOptions()
)
let editorView = SourceEditorView(frame: .zero)
editorView.dataSource = dataSource
editorView.colorTheme = theme
editorView.fontTheme = theme
editorView.enableCmdClickMultiCursor = false          // 否则 ⌘-click 被多光标吃掉
editorView.addEventConsumer(commandClickNavigator)
```

### ⌘-click 接入现有跳转

现有跳转信息来自生成侧、精度高于任何词法猜测（`ContentTextViewController.swift:145`
从 `.link` attribute 取 `RuntimeObject`）。接入方式是把「字符偏移 → RuntimeObject」的映射
改为「`SourceEditorPosition` → RuntimeObject」：

```swift
final class CommandClickNavigator: SourceEditorViewEventConsumer {
    func handleMouseEvent(_ event: NSEvent, in sourceEditorView: SourceEditorView) -> Bool {
        guard event.type == .leftMouseDown, event.modifierFlags.contains(.command) else { return false }
        let viewPoint = sourceEditorView.convert(event.locationInWindow, from: nil)
        guard let position = sourceEditorView.positionAtPoint(viewPoint),
              let runtimeObject = symbolIndex.runtimeObject(at: position)
        else { return true }
        router.trigger(.jump(runtimeObject))
        return true
    }

    var consumerPriority: SourceEditorEventConsumerPriority { .highest }
}
```

### 运行时加载策略（已实测，2026-08-15）

主 App **不得硬链接**这些框架，否则未安装 Xcode 的用户在 dyld 阶段即崩溃。做法：

1. 确定框架目录，**先看 App 内嵌的 `Contents/Frameworks/`，再看已安装的 Xcode**
   （`NSWorkspace.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")`，回落
   `/Applications/Xcode.app`）。要求目录内四个框架齐备才算命中。
2. 按绝对路径 `dlopen` 这四个框架 —— dyld 按其 install name（`@rpath/SourceEditor.framework/…`）
   注册 image，后续依赖同一 install name 的镜像直接复用，无需任何 rpath。
3. `Bundle.load()` 加载 bridge bundle，其 `@rpath` 依赖命中步骤 2 已加载的 image。
4. 取 `principalClass as? SourceEditorBridging.Type`，任一步失败即降级为方案 A 的现有实现。

「先内嵌后 Xcode」这一条让**是否随应用分发这些框架变成纯打包决定**：把框架放进
`Contents/Frameworks/` 就走内嵌，不放就借用用户的 Xcode，代码只有一条路径。自用构建可以内嵌
（省掉「必须装 Xcode」这条约束），公开发布不内嵌（Apple 二进制无再分发权利）。

**实测结论**（独立 host + bridge 程序，bridge 不带任何指向 Xcode 的 `LC_RPATH`）：

- **install name 复用成立**。bridge 加载成功并渲染出语法着色文本，token 解析精确命中。
- **加载顺序确实有影响** —— 此前标为「推测」的那一条得到证实：`SymbolCacheSupport` 依赖
  `SymbolCacheIndexing`，先加载前者会失败。**不采用手工维护的拓扑序**，改为**不动点循环**：
  反复扫描待加载集合，直到某一轮毫无进展才判定失败。这样 Xcode 以后改依赖图也不会失效。
- **最小集合是 4 个而非 7 个**：`SourceEditor`、`SourceModel`、`SourceModelSupport`、
  `_CodeCompletionFoundation`。`SymbolCache` 三件套服务于索引与补全，已验证可以不加载。
- **未预加载时是可恢复的 `dlopen` 失败，不是崩溃** —— 降级路径成立。
- **`.tbd` 纯文本足够链接**，仓库内无需放置任何指向 Xcode 的符号链接或二进制。

## 替代方案考量

### 打包框架随应用分发

**是什么**：把 7 个框架复制进 RuntimeViewer.app。
**为什么否**：这些是 Apple 的二进制，RuntimeViewer 在 GitHub 公开分发并带 Sparkle 自动更新，
不具备再分发权利。

### 硬链接而非运行时加载

**是什么**：构建期直接 `-framework SourceEditor`，运行期靠 `-rpath` 指向 Xcode。
**为什么否**：未安装 Xcode 的用户会在 dyld 阶段崩溃，且 Xcode 路径不固定（本机同时存在
`/Applications/Xcode.app`、`Xcode-26.5.0.app`、`Xcode-27.0.0-beta.app`）。必须可降级。

### 用 SourceModel 替换现有高亮

**是什么**：只取纯 ObjC 的 `SourceModel`（`SMSourceModel` / `SMLanguageSpecification`），
成本极低，只需一个手写头文件。
**为什么否**：**收益为负**。它是基于 `.xclangspec` 的词法分析器，只能猜测标识符类别；而
RuntimeViewer 现有高亮来自 MachOSwiftSection 的语义 token，知道每个标识符的真实类型与归属。
用词法高亮替换语义高亮是倒退。`SourceModel` 的结构信息（`foldableBlockItemForLocation:`、
`classItems`）对代码折叠有价值，但那些信息生成侧同样能给。

### 通过 ObjC 运行时调用而不重建接口

**是什么**：`NSClassFromString` + `performSelector`。
**为什么否**：已查证不可行。`SourceEditorView` 的 ObjC 可见表面只有 `NSResponder` 动作方法，
`dataSource` / `delegate` / `init` 全是纯 Swift；`SourceEditorDataSource` 继承
`_TtCs12_SwiftObject`，无任何 `@objc` 成员。

## 影响

### 用户可见变化

**方案 A**：随各项能力逐步落地，用户逐步获得代码折叠、sticky header、查找栏。跳转视觉维持
链接样式不变。

**方案 B**：内容视图观感变为 Xcode 编辑器；新增代码折叠、sticky header、查找栏、scope guides、
mark 分隔符、⌘-hover 下划线、Vim 模式（可选）。**跳转的触发方式从「点击链接」变为「⌘-click」**
—— 这是操作习惯的改变，必须保留原有点击行为或在首次使用时提示。未安装 Xcode 的用户看到的
是现有 NSTextView 实现，无功能回退，但也无新增能力。

### 可发现性

**方案 B** 的新能力应对齐 Xcode 的默认值（行号、折叠、minimap 默认开启；Vim 默认关闭），
并在设置面板中提供开关。若发生降级（未找到 Xcode），**不应弹窗打扰**，但需在设置面板中
说明「部分编辑器能力需要安装 Xcode」。

### 数据与配置兼容

两个方案均不改变文档格式、偏好设置或缓存结构。方案 B 需把现有 ThemeProfile 转换为
`.xccolortheme` 等价 dictionary，转换失败时回退到框架自带的 Default (Dark)/(Light)。

### 平台与最低版本

不变（macOS 15+）。方案 B 的框架 `minos` 为 14.0，低于本项目要求，无约束。
框架只有 arm64 slice，**无 x86_64、无 arm64e**：主 App 是 arm64，不受影响；
`RuntimeViewer-Debug-arm64e` 变体无法加载，需在该变体下强制降级为方案 A 的实现。
Intel Mac 需要用户安装通用版 Xcode。

### 发布

**方案 A**：无影响。

**方案 B**：需新增 `com.apple.security.cs.disable-library-validation` entitlement。该 entitlement
属于 hardened runtime 的既有例外，**不影响公证**；本应用当前 entitlements 为空（未启用沙盒），
无额外沙盒授权问题，也不影响 Sparkle 更新流程。

**但要说清楚它为什么是「照加」而不是「已证明必需」。** 库校验的规则是「只允许加载与自身同
Team ID 或由 Apple 签名的代码」，而 Xcode 的框架恰恰是 Apple 签名的（`Authority=Software
Signing`，Apple Root CA），按规则应当豁免、无需 entitlement。**这一点在本机无法验证** ——
开发机已关闭库校验（实测：Developer ID + `-o runtime` 的进程读不到 `CS_REQUIRE_LV`，且能成功
`dlopen` 一个 ad-hoc 签名的自建 dylib，库校验若在生效这一步必被拒）。本机通过不能证明用户机器
通过，所以按最保守方式落地：entitlement 照加，代价为零。

内嵌分发时另需注意：嵌入 App 的代码必须由本应用的 Developer ID 重签才能公证，等于把 Apple 的
签名换成自己的 —— 这也是「公开发布不内嵌」的额外理由。

## 落地步骤

仅方案 B 需要；方案 A 按各项能力独立排期，不在此展开。

1. ~~**验证 `dlopen` 加载路径**~~ —— **已完成（2026-08-15）**，结论见「运行时加载策略」。
2. ~~建立 stub framework 与接口子集，纳入构建；补齐 `.tbd` 生成脚本~~ —— **已完成**。
   仓库内 `Stubs/`，含 `Generate.sh`（tapi stubify + 裁剪）、`AuditMembers.sh`（查符号形式）、
   `Trim.py`。裁剪后两个 `.tbd` 合计不到 5 KB，只保留实际引用的 42 + 4 个符号。
3. ~~把编辑器实现隔离进可选加载 bundle，接入 `ContentCoordinator`~~ —— **已完成**。
   新增 `RuntimeViewerSourceEditorBridge` bundle target（照搬既有
   `RuntimeViewerCatalystHelperPlugin` 的形态），`SourceEditorLoader` 负责定位与降级，
   `ContentSourceEditorViewController` 与 `ContentTextViewController` 绑定同一个
   `ContentTextViewModel`，因此二选一就是全部切换成本。
4. ~~⌘-click 跳转~~ —— **已完成**。跳转目标仍从生成侧的 `.link` attribute 读取，
   保持语义精度；⌘⇧-click 开新 tab 的语义一并保留。
5. **在真实 App 内复测内存**。spike 的离屏测量得出 SourceEditor ≈ TextKit 2 的 2.8 倍，
   但绝对值不可信。若真实环境下确认显著劣化，需重新评估方案取舍。**未做。**
6. ~~**主题转换**~~ —— **已完成**。`SourceEditorThemeConversion` 把 `ThemeProfile` 渲染成
   `.xccolortheme` dictionary，**以框架自带主题为底再覆盖**（该格式约五十个键，多数在
   `ThemeProfile` 里没有对应物；从一份完整字典出发，未映射的键仍然有效，Xcode 以后加键也不会
   开天窗）。已实测覆盖生效。**两个不查就会错的点**：
   - **颜色分量必须是 calibrated / Generic RGB，不是 sRGB。** 框架用等价于
     `NSColor(calibratedRed:green:blue:alpha:)` 的方式解析 `"r g b a"`。实测同一个三元组：
     按 sRGB 解析渲染成 0.420/0.886/0.459，按 calibrated 解析渲染成 0.404/0.886/0.518 ——
     肉眼可辨，而且不会报任何错。
   - 嵌套字典必须整体替换后写回，且颜色/字体值是字符串（`"r g b a"` / `"字体名 - 字号"`）。
7. ~~**语义 token 注入**~~ —— **已完成，且比预想便宜得多**。见下方。
8. 逐项启用附加能力（折叠、sticky header、查找栏），每项单独验证。**未做**（`installMinimap()` /
   `installStickyHeaders()` / `installFoldingRibbon()` 三个入口已定位）。
9. ~~加上 `com.apple.security.cs.disable-library-validation` entitlement~~ —— **已加**，
   公证尚未走过。

### 语义高亮：走 `TextAttributeOverrideProvider`，不必重建 language service

首个版本的高亮是词法的（`NSString` 这类类型名不着色，因为词法扫描器不知道它是个类型）。
原以为只能实现 48 个 requirement 的 `SourceEditorLanguageService`，实际有一条便宜得多的路：

- `TextAttributeOverrideProvider` 只有 **2 个 requirement**，其中
  `pasteboardTextAttributeOverridesForLine` 还有默认实现。
- `SourceEditorTextAttributeOverride(range:attr:)` 直接接受 `NSAttributedString` 的属性字典，
  所以**生成侧已有的语义颜色可以原样喂进去**，不需要映射到框架的 token 类型。
- 注册入口是 `SourceEditorLayoutManager.addLayoutOverrideProvider(_:)` —— 该协议继承
  `LayoutOverrideProvider`，布局管理器按动态转型把 provider 分派到各自的桶里；框架自己的
  `SourceEditorLineAnnotationManager` 就是同时实现两个协议再这样注册的。

结果：**框架的词法着色作为底，生成侧的语义颜色覆盖在上面**，跳转目标仍来自 `.link` attribute。

两个不查就会踩的点：

- **列范围必须落在该行的内容长度内**（不含行尾换行符）。越界不是被忽略，而是框架直接
  `fatalError("specified column range out of bounds")`。
- `LayoutOverrideProviderPriority` 的 case 声明顺序**必须照抄 dump**（`low` / `medium` / `high`）。
  resilient 枚举的 case 索引与隐式 raw value 都来自声明顺序，顺序写错会静默取到别的 case。

### 语言服务路线（未采用，但已完整摸清）

比「颜色覆盖」更彻底的做法是提供自己的 `SourceEditorLanguageService`，让框架的整套机制都拿到
语义信息（`tokenRangeAtPosition` 变语义级 → ⌘-click 取词更准；省掉每次切换对象时遍历
attributed string 的开销；分隔符高亮、结构选择等一并受益）。

**不能靠继承 `GenericLanguageService` 实现。** 它对 `SourceEditorLanguageService` 与
`SourceEditorSyntaxTokenProvider` 的 conformance 都是空 extension，witness 全部来自协议扩展的
默认实现 —— 而协议扩展默认是**静态派发**，子类覆写不会被调用。它自己的 vtable 里只有
`indentLine`。要控制 token 必须由我们自己的类型直接 conform。

而直接 conform 比看上去便宜得多（**这些数字来自 dump，不是从符号表估的**）：

| 项 | 结论 |
|---|---|
| `SourceEditorLanguageService` | 48 个 requirement，**46 个有默认实现**，只需实现 `init(language:buffer:)` 与 `indentLine` |
| `SourceEditorSyntaxTokenProvider` | 3 个 requirement，全部有默认实现 —— 覆写它们就是注入语义 token 的入口 |
| 语言对象 | 不必自己实现 `SourceEditorLanguage`：`GenericLanguage` 是具体类，`init(name:identifier:languageService:lineDataFactory:editableRangeSnapshot:)` 可直接传入我们的 service 类型 |
| 语义表达力 | `SourceEditorTokenData.uiKind` 返回 `SourceEditorTokenType.UIKind`，含 `className` / `typeName` 等，且每个带 `Scope`（`.project` / `.external`）—— 正好对应主题里 `identifier.class` 与 `identifier.class.system` 的区分 |

**真正的成本不在这 2 个方法，而在把这一片接口铺出来**：协议本身 48 条签名 + 46 条默认实现，
连带 `SourceEditorBuffer`、`CodeStructure`、`Landmark`、`SourceEditorRefactorAction` 等十余个
不透明类型，外加自建的 token data 类型与 `UIKind` / `Scope` / `FontTraits` 三个枚举（case 顺序
照抄 dump）。数百行，全部机械。

**结论：暂不做。** 可见收益（颜色）已由 `TextAttributeOverrideProvider` 以约 60 行拿到；这条路线
的增量收益主要是 ⌘-click 取词精度与省掉一次遍历。已确认它不是死路，随时可以单独排期。

### 已知妥协（已解决，保留记录）：首个版本的语法高亮是词法的

「非目标」一节写明不用 `SourceModel` 的词法高亮替换现有语义高亮。当前实现**并未做到这一点**：
`SourceEditorDataSource` 接收纯文本并自行 tokenize，因此走这条路径时看到的是词法着色。

开关是 Settings › Editor，默认关闭。语义高亮补上之后「更好的编辑器 + 更差的高亮」这个理由
已经不成立，但仍保持默认关闭，因为「必须装 Xcode」这条约束还在，且附加能力（折叠 / sticky
header / 查找栏）尚未逐项验证。设置面板的说明文案需要随之更新。

### 语义 token 注入的可行性（已查清，未实现）

**值得做。** Xcode 主题的 token 分类本身就是语义级的：`identifier.class` / `identifier.type` /
`identifier.function` / `identifier.variable` / `identifier.constant` / `identifier.macro`，
每类还分 `.system`（SDK 符号）与非 system。这正是词法扫描器只能猜、而 MachOSwiftSection 的
语义 token 确切知道的信息 —— 注入之后着色会**比现在的 `NSTextView` 路径更细**，而不只是持平。

**路径清楚，但工作量比现有接口子集大一个量级：**

- `SourceEditorSyntaxTokenProvider` 是要实现的目标协议（3 个 requirement：
  `enumerateSyntaxTokensOnLine`、`syntaxTypeAtPosition` 的两个重载）。
- 它由 `SourceEditorLanguageService` 继承。**后者是 protocol 而非 class**（这是好消息，
  不需要子类化），但有 **48 个 requirement**，且含一个 `init(language:buffer:)`。
- 接入点已找到：`SourceEditorDataSource` 有一个
  `init(languageService:language:usingMutableString:name:formattingOptions:)`，
  可以直接传入自己的 language service，不必经由 `SourceEditorLanguage.langServiceClass`。
- 连带需要为若干类型补上不透明声明（`SourceEditorBuffer`、`CodeStructure`、`Landmark`、
  `SourceEditorNavigationTarget`、`SourceEditorRefactorAction` 等）。内容视图是只读的，
  没有诊断/补全/重构，多数 requirement 可以返回 `nil` / `[]` / `false` 或空实现。
- **`SourceEditorTokenType` 届时必须补全所有 case 且顺序正确** —— 现在它声明为空枚举，
  因为只做透传；一旦要**构造**该类型的值，resilient 枚举的 case 索引就来自声明顺序，
  空枚举的取巧做法失效。取 case 顺序的可行办法是反编译「token 类型 → `xcode.syntax.*` 键」
  的映射函数，其 switch 的分支顺序即声明顺序。

**收尾时必须判断两件事**（结果写进决策日志）：

- **配套文章** —— 方案 B 落地必须写实现说明：接口重建的两条机械规律、`enableCmdClickMultiCursor`
  这类「代码本身看不出来」的开关、降级路径的设计理由，都属于下次维护会踩的坑。
- **新术语** —— `PWT 偏移`、`dispatch thunk` 与 `直接符号` 的区分属于跨项目通用概念，
  应登记进全局术语表；`stub framework` 在本项目的特定含义登记进项目术语表。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-15 | Created as Draft | 起因是希望获得与 Xcode 一致的 Jump to Definition 手感。调研确认 SourceEditor 可用后，扩展为内容视图编辑器的整体选型。已完成方案 B 的可行性 spike 与性能实测，两项数据（fullLayout、内存）明确标注为不可信，待落地前复测。 |
| 2026-08-15 | → Accepted（方案 B） | 用户批准采纳方案 B 并要求先接入。同时确定分发策略：**自用构建把框架内嵌进 App，公开发布不内嵌**，代码统一走「内嵌优先、Xcode 回落」的 `dlopen` 路径，是否内嵌降为纯打包决定。 |
| 2026-08-15 | 落地步骤 1 完成 | `dlopen` + install-name 复用验证通过。同时证实此前标为「推测」的加载顺序问题真实存在（`SymbolCacheSupport` → `SymbolCacheIndexing`），改用不动点循环加载而非手工拓扑序；最小框架集合从 7 个收窄到 4 个。 |
| 2026-08-15 | entitlement 判断修正 | 原文断言库校验会拒绝加载 Apple 签名的框架，因而必须加 entitlement。该断言无法在本机验证——开发机已关闭库校验。按规则 Apple 签名的代码本应豁免，但改为「照加、代价为零」而非「已证明必需」。 |
| 2026-08-15 | 记录已知妥协 | 首个可用版本的语法高亮是词法的，与「非目标」一节的要求不符。因此做成 opt-in 开关而非替换默认实现，并把语义 token 注入列为落地步骤。 |
| 2026-08-15 | 主题转换完成 | 开关改为正式设置项（Settings › Editor），不再走隐藏的 UserDefaults 键；`ThemeProfile` 已能渲染成 `.xccolortheme`。实测查明颜色分量必须按 calibrated RGB 写入，按 sRGB 写会静默偏色。 |
| 2026-08-15 | 语义 token 注入定性为「值得做」 | 查明 Xcode 的 token 分类本身是语义级的，注入后着色会优于现有 `NSTextView` 路径而非持平；`SourceEditorLanguageService` 是 protocol（48 个 requirement）而非 class，且 `SourceEditorDataSource` 有直接接收 language service 的 initializer。工作量比现有接口子集大一个量级，单独排期。 |
| 2026-08-15 | 语义高亮完成，成本远低于预估 | 找到 `TextAttributeOverrideProvider`（2 个 requirement，其一有默认实现），可直接把生成侧的 `NSAttributedString` 颜色覆盖上去，无需重建 language service。上一行的排期判断作废。 |
| 2026-08-15 | 纠正：dump 才是权威来源 | 上面几条「无法从导出符号恢复」的结论是错的——RuntimeViewer 自己的 per-type dump 直接给出超类、枚举 case 顺序与 PWT 偏移。今后重建接口一律先查 dump，`nm` 反推只作为没有 dump 时的退路。 |
| 2026-08-15 | 补第三条接口重建规律 | 类的超类写错（把 NSObject 派生类声明成 Swift 根类）只在**释放时**崩，构造与调用全程正常，实例活到进程结束就完全不显形。判据是 `_OBJC_CLASS_$` 符号，已固化为 `Stubs/AuditClasses.sh`。实测确认 `@objc deinit` 不是判据也不能修复。 |
| 2026-08-15 | 行号与背景修复 | 行号需要显式安装 `SourceEditorGutter` 并 `enableLineNumbers()`（视图默认不带 gutter）；背景另需设 `SourceEditorView.backgroundColor` 与容器背景，主题字典的背景键只管文本区。当前行高亮色由背景色推导，因为 `ThemeProfile` 没有这一项。 |
