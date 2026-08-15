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

### 已完成（2026-08-15，分支 `feature/source-editor-integration`）

1. **`dlopen` 加载路径** —— 结论见「运行时加载策略」。install-name 复用成立；加载顺序有影响，
   已改为不动点循环；最小框架集合 4 个。
2. **stub framework 与接口子集** —— 仓库内 `Stubs/`，含 `Generate.sh` / `AuditMembers.sh` /
   `AuditClasses.sh` / `Trim.py`。三个 `.tbd` 裁剪后合计约 8 KB —— 未裁剪是 1.1 MB，
   所以**提交前务必确认落盘的是裁剪版**：`refresh-stubs.sh` 中途会写一遍全量 stub 用来
   重算已用符号，停在那一步就会把 1 MB 的文件提交进仓库（曾经发生过一次，已修）。
3. **可选加载 bundle 接入 `ContentCoordinator`** —— `RuntimeViewerSourceEditorBridge` bundle
   target，`SourceEditorLoader` 负责定位与降级，两个内容视图绑定同一个 ViewModel。
4. **⌘-click 跳转** —— 目标从生成侧 `.link` attribute 读取；⌘⇧-click 开新 tab 保留。
5. **行号** —— 需显式安装 `SourceEditorGutter`、`enableLineNumbers()`（视图默认不带 gutter），
   **并且必须设 `lineNumberFont`**，否则行号图层全是 0×0、gutter 塌成 6pt。见下。
6. **主题转换** —— `SourceEditorThemeConversion`，28 个语法键全部写入。
7. **语义高亮** —— 走 `SourceModelLanguageService.nodeTypeAdjuster` 改写解析器节点类型。
8. **正式设置项** —— Settings › Editor，`Settings.Editor.usesSourceEditor`，默认关闭。
9. **entitlement** —— `com.apple.security.cs.disable-library-validation` 已加。
10. **内存实测** —— 见下。spike 那个「2.8 倍」是离屏测量的假象,已作废。
11. **附加显示能力** —— 代码折叠、sticky header、minimap、行号、scope guides，五项都是
    Settings › Editor 里的独立开关。见下。

### 内存:SourceEditor 的开销可忽略(2026-08-15 实机测量)

运行中的 App(已启用 SourceEditor、浏览 AppKit)按 `heap` 归因:

| | |
|---|---|
| 进程 phys_footprint | 1081 MB(峰值 1532 MB) |
| 其中堆 | 686 MB / 450 万个对象 |
| **SourceEditor + SourceModel 的全部对象** | **2.0 MB / 19978 个,占堆 0.3%** |

它只为可见行保留图层(`SourceEditorLineLayer` 139 个 ≈ 一屏行数),解析器的规则表是一次性
常量。**采纳方案 B 不需要为内存付代价。**

进程总量由 RuntimeViewer 自身的模型数据构成(`Node`、`StringStorage`、`MachOSymbols.Symbol`
等),与本提案无关;针对它的优化在另一条未合并的分支上,故此处不作结论。

spike 阶段那个「SourceEditor ≈ TextKit 2 的 2.8 倍」是离屏窗口无内存压力、缓存从不回收导致的,
两边绝对值都不可用 —— 与本次「离屏判据不可靠」的教训是同一回事。

### 附加显示能力:五个开关,一次调用(2026-08-15)

`SourceEditorView` 上每项能力都是一对无参方法,自己从视图现有状态构造所需的一切 ——
反汇编确认 `installMinimap()` / `installStickyHeaders()` / `installFoldingRibbon()` 都不依赖
任何预先配置。折叠还需要 language service 能报告可折叠区间,而 `SourceModelLanguageService`
本身就 conform `FoldableLanguageService`,所以现成可用。

| 设置项 | 入口 | 默认 |
|---|---|---|
| Line Numbers | `SourceEditorGutter.enableLineNumbers()` / `disableLineNumbers()` | 开 |
| Code Folding Ribbon | `installFoldingRibbon()` / `uninstallFoldingRibbon()` | 开 |
| Sticky Headers | `installStickyHeaders()` / `uninstallStickyHeaders()` | 开 |
| Minimap | `installMinimap()` / `uninstallMinimap()` | **关** |
| Scope Guides | `showScopeGuides()` / `hideScopeGuides()` | 开 |
| Invisibles | `showInvisibles()` / `hideInvisibles()` | 关 |

minimap 默认关,因为它是唯一会占走文本宽度的一项,而内容面板本来就是三栏里最窄的。
invisibles 默认关(Xcode 同样默认关),它在嵌套很深的 Swift 声明里有用——缩进的精确层数
就是区分嵌套层级的东西。

**invisibles 不需要额外喂东西**,和 gutter 字体那个坑不同:`showInvisibles()` 自己读视图当前的
`colorTheme`、动态转型成 `ShowInvisiblesTheme` 再交给 layout manager,而 `SourceEditorTheme`
本身就 conform 该协议(有 conformance descriptor 为证),颜色取 `DVTSourceTextInvisiblesColor`
——正好是我们不覆盖、原样保留 Xcode 基础主题的那批键之一。
**但它在调用时把主题拷走了**,所以之后换主题(明暗切换)必须重调一次 `showInvisibles()`,
否则不可见字符还是旧主题的颜色。

### 查找栏:框架自带 ⌘F,只是位置要靠 content inset

不用做任何事就有查找栏——框架注册了默认 key binding,标准的 `performFindPanelAction:`
(sender 的 `tag` 是 `NSTextFinder.Action`,`showFindInterface` = 1)就能拉起。
它的位置问题见上一节的 `default` / `additional` 之辨。

**`install*` 不是幂等的,必须自己记状态。** `installMinimap()` 在已有 minimap 时会跳过创建,
但仍然继续把它作为 margin accessory 和 event consumer 再注册一遍。所以 bridge 保存
`appliedDisplayOptions`,只在真正翻转时调用对应的一半。`uninstall*` 反而是幂等的(各自对 nil
提前返回),`showScopeGuides` / `hideScopeGuides` 也是(都会先读旧标志、没变就什么都不做)
—— 唯独 scope guides 因此可以无条件调用,不必跟踪真实状态。

`appliedDisplayOptions` 的**初值必须描述 `init()` 之后的视图,而不是一个全新的
`SourceEditorView`** —— `init()` 会装 gutter 并开行号,所以 `showsLineNumbers` 初值是 `true`。

传参方式是一次五个 `Bool`,而不是五个属性:驱动它的是对 Settings 的 observation,重跑时并不
知道是哪个值动了,所以由 bridge 自己做 diff。

**验证方式:遍历视图与图层树数点,不是看截图。** 这是结构性问题(某个类在不在树里),
离屏完全可靠 —— 与「颜色结论必须看实机」的教训不冲突,那条针对的是渲染。harness 跑 8 轮
全开/全关,确认五项都能装上、都能拆干净、重复装不会叠第二份。

### 行号:光 `enableLineNumbers()` 不够,还要给字体(2026-08-15)

**`SourceEditorGutter.lineNumberFont` 不设,行号就一个都不显示** —— 而且症状不像缺字体,
像功能没接上:gutter 只有 6pt 宽(只剩那条分隔线),144 个行号图层全是 **0×0**。

成因链:`enableLineNumbers()` 只写一个 `Bool` 再刷新;行号尺寸由
`SourceEditorGutterMarginContentView.layerSizeForDigits(_:)` 算,它把 `"000…"` 放进一个
`SourceEditorFontSmoothingTextLayer`、用**存在 content view 上的字体**排版后读回尺寸。
那个字体初值是 nil,唯一写入口就是 `gutter.lineNumberFont` 的 setter。字体为 nil ⇒ 测得 0×0
⇒ margin 塌成分隔线宽度。

`.xccolortheme` 里**没有任何 gutter 相关的键**(整份文件只有 syntax colors/fonts、背景、选中、
当前行、插入点、invisibles),所以这个字体只能由调用方显式给。因此 `applyTheme` 多带一个
`lineNumberFont` 参数,用主题的正文字体 —— 由 App 侧传已解析好的 `NSFont`,而不是让 bridge
去二次解析 `"SFMono-Regular - 12.0"`。

改完字体还要**再调一次 `enableLineNumbers()`**:setter 只清掉尺寸缓存,不安排重绘;真正重绘的
`updateLineNumberDisplay()` 是私有的、没有 dispatch thunk,只能通过 enable/disable 这一对进去。

修复前后:margin 6pt → 36pt,行号图层 0×0 → 8×15 且 `contents != nil`。

### 工具栏穿透:滚动视图在里面,安全区到不了它(2026-08-15)

内容面板故意把顶边压到父视图顶部(而不是安全区),这样文本能滚到工具栏底下、拿到 macOS 26 的
scroll edge 模糊。`NSTextView` 那条路白拿这个效果:滚动视图**就是**面板自己的视图,AppKit 按
安全区自动给它 content insets。

`SourceEditorView` 是普通视图,**真正的滚动视图埋在它里面**,而且 `installScrollView()` 里
明确调了 `setAutomaticallyAdjustsContentInsets:` 关掉自动调整,改由它自己用
`defaultScrollViewContentInsets + additionalScrollViewContentInsets` 算。结果是安全区传不进去:
首几行正文和 sticky header 直接画在工具栏上,而不是从工具栏下面滚过去。

修法是在 `viewDidLayout()` 里把 `defaultScrollViewContentInsets.top` 设成
**view controller 的 `view.safeAreaInsets.top`**,每次布局重读——工具栏、全屏、窗口 chrome
都会改它,而这些都不会给内容面板发通知。

**必须写 `default`,不能写 `additional`。** 滚动视图的 content insets 是两者之和,
但 `additional` 是**查找面板自己的通道**:`present(_:)` 会把面板高度直接写进
`additional.top`,把我们放在那里的工具栏偏移无声地冲掉,同时面板自己也会贴到窗口顶边。
实测(安全区 66,面板高 28):

| 写入的字段 | 按 ⌘F 前 `contentInsets.top` | 按 ⌘F 后 | 查找栏在编辑器内的 y |
|---|---|---|---|
| `additional` | 66 | **28**(66 被冲掉) | 0(贴顶,压在工具栏下) |
| `default` | 66 | 94(66 + 28) | **66**(工具栏下沿) |

**必须取 `view`,不能取 `bridge.editorView`。** 后者在真实层级里读出来是 0:AppKit 是对着
controller 的 view 解析安全区的,不会为一个恰好越过它的后代重新推导。只有当那个视图**直接**
挂在 window 的 content view 上时,问它才拿得到正确值——测试 harness 就是这种结构,
所以 harness 量到 66、实机是 0,差点把这条结论带偏。

实测(带 toolbar 的 `.fullSizeContentView` 窗口,安全区 66pt):

| | 设置前 | 设置后 |
|---|---|---|
| `scrollView.contentInsets.top` | 0 | 66 |
| sticky header 在窗口中的 y | 582(紧贴顶部,在工具栏下面被压住) | 516 |

### sticky header 只有一行,是框架的设计,不是配置问题(2026-08-15)

用户报告:一条源码行软换行成好几行时,sticky header 只显示第一行、右边被裁掉。

**查证到指令级:** `StickyHeaderContentProvider.headerLineLayer(forLine:headerState:maxWidth:)`
在造完 line layer 后调用 `SourceEditorLineLayer.layoutAndSizeToWidth(_:minLineHeight:)`,
传的宽度是 **nil**(`mov x0, #0x0` / `mov w1, #0x1`,即 `Optional<CGFloat>.none`),
`minLineHeight` 是 0。宽度为 nil 就是「不限宽、不换行」。那个 `maxWidth` 参数另有用途 ——
函数里 `enumerateSubstringsInRange:` + `configureCharacter(at:opacity:maximumFontSize:)`
是给溢出尾部做淡出/缩小的。

结构上也只支持一行:`StickyHeaderViewContents` 只有一个 `line: SourceEditorLineLayer?`。
实测复现:正文首行 line layer 高 75pt(5 个 fragment),对应的 `StickyHeaderView` 高 18pt。

Xcode 自己也是这个行为。要改只能深入私有布局(拿到 `StickyHeaderStackView.headers`、
在框架自己的 `layout()` 之后重排 line layer 并撑高 header view),脆弱且每次滚动都要跟框架抢,
**未做**。

**尚未查清的小差异:** Xcode 的 sticky header 尾部有淡出/缩小(截图里看起来像省略号),
我们这边是硬切——放大到像素看,文字亮度一直到裁切边界都没变。框架里做这件事的是
`headerLineLayer` 内 `enumerateSubstringsInRange:` 块里调的
`configureCharacter(at:opacity:maximumFontSize:)`,`maxWidth` 由
`StickyHeaderView.drawingWidth(editor:)` 给(该函数 nil 分支是 `brk`,即强制解包,
我们没崩说明取到了正常值)。**没找到是什么条件把这段跳过了**,而不是"确认不支持"。
二进制里没有省略号字面量,sticky header 地址区间内也没有 `setLineBreakMode:` /
`setTruncationMode:` 调用,所以那个"省略号"很可能就是被缩到极小的最后几个字符。

**已知的框架侧小泄漏:** 每次重装 minimap 会多留 8 个图层
(`MinimapFindResultHighlightsLayer` 与 `MinimapRangeHighlightsLayer` 各 4 个),8 轮实测严格
线性(4→8→…→32)。推测是 `MinimapConfig.layoutVisualizations` 挂在视图的 `let minimapConfig`
上、`uninstallMinimap()` 不清它。每个 bridge 实例各有自己的 config,所以不跨标签页累积,
量级也只是每次开关 8 个图层 —— 记录在案,不为此绕开框架 API。

### 未完成

**A. 其余显示项。** `lineWrappingStyle` / `overscroll`,对只读接口的价值存疑,未做。
（查找栏与 invisibles 已完成,见上。）

**B. 系统符号与工程符号的颜色区分。** 主题里 `identifier.class` 与 `identifier.class.system`
是两个键，但 `ThemeProfile` 只有 7 种样式、没有这一维，现在两者同色。要区分必须先给
`Settings.Theme.Preset` 加一档（例如 `systemTypeName`），属于主题模型的改动，需单独决定。

**C. 走一次公证**，确认 entitlement 不影响 notarization。

**D. 分支尚未推送，未开 PR。** `main` 受保护必须走 PR。

**E. 配套实现说明未写。** 提案头部「配套文档」仍是「待定」。按项目文档约定，落地时应登记
实现说明的链接；本提案正文已承载了绝大部分内容，需判断是否还要单独成篇（判据：是否存在
「下次维护会踩、但代码本身看不出来」的决策——`Stubs/README.md` 已覆盖接口重建那部分）。

### 【已被取代】语义高亮的第一版：`TextAttributeOverrideProvider`

> 保留作记录。这一版**能出正确颜色，但它是在错误的解析结果上盖颜色** —— `tokenRangeAtPosition`
> 仍是词法的，⌘-click 取词不受益，且每次切换对象都要遍历整个 attributed string。
> 现行做法见下一节。

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

### 语义高亮：改写解析器的节点类型，而不是覆盖渲染结果

首个版本用 `TextAttributeOverrideProvider` 在渲染结果上盖颜色。**已改为走框架自己的扩展点**：
`SourceModelLanguageService.nodeTypeAdjuster`。语言服务会把每个解析出的节点交给 adjuster，
允许它改写节点类型 —— 这正是 Xcode 用索引数据升级词法解析的机制。

**为什么不能继承 `GenericLanguageService`**：它对两个协议的 conformance 都是空 extension，
witness 全部来自协议扩展的默认实现，而扩展默认是静态派发，子类覆写永远不会被调用；它自己的
vtable 里只有 `indentLine`。（`SourceModelLanguageService` 不同，`syntaxTypeAtPosition` 有
vtable 槽，继承它是可行的——但用 adjuster 更省。）

**关键发现：节点类型名就是主题的语法键。** `SMSourceNodeTypes` 是按名字注册的运行时表，
枚举一遍即可得到 `xcode.syntax.identifier.class`(23)、`.class.system`(29)、`.type`(26) 等 128 项。
所以把节点类型改成对应 id，主题就按语义上色，且**按名字查 id 跨版本稳**（id 依注册顺序分配）。

接入点很小：`SourceEditorDataSource.languageService`（`lazy var`，读一次即创建）转型为
`SourceModelLanguageService`，设上 adjuster 即可，不需要子类化，也不需要重建那 48 个
requirement 的语言服务协议。ObjC 侧 `SMSourceModelItem` / `SMSourceNodeTypes` 用一份手写头
加 modulemap 引入（`Stubs/SourceModel.framework/`），无需重建 Swift 接口。

收益不止颜色：`tokenRangeAtPosition` 也变成语义级，⌘-click 取词随之更准。

**两条实测得出的规则：**

- **只有当某个语义 run 完整包含该节点时才改写。** 解析器的节点边界与生成侧的 run 边界不一致 ——
  ObjC 方法声明里会出现一个跨越「参数类型 + 参数名」的节点。按「节点首字符所在 run」判定会把
  类型色染到参数名上。代价是少数跨 run 的节点保持框架原判，不会被错标。
- **不要覆写带默认实现的 requirement。** `invalidateCache()` 有默认实现，用空实现覆写它没有
  好处（本次实测它并非渲染不更新的原因，但默认实现属于框架的内部约定，无理由不要接管）。

### 主题转换必须写满全部 28 个语法键

`.xccolortheme` 的 `DVTSourceTextSyntaxColors` 有 28 个键；**只写一部分，剩下的会保留 Xcode
自带主题的颜色**，结果是同一个面板里混着两套主题（工程内的类跟随用户配色，SDK 的类是 Xcode 的紫色）。

而 `ThemeProfile` 只解析出 **7 种文本样式**（text / keyword / typeName / declaration /
comment / number / error），所以这是一个 28 → 7 的多对一映射，必须：

- **一个样式只指派一个键**用于改写节点类型。把同属一个样式的两个 `SemanticType` 映射到两个
  不同的键，屏幕上看不出差别，却会让节点类型和主题各说各话。
- 早期版本把 `.variable`（declaration 组）与 `.member(.name)`（typeName 组）映射到了同一个
  `identifier.variable` 键，后写者覆盖前者，属性名于是显示为类型色。分组现在照抄
  `ResolvedTheme.style(for:)`。
- 系统符号与工程符号（`.system` 后缀那一族）不再有颜色区分 —— `ThemeProfile` 没有这一维，
  强行保留只会让一半颜色不听设置。要区分需先给主题模型加一档。

### 离屏渲染判据不可靠，实机为准

本次改动的可见效果**三次被离屏 harness 判成失败，而实机是好的**。离屏窗口的渲染路径与真实
窗口不同，`cacheDisplay(in:to:)` 取到的位图既有色彩空间转换、也不保证与屏幕一致。

离屏检查可以用来证伪机制是否接通（是否崩溃、adjuster 是否被调用、token 类型是否变化），
**但不要用它判定「颜色对不对」** —— 那必须看实机截图。

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
| 2026-08-15 | 当前行高亮改为主题正式一项 | 原本由背景色推导（亮度判明暗、±0.05），是 0009 引入的临时做法。现新增 `Settings.Theme.Preset.currentLineHighlight` 槽，贯通 `ThemeProfile` / `ResolvedTheme` / 设置面板「Current Line」行。该槽带 `@Default`，否则已保存的自定义 preset 会因缺键解码失败。仅 SourceEditor 路径会绘制它——`NSTextView` 没有当前行高亮。 |
| 2026-08-15 | 语义高亮改走 nodeTypeAdjuster | 放弃 `TextAttributeOverrideProvider` 的颜色覆盖，改为通过 `SourceModelLanguageService.nodeTypeAdjuster` 改写解析器节点类型——框架自身的扩展点。收益扩展到 `tokenRangeAtPosition` 等依赖解析结果的行为。查明继承 `GenericLanguageService` 不可行（conformance 由协议扩展默认实现见证，静态派发）。 |
| 2026-08-15 | 主题必须写满 28 个键 | 只写部分键会让未写的键保留 Xcode 自带颜色，同一面板混着两套主题。同时修正多个 `SemanticType` 映射到同一键导致的覆盖：分组改为照抄 `ResolvedTheme.style(for:)`。 |
| 2026-08-15 | 记录离屏判据不可靠 | 离屏 harness 三次把实际正常的效果判成失败。今后颜色类结论一律以实机截图为准，离屏只用于证伪机制是否接通。 |
| 2026-08-15 | 纠正：dump 才是权威来源 | 上面几条「无法从导出符号恢复」的结论是错的——RuntimeViewer 自己的 per-type dump 直接给出超类、枚举 case 顺序与 PWT 偏移。今后重建接口一律先查 dump，`nm` 反推只作为没有 dump 时的退路。 |
| 2026-08-15 | 补第三条接口重建规律 | 类的超类写错（把 NSObject 派生类声明成 Swift 根类）只在**释放时**崩，构造与调用全程正常，实例活到进程结束就完全不显形。判据是 `_OBJC_CLASS_$` 符号，已固化为 `Stubs/AuditClasses.sh`。实测确认 `@objc deinit` 不是判据也不能修复。 |
| 2026-08-15 | 行号与背景修复 | 行号需要显式安装 `SourceEditorGutter` 并 `enableLineNumbers()`（视图默认不带 gutter）；背景另需设 `SourceEditorView.backgroundColor` 与容器背景，主题字典的背景键只管文本区。当前行高亮色由背景色推导，因为 `ThemeProfile` 没有这一项。 |
| 2026-08-15 | 附加显示能力落地（原落地步骤 A 的主体） | 折叠 / sticky header / minimap / 行号 / scope guides 五项接入，各自一个 Settings 开关。三个 `install*` 反汇编确认无前置依赖，折叠所需的 `FoldableLanguageService` 由 `SourceModelLanguageService` 现成 conform。查明 `install*` 不幂等（会重复注册 margin accessory 与 event consumer）而 `uninstall*` 与 `show/hideScopeGuides` 幂等，故 bridge 保存已应用状态、只在翻转时调用。 |
| 2026-08-15 | 结构性验证可以离屏做 | 「离屏判据不可靠」那条只针对渲染结果。装没装上是视图/图层树里有没有那个类，与 `cacheDisplay` 无关，8 轮全开/全关的计数 harness 是可信证据。顺带测出框架侧小泄漏：重装 minimap 每次多留 8 个高亮图层，严格线性，不为此绕开框架 API。 |
| 2026-08-15 | 行号一直没显示，真因是缺字体 | 此前记为「已完成」是错的——只验证了 gutter 视图存在，没验证行号有没有像素。`lineNumberFont` 为 nil 时行号图层测得 0×0、gutter 塌成 6pt，看起来像功能没接上。`.xccolortheme` 没有 gutter 键，字体只能由调用方传，故 `applyTheme` 增加 `lineNumberFont` 参数；改字体后还要再调一次 `enableLineNumbers()` 才会重绘。 |
| 2026-08-15 | 工具栏穿透需要显式传 content inset | `SourceEditorView` 把真正的滚动视图埋在里面，且 `installScrollView()` 关掉了 `automaticallyAdjustsContentInsets`，安全区传不进去，正文和 sticky header 画到了工具栏上。改为在 `viewDidLayout()` 把 editor view 的 `safeAreaInsets.top` 写进 `additionalScrollViewContentInsets.top`。这是 `NSTextView` 路径白拿、这里必须自己接的一项。 |
| 2026-08-15 | content inset 必须写 `default` 而非 `additional` | `additional` 是查找面板自己的通道，`present(_:)` 把面板高度写进去、冲掉我们放的工具栏偏移，面板也因此贴到窗口顶边。改写 `default` 后两者相加，⌘F 打开时面板落在工具栏下沿。这条是实测翻的案——先前从反汇编读成"两者相加所以互不影响"，是错的。 |
| 2026-08-15 | 加入 invisibles 开关 | 深层嵌套的 Swift 声明里缩进层数就是信息。`showInvisibles()` 自带主题（`SourceEditorTheme` conform `ShowInvisiblesTheme`），无需像 gutter 字体那样额外喂；但它拷走调用时的主题，换主题后必须重调。 |
| 2026-08-15 | sticky header 单行是框架设计 | `headerLineLayer` 给 line layer 传的宽度是 `nil`（指令级确认），即不限宽不换行；`StickyHeaderViewContents` 也只有一个 line layer。溢出尾部的淡出才是 `maxWidth` 的用途。Xcode 同行为，不改。 |
| 2026-08-15 | 设置面板文案更正（原落地步骤 D） | 「语法着色来自 Xcode 自己的 tokenizer，比内置视图不准」在语义高亮落地后已不成立，改为说明着色同样来自运行时元数据，并写明唯一例外是跨两段语义 run 的 token 保留框架自己的判断。 |
