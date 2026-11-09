# Draft - Tuist workspace 用六个上游库的本地检出

- **状态**: Accepted
- **创建日期**: 2026-11-09
- **最后更新**: 2026-11-09
- **实现分支 / PR**: `feature/tuist-local-dependencies`（worktree `.worktrees/RuntimeViewer-TuistLocalDependencies`），从 `next` @ b7613479 切出

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
2. **目录**：默认是检出的上一级目录，worktree 里就是 `.worktrees/`，与本地 workspace 的 `group:../MachOKit` 指向同一处。环境变量
   `TUIST_LOCAL_UPSTREAM_CHECKOUTS` 可以另指一个目录；脚本也经这个变量把目录交给清单，`Tuist/Package.swift` 与 `Workspace.swift`
   都读它。
3. **清单**：`Tuist/Package.swift` 在本地模式下按路径加上六个库，并关掉 `includeLocalPackageTestTargets`（理由见决策日志）；六个库的
   target 照四个本地包的做法恢复编译警告，名单放进 `Tuist/ProjectDescriptionHelpers/LocalPackages.swift`，由 `check` 对照六个包的
   清单核对。`Workspace.swift` 在本地模式下不生成 `RuntimeViewer Tests` scheme。
4. **依赖 checkout 按模式分开放**：本地模式用 `Dependencies/<checkout>-LocalDependencies`，切换模式时重新 `install` 再生成；`install`
   的锁文件比对跳过这六个库，其余照比。
5. **`warm` 与 `check` 总在远程模式下做**，结束时按记住的模式重新生成。缓存按内容寻址，六个库之外没有第三方包依赖它们，远程模式
   预热出的二进制本地模式照样命中；`check` 对照的是原生工程，本来就该用钉住的版本。
6. **六个库检出里的生成文件**：Tuist 会在每个按路径声明的包目录里写 `<包名>.xcodeproj/` 与 `Derived/`，六个仓库都没忽略前者，
   MachOKitExtensions 连后者也没忽略。打开本地模式时，脚本把这两项写进各检出的 `info/exclude`（只在本机生效，不提交）；切回远程模式
   时删掉这两项里 git 没跟踪的部分，免得之后用 Xcode 打开那个库的目录时，打开的是 Tuist 生成的工程而不是 `Package.swift`。
7. **workspace 排布**：本地模式下脚本按 `RuntimeViewer-Local.xcworkspace` 的顺序排导航栏，六个库在顶层最前面。
8. **文档**：`Documentations/Guides/TuistDevelopment.md` 加一节，`Documentations/Guides/LocalDependencies.md` 指过去，`AGENTS.md` 的
   Tuist 一节加一句。

没有询问就采用的假设：

- 开关做成会记住的命令行参数，不要求每次自己设环境变量。
- 默认目录沿用本地 workspace 那组链接，不另建一套。
- 生成文件用 `info/exclude` 挡住，不去改六个仓库的 `.gitignore` 再逐个推送。
- MachOKit 与 swift-demangling 在本地模式下内容哈希对不上缓存，自然从源码编，缓存配置不改。
- 验证在 Ultra 上做，用按锁文件版本克隆的副本（经环境变量指过去），不动两台机器上的六个检出；第一次经链接真正使用由用户来做。

## 落地步骤

1. **清单与脚本**：`Tuist/Package.swift`、`Workspace.swift`、`TuistScript.sh`、`.gitignore`。验证（Ultra，用副本）：远程模式下
   `check` 照常通过；打开本地模式后 generate 并编 App，六个库从副本编、警告恢复；不带参数的命令沿用本地模式；本地模式下跑 `check`，
   结束后 workspace 回到本地模式；切回远程模式时副本里 Tuist 生成的工程被删掉。
2. **文档**：`Documentations/Guides/TuistDevelopment.md`、`Documentations/Guides/LocalDependencies.md`、`AGENTS.md`。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-09 | Created as Draft | Tuist workspace 只能用远程版本，同时改上游库就得退回原生的本地 workspace；原型跑通后用户决定做成正式功能。 |
| 2026-11-09 | 原型验证通过 | 分支 `feature/tuist-local-dependencies`，在 Ultra（Xcode 27.2，Debug）上用按锁文件版本克隆的副本：`tuist install` 无报错，新锁文件只比原生的少了这六个库；从空的 DerivedData 编 App 用了 198 秒，六个库的源码全部来自副本，原本取缓存的 MachOKit 与 swift-demangling 也改从源码编；在副本里加一行未提交的 `#error`，不重新生成直接编，构建报的正是那一行；改 MachOKit 一行，增量构建 101 秒，下游全部重编。 |
| 2026-11-09 | 依据 SwiftPM 的顶替规则 | SwiftPM 求解依赖时先处理按路径声明的约束，并把同名的包记为已顶替（`PubGrubDependencyResolver.processInputs`；`PackageReference` 只按 identity 比较），其余地方按 URL 的声明随之失效；非根包的地址与它不同只报警告。`Documentations/Guides/LocalDependencies.md` 说 SwiftPM 拒绝同一个包经路径和 URL 各进一次，说的是 Xcode 里各清单自己切换路径的情形，这次没有重测，那句不改。 |
| 2026-11-09 | 本地模式下不映射包的测试 target | Tuist 4.210 的 `includeLocalPackageTestTargets` 对所有按路径声明的包一视同仁（`PackageInfoMapper` 的 `includesTestTargets`），打开就会带上六个库的测试：MachOSwiftSection 的 `SwiftSectionCommandTests` 依赖可执行 target，被 Tuist 拒绝，而且这类测试用到的产品都必须在 `Tuist/Package.swift` 里声明过。要跑四个本地包的测试，用远程模式或原生的本地 workspace。 |
| 2026-11-09 | 用户批准，开始实现 | 在原型所在的功能分支上继续，原型的三个提交保留。 |
