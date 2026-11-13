# Draft - 镜像种类图标换成 Xcode 的符号，路径栏的图标上色

- **状态**: In Progress
- **创建日期**: 2026-11-14
- **最后更新**: 2026-11-14

## 摘要

各处列出镜像时用的图标原来是几个随手挑的系统符号：framework 是 `latch.2.case`，bundle 是
`shippingbox`，App 与内核扩展没有自己的图标，判定写了三份（镜像树按节点名、Find 与 Report 只认
`.framework/`）。改为照 Xcode：framework、bundle、App、内核扩展用从 Xcode 提取的符号，文件夹与镜像
文件本身仍用系统的 `folder` 与 `doc`；种类只在一处判定，侧栏、路径栏、Find、Report、批量导出、标签、
历史、镜像页与标题都走它。编辑栏的路径栏给图标上色：文件夹蓝、framework 黄、bundle 浅蓝，其余用强调色。

## 方案

**种类**：`RuntimeImageKind`（RuntimeViewerAppCore）六种——`folder`、`framework`、`bundle`
（`.bundle`、`.plugin`、`.xpc`、`.appex`）、`application`（`.app`）、`kernelExtension`（`.kext`）、
`image`。两种判法：

- 镜像树的节点按自己的名字：扩展名是上面几种之一就是那一种，否则叶子是 `image`、其余是 `folder`。
  所以树里 `AppKit.framework` 是 framework，它下面的 `AppKit` 是镜像文件。
- 只列一个镜像的地方（Find、Report、标签、历史、镜像页）没有树，按路径上离它最近的那个包：
  `RuntimeImageKind(ofImageAt:)`，AppKit 显示 framework，`/usr/lib/libobjc.A.dylib` 显示镜像。
  标签的 `TabBarItem.Icon.image` 因此带上种类。

**符号**：framework、bundle、App、内核扩展四个符号放进 RuntimeViewerAppCore 自己的 asset catalog
（`Resources/Symbols.xcassets`，经 `Bundle.module` 取，`CustomSymbol` 列出全部），因为它不再依赖带资源的
UI 库。源文件是 Xcode 的 `doc-framework`、`bundle`、`app`、`doc-kext` 导出的 SF Symbols 7 模板，**降成
v6 模板放进来**：v7 比 v6 只多一条绘制动画的属性（`-sfsymbols-draw-reverses-motion-groups`），而 v6 是
macOS 15 那一代的模板、App 里已有的 `inject` 符号就是 v6；按 macOS 15 编出的两种 asset catalog 结构一致，
只差模板版本号。Find 的文件、头文件后缀、submodule 等其余符号这次不用。

**路径栏的颜色**（RuntimeViewerAppUI，下拉菜单的行一样）：文件夹 `systemBlue`、framework
`systemYellow`、bundle `systemCyan`，App、内核扩展与镜像文件 `controlAccentColor`；来源（My Mac）的图标与
对象图标不变。AppKitPlus 的路径控件原样画非 template 的图，所以带调色板配置的符号直接可用；窗口不在前台时
它照常把图标画淡。

**标题图标**照旧：bundle 棕色，其余蓝色，判定换成 `RuntimeImageKind`。

**没问就定的**：DriverKit 的 `.dext` 不算内核扩展，按文件夹显示；路径栏里不在树上的镜像
（直接挂在来源下的那种）与树里的镜像文件一样用 `doc`，不按所在的包——路径栏的形状就是那棵树。

**测试**：`RuntimeImageKindTests` 用已知路径与节点名逐种核对两种判法；`CustomSymbolTests` 载入每个符号；
路径栏的测试核对文件夹、framework 与镜像文件的图标画出来的颜色。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-14 | Created as Draft，方案经用户认可 | 用户给了从 Xcode 提取的符号，要统一各类镜像的图标，并给路径栏的图标按种类上色 |
| 2026-11-14 | 等 AppCore / AppUI 拆分合进 `next` 再动手 | 拆分改写的正是这几处图标定义，并让 AppCore 不再依赖 SFSymbols，同时做必然冲突 |
| 2026-11-14 | 镜像文件本身保持 `doc`，不用 Xcode 的 `module` | 用户的选择 |
| 2026-11-14 | 头文件、源文件后缀、submodule 与过滤菜单的符号这次不用 | 它们在 App 里没有对应的东西，用户同意先不用 |
| 2026-11-14 | 符号降成 v6 模板放进仓库 | App 最低支持 macOS 15；v6 是那一代的模板，App 已有的 v6 符号在那上面可用，v7 多出的只有一条绘制动画属性 |
| 2026-11-14 | 实现完成，待用户在 App 里看效果；镜像页的大图标也按所在的包显示 | 镜像页与它的标签显示同一个镜像，图标不该不同；镜像页本来就拿得到路径。没在 macOS 15 上实测，依据是编出的 asset catalog 与 App 已有的 v6 符号结构一致 |
