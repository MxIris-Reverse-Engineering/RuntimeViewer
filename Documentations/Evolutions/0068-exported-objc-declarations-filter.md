# 0068 - 只看导出的 ObjC 声明：ObjC 类的 Not Exported 标志与生成选项开关

- **状态**: Implemented
- **创建日期**: 2026-10-31
- **最后更新**: 2026-11-02
- **所属愿景**: 无
- **实现分支 / PR**: `feature/exported-objc-declarations-filter`（从本地 `next` 切，它已快进合入 `feature/exported-declarations-filter`，要用那里加的标志位、Filter Scope 行与占位说明；并回 `next`）
- **关联提案**: [0067](0067-exported-declarations-filter.md)（Swift 一侧，它把 ObjC 列为「不做」）；MachOObjCSection 的 0018 `objc-exported-declarations-only`（上游：按地址判断导出，打印器的开关与标记模式）

## 摘要

把「只看导出的声明」补到 ObjC。侧栏给本镜像明确未导出的 ObjC 类打上 `isNotExported`，Filter Scope 的「Not Exported」一行照用。Generation Options 的 ObjC 一节加勾选框「Print Exported Declarations Only」，开着时内容区、批量导出与 Find 一起去掉未导出的类、挂在这些类上的类别，以及偏移变量未导出的 ivar。判断全部来自 MachOObjCSection：类看类对象的地址上有没有导出符号，ivar 看偏移变量的地址。方法、属性、协议与类别本身没有自己的导出符号，一律保留。

## 方案

1. ✅ **侧栏标志。** 上游判定类对象明确未导出时，`RuntimeObjCSection.properties(forClassNamed:isSwiftStable:)` 加上 `.isNotExported`；结论由 indexer 在 `prepare()` 里算好，经包装类型的 `RuntimeObjCInterfaceIndexer.isClassDefinitelyNotExported(named:)` 读出。上游返回 `nil`（别的镜像的类、宿主补充的类）或镜像没有导出信息时不打。协议与类别不打。Swift 类在 ObjC 列表里的条目（`_TtC…`）照上游的判断打：测试 bundle 里有 204 个这样的类，标记与它们在 Swift 列表里的那一面逐个一致。Filter Scope 不加行，`notExported` 一行的 tooltip 改成连 ObjC 类一起说。
2. ✅ **生成选项。** 开关是上游的 `ObjCGenerationOptions.printExportedDeclarationsOnly`，旧设置解码为关。Generation Options 的 ObjC 一节加同名勾选框，MCP 的 `.mcp` 预设显式写成关闭。上游的 `isVisibilityOptionEnabled` 已认得 `objc.printExportedDeclarationsOnly`，Find 的 `RuntimeInterfaceVisibility` 不用改。
3. ✅ **打印为空。** 开着开关时，未导出的类、挂在本镜像未导出类上的类别打印为空串。内容区的占位说明从 Swift 对象扩到 ObjC 对象：条件改成看对象所属那一侧的开关，C 的 struct 与 union 不受影响。批量导出跳过空串，本来就不分语言。
4. ✅ **Find。** 不用改代码：开关打开时，上游的标记模式把未导出的类整段、未导出的 ivar 那一行标成只在开关关闭时可见，投影与内容区一致，语料照旧把空投影当作不存在。fixture 上开关开与关时投影与内容区逐字一致，私有 ivar 只在开关关闭时被成员搜索找到。
5. ✅ **测试。** Core 新增 `ObjCExportedDeclarationsTests`，fixture 是测试 bundle 里 public / private 的 `NSObject` 子类与纯 Swift 类，断言标志、开关开与关时的打印（私有 ivar 去掉、`init` 保留）、打印为空、批量导出跳过，以及 Find 的投影与成员；另一条遍历测试 bundle 里出现在 ObjC 列表的全部 204 个 Swift 类，断言两个列表的标记一致。语料可见性套件的两组「只看导出」选项把 ObjC 的开关也打开，在 libobjc 与 Foundation 上比对投影与内容区，并断言被标记的 ObjC 类开着开关时打印为空。`GenerationOptionsTests` 覆盖旧设置解码、`.mcp` 预设与 Find 的选项名，`ContentTextPipelineTests` 覆盖 ObjC 的占位说明。
6. ✅ **抬 MachOObjCSection 的 pin。** 五份锁文件抬到上游推到 origin 的 `next`（`e6dbf343`）。

没有询问就采用的假设：

- 另起一份提案，不并进 Swift 那份：那份已做完、待收尾，0062 / 0063 也是按 ObjC、Swift 两侧拆的。
- 用同一个标志位和同一行 Filter Scope：Swift 那份定标志时已写明，以后 ObjC 用同一位。
- ObjC、Swift 各一个勾选框，不做总开关：生成选项本来就按语言分节，各自映射到上游的选项类型。
- 开关打开后，Swift 类在 ObjC 一侧的 ivar 基本都会消失，因为苹果框架里这类 ivar 的偏移变量（`$s…Wvd`）基本不导出。这是上游按设计的结果，这里照用。

不做：ObjC 方法、属性、协议与类别本身的导出判断，它们没有自己的导出符号；`runtime-viewer-cli` 与 MCP 工具的参数。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-31 | Created as Draft | 用户要「只看导出的声明」也覆盖 ObjC。上游交给 MachOObjCSection 的会话实现，已合进它本地的 `next`（`c401651`），尚未推到 origin。 |
| 2026-10-31 | 用户批准，开始实现 | 上游在 MachOObjCSection 本地的 `next`（`c401651`）上、尚未推到 origin。包测试在远程依赖下用 `swift package edit` 只把 MachOObjCSection 换成这个提交，App 用临时 workspace 只让它顶替远程包，其余依赖都照锁文件；上游推送后再抬 pin。不用本地依赖模式：MachOSwiftSection 的本地 `next` 此时还带着另一项没推送的改动，会混进验证。 |
| 2026-10-31 | 第 6 步提前做：先把 MachOObjCSection 的 pin 抬到 `e6dbf343`，全程用远程依赖构建 | 开工后不久，上游推到了 origin（`e6dbf343`，提案落地为 0018），代码与 `c401651` 相同，之后只多了文档提交，上一行说的 edit 模式与临时 workspace 都不再需要。五份锁文件只改这一条；在全新构建目录里，Core 与 Packages 带测试编过，锁文件没被改写。 |
| 2026-10-31 | 包装类型上的查询返回 `Bool`，不转发上游的 `ObjCExportStatus?` | 侧栏只认「明确未导出」这一个答案；`ObjCExportStatus` 在 `ObjCMetadataSource`，RuntimeViewerCore 没有依赖这个 product，为一个类型名改清单不值得。 |
| 2026-10-31 | 挂在未导出类上的类别不在本仓库测 | 链接器把同镜像的类别并进了类，测试 bundle 与系统框架里都没有这种类别，只有不合并类别的镜像里才有；这一支由上游 MachOObjCSection 的测试覆盖。 |
| 2026-10-31 | Foundation 的实测并进语料可见性套件，不另开测试 | 那个套件本来就在 libobjc 与 Foundation 上逐条比对投影与内容区。把它两组「只看导出」选项的 ObjC 开关打开，不多加载镜像就覆盖了 ObjC 的类、类别与 ivar；再加一条断言，把「被标记」与「打印为空」连起来。 |
| 2026-10-31 | 实现完成，待用户看过后收尾 | 第 1–6 步已完成并推送功能分支。验证在 JH's Mac Studio Ultra（Xcode 27.2）上，用远程依赖、照抬过的锁文件：Packages 全量 682 个全过；Core 全量里 Communication 239、Injection 36 全过，Core 629 个中后台索引的 1 个、CrossReferences 70 个中 1 个在全量满载（负载约 30，别的会话在编译）时失败，两个套件单独重跑全过（已知现象）；CommandLine 与 App（Debug workspace，`-disableAutomaticPackageResolution`）编译通过，改过的文件没有新警告，锁文件没被改写。另用一次性探针在 SwiftUI 上比对两个列表的标记：出现在 ObjC 列表的 346 个 Swift 类都有 Swift 一侧的条目，两边标记的是同样的 321 个。文档：本提案就是完整记录；Generation Options 与 Filter Scope 没有使用指南，勾选框标题与 tooltip 已说明用途，不另写指南或实现说明；没有新术语。 |
| 2026-11-02 | 落地：编号 0068，状态改为 Implemented | 实现 2026-10-31 已合进 `next` 并推送，用户批准收尾；Swift 一侧先进 `next`，编号排在它的 [0067](0067-exported-declarations-filter.md) 之后。第 1–6 步与方案一致，没有没做完的项，「不做」的两项照旧。agent 的验证只有测试与编译，没有启动 App 看过。不另写使用指南或实现说明的判断不变；术语改判同 0067 的同日一行，术语表新增「未导出（not exported）」一条，含 ObjC 类与 ivar 的判断方式。 |
