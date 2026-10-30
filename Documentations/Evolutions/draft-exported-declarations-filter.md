# Draft - 只看导出的 Swift 声明：侧栏的 Not Exported 属性与生成选项开关

- **状态**: Accepted
- **创建日期**: 2026-10-30
- **最后更新**: 2026-10-31
- **所属愿景**: 无
- **实现分支 / PR**: `feature/exported-declarations-filter`（从 `next` 切，并回 `next`）
- **关联提案**: MachOSwiftSection 的 `draft-exported-only-marking-mode`（Find 依赖它；它也修正 C 导入类型的导出裁决）

## 摘要

让用户只看一个镜像对外导出的 Swift 声明：侧栏能筛掉未导出的类型与协议，内容区、批量导出与 Find 能去掉导出类型里未导出的成员。「导出」指符号在镜像的 export trie 里，是链接层面的事实，不是还原出来的访问级别。判断全部来自 MachOSwiftSection：类型与协议的 `exportStatus`（`prepare()` 之后就有），以及打印器的 `printExportedDeclarationsOnly` 过滤。类型或协议没导出时，它的成员与嵌套类型必然也没导出，所以侧栏只需要类型级的标志；成员只能由打印器删。

## 方案

1. **侧栏属性。** `RuntimeObject.Properties.Flag` 加 `isNotExported = 9`，只在 Swift 类型、协议（含嵌套与特化，特化沿用原型的值）的 `exportStatus.isDefinitelyNotExported` 为真时打上。判断不了的不打：镜像没有导出信息、Swift 声明的 `@objc` 协议、C 导入类型（上游改为不裁决之后；它的条目里并着本镜像给它写的扩展），以及扩展与 conformance 条目。选 Exclude 时这些照样显示，选 Only 能列出全部未导出的类型。Filter Scope 加一行 `notExported`，标题「Not Exported」，标题与 tooltip 写在 `SidebarRuntimeObjectScopeViewController`。旧版本的 engine 不打这一位，它的对象一律当作判断不了。
2. **生成选项。** `SwiftGenerationOptions` 加 `@Default(false) printExportedDeclarationsOnly`（旧设置照常解码），`applySwitches(of:)` 映射到打印器的同名配置，Generation Options 的 Swift 一节加勾选框「Print Exported Declarations Only」，MCP 的 `.mcp` 预设保持关闭。RuntimeViewer 逐个定义打印、不经过 `printRoot()`，所以 `RuntimeSwiftSection` 在 `prepare()` 之后给内容区与语料两个打印器都调用 `installExportFilterScope(types:protocols:)`，不装的话扩展这一腿会全部保留。
3. **打印为空。** 开着这个选项时，未导出的类型本身（例如从别的 interface 点类型名跳过去）和成员被删光的扩展会打印成空：内容区显示一句占位说明，批量导出跳过这些对象、不写空文件。
4. **Find。** 语料打印器已经开着标记模式，`RuntimeInterfaceVisibility` 经 `applySwitches(of:)` 自动拿到新开关；上游标记模式覆盖导出过滤之后，文本搜索与成员搜索自然与内容区一致，本仓库只需抬 MachOSwiftSection 的 pin。存盘的语料按产出它的代码的 `LC_UUID` 分目录（[0061](0061-derived-data.md)），升级后旧语料不会被读到。
5. **测试。** `RuntimeObjectScopeTests` 覆盖新行与新位的对应；Core 测试用一个带未导出类型的镜像断言标志、Exclude 与 Only；`GenerationOptionsTests` 断言旧设置解码后新开关为关。

不做：ObjC 一侧（MachOObjCSection 的 `ObjCExportIndex` 能判断类，以后要做是同一位；ObjC 方法没有导出符号可判）、`runtime-viewer-cli` 与 MCP 工具的参数。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-30 | Created as Draft | 用户要在 RuntimeViewer 里过滤掉未导出的类型和成员。用户批准分两份提案推进，本仓库这份依赖 MachOSwiftSection 的那份。 |
| 2026-10-30 | 侧栏属性与生成选项做成两个独立控件 | 侧栏能藏的只有类型与协议，成员只有打印器能删；每个属性位都要对应 Filter Scope 的一行，是本仓库的既有约定。 |
| 2026-10-30 | 标志取「未导出」方向，只在明确未导出时打上 | 与上游「不靠猜删东西」一致：判断不了的对象在 Exclude 下保留，Only 顺带能列出全部未导出的类型。 |
| 2026-10-30 | 这次只做 Swift 对象 | 范围按用户确认；ObjC 方法没有导出符号可判。 |
| 2026-10-31 | 用户批准，开始实现 | 上游 `draft-exported-only-marking-mode` 已实现，在 MachOSwiftSection 本地的 `next`（`ad95cacd`）上、尚未推到 origin：本仓库先用本地依赖（`USING_LOCAL_DEPENDENCIES=1`）构建，上游推送后再抬 pin。 |
