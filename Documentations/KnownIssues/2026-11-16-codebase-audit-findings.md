# 2026-11-16 代码库体检的裁决

审查对象：`next` @ `0a0003b8` 整个仓库，首次代码库体检。完整报告（发现 CA.1–CA.30、四问与修复验证）见
[`Reviews/CodebaseAudits/CodebaseAudit20261116.md`](../Reviews/CodebaseAudits/CodebaseAudit20261116.md)；本文件只登记
经用户确认、判为不修、暂不修或误报的条目，供以后的审查与体检跳过。

**约定**
- ID 接着体检报告编号，为 `CA.<N>`。
- 理由不再成立时（见各条「重新判断的条件」），把该条作为新发现重新报告，并在这里注明。

## 条目

| ID | 发现 | 严重度 | 处理 | 重新判断的条件 |
|---|---|---|---|---|
| CA.11 | 侧栏对象列表不再收听加载流后，服务进程仍把整个镜像读完，引擎的前台加载也一直压着后台索引（即 M6.1 / M6.6） | Major | 暂不修（用户决定）：在 `objectsWithProgress` 与侧栏的流结束时取消生产任务试过，没有用——转发的 `ObjectsInImageCommand` 没声明 `cancelsAcrossConnections`，撤不回；而它不声明，是因为旧版对端不认识 `cancelRequest`，经 Mach service 注入的载荷还会把陌生消息当成客户端离开。只取消侧栏那一层，又会让 Manual Loading 的记录在引擎仍在加载时提前结束。复现测试 `RuntimeObjectsStreamCancellationTests` 以已知问题保留 | 能按对端是否认识 `cancelRequest` 决定这条命令可否撤回时（协议级改动，需另写提案） |
| CA.31 | 「进程是否存活」的 `kill(_:0)` 判断写了 7 份，其中 3 份不把 `EPERM` 当作活着 | False positive | 不修：注入服务那份其实判了 `EPERM`；命令行工具里的两份（`HostRetirement.isRunning`、`HostSubcommands.isHostStillExiting`）在等自己的 host 进程退出，进程号被系统分给别的用户的进程时 `kill` 返回 `EPERM`，正说明 host 已退，不算活着是对的。7 份各自正确且有注释；合并要给三个清单里的四个 target 加对 `RuntimeViewerUtilities` 的依赖，不值得 | 又写出第 8 份，或某份的语义出错 |
| CA.32 | `Then.swift` 在 AppCore、AppUI、RuntimeViewerUI、App 与 iOS App 各有一份 | Nit | 不修：每份都是模块内部的 `protocol Then`，不对外导出 `then`；合成一份公开的，就会进各模块的公开接口 | 有了适合放它的 `package` 级共享模块 |
| CA.33 | `BatchExportingState` 的 `@RxObserved var` 没有 `private(set)` | False positive | 不修：它是几个步骤 ViewModel 与协调器共同写入的状态对象，不是 ViewModel，「ViewModel 的状态 `private(set)`」那条规则不适用 | 它被改成某个 ViewModel 独占 |
| CA.34 | Catalyst helper 的 `AppDelegate` 手写 `Logger(subsystem:category:)` | False positive | 不修：它是不链接任何包的外壳（根 `AGENTS.md`「a shell links no package」），用不了 FrameworkToolbox 的日志宏。同一批发现里 `ServicePluginEntry` 的手写 `Logger` 能链接日志宏，仍算违规 | 外壳改为链接包 |
| CA.35 | App target 里有 18 个 ViewModel（Main、Exporting、BatchExporting、Specialization、MCP、Attach 等），不在 AppCore | Nit | 不修：没有规则禁止，只是这些 ViewModel 测不到；算覆盖缺口，不算违规 | 规则改为要求 ViewModel 都在 AppCore |
