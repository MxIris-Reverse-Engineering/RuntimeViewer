# 愿景：自建代码视图引擎

- **状态**: Active
- **最后更新**: 2026-08-15
- **相关提案**: [0009](../Evolutions/0009-content-editor-engine-selection.md)、[0010](../Evolutions/0010-interface-snapshot-export.md)

愿景**不做具体决定**，它划定一个方向的边界与取舍原则，让后续每个提案不必重新论证一遍。

## 这是什么领域

RuntimeViewer 里**把已经生成好的 interface 文本显示出来**的那一层。

**算在里面**：文本布局与渲染、行号与各类边栏、折叠、缩进参考线、sticky header、
minimap、选区与高亮、查找、⌘-click 跳转、主题、导出成图片。

**不算在里面**：interface 是怎么从运行时元数据生成的（`RuntimeViewerCore` 那一侧）、
侧边栏与 Inspector 的信息架构、文档与 XPC。

一句话：**输入是一份带语义标注的富文本，输出是一个能读、能跳、能找的视图。**

## 为什么值得系统性投入

这不是"再加一个功能"，而是"这一整片区域现在有三种互斥的实现路线，必须选一条"。
不定方向的话，接下来每个提案都要把同一套理由重吵一遍：这一项要不要依赖 Xcode？
要不要照抄框架的分层？语义从哪来？

判据满足：一个提案解决不了——光是把布局核心立起来就得独立成篇，边栏、覆盖层、折叠、
查找各自还要一篇，每篇都得能单独构建、单独验证。

## 现状与代价

今天同一个内容面板有两套实现，都不够：

| | `NSTextView` + TextKit 2 | Xcode `SourceEditor` |
|---|---|---|
| 能否公开发布 | 能 | **不能**——框架是 Xcode 里的 Apple 二进制，不可分发 |
| 需要装 Xcode | 否 | **是** |
| 折叠 / sticky header / 查找栏 / scope guides | 无 | 有 |
| 5MB 文档最坏帧 | **25.08 ms（掉帧）** | 9.43 ms |
| 首屏 | 11.3 ms | 0.8 ms（不随文档增大） |
| 5MB 装载 | **18.4 ms** | 384.1 ms |

（数据出自 0009 的 spike 实测。）

代价具体到三条：

1. **公开发布版永远拿不到这些能力。** 现在的 opt-in 开关不是产品决策，是这个约束的产物——
   开关存在的唯一原因就是"不能保证用户有 Xcode"。
2. **每加一项能力都要交两道税。** 接口重建的税是机械的（0009 记了三条规律）；
   行为的税不是。今天加七个显示项，其中三个是"声明完全正确但就是不工作"：
   `lineNumberFont` 不设行号图层全是 0×0；content inset 写错字段会被查找面板冲掉；
   `install*` 不幂等而 `uninstall*` 幂等。这些只能靠反汇编加实测 harness 一个一个查。
3. **能力上限由别人定。** sticky header 单行截断是框架写死的
   （`layoutAndSizeToWidth` 传 `nil`），我们改不了。

## 根本的设计取舍

### 一、抄架构，还是抄 API

**抄 API**：把 1327 个类型重建成能编译的 stub，继续调用 Apple 的实现。
代价是永远带着"需要 Xcode"和"行为要一条条实测"这两条，且能力上限不归自己。

**抄架构**：读懂它的分层，自己写。代价是要真的写出一台布局引擎，且短期内能力不如原件。

### 二、只读专用，还是通用编辑器库

**只读专用**：把"文本不可变""语义由调用方给"写死进 API。
砍掉 journal / undo / managed range / edit assistant / 补全 / 重构 —— 也就是框架的大半。

**通用库**：留出语言无关的扩展点，别的项目也能用。那基本等于把 SourceEditor 的协议分层
照抄一遍，工作量上一个数量级。

### 三、语义从哪来：自己解析，还是生成侧直供

**自己解析**：像 `SourceModel` 那样从文本反推标识符类别、可折叠区间、作用域。
好处是任意文本都能显示。

**生成侧直供**：RuntimeViewer 在生成 interface 时**本来就知道**每个标识符是什么、
每个声明的范围在哪。直接把这些交给视图，一行解析代码都不写。
坏处是这个引擎只能显示自己生成的东西。

### 四、几何模型：按行分层，还是一整块

**按行分层**（SourceEditor 的做法）：每行一个 `CALayer`，只物化可见行。
首屏恒定 0.8 ms 就是这么来的。代价是要自己管图层池、可见范围、换行分片。

**一整块**（TextKit 2）：交给系统，惰性布局。代价是账在滚动时还——5MB 最坏帧 25 ms。

### 五、扩展点：小协议 + 提供者数组，还是子类化 / 单一委托

`SourceEditorLayoutManager` 上挂着**九个提供者数组**：

```swift
var layoutVisualizations: [LayoutVisualization]
var marginAccessories: [SourceEditorMarginAccessory]
var layoutOverrideProviders: [LayoutOverrideProvider]
var textAttributeOverrideProviders: [TextAttributeOverrideProvider]
var lineHighlightOverrideProviders: [LineHighlightOverrideProvider]
var columnShiftOverrideProviders: [ColumnShiftOverrideProvider]
var lineFragmentOverlayProviders: [LineFragmentOverlayProvider]
var lineAuxiliaryContentProviders: [LineAuxiliaryContentProvider]
var lineLayerRangeOverrideProviders: [LineLayerRangeOverrideProvider]
var hiddenTextOverrideProviders: [HiddenTextOverrideProvider]
```

每个协议都很小：`LayoutVisualization` 是 6 个方法**全带默认实现**的布局生命周期钩子，
`HiddenTextOverrideProvider` 只有 2 个方法，`LineAuxiliaryContentProvider` 只有 1 个。
`SourceEditorMarginAccessory` 继承 `LayoutVisualization` 再加锚点、优先级、宽度。

代价：抽象层数多，初次读起来绕。

**子类化 / 单一委托**：直接了当，但每加一种视觉效果都要改核心类。

### 六、几何变化怎么表达：叠加效果，还是改文本

布局管理器上还有一组**效果字典**：

```swift
var lineExpansionEffects: [Int: CGFloat]
var lineShiftEffects: [Int: CGPoint]
var columnExpansionEffects: [Int: [Int: CGFloat]]
var columnShiftEffects: [Int: [Int: (shift: …, padding: CGFloat, text: NSAttributedString?)]]
```

也就是说**折叠、内联注解、动画全部靠"在原文之上叠加几何效果"实现，文本一个字都不改**。
折叠 = `hiddenTextOverrideProvider` + `lineExpansionEffects`。

另一条路是改文本（真的把折叠掉的行删掉再重排），代价是所有偏移都要重算、
跳转和查找的坐标全部失效。

## 我们选的方向

**一、抄架构，不抄 API。** 逆向的产物是理解，不是 stub。现有的 `Stubs/` 继续按需扩，
但它的定位从此是"参照物"，不是"要抄完的 SDK"。

**二、先只读专用，但保留抽缝。**（**这一条待确认**——见文末。）
默认按只读做：文本不可变、语义由调用方给，先把引擎立起来。但模块边界照通用库的样子切，
将来要抽成独立库时不用推倒重来。放弃的是：短期内不追求"别的项目能直接用"。

**三、语义由生成侧直供。** 这是我们相对 Xcode 唯一的结构性优势，必须吃干净。
它同时解释了性能上唯一输的那一项——SourceEditor 5MB 装载要 384 ms，是因为它在装载时
做了全量词法分析和着色；我们不需要，**装载这一项有机会同时赢过两边**。

**明确放弃**：这个引擎不打算显示任意语言的任意文件。它只显示 RuntimeViewer 自己生成的东西。

**四、按行分层。** 首屏与滚动的确定性是采纳方案 B 的主要理由，自建就必须保住它。

**五、小协议 + 提供者数组。** 抄它的分层。今天接 `nodeTypeAdjuster` 只花了几十行，
就是这个分层的直接收益。

**六、叠加效果，不改文本。** 文本在布局期不可变，所有视觉变化都是叠加层。
这条与「二」相互加强：只读 + 不可变文本，等于把整个 journal / managed range 体系一起省掉。

### 这个方向放弃了什么

- **短期内能力不如原件。** 自建版本在很长一段时间里会比接 SourceEditor 少功能。
  两条路要并存一段时间——0009 那套不会因为这个愿景就被删掉，它同时是参照物和退路。
- **通用性。** 不做任意语言、不做编辑。
- **"照抄就能对"的确定性。** 抄 API 至少行为和 Xcode 一致；自己写就要自己定义正确。

## 我们有一个别人没有的条件

**原件就在旁边跑着，可以对拍。** 每一步都能拿同一份文本、同一个宽度，
跟 SourceEditor 比几何与帧时间。0009 期间写的 harness 已经在量这些：
视图/图层树的类名与尺寸、content inset、sticky header 的窗口坐标。

而且 RuntimeViewer 自己导出的 dump **带字段偏移**，等于给出了每个对象存了哪些状态。
`SourceEditorDataSource` 存 `lineData: ContiguousArray<SourceEditorLineData>` 与
`utf8RangeData: [NSRange]`，这两行就说明行索引与字节范围是分开缓存的。

## 分阶段设想

只给轮廓，顺序和拆分都可以调整。

1. **视口布局核心。** 行数据模型、按行的图层池、可见范围物化、换行分片。
   验收：同文本同宽度下几何与 SourceEditor 一致，帧时间对拍不劣于它。
2. **边栏机制 + 行号。** 照抄 margin accessory 的锚点/优先级/宽度分层，行号是第一个使用者。
3. **覆盖层机制。** scope guides、当前行、选区、invisibles、mark separators 挂上去。
4. **折叠。** 折叠区间由生成侧直接给；用「叠加效果」而非改文本实现。
5. **sticky header。** 同样吃生成侧的作用域信息。可以顺手做成多行——原件那个单行截断
   是它自己的限制，不是我们的。
6. **查找。** 与 `NSTextFinder` 对接，或自建。

导航（⌘-click）不单列一步：`.link` attribute 那条路与引擎无关，两套实现都已经在用。

## 不在此愿景内

- **编辑**。文本插入、删除、undo、edit assistant、自动缩进。
- **代码补全、重构、diagnostics、Vim 模式。** 都需要真实的编译器或 index 后端。
- **通用解析器。** 不写 `SourceModel` 的对应物。
- **iOS / Catalyst 上的对应实现。** 现在只谈 macOS；要不要跟进另议。
- **把 `Stubs/` 抄完。** 明确否掉——理由见「一」。

## 待确认

**取舍二**（只读专用 vs 通用库）当前按「先只读、保留抽缝」推进，但这是我的建议而非已决。
它影响第 1 步的 API 形状：只读专用可以把"语义由调用方给"写死进签名，通用库必须留扩展点。
定了之后回来更新本节与「我们选的方向」。

## 相关提案

| 提案 | 状态 | 它推进了愿景的哪一部分 |
|------|------|------------------------|
| [0009](../Evolutions/0009-content-editor-engine-selection.md) | Accepted | 参照物与退路：接入 SourceEditor，并沉淀了对它架构与行为的实测认识 |
| [0010](../Evolutions/0010-interface-snapshot-export.md) | Draft | 导出成图片。方案 A（自己排版）本身就是「不依赖框架」这一方向的第一次实践 |

---

> **愿景是活文档**，随认识加深可以修订，修订时更新「最后更新」。
