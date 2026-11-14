# 0090 - 镜像种类图标换成 Xcode 的符号与颜色

- **状态**: Implemented
- **创建日期**: 2026-11-14
- **最后更新**: 2026-11-14

## 摘要

各处列出镜像时用的图标原来是几个随手挑的系统符号：framework 是 `latch.2.case`，bundle 是
`shippingbox`，App 与内核扩展没有自己的图标，判定写了三份（镜像树按节点名、Find 与 Report 只认
`.framework/`）。改为照 Xcode：framework、bundle、App、内核扩展用从 Xcode 提取的符号，文件夹与 dylib 用
Xcode 的 `folder.fill` 与 `building.columns.fill`，其他二进制用系统的 `doc.fill`；种类只在一处判定，侧栏、
路径栏、Find、Report、批量导出、标签、历史、镜像页与标题都走它。图标的颜色也照 Xcode 按种类定、各处一样：
文件夹、bundle 与内核扩展是 Xcode 自己的浅蓝，framework 系统黄，dylib Xcode 的钢灰，App 次要文字的灰，其他
二进制用强调色。

## 方案

**种类**：`RuntimeImageKind`（RuntimeViewerAppCore）七种——`folder`、`framework`、`bundle`
（`.bundle`、`.plugin`、`.xpc`、`.appex`）、`application`（`.app`）、`kernelExtension`（`.kext`）、
`dynamicLibrary`（`.dylib`）、`image`（其他二进制）。两种判法：

- 镜像树的节点按自己的名字：扩展名是几种包之一就是那一种，否则叶子按文件名是 `dynamicLibrary` 或
  `image`（`RuntimeImageKind(imageFileAt:)`）、其余是 `folder`。所以树里 `AppKit.framework` 是
  framework，它下面的 `AppKit` 是其他二进制，`libobjc.A.dylib` 是 dylib。
- 只列一个镜像的地方（Find、Report、标签、历史、镜像页）没有树，按路径上离它最近的那个包，不在任何包里
  才按文件本身：`RuntimeImageKind(ofImageAt:)`，AppKit 显示 framework，`/usr/lib/libobjc.A.dylib` 显示 dylib。
  标签的 `TabBarItem.Icon.image` 因此带上种类。

**符号**：framework、bundle、App、内核扩展四个符号放进 RuntimeViewerAppCore 自己的 asset catalog
（`Resources/Symbols.xcassets`，经 `Bundle.module` 取，`CustomSymbol` 列出全部），因为它不再依赖带资源的
UI 库。源文件是 Xcode 的 `doc-framework`、`doc-bundle.fill`、`doc-app.fill`、`doc-kext` 导出的 SF Symbols 7 模板，**降成
v6 模板放进来**：v7 比 v6 只多一条绘制动画的属性（`-sfsymbols-draw-reverses-motion-groups`），而 v6 是
macOS 15 那一代的模板、App 里已有的 `inject` 符号就是 v6；按 macOS 15 编出的两种 asset catalog 结构一致，
只差模板版本号。Find 的文件、头文件后缀、submodule 等其余符号这次不用。

**颜色**：`RuntimeImageKind.iconColor` 一处定义，取自 Xcode 27.2 的 DVTUserInterfaceKit——它的
`Xcode.SymbolicIcon` 扩展给每种文件类型配一个符号和一个颜色名（`tint`），颜色在同一框架的 asset catalog 里：

| 种类 | Xcode 的类型 | 符号 | 颜色 |
|------|-------------|------|------|
| 文件夹 | `public.folder` | `folder.fill` | `doc-lightBlue`：sRGB 70, 169, 255，深色 66, 173, 255，不是系统色 |
| framework | `com.apple.framework` | `doc-framework` | `doc-yellow`，即 `systemYellow` |
| bundle | `com.apple.bundle` | `doc-bundle.fill` | `doc-lightBlue` |
| 内核扩展 | `com.apple.kernel-extension` | `doc-kext` | `doc-lightBlue` |
| App | 产品类型 `com.apple.product-type.application` | `doc-app.fill` | 没有 `tint`，Xcode 画成 `secondaryLabelColor` |
| dylib | `com.apple.mach-o-dylib` | `building.columns.fill` | `doc-steel`：Display P3 98, 127, 147，深色 sRGB 183, 213, 235，不是系统色 |

其他二进制 Xcode 没有专门的图标，用系统的 `doc.fill` 与强调色。Xcode 的分组
（`com.apple.dt.xcode.nav-group`）是灰色文件夹，镜像树的文件夹是磁盘上真的目录，对应的是 `public.folder`。

两种画法，选中的行都和 Xcode 一样变白：

- **能给模板着色的视图**——侧栏的镜像树、Find 的镜像行、Report 的镜像行、批量导出的镜像列表、镜像页的大
  图标——画 `icon`（template），`contentTintColor` 设成 `iconColor`。行被选中时 AppKit 把带 tint 的模板画成
  白色，Xcode 的 `DVTTemplateIcon` 选中时也换成 `alternateSelectedControlTextColor`。侧栏、Find、Report 的
  行外观各多一个颜色字段，不是镜像的行（Report 的工作种类、Find 的函数）没有，照旧用各自的默认色。
- **原样画图的地方**——路径栏和它的菜单、编辑区的标签、历史菜单——用 `coloredIcon`：同一符号加调色板配置，
  非 template。AppKitPlus 的路径控件原样画非 template 的图；窗口不在前台时它照常把图标画淡。

来源（My Mac）的图标与对象图标不变。**标题图标**也用 `iconColor`（原来 bundle 棕色、其余蓝色）。

**没问就定的**：DriverKit 的 `.dext` 不算内核扩展，按文件夹显示；路径栏里不在树上的镜像
（直接挂在来源下的那种）与树里的文件一样按自己的文件名，不按所在的包——路径栏的形状就是那棵树。

**测试**：`RuntimeImageKindTests` 用已知路径与节点名逐种核对两种判法，用上表的数值核对每种的颜色（浅色、
深色两种外观），核对 `coloredIcon` 画出来是那个颜色、镜像树的行带上节点种类的颜色；`CustomSymbolTests` 载入
每个符号；Find 与 Report 的测试核对镜像行带颜色、别的行不带；路径栏的测试核对树上文件夹、framework 与镜像
文件的图标画出来的颜色。读回颜色的 `ImageColorSampling` 在 `RuntimeViewerAppTestingSupport`，两个测试
target 共用。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-14 | Created as Draft，方案经用户认可 | 用户给了从 Xcode 提取的符号，要统一各类镜像的图标，并给路径栏的图标按种类上色 |
| 2026-11-14 | 等 AppCore / AppUI 拆分合进 `next` 再动手 | 拆分改写的正是这几处图标定义，并让 AppCore 不再依赖 SFSymbols，同时做必然冲突 |
| 2026-11-14 | 镜像文件本身保持 `doc`，不用 Xcode 的 `module` | 用户的选择 |
| 2026-11-14 | 头文件、源文件后缀、submodule 与过滤菜单的符号这次不用 | 它们在 App 里没有对应的东西，用户同意先不用 |
| 2026-11-14 | 符号降成 v6 模板放进仓库 | App 最低支持 macOS 15；v6 是那一代的模板，App 已有的 v6 符号在那上面可用，v7 多出的只有一条绘制动画属性 |
| 2026-11-14 | 实现完成，待用户在 App 里看效果；镜像页的大图标也按所在的包显示 | 镜像页与它的标签显示同一个镜像，图标不该不同；镜像页本来就拿得到路径。没在 macOS 15 上实测，依据是编出的 asset catalog 与 App 已有的 v6 符号结构一致 |
| 2026-11-14 | AppKitPlus 依赖最低版本提到 0.22.0，四份锁文件随之更新 | 用户在路径栏里看到 framework 图标的右边被切掉。原因在 AppKitPlus 的路径控件：它把每个图标都放进 16 pt 的格子里画，宽过 16 pt 的符号被格子裁掉（换图标之前的 `latch.2.case` 也被切了约 2 pt，只是不显眼）；Xcode 的 jump bar 走另一条路，按字号配置符号、按对齐框居中、不裁。用户选择在 AppKitPlus 里照 Xcode 修，修复随 0.22.0 发布 |
| 2026-11-14 | 文件夹换成 `folder.fill`，各处图标按种类上 Xcode 的颜色，选中行变白 | 用户要求图标的符号与颜色都和 Xcode 一致，不只路径栏。颜色按 DVTUserInterfaceKit 的图标表取，不按截图调：原来路径栏的文件夹 `systemBlue`、bundle `systemCyan` 都不是 Xcode 的 |
| 2026-11-14 | App 用 Xcode 画它的次要文字灰，不用强调色 | 用户的选择。Xcode 没给 App 图标配颜色，没有颜色名时它取 `secondaryLabelColor` |
| 2026-11-14 | bundle 的符号换成实心的 `doc-bundle.fill` | 用户的选择：Xcode 给 bundle 用的就是它 |
| 2026-11-14 | 镜像文件不照 Xcode，保持 `doc` 与强调色 | 用户这次只点名了文件夹、framework、bundle、App；镜像文件此前定的是 `doc`（见上） |
| 2026-11-14 | dylib 单列一种，用 Xcode 的 `building.columns.fill` 与钢灰；App 换成实心的 `doc-app.fill`；其他二进制用 `doc.fill` | 用户的要求，推翻上一行「镜像文件保持 `doc`」：dylib 照 Xcode 的 library 图标与颜色，App 与其他二进制都用实心版。其他二进制 Xcode 没有专门的图标，颜色保持强调色 |
| 2026-11-14 | 侧栏镜像树的行收紧图标与标题的间距：图标离行首 2 pt，标题跟在图标右边 4 pt | 原来标题在图标右边 10 pt，换成更宽的实心符号后显得太空。先试过照 Xcode 项目导航器（`IDENavigatorDataCell`）把图标放进 16 pt 的槽、标题固定从 19 pt 开始，用户没有采用，改用自己调的这组值 |
| 2026-11-14 | 实现完成，落地为 0090 | 用户在 App 里看过。不另写使用指南或实现说明：种类、符号与颜色都在 `RuntimeImageKind` 一处，各处该用 `icon` 还是 `coloredIcon` 已写在它的文档注释和 `RuntimeViewerPackages/Sources/AGENTS.md` 里。没有新术语。没做的验证：v6 符号没在 macOS 15 上实测（依据见上）；iOS 侧栏只加了一行着色，没编 iOS |
