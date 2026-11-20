# 2026-11-20 多行标签撑宽窗口的同类排查

来由：验收 [`draft-isolated-framework-loading`](../Evolutions/draft-isolated-framework-loading.md) 时，用户在 Mac Catalyst
窗口里让一次 Load Frameworks 失败，诊断 sheet 比主窗口还宽，居中后左对齐的内容落在屏幕外，看上去一片空白。这次修在
`FrameworkLoadViewController` 里（`FrameworkLoadWrappingLabel`）。本文件登记修完后对整个 App 的同类排查：都是 `next`
上原本就有的问题，与那个功能无关，用户决定暂不修。

**机制**（已在诊断页上证实）：多行 `Label`（`maximumNumberOfLines = 0`）的 `preferredMaxLayoutWidth` 为 0 时，AppKit 把
整段文字排成一行的宽度当作它的内在宽度（Apple 文档：0 表示「no maximum preferred width」），抗压优先级是默认的 750，
高于窗口保持尺寸的 500（`NSLayoutPriorityWindowSizeStayPut`），于是长路径、长错误信息会把 sheet、popover 或窗口撑宽。
修法：横向抗压降到 500 以下，宽度由容器决定，并随宽度同步 `preferredMaxLayoutWidth`，折行后的高度也随之正确。

**约定**
- ID 为 `WL.<N>`。
- 修掉一条时在这里注明修复的提交，条目不删。

## 条目

| ID | 发现 | 严重度 | 处理 | 重新判断的条件 |
|---|---|---|---|---|
| WL.1 | Specialization sheet 的 `statusLabel`（`SpecializationViewController`）与诊断页同一模式：左右是 required 的 20 点边距，抗压仍为 750，`preferredContentSize` 的 520 拦不住；文字是「Image is not indexed: <路径>」、引擎给的不支持说明或 `error.localizedDescription`，长的时候把 sheet 撑宽 | Major | 暂不修（用户决定，2026-11-20）。没有实测，按已证实的机制判断 | 有人报 Specialization sheet 过宽或内容跑出屏幕；或顺手改这个页面时一并修 |
| WL.2 | 镜像页的 `pathLabel`（`ContentImageViewController`）是单行、中间截断的标签，抗压仍为 750，内容是完整镜像路径，左右只有 required 的不等式约束，可能把编辑区乃至窗口撑宽 | 待实测 | 暂不修（用户决定）。是否成立没有实测：单行截断标签可能本来就不按整行要宽度 | 打开一个路径很长的镜像页，看编辑区或窗口是否被撑宽 |
| WL.3 | 五处多行标签的宽度被别的约束封顶、没设 `preferredMaxLayoutWidth`，按上述机制内在高度只有一行，折行后可能只显示第一行：侧栏对象列表的空列表说明（`SidebarRuntimeObjectViewController.emptyLabel`）、Compound Words sheet 的 `explanationLabel` 与 `refusalLabel`、命名词云窗口的 `messageLabel`、镜像页的 `failureLabel`（dyld 错误信息） | 待实测 | 暂不修（用户决定）。「只显示一行」是按机制推断的，没有实测——侧栏那条存在已久，没人报过，AppKit 可能另有处理 | 让其中一处显示长文字（例如加载一个会失败的镜像看 `failureLabel`），看是否只露出一行；成立就五处一起修，另看 Inspector 的 `InspectorReferencesViewController.hintLabel` 与 `InspectorRelationshipsViewController.emptyLabel` 两处低风险的 |

排查过、判为没有问题的：批量导出配置页的 `summaryLabel`（永远是「N images selected」）、导出完成页的 `summaryLabel`
（`preferredMaxLayoutWidth = 350`）、`PrivateDeclarationViewController` 的标签（按宽度设了 `preferredMaxLayoutWidth`）、
镜像页的 `objectCountsLabel`（显式换行、每行都短）、Find 结果行的标题（最多两行，宽度由列决定）、`HUDView` 的标签（HUD
固定 160 宽）。
