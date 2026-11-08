# Draft - 两个 XPC service 改成加载共享插件的外壳，local-runtime service 改名为 local service

- **状态**: In Progress
- **创建日期**: 2026-11-08
- **最后更新**: 2026-11-08
- **所属愿景**: 无
- **实现分支 / PR**: `feature/shared-service-plugin`（worktree `.worktrees/RuntimeViewer-SharedServicePlugin`），从 `next` 切出

## 摘要

App 包里有五个二进制各自静态链着一份 RuntimeViewerCore 与 MachO 系列库：App、local-runtime service、offline service、Catalyst 插件、内嵌 CLI。Release 通用二进制里每份约 48 MB，死代码剥离只在单个二进制内部起作用，不会跨二进制去重。Catalyst 的 service 与 helper 早就是外壳：可执行文件只有几百 KB，运行时从 `Contents/PlugIns` 加载 `RuntimeViewerCatalystHelperPlugin` 来干活。这次把 local 与 offline 两个 service 也改成这样的外壳，四个进程共用一份插件，插件改一个不再只属于 Catalyst 的名字。顺带把 `RuntimeViewerLocalRuntimeService` 改名为 `RuntimeViewerLocalService`。Debug 下试过 local service：可执行文件从 70,151 KB 降到 138 KB，插件只多了 57 KB；估计 Release 下两个 service 合计能省约 90 MB。App 与 CLI 仍各带一份，不在这次范围内。

## 方案

### 为什么是外壳加插件，而不是动态库

2026-11-08 先试过把 Core 做成动态库，四种做法都不成立。原因在 Xcode：一个进程里只要有两个镜像静态链着同一个包 target，Swift Build 就认定是「菱形依赖」，把那个 target 连同它的依赖整条改成动态 framework，而且按 target 改、所有平台一起改（`Sources/SWBTaskConstruction/ProductPlanning/ProductPlan.swift`）。Core 与 App 的其他包共用 FrameworkToolbox、swift-collections、swift-dependencies 等第三方库，所以无论动态库怎么切，这些库都会被一并改成动态：helper daemon 改成经 `@rpath` 链 FoundationToolbox，模拟器 payload 也被改成动态，MetaCodable 的宏插件找不到 OrderedCollections 直接崩溃。关掉这项检查虽然能编过，但那十来个第三方库会在 App 进程里各有两份，用户没有接受。插件是 `dlopen` 进来的，不在链接图里，这条规则管不到它；Catalyst 的两个外壳已经证明这条路走得通。

### 要做的事

1. **插件改名**：`RuntimeViewerCatalystHelperPlugin` → `RuntimeViewerServicePlugin`，target、文件夹、xcconfig 目录、App 里的 `Embed Catalyst Plugin` 拷贝阶段一起改。跨进程的入口类型同时改掉 AppKit / Catalyst 字样和缩写：`AppKitBridge` → `ServicePluginLoader`，`AppKitPlugin` → `ServicePlugin`，`AppKitPluginImpl` → `ServicePluginEntry`。
2. **四个入口**：`launch()` → `launchCatalystHelper()`，`runService()` → `runCatalystService()`，新增 `runLocalService()` 与 `runOfflineService()`，内容分别是两个 service 原来 `main.swift` 里的启动代码。
3. **两个 service 变外壳**：`main.swift` 只用 `ServicePluginLoader` 加载插件、调用对应入口；target 不再依赖、也不再链接任何包；`ServicePluginLoader.swift` 与 `ServicePlugin.swift` 照 Catalyst service 现在的写法，用同步文件夹的 exception set 编进来。
4. **改名 local-runtime → local**（✅ 已完成）：target、文件夹、产物、xcconfig 目录、bundle identifier（`dev.JH.RuntimeViewerLocalService`、`com.JH.RuntimeViewerLocalService`）、App `Info.plist` 的 key `RuntimeViewerLocalServiceBundleIdentifier`、Core 的 `RuntimeLocalService` 与 `RuntimeLocalServiceHost`（目录 `LocalService/`）、测试工具 `LocalServiceFixture`，以及 Tuist 描述、注释与现行文档。已归档的提案、问题记录和指向 0037 的链接保留原样；`observeLocalRuntimeRestarts` 这类指「本机运行时」概念的名字不改。
5. **文档**：根 `AGENTS.md`（外壳一节、`install()` 调用位置表、派生数据一节）、`Configurations/AGENTS.md`（插件一节）、`Documentations/DerivedData.md`、`CommunicationAndEngineArchitecture.md`、`Glossary.md`；Tuist 的 `Project.swift` 同步，提交前 `./TuistScript.sh check` 通过。
6. **验证**：Debug-arm64e 与 Release 各编一次，量每个二进制的大小，确认 `PackageFrameworks` 里除 ObjCRuntimeToolbox 外没有自动拆出的 framework，daemon 与 payload 的链接不变；Core 与 Packages 的测试编译通过；用户实测「My Mac」、离线打开一个文件、「My Mac (Mac Catalyst)」三条路径都正常。

### 没问就定下的假设

- offline service 原先不链接 RuntimeViewerInjection 和 RuntimeViewerCrossReferences，现在通过插件带进了进程。它的入口照样调用 `RuntimeInjection.install()` 与 `RuntimeCrossReferences.install()`，「链接了就要调用」这条规则因此不必再开例外。offline 引擎对这两类命令一律在客户端自己作答，装上的处理器不会被调到。
- 外壳不在构建期依赖插件 target，只在运行时加载它，构建顺序由 App 对插件的依赖保证，与 Catalyst 的外壳相同。
- 改了 bundle identifier 不影响已有数据：派生数据目录按 App 自己的 bundle identifier 存放，service 的 key 只用来判断「这是不是 App 里的 service」。
- 两个 service 原来链接的系统库与插件完全一致，外壳加载插件后，「My Mac」看到的进程镜像列表不变。
- `RuntimeViewerLocalServiceTypes.swift` 是项目模板留下的示例代码，没有地方用到，顺手删掉。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-08 | Created as Draft | 五个二进制各带一份 Core，包体里约 190 MB 是重复代码，用户希望只留一份 |
| 2026-11-08 | 不做 Core 动态库 | 四种做法都被 Xcode 的菱形依赖规则卡住；唯一能编过的那种会让十来个第三方库在 App 进程里重复，用户不接受。试验记录见上文「为什么是外壳加插件」 |
| 2026-11-08 | 不建共享的 framework target | 用户自己试过、我也试过：App 与该 framework 静态链同一批包，Xcode 把约 80 个包全改成动态，模拟器版 MachOKitExtensions 链接失败 |
| 2026-11-08 | 外壳覆盖 local 与 offline 两个 service，内嵌 CLI 不在本次范围 | 用户选定；CLI 做外壳还要把命令行代码带进插件，改动更大 |
| 2026-11-08 | local-runtime service 改名为 local service，Core 类型一起改 | 用户要求；Core 类型对齐已有的 `RuntimeOfflineService` / `RuntimeOfflineServiceHost` |
| 2026-11-08 | 用户批准，开始实现 | 按用户选定的条件，只在功能分支上本地提交，不推送、不合进 `next` |
