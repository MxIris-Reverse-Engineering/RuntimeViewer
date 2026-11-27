# Draft - 对象图标改用 AppKitPlus 的 NSIcon 绘制

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-27
- **最后更新**: 2026-11-28
- **所属愿景**: 无
- **关联提案**: [0091 - AppCore / AppUI 拆分](0091-app-core-ui-split.md)（定下「AppCore 选字形、AppUI 画字形」的分工与 `runtimeObjectIconRendering`）
- **实现分支 / PR**: `feature/nsicon-object-icons`（worktree `.worktrees/RuntimeViewer-NSIconObjectIcons`）
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

运行时对象前面的 Xcode 风格字母图标（橙色 `C`、紫色 `Pr`、蓝色 `Ex`……）目前由 UIFoundation 的 `IDEIcon`
画，它是对开源项目 ide-icons 的移植，形状、字体和留边都不是 Xcode 的。本提案把唯一的渲染器
`IDEIconRuntimeObjectIconRenderer` 换成用 AppKitPlus 的 `NSIcon`（Xcode 27 `DVTGeneratedIconSpec` 的复刻）画，
macOS 与 iOS / visionOS 共用同一份代码——iOS 一侧经 AppKitPlus-Release 同包发布的 UIKitPlus 拿到同名的
`NSIcon`。底板铺满图标框，图标按原样作为一张图片交给各个视图，选中行的样子不变；随后去掉 UIFoundation 的
`IDEIcons` trait。

## 动机

- **形状和字体不是 Xcode 的。** `IDEIcon` 在 18pt 的框里画一个内缩 1pt、圆角 4.5 的普通圆角矩形，字母是 12pt 的
  系统字体 semibold（`UIFoundation/Sources/UIFoundationShared/IDEIcons/IDEIcon+Image.swift`，`.simple` 分支与
  `fontSize = (size / 1.5).rounded()`）。Xcode 的代码符号图标是连续圆角的 squircle（圆角为边长的五分之一），
  字母是 SF Pro Rounded，字号按 Xcode 自己的表取（16pt 图标里 11pt）。RuntimeViewer 处处照 Xcode 做界面
  （Find 导航器、跳转栏、侧栏浮层栏），唯独这些图标是仿的。
- **尺寸和 Xcode 对不上。** RV 有几处直接照 Xcode 的度量取了 16pt 图标框（Find 导航器
  `FindResultCellStyle.Metrics.iconSize`、跳转栏、运行时来源弹窗、历史菜单），但 `IDEIcon` 在框里留了 1pt 透明边，
  画出来的底板只有 14pt，比 Xcode 同一位置小一圈。
- **iOS 上不跟深浅色。** `IDEIcon` 在 iOS 上先画成一张固定颜色的 `CGImage`（`IDEIcon.cgImage`），渲染器又按字形
  永久缓存它，所以系统切换深浅色后图标仍是第一次画时的颜色。`NSIcon` 在 iOS 上给出的图片在 `imageAsset`
  里带着浅色、深色、高对比度各一份画法，`UIImageView` 自己挑。
- **上游已经具备。** AppKitPlus 已经复刻了 Xcode 的图标绘制并在 0.24.0 随 UIKitPlus 发布到 iOS / visionOS，RV
  已经依赖 AppKitPlus 0.24.0；继续维护一套仿制品没有理由。

## 前期调研

- **现状代码怎么走的**
  - AppCore 只选字形：`RuntimeObjectIcon.Glyph(text:color:style:size:)`
    （`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/RuntimeObject/RuntimeObjectIcon.swift`），颜色与样式是
    `IDEIconColor` / `IDEIconStyle` 的同名镜像，AppCore 不依赖任何 UI 库（`RuntimeViewerPackages/Sources/AGENTS.md`）。
  - AppUI 画字形：`RuntimeObjectIcon.image(for:)` 读依赖 `runtimeObjectIconRendering`
    （`RuntimeViewerAppUI/RuntimeObject/RuntimeObjectIcon+Image.swift`），live 值是
    `IDEIconRuntimeObjectIconRenderer`（`RuntimeViewerAppUI/RuntimeObject/IDEIconRuntimeObjectIconRenderer.swift`），
    test 值是画空白图的 `BlankRuntimeObjectIconRenderer`。两者都经 `RuntimeObjectIconImageCache` 保证同一字形永远
    返回同一个图片对象（视图比对图片是否相同来决定重画，`RuntimeObjectIconGlyphTests.sameGlyphSameImage`）。
  - 全仓库用到 `IDEIcon` 的只有这个渲染器和它的测试 `IDEIconRuntimeObjectIconRendererTests`，以及
    `Package.swift` 里 `uiFoundationTraits` 的 `"IDEIcons"`；App 工程（macOS、iOS）里没有一处直接写 `IDEIcon`。
  - 这个渲染器没有平台条件：iOS、visionOS App 链接同一个 `RuntimeViewerAppUI`，今天在 iOS 上也是 `IDEIcon` 在画。
  - 生产代码只用到 `.simple` 一种样式（`defaultIconStyle`）；`.default`、`.outline`、`.simpleHighlighted` 和颜色
    `.monochrome` 只在渲染器的映射和测试里出现（`rg` 全仓库核对过）。AppCore 实际用到的颜色：blue、gray、
    green、orange、pink、purple、teal。
  - 图标框尺寸：macOS 默认 18pt（侧栏、检查器、特化选择器），iOS 默认 24pt；跳转栏、Find、来源弹窗、历史菜单
    16pt；检查器 References 页 14pt。多数视图按图片自身尺寸布局（侧栏 `RuntimeObjectCellView` 的 `ImageView`），
    Find 的图标视图约束为 `metrics.iconSize`。
- **上游已具备的能力**（AppKitPlus 0.24.0，`AppKitPlus/Icons/NSIcon.h`、`NSGeneratedIconSpecification.h`）
  - `NSGeneratedIconSpecification(letters:shape:backgroundColor:glyphColor:)`：字母放在底板上，`.squircle` 即 Xcode
    代码符号图标的形状，`glyphColor: nil` 为白字。
  - `NSIcon(generatedIconSpecification:)`：按规格缓存的图标；`image(of:)` 给出指定尺寸的图片，图标铺满整个尺寸；
    `highlightedImage(of:)` 是选中行用的白底、字母镂空的那张。`NSIcon` 线程安全（头文件 *Threading*：「icons can be
    made, varied and drawn on any thread」）。
  - `NSIconColor` 是 Xcode 的 28 种颜色，`.color` 取 `NSColor` / `UIColor`。其中 `.blue`、`.brown`、`.gray`、
    `.green`、`.orange`、`.pink`、`.red`、`.teal`、`.yellow` 就是同名系统色，`.pinkishPurple` 是 `systemPurple`，
    `.purple` 是 `systemIndigo`，`.ocean` 是 `systemMint`，`.coreML` 是 `systemCyan`——`IDEIcon` 的 `.simple`
    样式用的正是这些系统色（`IDEIconColor.simpleColor`），所以颜色一个不变。
  - macOS 上 `image(of:)` 的图片在每次绘制时按当时的外观取色；iOS 上它按当前 trait 的屏幕倍率画（没有指定时
    取 2），`imageAsset` 里带深浅色与高对比度的各一份。
  - UIKitPlus 与 AppKitPlus 编同一批源文件，Swift 里的类型名与方法名完全相同，只有模块名不同（`UIKitPlus`），
    是一个动态 framework，支持 iOS 17、visionOS 1，**不支持 tvOS 与 Mac Catalyst**（发布包 `Package.swift`）。
    0.24.0 是第一个带 UIKitPlus 的版本，RV 的下限正是 `from: "0.24.0"`，不用抬版本。
- **验证过什么**
  - `IDEIcon` 的 `.simple` 在框内留 1pt 边：`bounds.insetBy(borderWidth)`，macOS 上 `borderWidth = 1`；iOS 上按像素
    画，同样是 1pt。`NSIcon.image(of:)` 不留边。
  - 越狱版打包脚本 `BuildJailbrokenIPAScript.sh` 按目录查找内嵌 framework 再签名（「Found rather than listed」），
    多出一个 `UIKitPlus.framework` 不用改脚本。
  - **推测，实现时核对**：iOS 上渲染器在 cell 配置时于主线程调用，此时 `UITraitCollection.current` 是主屏的
    trait，`image(of:)` 按主屏倍率出图；若在 3x 机型上发糊，再按窗口场景的 `displayScale` 处理。

## 提议方案

1. AppUI 新增渲染器 `NSIconRuntimeObjectIconRenderer`，取代 `IDEIconRuntimeObjectIconRenderer` 成为
   `runtimeObjectIconRendering` 的 live 值。每个字形画成
   `NSIcon(generatedIconSpecification: NSGeneratedIconSpecification(letters: glyph.text, shape: .squircle, backgroundColor: NSIconColor(glyph.color).color, glyphColor: nil))`
   的 `image(of:)`，尺寸就是 `glyph.size`，底板铺满；`.simpleHighlighted` 取 `highlightedImage(of:)`。照旧经
   `RuntimeObjectIconImageCache` 每个字形只画一次、永远返回同一张图。
2. 这个文件只有 `import` 一处按平台分（`AppKitPlus` / `UIKitPlus`），其余代码两个平台一字不差。
3. `Package.swift`：`RuntimeViewerAppUI` 在 iOS、visionOS 上依赖 AppKitPlus-Release 的 `UIKitPlus` 产品；
   `uiFoundationTraits` 去掉 `"IDEIcons"`。
4. AppCore 的 `Glyph.Color` 删掉 `.monochrome`，`Glyph.Style` 删掉 `.default`、`.outline`：生产代码没用过它们，
   `NSIcon` 也没有对应的画法。其余颜色与样式名字不变，文档注释改为指向 `NSIconColor` 与 `NSIcon` 的两张图。
5. 测试与文档里写着 `IDEIcon` 的地方一并改掉。

### 非目标

- **不做选中行反白。** `NSIcon` 能在选中行显示白底镂空的图标，但那要把各列表的图标视图换成 `NSIconView`（iOS
  按选中状态换图），涉及十几个 cell；这次各处仍拿一张图片，选中时样子不变。
- **不改图标框尺寸。** `defaultIconSize`（18 / 24）和各处的 16、14 都不动；底板铺满后，侧栏这类 18pt 的框里
  底板比现在大 2pt，这是选定的结果。
- **不用 `NSIcon` 现成的代码符号图标**（`NSIcon.codeSymbolIcon(named: .class)` 等）。RV 的配色与 Xcode 的不同
  （Objective-C 类是橙色、Swift 类型是蓝色，Xcode 的类一律紫色），字母与颜色仍由 AppCore 的 `glyphContent(for:)` 决定。
- **不接入非焦点编辑栏的图标变灰**（`NSIcon.forInactivePane()`）。
- **不支持 tvOS。** UIKitPlus 没有 tvOS 切片；RV 的 iOS 工程名义上列了 tvOS，但没有任何构建或发布走 tvOS，
  接入后 `RuntimeViewerAppUI` 在 tvOS 上编不过。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerPackages/Package.swift` · `RuntimeViewerAppUI` | 修改 | 依赖加 `.product(name: "UIKitPlus", package: "AppKitPlus-Release", condition: .when(platforms: [.iOS, .visionOS]))` | iOS / visionOS 上拿到 `NSIcon` | 1 |
| `RuntimeViewerPackages/Package.swift` · `uiFoundationTraits` | 修改 | 去掉 `"IDEIcons"` | 不再有人用 `IDEIcon` | 1 |
| `RuntimeViewerPackages/Package.resolved` | 修改 | 只把 `originHash` 换成新 `Package.swift` 的 sha256，pin 一个不动 | 清单变了，原 hash 对不上会让 SwiftPM 整体重新解析、抬高别的依赖 | 1 |
| `RuntimeViewerAppUI/RuntimeObject/NSIconRuntimeObjectIconRenderer.swift` · `NSIconRuntimeObjectIconRenderer` | 新增 | 用 `NSIcon` 画字形；`NSIconColor.init(_: RuntimeObjectIcon.Glyph.Color)` 映射颜色 | 本提案的主体 | 1 |
| `RuntimeViewerAppUI/RuntimeObject/IDEIconRuntimeObjectIconRenderer.swift` · `IDEIconRuntimeObjectIconRenderer`、`IDEIconColor.init(_:)`、`IDEIconStyle.init(_:)` | 删除 | 整个文件 | 被新渲染器取代 | 1 |
| `RuntimeViewerAppUI/RuntimeObject/RuntimeObjectIcon+Image.swift` · `RuntimeObjectIconRenderingKey` | 修改 | `liveValue` 换成 `NSIconRuntimeObjectIconRenderer()`；协议与 key 的文档注释改指 `NSIcon` | 切换 live 值 | 1 |
| `RuntimeViewerAppCore/RuntimeObject/RuntimeObjectIcon.swift` · `Glyph.Color`、`Glyph.Style` | 修改 | 删 `.monochrome`、`.default`、`.outline`；文档注释改指 `NSIconColor` 与 `NSIcon` 的两张图 | 没有用处，也没有对应画法 | 1 |
| `RuntimeViewerAppCore/Main/NavigationHistorySnapshot.swift` · `iconSize` | 修改 | 注释里的 `IDEIcon` 改成 `NSIcon` | 注释过时 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/NSIconRuntimeObjectIconRendererTests.swift` | 新增 | 颜色映射、铺满尺寸、两种样式与 `NSIcon` 的输出一致 | 守住渲染器的契约 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/IDEIconRuntimeObjectIconRendererTests.swift` | 删除 | 整个文件 | 对照的对象没了 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/RuntimeObjectIconGlyphTests.swift` | 修改 | 注释指向新测试 | 注释过时 | 1 |
| `RuntimeViewerPackages/Sources/AGENTS.md` | 修改 | 图标一段的 `IDEIcon` 改成 `NSIcon`；「`IDEIcon` 没加锁所以测试在主线程」改成按现状描述 | 文档与代码同批 | 2 |
| `RuntimeViewerPackages/Tests/AGENTS.md` | 修改 | 对照 UI 库的测试清单里换成新测试名 | 同上 | 2 |
| `AGENTS.md`（根）· *Dependency floors* | 修改 | AppKitPlus `0.24.0` 一句补上「也是第一个带 UIKitPlus 的版本，iOS 与 visionOS 的对象图标用它的 `NSIcon` 画」 | 记下下限的又一个理由 | 2 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案 | 索引 | 0 |

## 架构图

依赖与绘制关系，改了什么：

```text
RuntimeViewerAppCore
└── RuntimeObjectIcon.Glyph            (text, color, style, size)  ~ Color -monochrome, Style -default -outline
        │  RuntimeObjectIcon.image(for:) → @Dependency(\.runtimeObjectIconRendering)
        ▼
RuntimeViewerAppUI
├── RuntimeObjectIconRenderingKey
│   ├── liveValue: - IDEIconRuntimeObjectIconRenderer
│   │              + NSIconRuntimeObjectIconRenderer
│   └── testValue:   BlankRuntimeObjectIconRenderer   (unchanged)
├── - IDEIconRuntimeObjectIconRenderer ──► UIFoundation.IDEIcon        (trait "IDEIcons" -)
└── + NSIconRuntimeObjectIconRenderer
        ├── macOS ─────────────► AppKitPlus.NSIcon / NSGeneratedIconSpecification / NSIconColor
        └── iOS, visionOS ─────► UIKitPlus.NSIcon  / NSGeneratedIconSpecification / NSIconColor   (+ dependency)
```

一个字形画成图片的调用链：

```text
cell view: appearance.primaryIcon?.image            (IconDescriptor.glyph)
└── RuntimeObjectIcon.image(for: glyph)
    └── NSIconRuntimeObjectIconRenderer.image(for:)
        └── RuntimeObjectIconImageCache.image(for:drawing:)     (first time only)
            ├── NSGeneratedIconSpecification(letters: glyph.text, shape: .squircle,
            │                                backgroundColor: NSIconColor(glyph.color).color, glyphColor: nil)
            ├── NSIcon(generatedIconSpecification:)
            └── .simple            → icon.image(of: CGSize(width: glyph.size, height: glyph.size))
                .simpleHighlighted → icon.highlightedImage(of: …)
```

## 详细设计

```swift
import Foundation
import RuntimeViewerAppCore
#if os(macOS)
import AppKitPlus
#else
import UIKitPlus
#endif

/// Draws an object's icon as Xcode draws a code symbol's — the glyph's letters on a squircle of one of
/// Xcode's icon colours — with AppKitPlus's `NSIcon` (UIKitPlus's on iOS and visionOS), and keeps each
/// image it drew: the same glyph always gives back the same image.
final class NSIconRuntimeObjectIconRenderer: RuntimeObjectIconRendering {
    private let imageCache = RuntimeObjectIconImageCache()

    func image(for glyph: RuntimeObjectIcon.Glyph) -> NSUIImage {
        imageCache.image(for: glyph) { glyph in
            let specification = NSGeneratedIconSpecification(
                letters: glyph.text,
                shape: .squircle,
                backgroundColor: NSIconColor(glyph.color).color,
                glyphColor: nil
            )
            let icon = NSIcon(generatedIconSpecification: specification)
            let imageSize = CGSize(width: glyph.size, height: glyph.size)
            switch glyph.style {
            case .simple: return icon.image(of: imageSize)
            case .simpleHighlighted: return icon.highlightedImage(of: imageSize)
            }
        }
    }
}

extension NSIconColor {
    /// The icon colour drawn for a glyph colour: the system colour of the same name, which is what the
    /// glyph colours have always been.
    init(_ color: RuntimeObjectIcon.Glyph.Color) {
        switch color {
        case .blue: self = .blue
        case .brown: self = .brown
        case .gray: self = .gray
        case .green: self = .green
        case .orange: self = .orange
        case .pink: self = .pink
        case .purple: self = .pinkishPurple   // systemPurple
        case .red: self = .red
        case .teal: self = .teal
        case .yellow: self = .yellow
        case .indigo: self = .purple          // systemIndigo
        case .mint: self = .ocean             // systemMint
        case .cyan: self = .coreML            // systemCyan
        }
    }
}
```

- `NSIconColor` 是 Objective-C 的 `NS_ENUM`，Swift 里允许在扩展里加 `init`；它导入为非冻结枚举，但这里是从
  RV 自己的冻结枚举映射过去，`switch` 穷尽 `Glyph.Color` 即可。
- `RuntimeObjectIconImageCache` 不动：`NSIcon` 自己的图片缓存只在图片还被用着时有效，不能保证「同一字形永远
  同一对象」，这一条仍由 RV 的缓存负责。
- `Glyph.Style` 剩 `.simple` 与 `.simpleHighlighted` 两个值，名字不改，免得牵动 AppCore 与 AppUI 公开函数的
  默认参数；文档注释写明二者分别是 `NSIcon` 的主图与选中图。
- `Glyph.Color` 剩 13 个值，`monochrome` 删去；文档注释改为「画在同名系统色上，即 `NSIconColor` 里的对应颜色」。

## 替代方案考量

- **底板保持现在的大小（框内留 1pt 透明边）。** 否：要在渲染器里按平台各写一段补边的画图代码，iOS 上重画
  会丢掉 `imageAsset` 里的深浅色变体；而且 Find、跳转栏这些照 Xcode 取 16pt 框的地方，铺满后才和 Xcode 一样大。
- **铺满并把默认尺寸 18 改 16（iOS 24 改 22）。** 否：侧栏图标框变窄，标题左移 2pt，牵动所有用默认尺寸的
  视图布局；本次只换绘制。
- **连同选中行反白一起做（`NSIconView`）。** 否，留作以后：改动面是十几个 cell 与 iOS 的选中状态处理，与「换
  绘制」无关，可以单独成提案。
- **用 `NSIcon.codeSymbolIcon(named:)` 的现成图标。** 否：Xcode 的配色与 RV 用颜色区分语言的做法冲突（见非目标）。
- **让 UIFoundation 的 `IDEIcon` 改用 `NSIcon` 实现。** 否：UIFoundation 在 iOS 上不依赖 UIKitPlus，要先改上游并发版，
  而 RV 只需在自己的渲染器里换一行实现。

## 影响

### 用户可见变化

- 所有运行时对象的字母图标改成 Xcode 的样子：连续圆角的 squircle、SF Pro Rounded 字母，颜色不变。
- 底板铺满图标框：侧栏、检查器、特化选择器（18pt）与 iOS 列表（24pt）里比现在大 2pt；Find、跳转栏、来源弹窗、
  历史菜单（16pt）与 Xcode 同一位置一样大；检查器 References 页 14pt。图标框本身与行布局不变。
- iOS / visionOS 上图标随系统深浅色切换（之前停在第一次画时的颜色）。
- 选中行里的图标样子不变（非目标）。

### 可发现性

无新功能入口，打开 App 即看到新图标。

### 数据与配置兼容

无：图标不落盘，书签、设置、派生数据都不涉及。

### 平台与最低版本

- 最低版本不变：AppKitPlus 要求 macOS 14、UIKitPlus 要求 iOS 17 / visionOS 1，都低于 RuntimeViewerPackages 的
  macOS 15、iOS 18、visionOS 2。
- tvOS：`RuntimeViewerAppUI` 不再能为 tvOS 编译（UIKitPlus 无 tvOS 切片）；RV 不发布 tvOS 版，也没有 tvOS 构建。
- Mac Catalyst：不受影响，Catalyst 的 helper 与 service 是只加载 macOS 插件的外壳，不链接 `RuntimeViewerAppUI`。

### 发布

- iOS、visionOS、越狱版 App 多内嵌一个 `UIKitPlus.framework`（动态库，约 1.2 MB 的压缩包），由 Xcode 随包依赖自动
  嵌入并签名；越狱版打包脚本按目录找 framework，不用改。
- macOS 版不变（AppKitPlus 早已内嵌）；SwiftPM 解析时本来就会下载 UIKitPlus 的压缩包。
- 不涉及权限、entitlement、隐私清单、公证与 Sparkle。

## 落地步骤

0. **登记提案** —— 改动地图最后一行
   - 行为：提案以 `draft-nsicon-object-icons` 出现在两份索引里。
1. **换上新渲染器，删掉 IDEIcon**（已完成）—— 改动地图里步骤为 1 与 2 的各行：`Package.swift` 的 UIKitPlus 依赖与
   `IDEIcons` trait、`Package.resolved` 的 `originHash`、新渲染器与新测试、`RuntimeObjectIcon+Image.swift` 的 live 值、
   旧渲染器与旧测试、`Glyph` 的三个无用值、两处注释（原计划分两步：新渲染器的 `switch` 要穷尽 `Glyph`，
   三个无用值不删就编不过，而删了它们旧渲染器又编不过，所以合成一步）
   - 行为：`glyphColourIsTheSystemColourOfTheSameName`——13 种字形颜色各自画在同名系统色上（浅色与深色外观下
     解析出的 sRGB 分量与系统色一致）。
   - 行为：`simpleGlyphMatchesNSIcon`——与同规格 `NSIcon.image(of:)` 的输出逐字节相同。
   - 行为：`highlightedGlyphMatchesNSIconsHighlightedImage`——与 `highlightedImage(of:)` 的输出逐字节相同。
   - 行为：`plateFillsTheGlyphsSize`——14、16、18、24pt 的图片尺寸都等于 `glyph.size`，四条边的中点都是底板
     （不透明度大于 0.9；`IDEIcon` 留的 1pt 边在那里是透明的）。
   - 行为：`liveRendererIsTheNSIconOne`——`RuntimeObjectIconRenderingKey.liveValue` 是 `NSIconRuntimeObjectIconRenderer`。
   - 行为：`RuntimeObjectIconGlyphTests` 原有用例照旧通过（同一字形同一图片）；源码与清单里不再出现 `IDEIcon`。
   - 构建：macOS 包测试通过；iOS 与 visionOS 的 App 编译通过。
2. **文档**（已完成）—— 两份子目录 `AGENTS.md`、根 `AGENTS.md` 的依赖下限
   - 行为：文档里描述的渲染器、测试名、线程说明与代码一致。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不要：调用方契约（字形 → 图片、同一字形同一图片）没变，渲染器的取舍写在本提案与
  `Sources/AGENTS.md` 里已经够。
- **有没有引入新术语** —— 预计没有。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-27 | Created as Draft | 用户要求对象图标改用 AppKitPlus 的 `NSIcon`、不再用 UIFoundation 的 `IDEIcon`，iOS 一侧经 UIKitPlus 同样接入，两个平台共用一份代码。 |
| 2026-11-27 | 底板铺满图标框 | 用户选定：与 Xcode 同尺寸的地方完全一致、两个平台一份代码；18pt 框里底板大 2pt 是接受的代价。否掉了「保留 1pt 边」与「默认尺寸改 16」。 |
| 2026-11-27 | 只换绘制，不做选中反白 | 用户选定：各处仍显示一张图片；`NSIconView` 的选中反白改动面大，留作以后。 |
| 2026-11-27 | Accepted | 用户批准，开始实现。 |
| 2026-11-27 | 第 1、2 步合并 | 新渲染器的 `switch` 要穷尽 `Glyph.Color` 与 `Glyph.Style`，三个无用值不删新渲染器编不过，删了旧渲染器编不过，两步分不开。 |
| 2026-11-27 | `Package.resolved` 只改 `originHash` | `RuntimeViewerPackages/Package.resolved` 的 `originHash` 就是 `Package.swift` 内容的 sha256（SwiftPM `computeResolvedFileOriginHash`），清单一改就对不上，SwiftPM 会整体重新解析、把 swift-type-indexing 顺手抬到 0.2.0。改为保留原有 pin、只把 `originHash` 换成新清单的 sha256；三个 workspace 的锁文件不受清单影响，不动。 |
| 2026-11-27 | 包测试走本地依赖模式 | 按锁文件远端解析编不过（基线如此：next 钉的 MachOSwiftSection 要 MachOKitExtensions 未发版的接口，`extra argument 'recordsFunctionAddressReferences'`），包级构建与测试用 `USING_LOCAL_DEPENDENCIES=1` 原地跑，iOS 与 visionOS 的 App 用 `RuntimeViewer-Local.xcworkspace` 编。 |
| 2026-11-28 | 实现完成，待用户看过后收尾 | macOS 包测试中本提案的两个套件通过，AppCore 与 AppUI 整包跑出的 7 条失败都是记录在案的既有红灯（其中两条单独重跑通过）；iOS 与 visionOS 的 App 用本地依赖 workspace 编过，两个 App 包都嵌入了 `UIKitPlus.framework`。iOS 3x 屏是否发糊没有在设备或模拟器上看过。macOS App 没有单独编：App 代码只用到保留下来的颜色与样式。 |
| 2026-11-28 | 配套文档与术语 | 不配使用指南或实现说明：调用方契约（字形 → 图片、同一字形同一图片）没变，渲染器的取舍写在本提案与 `RuntimeViewerPackages/Sources/AGENTS.md`；没有新术语。 |
