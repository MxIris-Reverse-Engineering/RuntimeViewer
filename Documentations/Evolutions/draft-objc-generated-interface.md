# Draft - Generated Interface：把 ObjC 对象显示成 Swift 接口

- **状态**: Accepted
- **创建日期**: 2026-11-10
- **最后更新**: 2026-11-10
- **所属愿景**: 无
- **关联提案**: MachOSwiftSection 的草案 `draft-objc-imported-declarations`（ObjC 类、category 与协议按 ClangImporter 的规则建成 Swift 声明，本提案的全部 Swift 文本都由它生成）、[0026](0026-objc-swift-class-counterparts.md)（ObjC 类与 Swift 类互标角标、互相跳转）、[0063](0063-swift-declared-objc-protocols-in-swift-list.md)（Swift 列表列出 Swift 定义的 `@objc` 协议）、[0076](0076-editor-panes.md)（编辑器分栏：每个标签有自己的导航历史）
- **实现分支 / PR**: `feature/objc-generated-interface`（worktree `.worktrees/RuntimeViewer-ObjCGeneratedInterface`，自 `next` 切出；MachOSwiftSection 一侧的第一步做完再建）

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
- `RuntimeInterfaceLanguage` 是包着字符串的 struct，有 `.objectiveC` 与 `.swift` 两个静态成员。不用 enum，是为了以后加一种语言时旧版照样能解码。
- 服务进程里，`_interface(for:options:)` 的 ObjC 分支遇到 `.swift` 时，交给这个镜像的 Swift section：它手上有 MachOSwiftSection 的索引器与打印器，与 Swift 一侧合并要用的就是这两样。路由不变：请求照旧按对象所在的镜像分派，借用的 shared cache 镜像由它的归属 engine 打印（0081）。
- 文档的接口缓存以生成选项为键，Swift 形式自然分开缓存。

### 导航与内容区

- 导航历史的条目从 `RuntimeObject` 改成「对象加接口语言」，两者一起决定是不是同一条，所以 Back 能从 Swift 形式回到头文件。`SelectionRoute.open` 加 `interfaceLanguage` 参数，默认 `nil`。
- `selectedRuntimeObject` 照旧只是对象，Inspector、在侧栏中定位等只关心对象的地方不受影响。
- 内容区的加载、遮罩与跳转都照旧，只是请求时带上当前条目的语言。

### 没问就定的假设

- 从 Swift 形式里点类型跳转时，目标是 ObjC 类型就也打开它的 Swift 形式，与 Xcode 在 Generated Interface 里跳转的行为一致；目标是 Swift 类型的照常打开。
- 拷贝或导出当前对象的接口时，跟着正在显示的语言走，导出的文件扩展名用 `.swift`。批量导出不变。
- Find 的语料与结果不变：语料仍是 ObjC 头文件的文本，点结果打开头文件。
- 命令先不配快捷键。
- 本提案不做的，列作后续：`runtime-viewer-cli` 与 MCP 的入口、批量导出成 Swift、C struct 与 union，以及反方向的视图——Swift 类显示成编译器生成的 `-Swift.h` 头文件，即 Xcode 同一个菜单里的另一项。

### 落地顺序

1. MachOSwiftSection 的草案落地并发版；开发期间用 `RuntimeViewer-Local.xcworkspace` 接本地检出。
2. Core：`RuntimeInterfaceLanguage`、请求与返回的两个字段、服务进程里的分派，以及测试，包括旧版对端不带返回字段的情形。
3. App：导航条目、三处入口、内容区的请求与旧版提示。
4. 抬 MachOSwiftSection 的 pin，更新 README 的功能列表。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-10 | Created as Draft | 用户想要 Xcode 的 Generated Interface：把 ObjC 内容显示成 Swift 接口，名字照 ClangImporter 的规则；由 Swift 定义或实现的类要与 Swift 一侧的信息合在一起 |
| 2026-11-10 | Swift 文本由 MachOSwiftSection 扩展已有的 ClangImporter 移植生成，不在运行时调用编译器 | 用户选定。离线文件、iOS 与命令行都能用，不依赖装了 Xcode |
| 2026-11-10 | 入口做成 Xcode 式的命令，作为一次导航打开，不做全局开关 | 用户选定。与 Xcode 一致，Back 能回到头文件；Find 的语料与结果也不受影响 |
| 2026-11-10 | 按轻量档写精简提案，与 MachOSwiftSection 的草案各管一个仓库 | 用户选定 |
| 2026-11-10 | 用户批准；先做 MachOSwiftSection 草案的第一步（命名准确率测量），本仓库的实现排在它之后 | 用户批准时指定的顺序；测量结果可能改变 MachOSwiftSection 一侧类型来源的优先级，本仓库只消费它的输出 |
