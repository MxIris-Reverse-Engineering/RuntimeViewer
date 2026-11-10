# Draft - Generated Interface：把 ObjC 对象显示成 Swift 接口

- **状态**: In Progress
- **创建日期**: 2026-11-10
- **最后更新**: 2026-11-10
- **所属愿景**: 无
- **关联提案**: MachOSwiftSection 的提案 0090-objc-imported-declarations（ObjC 类、category 与协议按 ClangImporter 的规则建成 Swift 声明，本提案的全部 Swift 文本都由它生成）、[0026](0026-objc-swift-class-counterparts.md)（ObjC 类与 Swift 类互标角标、互相跳转）、[0063](0063-swift-declared-objc-protocols-in-swift-list.md)（Swift 列表列出 Swift 定义的 `@objc` 协议）、[0076](0076-editor-panes.md)（编辑器分栏：每个标签有自己的导航历史）
- **实现分支 / PR**: `feature/objc-generated-interface`（worktree `.worktrees/RuntimeViewer-ObjCGeneratedInterface`，自 `next` 切出）

## 摘要

Xcode 打开一个 ObjC 头文件时，相关项菜单里有 Generated Interface：把头文件显示成 Swift 导入它之后的样子。RuntimeViewer 给 ObjC 类、category 与协议加上同样的视图。Swift 文本由 MachOSwiftSection 的新接口生成：名字照 ClangImporter 的规则从 selector 推出；成员由 Swift 实现时——桥接出去的 Swift 类、`@objc @implementation` 类、Swift 写的 category——直接取那个 Swift 成员的真实声明，所以这几种类读到的是真名，与 Swift 一侧的信息合在一起。它作为一次导航打开，Back 回到 ObjC 头文件。

## 方案

### 入口

- RuntimeViewer 没有 jump bar，也就没有 Xcode 那个相关项菜单。命令 **Generated Interface** 放在三处：Navigate 菜单、内容区的右键菜单、侧栏对象行的右键菜单（在 0026 的「跳到 Swift 类」旁边）。
- 只对 ObjC 类、category 与协议可用；C struct 与 union 暂不支持，命令置灰。
- 显示 Swift 形式时菜单项打勾，再选一次回到 ObjC 头文件。两次切换都是导航，记进当前标签的历史。
- 按住 ⌥ 在新标签打开，⌥⇧ 在下一个编辑栏打开，与其他打开方式一致（`SelectionRouteDestination+ModifierFlags`）。

### 请求与引擎

- **不加新命令**：旧版注入载荷收到不认识的命令会断开连接（PR121.73）。改为在已有的 interface 请求里加一个字段，旧版会忽略它。
- `RuntimeObjectInterface.GenerationOptions` 加 `interfaceLanguage: RuntimeInterfaceLanguage?`：`nil` 表示用对象自己的语言，也就是现在的行为；`.swift` 表示要 Swift 形式。它与 `marksCommentStructure` 一样由内容区按请求决定，不是用户设置的生成选项。名字取自 DocC 表示接口语言的 `interfaceLanguage`。
- `RuntimeObjectInterface` 加 `interfaceLanguage`，说明返回的是哪种语言，旧版不带这个键，解码为 `nil`。内容区要了 `.swift` 却没拿到时，显示「这个引擎的进程版本太旧，不支持 Generated Interface」，不把 ObjC 头文件当成 Swift 显示。
- `RuntimeInterfaceLanguage` 是包着字符串的 struct，有 `.objectiveC` 与 `.swift` 两个静态成员，取 DocC 的标识 `occ` 与 `swift`。不用 enum，是为了以后加一种语言时旧版照样能解码。本版对端总是填上回复的语言（ObjC section 填 `.objectiveC`，Swift section 填 `.swift`）。
- 服务进程里，`_interface(for:options:)` 的 ObjC 分支遇到 `.swift` 时，交给这个镜像的 Swift section（`RuntimeSwiftSection.importedInterface(for:)`）：它手上有 MachOSwiftSection 的索引器与打印器，与 Swift 一侧合并要用的就是这两样，打印结果另有一份缓存，随打印配置一起清空。对象不在这个镜像里时，类与协议照 ObjC 分支的做法找定义它的镜像再打印；category 不跨镜像找。路由不变：请求照旧按对象所在的镜像分派，借用的 shared cache 镜像由它的归属 engine 打印（0081）。
- 文档的接口缓存以生成选项为键，Swift 形式自然分开缓存。

### 导航与内容区

- 导航历史的条目从 `RuntimeObject` 改成 `NavigationEntry`（对象加接口语言），两者一起决定是不是同一条，所以 Back 能从 Swift 形式回到头文件；后退菜单里这一条标成「名字 (Generated Interface)」。`SelectionRoute.open` 加 `interfaceLanguage` 参数，默认 `nil`。`ContentRoute` 不变：内容区协调器从窗格当前标签读语言，按「对象加语言」判断要不要重建。
- `selectedRuntimeObject` 照旧只是对象，Inspector、在侧栏中定位等只关心对象的地方不受影响。
- 内容区的加载、遮罩与跳转都照旧，只是请求时带上当前条目的语言；SourceEditor 按 Swift 高亮。要了 `.swift` 而回复的语言不是 `.swift` 时，显示两行说明（对端是更早的 RuntimeViewer，只发得出头文件；后退可回到头文件）。
- 三处入口的具体形状：Navigate 菜单的 Generated Interface 是开关，正显示 Swift 形式时打勾，再选回到头文件；内容区右键菜单里是同一个开关，针对正在显示的对象；侧栏行的右键菜单是「Open Generated Interface」，总是打开 Swift 形式。前两处按住 ⌥ 在新标签、⌥⇧ 在下一个编辑栏打开。

### 没问就定的假设

- 从 Swift 形式里点类型跳转时，目标是 ObjC 类型就也打开它的 Swift 形式，与 Xcode 在 Generated Interface 里跳转的行为一致；目标是 Swift 类型的照常打开。
- 工具栏的保存与分享跟着正在显示的语言走，Swift 形式存成 Swift interface。没有单独的「拷贝接口」命令，⌘C 拷的就是屏幕上的文本。批量导出不变。
- Find 的语料与结果不变：语料仍是 ObjC 头文件的文本，点结果打开头文件。
- 命令先不配快捷键。
- 本提案不做的，列作后续：`runtime-viewer-cli` 与 MCP 的入口、批量导出成 Swift、C struct 与 union，以及反方向的视图——Swift 类显示成编译器生成的 `-Swift.h` 头文件，即 Xcode 同一个菜单里的另一项。

### 落地顺序

1. MachOSwiftSection 的提案落地（已完成，0090）。本仓库对它是 `branch: "next"` 依赖，不用等发版，把锁文件里的修订号抬到含 0090 的 `next` 即可。
2. Core：`RuntimeInterfaceLanguage`、请求与返回的两个字段、服务进程里的分派，以及测试，包括旧版对端不带返回字段的情形。
3. App：导航条目、三处入口、内容区的请求与旧版提示。
4. 抬 MachOSwiftSection 的 pin，更新 README 的功能列表（已完成）。

第二、三步已完成：Core 的语言字段、分派与测试（`GeneratedInterfaceTests`，混版本测试里加了旧服务端回复解出空语言），App 的导航条目、三处入口、内容区的请求与旧版说明、保存与分享。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-10 | Created as Draft | 用户想要 Xcode 的 Generated Interface：把 ObjC 内容显示成 Swift 接口，名字照 ClangImporter 的规则；由 Swift 定义或实现的类要与 Swift 一侧的信息合在一起 |
| 2026-11-10 | Swift 文本由 MachOSwiftSection 扩展已有的 ClangImporter 移植生成，不在运行时调用编译器 | 用户选定。离线文件、iOS 与命令行都能用，不依赖装了 Xcode |
| 2026-11-10 | 入口做成 Xcode 式的命令，作为一次导航打开，不做全局开关 | 用户选定。与 Xcode 一致，Back 能回到头文件；Find 的语料与结果也不受影响 |
| 2026-11-10 | 按轻量档写精简提案，与 MachOSwiftSection 的草案各管一个仓库 | 用户选定 |
| 2026-11-10 | 用户批准；先做 MachOSwiftSection 草案的第一步（命名准确率测量），本仓库的实现排在它之后 | 用户批准时指定的顺序；测量结果可能改变 MachOSwiftSection 一侧类型来源的优先级，本仓库只消费它的输出 |
| 2026-11-10 | MachOSwiftSection 一侧落地为 0090 并推送到它的 `next`；用户要求接着做本仓库一侧，状态改 In Progress | 用户看过 MachOSwiftSection 一侧后的安排 |
| 2026-11-10 | 不等 MachOSwiftSection 发版：锁文件里它的 `branch: "next"` pin 直接抬到含 0090 的修订号 | 本仓库的三个包与两个 workspace 都按分支依赖它，发版不是前提；它这段区间没有改依赖声明，不用连带抬别的库 |
| 2026-11-10 | 语言标识取 DocC 的 `occ` 与 `swift` | 名字本就取自 DocC 的 `interfaceLanguage`，标识一并沿用 |
| 2026-11-10 | `ContentRoute` 不加语言，内容区协调器从窗格的当前标签读 | 路由在编辑区状态更新之后才到协调器，标签上已经是新条目；少改一层路由，`.back` 也自然拿到语言 |
| 2026-11-10 | 内容区右键菜单的入口针对正在显示的对象，不针对点中的类型名 | 与 Navigate 菜单是同一个开关；点中的类型可以先跳过去再切换 |
| 2026-11-10 | 没有「拷贝接口」命令，改为让工具栏的保存与分享跟着语言走 | 应用里单个对象的导出只有这两条路，拷贝就是拷选中的文本 |
| 2026-11-10 | 侧栏的入口只打开 Swift 形式、只在当前标签打开 | 与同一菜单里的「跳到对应的类」一致；要新标签可以用菜单里已有的两项先打开再切换 |
