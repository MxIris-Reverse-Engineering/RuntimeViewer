# Draft - 只看导出的 Swift 声明：侧栏的 Not Exported 属性与生成选项开关

- **状态**: In Progress
- **创建日期**: 2026-10-30
- **最后更新**: 2026-10-31
- **所属愿景**: 无
- **实现分支 / PR**: `feature/exported-declarations-filter`（从 `next` 切，并回 `next`）
- **关联提案**: MachOSwiftSection 的 `draft-exported-only-marking-mode`（Find 依赖它；它也修正 C 导入类型的导出裁决）

## 摘要

让用户只看一个镜像对外导出的 Swift 声明：侧栏能筛掉未导出的类型与协议，内容区、批量导出与 Find 能去掉导出类型里未导出的成员。「导出」指符号在镜像的 export trie 里，是链接层面的事实，不是还原出来的访问级别。判断全部来自 MachOSwiftSection：类型与协议的 `exportStatus`（`prepare()` 之后就有），以及打印器的 `printExportedDeclarationsOnly` 过滤。侧栏只给类型与协议打标志，成员只能由打印器删。每个类型各有各的判断：未导出的类型里也可能嵌着已导出的类型（Foundation 的 `LocalePreferences.ICUSymbolsAndStrings`），Exclude 时外层类型作为它的容器照样列出。

## 方案

1. ✅ **侧栏属性。** `RuntimeObject.Properties.Flag` 加 `isNotExported = 9`，只在 Swift 类型、协议（含嵌套与特化，特化沿用原型的值）的 `exportStatus.isDefinitelyNotExported` 为真时打上。判断不了的不打：镜像没有导出信息、Swift 声明的 `@objc` 协议、C 导入类型（上游改为不裁决之后；它的条目里并着本镜像给它写的扩展），以及扩展与 conformance 条目。选 Exclude 时这些照样显示，选 Only 能列出全部未导出的类型。Filter Scope 加一行 `notExported`，标题「Not Exported」，标题与 tooltip 写在 `SidebarRuntimeObjectScopeViewController`。旧版本的 engine 不打这一位，它的对象一律当作判断不了。
2. ✅ **生成选项。** `SwiftGenerationOptions` 加 `@Default(false) printExportedDeclarationsOnly`（旧设置照常解码），`applySwitches(of:)` 映射到打印器的同名配置，Generation Options 的 Swift 一节加勾选框「Print Exported Declarations Only」，MCP 的 `.mcp` 预设保持关闭。RuntimeViewer 逐个定义打印、不经过 `printRoot()`，所以 `RuntimeSwiftSection` 在 `prepare()` 之后给内容区与语料两个打印器都调用 `installExportFilterScope(types:protocols:)`，不装的话扩展这一腿会全部保留。
3. ✅ **打印为空。** 开着这个选项时，未导出的类型本身（例如从别的 interface 点类型名跳过去）和成员被删光的扩展会打印成空：内容区显示一句占位说明，批量导出跳过这些对象、不写空文件。
4. **Find。** 语料打印器已经开着标记模式，`RuntimeInterfaceVisibility` 经 `applySwitches(of:)` 自动拿到新开关；上游标记模式覆盖导出过滤之后，文本搜索与成员搜索与内容区一致，前提是本仓库自己拼接与摘取的部分也跟上：语料打印器装上导出过滤的 scope（第 2 步），定义之间的空行带上两侧定义的可见条件（第 3 步），以及一个外层被排除、自己没被排除的嵌套类型不从外层的打印里摘取、单独打印——摘出来的那段带着外层「开关关闭才可见」的条件，而它单独打印时没有。✅ 以上已完成。还剩抬 MachOSwiftSection 的 pin：要等上游把 `next` 推到 origin。存盘的语料按产出它的代码的 `LC_UUID` 分目录（[0061](0061-derived-data.md)），升级后旧语料不会被读到。
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
| 2026-10-31 | 标志用测试 bundle 自己声明的 fixture 断言；Exclude 与 Only 的断言放在 Packages 的 `RuntimeObjectScopeTests` | 第 5 步原写「Core 测试用一个带未导出类型的镜像断言标志、Exclude 与 Only」，但 `RuntimeObjectScope` 在 RuntimeViewerApplication，Core 测试够不到；用测试 bundle 里的 public / private 类型与协议当镜像，结果不随系统版本变。 |
| 2026-10-31 | 一个条目的几个定义改用 Semantic 的 `joined(separator:)` 拼接 | RuntimeViewer 自己用空行把类型、扩展、conformance 连成一个条目。原写法在被过滤掉、打印为空的定义两侧也加空行：整个条目都被过滤时内容不是空串，导出类型带一个被删光的扩展时中间多出几行空行。`joined` 跳过空的定义；标记打印里每个分隔空行只在两侧都有定义可见时才可见，语料投影后与内容区逐字一致。 |
| 2026-10-31 | 本镜像未导出的类上的 ObjC 类别 conformance 照 `printRoot()` 的规则处理 | 这类 conformance 由 RuntimeViewer 逐条打印，打印器的导出过滤管不到；上游 `SwiftInterfaceBuilder` 在开关打开时去掉它、标记时把它标成开关关闭才可见，这里照做，内容区与语料都与上游一致。 |
| 2026-10-31 | 内容区的占位说明是两行注释，由 `ContentTextViewModel` 换进正文 | 引擎照旧返回空串（批量导出据此跳过）；只在 Swift 对象、开关打开、打印为空时换成说明，NSTextView 与 SourceEditor 两条显示路径都不用改。 |
| 2026-10-31 | 批量导出跳过的对象既不算成功也不算失败 | 完成页的「N interfaces」与实际写出的文件对得上；`RuntimeInterfaceExportResult` 的公开结构不变，各方照常收到 `objectCompleted`。 |
| 2026-10-31 | 外层被排除、自己没被排除的嵌套对象在语料里单独打印 | 实测 Foundation 的 `LocalePreferences` 未导出、它嵌着的 `ICUSymbolsAndStrings` 却已导出；外层的标记打印把整个外层连同嵌套定义一起标成「开关关闭才可见」，从里面摘出的嵌套定义就比它单独打印多了这层条件，开着开关时 Find 会漏掉内容区显示的内容（`RuntimeInterfaceCorpusNestingTests` 851 个嵌套类型里 1 个不一致；同一份基线代码配旧上游通过、配新上游失败）。用第 1 步的标志认出这类对象，走已有的「单独打印」分支，只多打印极少数对象。上游契约里的这个例外已告知 MachOSwiftSection 会话，由上游决定写进文档还是改标记方式。 |
| 2026-10-31 | Find 的测试只给 fixture 建语料，不给整个测试 bundle 建 | 测试 bundle 静态链着依赖，给整个 bundle 建语料会打印到 `FoundationToolbox.KeychainStorage.publisher`，MachOSwiftSection 的 opaque type 解析器在 Debug 构建下对它 `assertionFailure`，整个测试进程崩掉。这段断言 2026-09-18 起就在、与本提案无关，已告知上游；测试按语料构建的方式逐个打印 fixture 一族再组装成条目，读法与 `searchInterfaces` / `searchMembers` 相同。 |
