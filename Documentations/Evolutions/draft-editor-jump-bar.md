# Draft - 编辑栏的路径栏：在编辑栏里切换镜像，侧栏不动

- **状态**: In Progress
- **创建日期**: 2026-11-13
- **最后更新**: 2026-11-13
- **实现分支**: `feature/editor-jump-bar`

## 摘要

给每个编辑栏（pane）加一条 Xcode 式的路径栏（jump bar），控件用 AppKitPlus 的 `NSPopUpPathControl`——Xcode `DVTPathControl` 的移植，Find 的模式路径已经在用。路径是「来源 › 镜像树根 › 各级目录 › 镜像 › 对象」，点任一段弹出那一层的同级项，目录行带子菜单逐层展开，只有选到镜像或对象时菜单才关上并跳转。跳转只发生在这一栏，侧栏不跟着换镜像。跳到还没索引的镜像时自动开始索引，进度显示在这一栏里，索引完再显示内容。RuntimeViewer 现在没有路径栏（[0084](0084-objc-generated-interface.md)「入口」一节）。另外，用户手动加载的镜像也记进 Report navigator，作为第四类「Manual Loading」。

## 方案

### 路径与菜单

- **路径**：第一段是来源（Engine 的名字与图标，相当于 Xcode 的项目或 SDK 那一段），接着是侧栏镜像树上的那条链——树根（`Dyld Shared Cache`、`Others`，离线文件则是文件名）、各级目录、镜像；这一栏显示对象时，最后一段是对象。
- **菜单**：每段列出可以替换它的同级项。目录行有子菜单，打开时才读子项；镜像行没有子菜单（`representsDocumentRoot`，同 Xcode 菜单里的文件行），选中就跳过去。选目录行不会关菜单，所以只有选到镜像或对象，菜单才关上。
- **对象**：镜像在路径末尾时，后面接一段「No Selection」（控件对 document root 的既有行为），它的菜单列出这个镜像的全部对象；显示对象时，这一段就是对象本身，菜单同样列出全部对象。嵌套类型缩进列在外层类型下面（控件的 inline 子项，同 Xcode 列文件内符号的方式），不同种类之间有分隔线。选一个对象就在这一栏打开，等同在侧栏单击它。
- **图标**沿用侧栏：镜像树节点用 `RuntimeImageNode.icon`，对象用 `RuntimeObjectIcon`。
- **修饰键**沿用其他打开方式（`SelectionRouteDestination+ModifierFlags`）：⌥ 在新标签打开，⇧⌥ 在下一个编辑栏打开。
- **空标签**：路径栏只有「No Selection」一段，菜单从来源开始，可以从空标签直接走到任何镜像。
- 呈现用菜单（Xcode 的默认），不用 popover；控件两种都支持，换只要一行配置。

### 跳到镜像：索引与进度都在这一栏

- **导航**：选中镜像时，这一栏先拿到焦点（`.focusEditorPane`），再走新路由 `SelectionRoute.openImage(_:in:)`。它是当前标签历史里的一步（Back 回到之前的对象），标签标题是镜像名、图标是镜像图标。不发 `.switchImage`，侧栏不动。
- **历史条目**：`NavigationEntry` 分成两种——对象（连同显示语言）与镜像，`object` 变成可选。停在镜像条目时 `selectedRuntimeObject` 为 `nil`，Inspector 显示占位。
- **镜像页**：`ContentCoordinator` 加一种内容「镜像」（新的 `ContentImageViewController` 与 `ContentImageViewModel`），按一个状态枚举显示：
  - 已索引：一页「No Selection」占位，写镜像名、路径与各种类的对象数，提示从路径栏末段选对象。
  - 未索引：自动开始索引。已加载的只建对象（`objectsWithProgress(in:)`），没加载的先加载（`loadImage(at:onProgress:)`），与侧栏的 Load now、Find 跳转走同一条路。进度条、阶段说明与计数显示在这一栏，样子与侧栏对象页的加载视图相同：把侧栏的 `ImageLoadingView` 挪进 RuntimeViewerUI，两处共用。完成后换成镜像页，路径栏「No Selection」的菜单随之有了对象。
  - 失败：显示错误与「Try Again」。
  - 进度按 `withLoadingPlaceholder` 的时机出现，索引一闪而过时不闪进度。
- 索引按前台加载走（`performingForegroundLoad`，后台索引让路）。离开镜像页不取消已经开始的索引：引擎这一层取消不了，建好的结果之后照样用得上。

### 附带：用户手动加载的镜像记进 Report

Report navigator 现在只记后台工作（后台索引、可搜索接口、交叉引用），用户自己加载的镜像哪里都查不到。加第四类 **Manual Loading**：

- **记哪些**：用户发起、真的做了加载或索引的那些——侧栏的 Load now、在侧栏打开一个还要索引的镜像、Load Frameworks…、路径栏跳到的镜像、Find 结果或内容区要用到的未索引镜像。不记：已经索引好、一打开就有的镜像（没做任何事）；批量导出（有它自己的进度表单）；MCP 与命令行的请求（不是用户在 App 里点的）。
- **怎么显示**：与另三类同一个样子——进行中的一行一张镜像，转圈加阶段与百分比；结束的按时间倒序，写用了多久，失败的带错误标记与原因。Clear History 一并清掉，进行中的不能取消（引擎这一层取消不了）。
- **放在哪**：按 Engine 共享，与另三类一起在 `RuntimeEngineBackgroundWork` 里（新的 `ManualImageLoadCoordinator`），同一个 Engine 的各个窗口看到同一份；共享缓存里借来的镜像记在它所属 Engine 的那一组。
- **算进「进行中」**：手动加载进行中时，Report 标签照样标出有工作在跑，App 也不进 App Nap（`isWorkInProgress`），不然切走后大镜像会慢好几倍。
- 工具栏的活动显示这次不跟（它只报后台工作），列为后续项。

### 栏的位置与外观（照 Xcode 27.2）

- 每一栏都有路径栏，在标签栏下面，标签栏隐藏时就在这一栏顶部。macOS 26 起与标签栏一样浮在内容上：内容的安全区加上栏高，栏登记为内容滚动视图的顶部 pocket 容器（沿用 `ScrollPocketContainerRegistration`）。macOS 15 上栏不透明，内容从栏下开始。
- 已知的几何（`/Volumes/RE/Xcode/27.2-27B52/README.md`「Editor panes — visuals」§3）：路径栏由 `+[IDEEditorBar navigationBarWithJumpBar:]` 建成，28 点的控件行、上下各 4 点、底边一条 1 点的分隔线（`vibrantDividerColor`），共 37 点。还缺的——`IDEEditorJumpBar` 里 `DVTPathControl` 的 control size、字体、capsule 高亮、`lastComponentFillsWidth`，顶行一栏的上边距，空编辑器显示什么——实现第一步逆向补齐，写进同一份笔记。
- **关闭按钮挪位**，照 Xcode 的规则（同一份笔记「Editor panes」§7）：标签栏只在某一栏有两个以上标签时显示（各栏一起显示），隐藏时关闭按钮放到路径栏最前面。现在只要有两个以上的栏就显示标签栏，只是为了放关闭按钮。

### 代码位置

- **路径项**：RuntimeViewerApplication 新增一组 `NSPopUpPathItem`（来源、镜像树节点、对象），按 Engine 缓存、惰性建立，同一个节点始终是同一个对象（控件按指针比较）；`childItems` 发 KVO 通知，镜像索引完成时对象行随之出现。从对象找镜像节点按 Engine 的规范路径比较（模拟器的 `DYLD_ROOT_PATH`）。来源换了或镜像列表变了（`imageNodesPublisher`），缓存重建。
- **adapter**：`EditorJumpBarAdapter`，做法同 `FindModePathControlAdapter`：把这一栏当前的条目换成控件的 `selectedItem`，把选中换成路由；路径由 view model 决定，选中后立刻放回 view model 的路径（`RuntimeViewerUsingAppKit/AGENTS.md`「Filter fields, filter bars and pop-up paths」）。
- `EditorPaneViewModel` 加路径栏的输入与输出，`EditorPaneViewController` 放视图。

### 落地步骤（每步各自能构建通过）

1. ✅ 逆向 Xcode 27.2 的路径栏，补齐上面缺的几何与配置（`/Volumes/RE/Xcode/27.2-27B52/README.md`「Editor jump bar (2026-11-13)」，含 AppKitPlus 映射清单）。
2. ✅ 模型：镜像条目、`SelectionRoute.openImage`，`EditorArea` 与 `ContentRoute` 跟上，附测试。
3. ✅ 路径项与 adapter，附测试：路径怎么构成、菜单列什么、选中变成什么路由、换来源后重建。
4. ✅ 镜像页：`ContentImageViewModel`（索引状态机，附测试）与视图，加载视图挪进 RuntimeViewerUI。
5. Report 的 Manual Loading：`ManualImageLoadCoordinator`、第四类的行、各个手动加载入口接上，附测试。
6. 编辑栏接上路径栏：布局、pocket 登记、标签栏显隐与关闭按钮挪位。
7. 文档：本提案、`RuntimeViewerUsingAppKit/AGENTS.md` 的路径栏规则、0084「入口」那一句、两份索引。

### 没有询问就采用的假设

- 同一镜像内跳对象，侧栏对象页照旧选中那一行（Find 与内容里的链接现在也是这样）；「侧栏不动」指不换侧栏显示的镜像。
- 没加载的镜像直接加载，不再先问 Load now。加载会在 service 进程里 dlopen 它、跑它的初始化代码。
- 路径到对象为止。Xcode 最后那段「光标所在的符号」在这里是成员（`cursorMember`），这次不做；⌃4–⌃6 打开各段菜单的快捷键、Related Items 菜单也不做。三者列为后续项。

### 风险

- 大镜像的对象菜单很长（SwiftUI 约 1.4 万个对象），NSMenu 一次建这么多行可能要几百毫秒以上。先实测，慢的话把对象那一段改用控件的 popover 呈现（带过滤框）。
- `NavigationEntry.object` 变成可选，要改十几处调用点。
- 多栏、每栏一个标签时标签栏不再显示，界面上少一条栏。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-13 | Created as Draft | 用户要一条 Xcode 式的路径栏：在编辑栏里换镜像、侧栏不动，没索引的镜像自动索引，进度显示在这一栏 |
| 2026-11-13 | 控件用 AppKitPlus 的 `NSPopUpPathControl` | 用户指定；它是 Xcode `DVTPathControl` 的移植，Find 的模式路径已在用 |
| 2026-11-13 | 跳到镜像、索引完成后显示「No Selection」占位页，对象从路径栏末段选 | 用户选定；同 Xcode 打开文件后在符号段选符号。另两个选项——在编辑栏里列出对象列表、自动打开一个对象——前者要多做一个列表页，后者打开哪个是猜的 |
| 2026-11-13 | 镜像在菜单里是末端，不展开成对象子菜单 | 用户选定；同 Xcode 菜单里的文件行，菜单里只有一种行为。已索引的镜像展开、未索引的作末端的做法，会让同一个菜单里有两种行为 |
| 2026-11-13 | 状态改为 Accepted，开始实现 | 用户批准 |
| 2026-11-13 | 功能分支从本地 `next` 切，叠在尚未推送的「编辑区内容从工具栏与标签栏下滚过」合并上 | 本地 `next` 有那次合并的 4 个提交等用户目视验收后才推；路径栏要用它的 pocket 登记，所以叠在上面，提案提交只留在本地 `next` |
| 2026-11-13 | 追加：用户手动加载的镜像也记进 Report，作为第四类「Manual Loading」 | 用户在开工后追加的小需求；路径栏的自动索引也是用户发起的加载，同一份提案一起做。记哪些、不记哪些见「附带」一节 |
