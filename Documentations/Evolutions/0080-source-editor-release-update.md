# 0080 - 一条命令换钉住的 SourceEditor 版本，Tuist 构建前也取框架

- **状态**: Implemented
- **创建日期**: 2026-11-05
- **最后更新**: 2026-11-09
- **实现分支 / PR**: `feature/source-editor-release-update`（从 `next` 切，并回 `next`）

## 摘要

官方构建带的重建版 SourceEditor，版本号和四个 SHA-256 钉在 `RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease.txt`（[0072](0072-reconstructed-source-editor.md)）。换版现在要手工把四个哈希从那一版的 `Package.swift` 里抄过来，容易抄错，也看不到跨过的几版里有哪些破坏性改动。本提案加一个脚本 `UpdateSourceEditorScript.sh`，一条命令换到指定版本或最新版，并下载、校验。同时让 `TuistScript.sh` 在生成和构建之前先取框架，和 `RunScript.sh` 一样：它现在从不取，换版以后 Tuist workspace 的构建会停在 Embed SourceEditor Frameworks 阶段，报「下载的不是钉住的版本」。顺带用新脚本把钉住的版本从 26.6.2 换到 26.6.3。

## 方案

**一、`UpdateSourceEditorScript.sh`（仓库根目录，和 `FetchSourceEditorScript.sh` 并列）**
- 用法：`./UpdateSourceEditorScript.sh [<版本>]`，不给版本就取 `Mx-Iris/SourceEditor` 的最新 Release；`--dry-run` 只打印新旧钉住内容的差别和跨过的 Breaking 改动，不写文件；`--help`。
- 步骤：
  1. 照 `FetchSourceEditorScript.sh` 的读法读当前的 `PinnedRelease.txt`：版本号和框架名单。
  2. 用 `gh api` 读目标版本 tag 上的 `Package.swift`，取每个 `binaryTarget` 的 `checksum`。名单里有一个框架找不到就失败，文件不动。
  3. 只改 `version` 那一行和名单里各框架那一行，注释、空行和框架顺序原样保留。
  4. 跑 `FetchSourceEditorScript.sh`：它下载四个 zip，逐个对新的哈希校验，等于拿真实的资产把 `Package.swift` 给的值核对一遍。下载或校验失败、或者中途被打断，就把 `PinnedRelease.txt` 恢复原样，带着它的退出码退出。
  5. 打印「旧版本 → 新版本」、Release 的地址，以及跨过的每一版 Release 说明里的 Breaking 一节；最后提示跑桥接测试、提交 `PinnedRelease.txt`。
- 已经是目标版本时不改文件，只跑一次 `FetchSourceEditorScript.sh`，确保框架在位。
- 退出码与 `FetchSourceEditorScript.sh` 一致：0 成功；2 没装 `gh`、没登录或没有仓库权限；1 其他错误。

**二、`TuistScript.sh`**
- `generate`、`warm`、`build`、`check` 开始前先跑一次 `FetchSourceEditorScript.sh`。取不到（没装 `gh`、没登录、没有权限）就打一行提示照常往下走，和 `RunScript.sh` 一样；`--dry-run` 只打印这条命令。`install` 不取。
- 在命令开头跑一次，不放进 `generate_workspace`：`build` 和 `check` 在非 Debug 配置下退出时还要再生成一次，放进去会重复提示。
- 选在生成时就取，不只在 `build` 时取：开发时多是 `generate` 以后在 Xcode 里构建，换版后没取的话，Xcode 里的构建会停在嵌入阶段。

**三、文档**
- `RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`：构建管线里加上这个脚本，「换版本」一条改成跑它。
- 根 `AGENTS.md`：SourceEditor 一节的触发条件加上这个脚本。
- `Documentations/Guides/TuistDevelopment.md`：写明这四个命令会先取框架。
- `PinnedRelease.txt` 头注释里「换版本要手改」那句改成跑脚本，和第四部分的换版放进同一个提交：`FetchSourceEditorScript.sh` 逐字节比对这个文件，单改注释也会让每台机器上已下载的框架失效、要重新下载。

**四、换到 26.6.3**
- 用新脚本换版。26.6.3 的 Breaking 改动里，RV 只用到 `SMSourceNodeTypes.nodeTypeName(forId:)`：返回值从 `Any` 变成 `String?`，`SemanticNodeTypeAdjuster.swift` 里的 `as? String` 和解释它的注释删掉。其余几项（`enumerateIdentifierItems(in:using:)`、`sourceBufferProvider`、`languageSpecification`、`standardTypes`、`availableKeywords()`）RV 都没用到。

**验证**
- 两个脚本都过 `bash -n`；`--dry-run` 的输出符合预期。
- 换版脚本在功能 worktree 里实跑：换到 26.6.3，`PinnedRelease.txt` 与 `Frameworks/` 都对上；给一个不存在的版本号，报错且文件不动。
- `TuistScript.sh` 的 `generate --dry-run`、`build --dry-run` 打印出取框架这一步。
- 26.6.3：桥接测试（Debug-arm64e）通过，没过的只能是 `next` 上早就不过的 `SourceEditorScrollerTests`；构建产物目录里四个框架的 LC_UUID 与 26.6.3 的下载一致。

**落地步骤**
1. 换版脚本与它的文档。（已完成）
2. `TuistScript.sh` 与 Tuist 指南。（已完成）
3. 用脚本换到 26.6.3，`PinnedRelease.txt` 的头注释、桥接里多余的类型转换同批改，跑桥接测试。（已完成）

**没问就采用的假设**
- 脚本名照 `UpdatePackagesScript.sh`、`FetchSourceEditorScript.sh` 的叫法，用 bash 写，风格和它们一致。
- 哈希以那一版自己的 `Package.swift` 为准（`PinnedRelease.txt` 的注释就是这样规定的），不自己算；下载后的校验交给 `FetchSourceEditorScript.sh`。
- 不顺带改 `UpdatePackagesScript.sh`：SourceEditor 的新版可能带破坏性改动，要单独换、单独验证。
- `FetchSourceEditorScript.sh`、`RunScript.sh`、`ArchiveScript.sh` 不改。
- 构建与测试在公司那台 Mac 上经 `queued-build` 跑，构建产物放 agent 自己的目录。
- 脚本写完先交用户看过，再运行。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-05 | Created as Draft | 换钉住的 SourceEditor 版本要手抄四个哈希，Tuist workspace 也从不取框架；用户要一个换版脚本，并让 Tuist 脚本跟着改 |
| 2026-11-05 | 用户批准，状态改为 Accepted；顺带把钉住的版本换到 26.6.3 | 新脚本第一次实际使用正好就是这次换版；26.6.3 修了 `string(for:)` 在没有 item 时的返回值和文档注释语言服务的回答，RV 只需删一处多余的类型转换 |
| 2026-11-05 | 验证（公司那台 Mac，Xcode 27.2，Debug-arm64e） | 换版脚本：`--help`、`--dry-run`（列出 26.6.3 的三条 Breaking）、实际换到 26.6.3（下载目录里的副本与 `PinnedRelease.txt` 逐字节相同）、已是该版时只确认框架在位；不存在的版本号和写错的参数都报错、退出码 1、文件不动；把框架目录设成不可写让下载失败，退出码 1，`PinnedRelease.txt` 逐字节恢复，已下载的框架不动。`TuistScript.sh`：`generate`、`build` 的 `--dry-run` 第一步都是取框架，`install` 不取。26.6.3：桥接测试 35 个通过 33 个，没过的仍是 `next` 上早就不过的两个 `SourceEditorScrollerTests`（`8f3414e0` 起不再自动隐藏滚动条，测试没跟着改）；构建产物目录与 App 里四个框架的 LC_UUID 都和 26.6.3 的下载一致；`codesign --verify --deep --strict` 通过。没验证：Release universal 构建（改的那一行在 `#if arch(arm64)` 之内，Intel 切片不编译它）、实跑 Tuist 的 `generate` 与 `build`、启动 App |
| 2026-11-05 | 实现完成，待用户看过后收尾 | 文档已同步：模块的 `AGENTS.md`、根 `AGENTS.md`、Tuist 指南；用法写在脚本头注释和模块的 `AGENTS.md` 里，不另写使用指南和实现说明；没有新术语 |
| 2026-11-09 | 编号 0080，状态改为 Implemented | 用户要求收尾。实现在 2026-11-05 就已合进 `next`，此后钉住的版本又换到了 26.6.4。当时没验证的三项：Tuist 生成与构建前取框架，此后每次 `TuistScript.sh check` 第一步都会走到（收尾时那次也是，框架已在位）；启动 App 的目视并入 [0072](0072-reconstructed-source-editor.md) 的后续项「重建版 SourceEditor 在 App 里的目视」；Release universal 构建留给下次发版的归档。没有偏离方案之处，没有未做的项。不另写使用指南或实现说明：用法在脚本头注释与 `RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md` 里；没有新术语 |
