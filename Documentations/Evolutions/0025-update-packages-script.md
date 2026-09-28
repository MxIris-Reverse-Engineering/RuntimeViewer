# 0025 - 一条命令更新三个 workspace 的依赖

- **状态**: Implemented
- **创建日期**: 2026-09-27
- **最后更新**: 2026-09-27
- **实现分支 / PR**: `feature/update-packages-script`，提 PR 到 `main`，同批合进 `next`

## 摘要

Xcode 27 的 File ▸ Packages ▸ Update to Latest Package Versions 经常没反应或直接失败：Xcode 从本地的依赖
git 镜像里挑版本，却不先 fetch 这些镜像，它没见过的新版本就等于不存在。眼下只能手动删掉 `Package.resolved`
让它重新拉取，而且 RuntimeViewer、RuntimeViewer-Debug、RuntimeViewer-Distribution 三个 workspace 要各做一遍。
新增仓库根目录的 `UpdatePackagesScript.sh`：一条命令把三个 workspace 的依赖更新到清单允许的最新版本，
Xcode 开着也能跑；再配一个 Xcode 里右键就能执行的命令插件，调用同一个脚本。

## 方案

- **先 fetch 依赖镜像**：SwiftPM 的全局缓存（新的 SourcePackages 从它复制）、脚本自己的 SourcePackages、
  `RunScript.sh` / `ArchiveScript.sh` 的 DerivedData，以及 Xcode 为这几个 workspace 建的 DerivedData（按各自
  `info.plist` 里记录的 workspace 路径找）。8 个并行，去重；个别镜像失败只警告不中断。
- **每个 workspace 重新解析**：备份并删除 `Package.resolved`，同时删除 `workspace-state.json` —— 只删锁文件时
  SwiftPM 会从它读回旧版本，等于没更新。再用 `xcodebuild -resolvePackageDependencies` 依次按
  `RuntimeViewerCatalystHelper`、`RuntimeViewer macOS` 两个 scheme 解析，与 `RunScript.sh` / `ArchiveScript.sh`
  的 `--update-packages` 一致。
- **在脚本自己的 DerivedData 里解析**：`/Volumes/DerivedData/RuntimeViewer/PackageUpdate`（卷不在时退回项目内
  `DerivedData/PackageUpdate`，已被 gitignore），三个 workspace 共用一份 SourcePackages。Xcode 正在用的那份不碰；
  它发现锁文件变了，会从已经 fetch 好的镜像里检出新版本。
- **失败时复原**：解析失败或中途 Ctrl-C，都把原来的 `Package.resolved` 放回去；给出日志路径，并对两类已知错误
  给出下一步（上游把 tag 改指到别的提交 → SwiftPM 的 fingerprint 记录；残留 checkout 与清单对不上 → `--clean`）。
- **报告变化**：逐个 workspace 列出哪些包升了、新增、移除，并列出有改动、受版本控制的锁文件，提示提交。
  Distribution 的锁文件是发布归档用的那份。
- **不带本地依赖**：强制取消 `USING_LOCAL_DEPENDENCIES`。锁文件记录的是远程 pin，开着本地依赖时那些包会从
  锁文件里消失。
- **Xcode 里的入口**：`RuntimeViewerPackages` 新增一个命令插件 target `UpdatePackages`（`Plugins/UpdatePackages`，
  没有对应的 product，也没有任何东西依赖它）。在 Project navigator 里右键 `RuntimeViewerPackages` 即可运行，
  只做一件事：调用包目录上一级的 `UpdatePackagesScript.sh`，把弹窗里填的参数转交过去（先剔掉 Xcode 自动附加的
  `--target`）。
  - 前提是一次性关掉 Xcode 的命令插件沙盒：
    `defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES`，然后重启 Xcode。
    名字虽叫「清单沙盒」，Xcode 的 SwiftPM 用同一个标志决定清单求值和命令插件的沙盒，所以打开后所有项目、
    所有依赖的 `Package.swift` 和所有命令插件都不再受沙盒限制。
    沙盒只允许插件写自己的工作目录，而脚本要写仓库根目录下的锁文件、Xcode 自己的依赖镜像和全局缓存 ——
    Xcode 27 更新失败的根因恰恰在镜像，沙盒里的插件碰不到，所以没有「沙盒内」的版本。
  - 插件先试着在仓库根目录写一个探测文件：写不了就说明沙盒还开着，什么都不改，只提示上面的开关或改用终端脚本。
  - 共同限制：Xcode 要能加载依赖图才能运行插件；解析已经坏掉时插件可能出不来，那时用终端脚本。
- 未经询问自行决定的：只处理三个 workspace 的锁文件，不动 `RuntimeViewerCore` / `RuntimeViewerPackages`
  等包各自的 `Package.resolved`（单独更新包会选出互不兼容的 swift-syntax 约束，workspace 靠本地的预编译
  swift-syntax 统一）；`RunScript.sh` / `ArchiveScript.sh` 自己的 `--update-packages` 保持原样；不自动提交；
  没有新增依赖（版本对比用系统自带的 `python3`）。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-27 | Created as Draft | 用户：「加一个脚本，一键将3个workspace的依赖全部更新，目前Xcode27 GUI update经常无效或者失败，都要删除resolved重新拉取，写一个脚本解决」 |
| 2026-09-27 | 在脚本自己的 DerivedData 里解析，而不是 Xcode 正在用的那份 | 用户选择。跑脚本时 Xcode 可以开着；另一方案要求先在 Xcode 里关掉对应 workspace，而脚本没法可靠判断它开没开 |
| 2026-09-27 | 从 main 切分支，提 PR 到 main，同时合进 next | 用户选择；也符合 AGENTS.md「不依赖 next 的改动走 main」 |
| 2026-09-27 | 增加 Xcode 入口，形式为包命令插件 | 用户：「加一个Xcode Plugin，可以在GUI操作」，并明确要「类似Package Plugin这种」，不用 Xcode 的 Behaviors |
| 2026-09-27 | 插件不做沙盒内的简化版，而是要求关掉 Xcode 的插件沙盒 | 用户选择。依据：Xcode 自带 SwiftPM 的插件沙盒规则是默认拒绝、只放开插件工作目录与授权的包目录（在 `SwiftPM.framework` 的字符串里核对过）；`XcodeProjectPlugin` 只提供工程名、目录、文件与 target，没有 workspace、没有依赖解析接口，也没有包插件的 `packageManager`；Xcode 读取 `IDEPackageSupportDisablePluginExecutionSandbox` 的位置见 `/Volumes/RE/Xcode/27.0/README.md`（`IDESwiftWorkspace.isSandboxingDisabled`，以及构建类插件的执行路径）。右键运行的命令插件走 `SPMWorkspace.invokePlugin`，是否认这个开关尚待实测 |
| 2026-09-27 | 改用 `IDEPackageSupportDisableManifestSandbox`，放弃 `IDEPackageSupportDisablePluginExecutionSandbox` | 实测：后者设为 YES 并重启 Xcode 后，插件仍报沙盒错误。反汇编 `SwiftPM.framework` 的 `SPMWorkspace.init`：命令插件运行器 `DefaultPluginScriptRunner` 的 `enableSandbox:` 与 `ManifestLoader` 的 `isManifestSandboxEnabled:` 是同一个标志，只由前者（以及仅 Apple 内部生效的 `XBS_DISABLE_SANDBOXED_BUILDS`）决定；后者只作用于构建类插件。代价随之扩大到所有包清单的求值，用户知情后选择接受 |
| 2026-09-27 | 另一方案「保留沙盒、由常驻 LaunchAgent 在沙盒外代跑」不做 | 更安全但多一个常驻组件，且插件能往哪里写请求还需另行确认；用户选了关开关 |
| 2026-09-27 | 验证 | 插件：用户在 Xcode 里单独打开 `RuntimeViewerTools`、右键运行 `UpdatePackages --dry-run`，打开开关前报沙盒错误，打开后打印出预定的命令。脚本：在 main 的工作目录里真跑一次（`--derived-data` 指向 agent 目录），fetch 172 个镜像（1 个因网络偶发失败，警告后继续，重试即成功），三个 workspace 都解析成功，分别 38 / 39 / 41 个包升级，退出码 0；跑完还原了三个锁文件，锁文件的刷新不进这次提交 |
| 2026-09-27 | Implemented，落地为 0025 | 配套文档：用法与开关写在 `AGENTS.md` 的 Build Commands，插件的报错里也写了下一步，不另写指南；无新术语 |
| 2026-09-27 | 插件改放进现有的 `RuntimeViewerPackages`，删掉单独的 `RuntimeViewerTools` 包 | 用户：「这个不要单独写Package，写到现在就有的RuntimeViewerPackages里面去」。三个 workspace 与 `.gitignore` 里对 `RuntimeViewerTools` 的引用一并去掉；插件按「包目录的上一级是仓库根目录」找脚本，这一关系不变 |
