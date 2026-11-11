# Draft - 补全右键菜单：各处列出的对象用同一组命令

- **状态**: In Progress
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **所属愿景**: 无
- **关联提案**: [0022](0022-reveal-in-sidebar-navigator.md)（Reveal in Sidebar Navigator）、[0056](0056-cross-references.md)（交叉引用）、[0076](0076-editor-panes.md)（编辑器分栏与标签）、[0084](0084-objc-generated-interface.md)（Generated Interface）、`draft-filter-scope-memory`（同批的交互补全，先落地）
- **实现分支 / PR**: `feature/context-menus`（从本地 `next` 切出，`next` 已含 `feature/filter-scope-memory`）

## 摘要

同一个运行时对象在侧栏、Inspector、内容区、编辑区标签与 Find 结果里都会出现，右键菜单却各写各的：侧栏对象行有开新标签、开到下一栏、跳对端与 Generated Interface；内容区多了交叉引用；Inspector 的五个列表一个菜单都没有，其中四个连 ⌥ 点击开新标签也不支持；编辑区的标签没有菜单、也不能拖动排序；镜像列表只有「加书签」；哪里都拷不出名字。改为由一份共用的对象命令（`RuntimeObjectAction`）决定一个对象能做什么、叫什么、做了什么，各处菜单都从它取，再加上各处独有的命令；同时补上镜像行、编辑区标签与 Find 结果各自缺的命令。

## 方案

**共用的对象命令**（`RuntimeViewerApplication`）

- `RuntimeObjectAction`：Open in New Tab、Open in Next Editor Pane、Open Generated Interface（ObjC 对象有 Swift 形式时）、Find Type References（能找引用的类型）、Copy Name。`actions(for:)` 按菜单顺序给出一个对象可用的那些。
- 执行集中在 `ViewModel` 基类的 `perform(_:on:)`：开新标签与下一栏走 `selectionRouter`，Generated Interface 作为一次导航打开，Find Type References 交给 `findSession.runCrossReferenceCommand`，Copy Name 写剪贴板。
- 剪贴板与 Finder 经两个依赖（`PasteboardClient`、`FinderClient`）：测试里默认什么都不做，不会改写用户的剪贴板或弹出 Finder。
- 标题与图标写在 App 一侧的一处（`RuntimeObjectAction+Menu`），各处菜单显示一致。

**各处的菜单**

- 侧栏对象行：共用命令，加上原有的跳对端与书签命令。原来手写的三项改由共用命令提供。
- Inspector：类层级、协议层级、Relationships、Specializations 四个列表加菜单（共用命令），并支持 ⌥ 点击开新标签、⇧⌥ 点击开到下一栏，与侧栏一致。References 列表不加菜单：它的行是函数而不是对象，⌥ / ⇧⌥ 点击早已支持。
- 内容区：链接所指对象加 Copy Name；菜单末尾加 Reveal in Sidebar Navigator（作用于屏幕上的对象，经响应链，可用性与主菜单相同）。链接的打开命令照旧由内容区先解析再打开，不走共用命令。
- 编辑区标签：Close Tab、Close Other Tabs（窗格里还有别的标签时）、Close Tabs to the Right（不是最后一个时），以及标签所显示对象的共用命令，去掉 Open in New Tab 与 Open Generated Interface：这两项作用于焦点窗格的标签，不是被点的这个。标签栏在每次刷新时建菜单，所以这几项随左右的标签变化。标签可以拖动排序：标签栏报告新顺序，ViewModel 算出被移动的那一个，交给模型里早已存在的 `moveTab`。
- 镜像行（目录与书签两页）：Open（等同双击）、Find in This Image…（Find 的范围设成这个镜像并打开 Find 页，等用户输入查询，不立即搜索）、Copy Name、Copy Path、Show in Finder（文件在本机磁盘上、且 Engine 在本机时），加上原有的加书签 / 移除书签。目录行（路径中间的文件夹）只有加书签。两页的菜单都改由基类 `SidebarRootViewController` 建。
- Find 结果：Copy，拷贝那一行显示的文字（`filterableText`）。

**没有询问就采用的假设**

- 菜单不加分隔线：列表菜单用 RxAppKit 的 `rx.items`，它不支持分隔线；内容区沿用原有的分隔方式。
- 「Copy Name」拷贝列表里显示的名字（`displayName`），不拷贝 mangled name 或限定名。
- Show in Finder 只给 My Mac、Mac Catalyst、本机 Attach 的进程与离线文件；设备与另一台 Mac 上的路径不在本机，即使本机碰巧有同名文件也不提供。
- 导出、加入 Always Index、跨镜像的 Reveal、References 列表的菜单不在这次范围内，记为后续项。
- 「Open in New Tab」的图标统一用 `plus.square.on.square`（内容区与 Find 原本就用它），侧栏原来的自定义标签图标不再用于这一项。

**落地步骤**

1. ✅ 共用命令、`ViewModel.perform(_:on:)`、两个依赖与它们的测试替身；单元测试。
2. ✅ 侧栏对象行、Inspector 四个列表、内容区接入；ViewModel 测试。
3. ✅ 编辑区标签的菜单与拖动排序；ViewModel 测试。
4. ✅ 镜像行的菜单、Find 结果的 Copy；ViewModel 测试。

**验证**：`RuntimeViewerPackages` 的相关测试（新增 4 个套件，连同侧栏、镜像页、Inspector、内容区、Find、编辑区与 ViewModel 基类的既有套件，共 28 个套件 189 个测试）在 Ultra 上全部通过；Tuist workspace 编 App（Debug）通过。没有启动 App 手工看过：菜单的外观、右键在 Inspector 那几张不接受焦点的表格上能否弹出、标签拖动的手感都未目视。

`AGENTS.md`（`RuntimeViewerUsingAppKit/`）的「Tables and Outlines」补了一条：列表的右键菜单用 `installContextMenu(items:)`，运行时对象的命令只从 `RuntimeObjectAction` 取。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-11 | Created as Draft | 交互缺口盘点里右键菜单最零散：同一个对象在各处能做的事不一样，Inspector 与编辑区标签完全没有菜单 |
| 2026-11-11 | 用户批准，提案由 agent 起草、用户事前未审阅全文 | 用户看过交互缺口的盘点与默认做法（先抽一份各处共用的对象命令）后，选择三块都做，经 `implement-feature` 一路实现 |
| 2026-11-11 | 开始实现 | |
| 2026-11-11 | 从本地 `next` 切出，叠在 `feature/filter-scope-memory` 合并之后 | 三块按顺序做，后一块从合进前一块的本地 `next` 切，避免同改侧栏文件时冲突 |
| 2026-11-11 | References 列表不加菜单 | 它的行是函数，⌥ / ⇧⌥ 点击已有；它的表格在每个分节视图里，接菜单要为三个分节各接一条通道，收益小，记为后续项 |
| 2026-11-11 | 标签菜单去掉 Open in New Tab 与 Open Generated Interface | 两者都作用于焦点窗格的当前标签，在别的标签上选会打开错的对象 |
| 2026-11-11 | 命令的执行放在 `ViewModel` 基类的 `perform(_:on:)`，不放在 `DocumentState` | 剪贴板依赖要在 ViewModel 创建时解析（测试环境才替换得到）；`DocumentState` 在测试里建在依赖覆盖之外 |
| 2026-11-11 | 实现完成，待用户看过后收尾 | 自审没有发现要修的问题；文档：提案、两个索引与 `RuntimeViewerUsingAppKit/AGENTS.md` 的一条约定已同批更新，不需要另写指南或实现说明，没有新术语 |
