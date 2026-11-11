# 0087 - 键盘与标准命令：前进后退、回车、删除与拷贝

- **状态**: Implemented
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **所属愿景**: 无
- **关联提案**: [0086](0086-context-menus.md)（共用的对象命令与镜像命令，本提案的拷贝与打开都走它们）、[0085](0085-filter-scope-memory.md)（同批的交互补全）、[0076](0076-editor-panes.md)（每个标签有自己的导航历史）
- **实现分支 / PR**: `feature/keyboard-commands`（从本地 `next` 切出，`next` 已含 `feature/filter-scope-memory` 与 `feature/context-menus`；并回 `next`）
- **配套文档**: 无 —— 理由见决策日志

## 摘要

几个常用操作只能用鼠标做：前进与后退只有工具栏按钮，没有菜单项，也没有 Xcode 的 ⌃⌘← / ⌃⌘→；镜像列表只能双击打开，回车没反应；书签不能按 ⌫ 删除；侧栏列表里选中一行按 ⌘C 什么都不拷。补上这些键盘与标准命令，执行都复用已有的路由与右键菜单的命令，不另写一套逻辑。

## 方案

- **Navigate ▸ Go Back（⌃⌘←）/ Go Forward（⌃⌘→）**：标题与快捷键照 Xcode，放在 Navigate 菜单末尾。动作在 `MainWindowController`，发 `.backward` / `.forward`，与工具栏按钮相同；只在焦点窗格的当前标签能后退 / 前进时可用。
- **列表的按键**：`StatefulOutlineView` 加 `keyDownHandler`，每次按键先交给它，返回 `true` 就算处理了，否则照旧交给 `NSOutlineView`。按键的判断放在 `NSEvent` 的两个属性里（回车含小键盘 Enter，删除含向前删除），只认不带修饰键的按法。
  - 镜像列表（目录与书签两页）：回车等同双击——镜像就打开，文件夹就展开或收起。
  - 镜像书签页与对象书签页：⌫ 删除选中的那条书签（只认书签本身那一行，与右键菜单的 Remove Bookmark 相同）。
- **⌘C（Edit ▸ Copy）**：镜像列表两页拷贝选中镜像的名字，对象列表两页拷贝选中对象的名字，分别走右键菜单的 Copy Name；没有选中行时菜单项置灰。过滤框有焦点时 ⌘C 照常拷贝框里的文字。

**没有询问就采用的假设**

- 回车只在列表有焦点时生效；对象列表本来就是选中即打开，不加回车。
- ⌘C 只做侧栏的四页：Inspector 的列表不接受焦点，Find 页是泛型的视图控制器，放不下 `@objc` 的 `copy(_:)`，它的结果已有右键菜单的 Copy。
- 不加 Edit ▸ Delete 菜单项，⌫ 只是列表上的按键。
- 不做触控板的左右滑动前进后退。

**落地步骤**

1. ✅ Go Back / Go Forward 菜单项与动作。
2. ✅ `StatefulOutlineView.keyDownHandler` 与 `NSEvent` 的按键判断；单元测试。
3. ✅ 镜像列表的回车、两个书签页的 ⌫、侧栏四页的 ⌘C。

**验证**：`RuntimeViewerPackages` 的相关测试（新增按键判断一个套件，连同侧栏、镜像页、右键菜单命令与跨平台源码守卫，共 20 个套件 108 个测试）在 Ultra 上全部通过；Tuist workspace 编 App（Debug）通过。没有启动 App 手工按过这些键；SourceEditor 面板有焦点时 ⌃⌘← 会不会先被编辑器接走，没有验证。

**文档**：README 的 Highlights 同批补了这三块交互补全（Filter Scope 记忆、右键菜单、Go Back / Go Forward 与标签菜单），不另写指南。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-11 | Created as Draft | 交互缺口盘点里列出的几项键盘与标准命令缺口 |
| 2026-11-11 | 用户批准，提案由 agent 起草、用户事前未审阅全文 | 用户看过交互缺口的盘点与默认做法后，选择三块都做，经 `implement-feature` 一路实现 |
| 2026-11-11 | 开始实现 | |
| 2026-11-11 | 从本地 `next` 切出，叠在 `feature/context-menus` 合并之后 | 拷贝与打开要用右键菜单那份提案加的命令 |
| 2026-11-11 | ⌘C 也拷贝文件夹行的名字 | 镜像列表里选中的可能是路径中间的文件夹；拷贝名字对它同样有意义，右键菜单的 Copy Name 只给镜像是因为文件夹没有别的命令 |
| 2026-11-11 | README 的 Highlights 在本分支一并补上三块交互补全 | 三块按顺序落地，README 一处改完比分在三条分支上各改一次少一轮冲突 |
| 2026-11-11 | 实现完成，待用户看过后收尾 | 自审没有发现要修的问题；文档：提案、两个索引与 README 已同批更新，`StatefulOutlineView` 的新入口写在它自己的文档注释里，不需要改 `AGENTS.md`，没有新术语 |
| 2026-11-11 | 用户看过后收尾，落地为 0087，状态改 Implemented | 与方案没有偏离，没有留下未做的项。用户看效果时报的「揭示的行停在钉住的分节标题下」是之前就有的问题，另修在 `fix/reveal-below-pinned-rows`（`ResolvedIssues/2026-11-11-revealed-row-under-pinned-section-header.md`）。不配使用指南或实现说明：快捷键在菜单里看得到，README 已写；没有新术语 |
