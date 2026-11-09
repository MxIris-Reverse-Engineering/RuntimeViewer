# 0082 - Tuist workspace 用六个上游库的本地检出

- **状态**: Implemented
- **创建日期**: 2026-11-09
- **最后更新**: 2026-11-09
- **实现分支 / PR**: `feature/tuist-local-dependencies`（worktree `.worktrees/RuntimeViewer-TuistLocalDependencies`），从 `next` @ b7613479 切出
- **配套文档**: [使用指南：Tuist 开发](../Guides/TuistDevelopment.md)「用本地检出的上游库」一节

## 摘要

`RuntimeViewer-Tuist.xcworkspace` 现在只用锁文件钉住的远程版本，同时改 MachO 那几个上游库和本仓库时，只能退回原生的
`RuntimeViewer-Local.xcworkspace`。给 `TuistScript.sh` 加一个会记住的本地依赖模式：打开后，`Tuist/Package.swift` 按路径声明
MachOKit、MachOKitExtensions、MachOObjCSection、MachOSwiftSection、swift-demangling、swift-semantic-string，默认取检出旁边那组
`.worktrees/` 链接，与本地 workspace 相同。根包按路径声明的包会顶替依赖图里所有同名的 URL 依赖，所以这六个库从本地源码编、
未提交的改动直接生效，其余第三方依赖照旧走二进制缓存。代价是这个模式下 Tuist workspace 里跑不了四个本地包的测试。

## 方案

1. **开关**：`./TuistScript.sh <命令> --local-dependencies` 打开，`--remote-dependencies` 关闭。状态记在检出里的
   `Tuist/.local-dependencies`（加进 `.gitignore`，内容是六个库所在的目录），之后不带这两个参数的 `install`、`generate`、`build`
   沿用它；每条命令开头打印当前模式。打开时先确认六个目录都在、目录名与包名一致。
2. **目录与名单**：默认是检出的上一级目录，worktree 里就是 `.worktrees/`，与本地 workspace 的 `group:../MachOKit` 指向同一处。环境
   变量 `TUIST_LOCAL_UPSTREAM_CHECKOUTS` 可以另指一个目录。是哪几个库，脚本从本地 workspace 的 `group:../<名字>` 成员读出，那边加了
   库这里自动跟上。脚本经三个环境变量把这些交给清单：`TUIST_LOCAL_UPSTREAM_CHECKOUTS`（目录）、`TUIST_LOCAL_UPSTREAM_PACKAGES`（库名）、
   `TUIST_LOCAL_UPSTREAM_TARGETS`（要恢复警告的 target）。
3. **清单**：`Tuist/Package.swift` 在本地模式下按路径加上这几个库，并关掉 `includeLocalPackageTestTargets`（理由见决策日志）；它们的库
   与宏 target 照四个本地包的做法恢复编译警告，名单由脚本每次读这几个库自己的清单得出。`Workspace.swift` 在本地模式下不生成
   `RuntimeViewer Tests` scheme。
4. **依赖 checkout 按模式分开放**：本地模式用 `Dependencies/<checkout>-LocalDependencies`。两种模式共用 `Tuist/Package.resolved`，
   脚本在 `Work/<checkout>/InstalledDependencies` 记下上次解析用的是哪种模式，对不上就先重新 `install`；没有这份记录的检出是本地模式
   出现之前解析的，按远程模式算。`install` 的锁文件比对在本地模式下跳过这几个库，其余照比。
5. **`warm` 与 `check` 总在远程模式下做**，结束时按记住的模式重新生成。缓存按内容寻址，六个库之外没有第三方包依赖它们，远程模式
   预热出的二进制本地模式照样命中；`check` 对照的是原生工程，本来就该用钉住的版本。
6. **六个库检出里的生成文件**：Tuist 会在每个按路径声明的包目录里写 `<包名>.xcodeproj/` 与 `Derived/`，六个仓库都没忽略前者，
   MachOKitExtensions 连后者也没忽略。生成之前，脚本把这两项写进各检出的 `info/exclude`（只在本机生效，不提交），并把本检出记在库的
   git 目录里（`runtimeviewer-tuist-local-dependencies`）：另一个检出的本地模式正占着同一个库目录时报错，库里 git 跟踪着
   `<包名>.xcodeproj` 时也报错。切回远程模式时删掉本检出生成的 `<包名>.xcodeproj/` 与那份记录，免得之后用 Xcode 打开那个库的目录时，
   打开的是 Tuist 生成的工程而不是 `Package.swift`；`Derived/` 留着（理由见决策日志）。
7. **workspace 排布**：本地模式下脚本按 `RuntimeViewer-Local.xcworkspace` 的顺序排导航栏，用默认目录时六个库在顶层最前面；经环境变量
   另指目录时它们对不上本地 workspace 里的路径，排在本地包与 App 工程之后。
8. **文档**：`Documentations/Guides/TuistDevelopment.md` 加一节，`Documentations/Guides/LocalDependencies.md` 指过去，`AGENTS.md` 的
   Tuist 一节加一句。

没有询问就采用的假设：

- 开关做成会记住的命令行参数，不要求每次自己设环境变量。
- 默认目录沿用本地 workspace 那组链接，不另建一套。
- 生成文件用 `info/exclude` 挡住，不去改六个仓库的 `.gitignore` 再逐个推送。
- MachOKit 与 swift-demangling 在本地模式下内容哈希对不上缓存，自然从源码编，缓存配置不改。
- 验证在 Ultra 上做，用按锁文件版本克隆的副本（经环境变量指过去），不动两台机器上的六个检出；第一次经链接真正使用由用户来做。

## 落地步骤

1. ✅ **清单与脚本**：`Tuist/Package.swift`、`Workspace.swift`、`TuistScript.sh`、`.gitignore`。验证（Ultra，用副本）：远程模式下
   `check` 照常通过；打开本地模式后 generate 并编 App，六个库从副本编、警告恢复；不带参数的命令沿用本地模式；本地模式下跑 `check`，
   结束后 workspace 回到本地模式；切回远程模式时副本里 Tuist 生成的工程被删掉。
2. ✅ **文档**：`Documentations/Guides/TuistDevelopment.md`、`Documentations/Guides/LocalDependencies.md`、`AGENTS.md`。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-09 | Created as Draft | Tuist workspace 只能用远程版本，同时改上游库就得退回原生的本地 workspace；原型跑通后用户决定做成正式功能。 |
| 2026-11-09 | 原型验证通过 | 分支 `feature/tuist-local-dependencies`，在 Ultra（Xcode 27.2，Debug）上用按锁文件版本克隆的副本：`tuist install` 无报错，新锁文件只比原生的少了这六个库；从空的 DerivedData 编 App 用了 198 秒，六个库的源码全部来自副本，原本取缓存的 MachOKit 与 swift-demangling 也改从源码编；在副本里加一行未提交的 `#error`，不重新生成直接编，构建报的正是那一行；改 MachOKit 一行，增量构建 101 秒，下游全部重编。 |
| 2026-11-09 | 依据 SwiftPM 的顶替规则 | SwiftPM 求解依赖时先处理按路径声明的约束，并把同名的包记为已顶替（`PubGrubDependencyResolver.processInputs`；`PackageReference` 只按 identity 比较），其余地方按 URL 的声明随之失效；非根包的地址与它不同只报警告。`Documentations/Guides/LocalDependencies.md` 说 SwiftPM 拒绝同一个包经路径和 URL 各进一次，说的是 Xcode 里各清单自己切换路径的情形，这次没有重测，那句不改。 |
| 2026-11-09 | 本地模式下不映射包的测试 target | Tuist 4.210 的 `includeLocalPackageTestTargets` 对所有按路径声明的包一视同仁（`PackageInfoMapper` 的 `includesTestTargets`），打开就会带上六个库的测试：MachOSwiftSection 的 `SwiftSectionCommandTests` 依赖可执行 target，被 Tuist 拒绝，而且这类测试用到的产品都必须在 `Tuist/Package.swift` 里声明过。要跑四个本地包的测试，用远程模式或原生的本地 workspace。 |
| 2026-11-09 | 用户批准，开始实现 | 在原型所在的功能分支上继续，原型的三个提交保留。 |
| 2026-11-09 | 警告名单由脚本读库的清单得出，不写进 `LocalPackages.swift` | 方案原定把名单写死、由 `check` 对照钉住的版本核对。本地检出常常走在钉住的版本前面，那里新加的 target 会漏掉；每次生成前读一遍本地清单总是对的，也不用维护名单。库名同样从本地 workspace 读，那边加了库这里自动跟上。 |
| 2026-11-09 | 记下上次解析用的模式 | 两种模式共用 `Tuist/Package.resolved`，本地模式解析出的锁文件少了这几个库，接着按远程模式生成就对不上。`Work/<checkout>/InstalledDependencies` 记下上次解析用的模式，对不上就先重新 `install`；`check`、`warm` 在本地模式下临时改用远程依赖时也靠它。 |
| 2026-11-09 | 生成进库目录的工程归生成它的检出 | 实测 MachOSwiftSection 生成的工程引用了生成它的那个检出的依赖目录（`Dependencies/<checkout>-LocalDependencies/artifacts/…`）和二进制缓存，另一个检出再生成就会把它换掉。脚本把检出记在库的 git 目录里，另一个检出的本地模式正占着同一个库目录时报错；库里 git 跟踪着同名工程文件时也报错，免得 Tuist 覆盖它。 |
| 2026-11-09 | 切回远程模式只删 `<包名>.xcodeproj/`，`Derived/` 留着 | 方案原定两项都删。影响 Xcode 打开方式的只有工程文件；`Derived/` 已被 `info/exclude` 挡住，五个仓库的 `.gitignore` 本来也忽略它，里面还可能有别的工具的输出，删了得不偿失。 |
| 2026-11-09 | `AGENTS.md` 只加一句 | 它已有约 62 KB，离 Codex 只读前 64 KiB 的上限很近；细节写在 `TuistDevelopment.md`。 |
| 2026-11-09 | 验证通过 | Ultra，Xcode 27.2，Debug；六个库用按锁文件版本克隆的副本，经一个放符号链接的目录指过去，与 `.worktrees/` 的布局相同。远程模式：`install` 与 `check` 照常通过。本地模式：切换后重新解析，跳过六个库后锁文件比对无差异；编 App 170 秒通过，六个库从副本编，副本里加的一行 `#warning` 出现在构建日志里；副本的 `git status` 干净，`info/exclude` 与占用记录都写上了；workspace 里没有测试 scheme；不带参数再 `generate` 沿用本地模式、不重新解析。本地模式下跑 `check`：先按远程依赖重新解析、比对通过，结束时按本地依赖解析并生成回来，测试 scheme 随之去掉。另一个检出占着库、库里跟踪着工程文件，两种情况都报错。切回远程模式：重新解析，六个库里生成的工程与占用记录删掉、`Derived/` 留着，测试 scheme 回来。没做的：`check --build`（两边各编一次 App 再比对，约半小时），以及经 `.worktrees/` 下真实链接的使用和那时的导航栏顺序。 |
| 2026-11-09 | 实现完成，待用户看过后收尾 | 文档同批更新：`TuistDevelopment.md` 新增「用本地检出的上游库」一节，日常用法表与存放位置表各加一行；`LocalDependencies.md` 指过去；`AGENTS.md` 加一句；`Documentations/README.md` 两份指南的条目补上这个模式。没有新术语，不需要实现说明：脚本与清单里的注释已写明每处写法的原因。 |
| 2026-11-09 | 合进 `next`，编号 0082，状态改为 Implemented | 用户要求收尾。合并没有冲突。合并后的 `TuistScript.sh check` 报 `SwiftObjCInterop` is not a valid configured external dependency：`next` 上同期进来的一个提交让 RuntimeViewerCore 依赖 MachOSwiftSection 新拆出的 `SwiftObjCInterop` 模块，锁文件钉住的 MachOSwiftSection 还没有它；不含本分支的 `next` 报同一个错，与本提案无关，抬 pin 后再跑。没做的两项——`check --build`，以及经 `.worktrees/` 下真实链接的使用与那时的导航栏顺序——列进提案索引的「暂缓的后续项」。配套文档是 `Guides/TuistDevelopment.md` 的「用本地检出的上游库」一节，已登记到头部；没有新术语 |
| 2026-11-09 | 抬 pin 之后补跑 `TuistScript.sh check`，通过 | 同日把 MachO 系列库的 pin 抬到含 `SwiftObjCInterop` 的 next，并在 `Tuist.swift` 的源码依赖名单里补上这个 target；先 `install` 再 `check`，Tuist 描述与原生工程一致，两边锁文件也一致 |
