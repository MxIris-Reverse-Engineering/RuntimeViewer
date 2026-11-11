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
- Inspector：类层级、协议层级、Relationships、Specializations 四个列表加菜单（共用命令），并支持 ⌥ 点击开新标签、⇧⌥ 点击开到下一栏，与侧栏一致；References 列表加 Open in New Tab 与 Open in Next Editor Pane 两项（它的行是函数，不是对象）。
- 内容区：链接所指对象加 Copy Name；菜单末尾加 Reveal in Sidebar Navigator（作用于屏幕上的对象，经响应链，可用性与主菜单相同）。
- 编辑区标签：Close Tab、Close Other Tabs、Close Tabs to the Right，以及标签所显示对象的共用命令（Open in New Tab 除外：标签本身就是它）；标签可以拖动排序（模型里的 `moveTab` 早已存在）。
- 镜像行（目录与书签两页）：Open（等同双击）、Find in This Image…（Find 的范围设成这个镜像并打开 Find 页）、Copy Name、Copy Path、Show in Finder（文件在本机磁盘上、且 Engine 在本机时），加上原有的加书签 / 移除书签。
- Find 结果：Copy，拷贝那一行显示的文字。

**没有询问就采用的假设**

- 菜单不加分隔线：列表菜单用 RxAppKit 的 `rx.items`，它不支持分隔线；内容区沿用原有的分隔方式。
- 「Copy Name」拷贝列表里显示的名字（`displayName`），不拷贝 mangled name 或限定名。
- Show in Finder 只给 My Mac、Mac Catalyst、本机 Attach 的进程与离线文件；设备与另一台 Mac 上的路径不在本机，即使本机碰巧有同名文件也不提供。
- 导出、加入 Always Index、跨镜像的 Reveal 不在这次范围内，记为后续项。

**落地步骤**

1. 共用命令、`ViewModel.perform(_:on:)`、两个依赖与它们的测试替身；单元测试。
2. 侧栏对象行、Inspector 四个列表与 References、内容区接入；ViewModel 测试。
3. 编辑区标签的菜单与拖动排序；ViewModel 测试。
4. 镜像行的菜单、Find 结果的 Copy；ViewModel 测试。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-11 | Created as Draft | 交互缺口盘点里右键菜单最零散：同一个对象在各处能做的事不一样，Inspector 与编辑区标签完全没有菜单 |
| 2026-11-11 | 用户批准，提案由 agent 起草、用户事前未审阅全文 | 用户看过交互缺口的盘点与默认做法（先抽一份各处共用的对象命令）后，选择三块都做，经 `implement-feature` 一路实现 |
| 2026-11-11 | 开始实现 | |
| 2026-11-11 | 从本地 `next` 切出，叠在 `feature/filter-scope-memory` 合并之后 | 三块按顺序做，后一块从合进前一块的本地 `next` 切，避免同改侧栏文件时冲突 |
