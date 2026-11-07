# 0078 - 本地依赖 workspace：MachO 这几个库改用本地检出

- **状态**: Implemented
- **创建日期**: 2026-11-08
- **最后更新**: 2026-11-08
- **配套文档**: [使用指南](../Guides/LocalDependencies.md)

## 摘要

新增 `RuntimeViewer-Local.xcworkspace`。它的内容与 `RuntimeViewer-Debug.xcworkspace` 相同，另加 MachOKit、
MachOKitExtensions、MachOObjCSection、MachOSwiftSection、swift-demangling、swift-semantic-string 六个库的本地检出。
这几个库经常和本仓库一起改：在这个 workspace 里它们直接用本地检出编进 App，不必先推送再抬 pin，其余依赖照锁文件
不动。要按钉住的版本编，照旧开 Debug workspace。

## 方案

- workspace 放在仓库根，与 Debug workspace 并排。条目与 Debug workspace 相同，再加六条 `group:../<库名>`：路径落在
  检出旁边的 `.worktrees/` 里，即本仓库 `.worktrees/` 下指向各库常驻检出的符号链接。`RuntimeViewerCore/Package.swift`
  的本地候选用的也是这组链接。原先只缺 MachOKitExtensions 一条，两台 Mac Studio 都已补上。
- workspace 里的本地包按包名顶替依赖图里所有同名的包，不论哪个清单按 URL 引用它。所以不改任何仓库的 `Package.swift`，
  也不用环境变量。
- 锁文件不进仓库（`.gitignore`），第一次使用时从 Debug workspace 拷一份。Xcode 解析时去掉六个库的条目，其余 pin 不变。
- `WorkspaceSettings.xcsettings` 照抄 Debug workspace 的，`iOSPackagesShouldBuildARM64e` 照样打开。
- `AGENTS.md` 的两段 workspace 说明合成一段：原来的「Workspace preference」让 agent 优先用仓库外的伞形 workspace，
  而那个 workspace 接的是本仓库在 `main` 上的主检出；「Workspaces」说 Debug workspace 接了本地检出，与实际不符。
- 脚本不改：`UpdatePackagesScript.sh` 只处理它点名的三个 workspace；`RunScript.sh` 用 `--workspace` 与
  `--derived-data` 就能换到本地 workspace。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-08 | 以 Draft 创建，用户批准，开始实现 | 用户常改这几个库，要它们走本地检出时依赖不冲突，也能随时回到远程 pin。 |
| 2026-11-08 | 本地开关放在 workspace 一层，不放进各个 `Package.swift` | 每个清单自己决定用路径还是 URL。只开 Core 的候选时，MachOSwiftSection 等库的清单仍按 URL 引用同一批包，而 SwiftPM 拒绝同一个包经路径和 URL 各进一次。`USING_LOCAL_DEPENDENCIES` 能让各清单一致，但它打开所有清单的全部本地候选，UIFoundation、Rx 几个库、MachInjector、swift-helper-service 也跟着换成本地。改成按库名生效的环境变量要改五个仓库的清单，切换要重启 Xcode，开着时还会改写 Debug workspace 提交的锁文件。 |
| 2026-11-08 | workspace 进仓库，与 Debug workspace 并排 | 用户选的：两台 Mac 都随仓库拿到。路径相对 `.worktrees/`，本仓库的任何 worktree 都能用同一个文件。 |
| 2026-11-08 | 锁文件不进仓库，从 Debug workspace 拷 | 它的内容随本机六个检出的清单变化，提交了会频繁改动、两台互相覆盖。拷 Debug 的锁文件，其余依赖就与 RV 钉的版本一致。 |
| 2026-11-08 | 只放六个库 | 跟本仓库一起改的就是这几个。swift-capstone、capstone、swift-objc-dump 很少改，留在远程。 |
| 2026-11-08 | 实测通过 | Ultra，Xcode 27.2：解析没有包身份冲突；除去六个本地库，pin 与 Debug workspace 逐条相同，只多一条本地 MachOSwiftSection 测试用的 swift-snapshot-testing；用同样六个库的临时 workspace 编 `RuntimeViewer macOS` 的 Debug 构建通过；仓库里提交的锁文件没有变化。 |
| 2026-11-08 | 配一份使用指南，不写实现说明，不加术语 | 用法、链接与锁文件的约定都在 [使用指南](../Guides/LocalDependencies.md)；实现只有一个 workspace 文件，没有新术语。 |
| 2026-11-08 | 实现完成，待用户看过后收尾 | 改动还没提交。 |
| 2026-11-08 | 落地为 0078，状态改 Implemented | 用户批准提交并推送。 |
