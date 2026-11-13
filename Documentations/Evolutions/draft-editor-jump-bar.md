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
- **空标签**：不显示路径栏，标签里打开了镜像或对象才有。Xcode 的空编辑器显示一段点不开的「No Selection」。
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

- 一栏的当前标签打开了镜像或对象时才有路径栏，在标签栏下面，标签栏隐藏时就在这一栏顶部；空标签不显示，内容的安全区也不留它的高度。macOS 26 起与标签栏一样浮在内容上：内容的安全区加上显示着的栏的高度，每条栏背后各一块独立的 scroll pocket（UIFoundation 的 `ScrollPocketView`，与标签栏相同）。macOS 15 上栏不透明，内容从第一条栏的上沿开始、靠安全区让出栏高。
- 高度与控件配置照逆向结果（`/Volumes/RE/Xcode/27.2-27B52/README.md`「Editor jump bar (2026-11-13)」，含 AppKitPlus 映射清单）：28 点的控件行，底边一条 1 点的线（`vibrantDividerColor`：黑或白 10%，增强对比度时 55.7% / 49.8%）；顶行一栏或标签栏下方共 33 点，下方一栏没有标签栏时共 37 点。控件行从安全区左缘 8 点开始；路径控件 `controlSize = .small`，其余用 AppKitPlus 的默认值（菜单而非 popover、不画 capsule、末段不占满整行），宽度贴自己的内容、行窄了先压缩它。
- **控件行垂直居中**，与 Xcode 不同：没有标签栏时，控件行放在栏顶与底边线的正中——顶行一栏上下各 2 点，下方一栏各 4 点。Xcode 顶行一栏的控件行贴着栏顶、下面留 4 点，文字比中线高 2 点。标签栏下方仍贴着栏顶：上面隔着标签栏行下的 4 点，与下面的 4 点相等。两条栏的高度与这个位置都由 `EditorPaneBarMetrics` 算，有测试钉住。
- **关闭按钮挪位**，照 Xcode 的规则（同一份笔记「Editor panes」§7）：标签栏只在某一栏有两个以上标签时显示（各栏一起显示），隐藏时关闭按钮（23 点宽）和一条分隔线（1 × 12，两侧各 4 点）放到路径栏最前面，路径控件因此从 40 点开始。原来只要有两个以上的栏就显示标签栏，只是为了放关闭按钮。当前标签空着、两条栏都不显示的那一栏没有关闭按钮，用菜单的 Close Editor Pane（⌃⇧⌘W）关。
- **未聚焦的栏**：路径的标题用次级标签色（代理的 `titleColorFor` 回答，聚焦变化时重建路径）。Xcode 另把箭头从 11 点换成 8 点、图标转灰，AppKitPlus 只有窗口级的激活状态，这两点这次不做。

### 代码位置

- **路径项**（RuntimeViewerApplication `EditorArea/JumpBar/`）：`EditorJumpBarItem`（来源、目录、镜像、对象四种），由每个文档一份的 `EditorJumpBarItemStore` 惰性建立并保留，同一个节点始终是同一个对象（控件按指针比较）；它跟随文档的 Engine，Engine 或镜像列表变了就整棵重建并发出 `treeRebuilt`。从对象找镜像节点按 Engine 的规范路径比较（模拟器的 `DYLD_ROOT_PATH`），树里没有的镜像挂在来源下面。镜像的对象只在镜像已索引后才读（`isImageIndexed`，否则等 `imageDidIndexPublisher`），读到后经 `childItems` 的 KVO 通知控件；一个对象在读到之前先挂在镜像下，读到后保留同一个 item、挪到外层类型下面并发出 `itemsMoved`。类型加了特化时重读那个镜像。
- **adapter**：`EditorJumpBarAdapter`，做法同 `FindModePathControlAdapter`：把这一栏的位置（`EditorJumpBarLocation`）换成控件的 `selectedItem`，把选中换成 `EditorJumpBarChoice`（目标加修饰键决定的打开位置）；路径由 view model 决定，选中后立刻放回。只有镜像与对象能选，来源与目录只用来往下走；对象的嵌套类型在菜单里缩进列出。
- **编辑栏**：`EditorPaneViewModel` 加 `jumpBarLocation`、`isJumpBarHidden` 输出与 `jumpBarChoiceSelected` 输入（先 `.focusEditorPane` 再打开），标签栏改照 Xcode 的显隐规则；`EditorPaneViewController` 放路径栏视图（`EditorPaneJumpBarView`），按 `EditorPaneBarMetrics`（RuntimeViewerApplication）排两条栏，store 由 `EditorAreaCoordinator` 交给每一栏。
- **镜像页**：`ContentImageViewModel` 与 `ContentImageViewController`，`ContentCoordinator` 的第四种 scene；进度视图 `ImageIndexingProgressView` 挪进 RuntimeViewerUI，侧栏对象页也用它。
- **Manual Loading**（RuntimeViewerApplication `ManualLoading/`）：`ManualImageLoadCoordinator`（`RuntimeEngineBackgroundWork` 的一部分）与 `DocumentState.recordingManualLoad(ofImageAt:_:)` / `indexImageForUser(at:)`；Report 的 `ReportCategory.manualLoading` 与两种行。接入点：侧栏的 Load now 与打开未索引镜像、Load Frameworks…、镜像页、内容区索引对象所在的镜像、Find 的交叉引用查询。

### 落地步骤（每步各自能构建通过）

1. ✅ 逆向 Xcode 27.2 的路径栏，补齐上面缺的几何与配置（`/Volumes/RE/Xcode/27.2-27B52/README.md`「Editor jump bar (2026-11-13)」，含 AppKitPlus 映射清单）。
2. ✅ 模型：镜像条目、`SelectionRoute.openImage`，`EditorArea` 与 `ContentRoute` 跟上，附测试。
3. ✅ 路径项与 adapter，附测试：路径怎么构成、菜单列什么、选中变成什么路由、换来源后重建。
4. ✅ 镜像页：`ContentImageViewModel`（索引状态机，附测试）与视图，加载视图挪进 RuntimeViewerUI。
5. ✅ Report 的 Manual Loading：`ManualImageLoadCoordinator`、第四类的行、各个手动加载入口接上，附测试。
6. ✅ 编辑栏接上路径栏：布局、pocket 登记、标签栏显隐与关闭按钮挪位。
7. ✅ 文档：本提案、根目录与 `RuntimeViewerUsingAppKit/AGENTS.md` 的规则、README 的 Highlights、术语表、两份索引。

### 没有询问就采用的假设

- 同一镜像内跳对象，侧栏对象页照旧选中那一行（Find 与内容里的链接现在也是这样）；「侧栏不动」指不换侧栏显示的镜像。
- 没加载的镜像直接加载，不再先问 Load now。加载会在 service 进程里 dlopen 它、跑它的初始化代码。
- 路径到对象为止。Xcode 最后那段「光标所在的符号」在这里是成员（`cursorMember`），这次不做；⌃4–⌃6 打开各段菜单的快捷键、Related Items 菜单也不做。三者列为后续项。
- Manual Loading 不记批量导出（它有自己的进度表单）、MCP 与命令行的请求（不是用户在 App 里点的），也不记已经索引好、什么都没做的打开。

### 后续项

- 成员段（光标所在的成员，Xcode 的符号段）、⌃4–⌃6 打开各段菜单、Related Items 菜单。
- 未聚焦栏的 8 点箭头与灰色图标：要 AppKitPlus 加栏级的激活状态。
- 关闭按钮后那条分隔线的颜色用的是 `separatorColor`，Xcode 的 `contentDividerColor` 具体值逆向笔记里没有。
- 工具栏的活动显示跟进 Manual Loading（现在只在 Report 里）。

### 风险

- 大镜像的对象菜单很长（SwiftUI 约 1.4 万个对象），NSMenu 一次建这么多行可能要几百毫秒以上。控件的菜单支持边打字边过滤；还没在 App 里实测，慢的话把对象那一段改用控件的 popover 呈现（带过滤框）。
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
| 2026-11-13 | 空标签的「No Selection」做成可以点开、从来源往下走，不照 Xcode 的空编辑器做成点不开 | 每个新窗口都从空标签开始，能从这里直接选镜像是这个功能的用处；与 Xcode 的差别只在空标签这一处 |
| 2026-11-13 | 未聚焦的栏只把路径标题换成次级标签色，8 点箭头与灰色图标列为后续项 | AppKitPlus 0.21.0 只有窗口级的激活状态，箭头与图标要它加栏级的状态；标题色经代理就能做到 |
| 2026-11-13 | 手动加载的入口统一走 `DocumentState.recordingManualLoad(ofImageAt:_:)` / `indexImageForUser(at:)`，只在真有活要干时记录 | 一处记录规则，各入口只决定「这次是不是真的要加载或索引」；侧栏每批后台索引后都会重载，已索引的镜像记进去只会刷屏 |
| 2026-11-13 | 不改已落地的 0084 里「RuntimeViewer 没有 jump bar」那一句 | 落地的提案是决策快照，保持原貌；现状写在本提案与 AGENTS.md 里 |
| 2026-11-13 | 用户的加载只在对端是本 App 自带的服务（本机 `.local`、离线文件 `.file`）时用带进度的加载命令，注入的进程、网络对端照旧用不带进度的（`RuntimeEngine.loadImageForUser(at:reportProgress:)`） | 带进度的加载命令 3.0.0-beta.5 才有，更早版本注入的载荷或对端收到不认识的命令会断开连接；本机与离线文件的服务与 App 同一个版本。对那些对端，镜像页的进度在「加载」这一段只能显示阶段开始前的状态 |
| 2026-11-13 | 路径项的 store 在读对象途中收到「已索引」通知时，读完发现没索引就再读一次 | 复查时发现的竞态：先问「是否已索引」得到否、索引恰在其后完成，那次通知被忽略，镜像就一直等一个已经过去的通知。时序竞争没法稳定复现，没写测试 |
| 2026-11-13 | 实现完成，待用户看过后收尾 | Ultra（macOS 27.2、Xcode 27.2）上：RuntimeViewerPackages 全量 970 条测试，失败 5 条——注入载荷的两条 IPC、Call Hierarchy、标题悬停、语料构建的 activity——在功能分支切出前的基线上同样失败（基线另有一条偶发），没有本次引入的；其中 Call Hierarchy 与语料 activity 两条单独重跑通过。App（Tuist workspace，Debug）编译通过。没做界面验证（没有在 App 里点过路径栏，大镜像对象菜单的速度也没实测）。文档：规则写进根目录与 UI 层的 AGENTS.md，README 的 Highlights、术语表与两份索引已更新；不另写使用指南与实现说明，没有 App 之外的调用方 |
| 2026-11-13 | 用户看过后定：当前标签什么都没打开时不显示路径栏，打开了镜像或对象才显示；取代上面「空标签的 No Selection 可以点开」那一条 | 用户的决定。从空标签选镜像改由侧栏开始。多栏、每栏一个标签时关闭按钮放在路径栏里，空标签那一栏于是没有关闭按钮，靠菜单的 Close Editor Pane 关；不为它单留一条只放关闭按钮的栏，那样空标签上仍有一条栏 |
| 2026-11-13 | 用户看过后指出路径栏没有垂直居中：没有标签栏时，控件行改放在栏顶与底边线正中；标签栏下方不变，栏高仍照 Xcode | 照 Xcode 的几何，顶行一栏的控件行贴着栏顶、下面留 4 点，文字比中线高 2 点，用户一开窗口看到的正是这种；下方一栏上下本来各 4 点，标签栏下方上面有标签栏行下的 4 点、下面也是 4 点，看上去本来就居中，改成在自己的范围里居中反而离标签近。两条栏的尺寸抽成 `EditorPaneBarMetrics` 以便测试 |
| 2026-11-13 | 这两处修完，待用户再看 | Ultra 上：路径栏相关的四个套件（`EditorPaneBarMetrics`、`EditorPaneViewModel`、编辑区路由、路径栏）48 条测试通过；居中那条测试先在旧算法上跑过，只有顶行一栏没有标签栏那一例失败，确认抓得住；App（Tuist workspace，Debug）编译通过。仍没做界面验证 |
| 2026-11-13 | 路径栏的模糊改为背后一块独立 pocket，不再登记给内容的滚动视图 | 随「编辑区内容从工具栏与标签栏下滚过」的修复（两栏时工具栏只有左栏一段有模糊）一起改：那次修复撤掉了 `ScrollPocketContainerRegistration`，标签栏改用背后一块 `ScrollPocketView`；路径栏照同样的做法，与 Xcode 的编辑栏一致。合并时在那个提案的功能分支上改，路径栏的布局与行为不变 |
