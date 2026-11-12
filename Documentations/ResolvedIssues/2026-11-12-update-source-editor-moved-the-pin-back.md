# 2026-11-12 不带版本号运行 UpdateSourceEditorScript.sh，把 pin 从 27.2.0-alpha.1 退回 26.6.6

**调查日期：** 2026-11-12
**修复落地：** 分支 `fix/source-editor-update-stays-on-pinned-line`，只改 `UpdateSourceEditorScript.sh` 与说明
**Severity：** Minor —— 只在开发机上手动移动 pin 时出现，被退回的 pin 没有提交；但退回之后 App 链接的是 26.6.6，靠 27 线修好的问题又回来了：行内展开的关闭按钮点不动，见 `feature/observable-macro` 上的纪要 `2026-11-11-inline-expansion-dismiss-button-ignores-clicks.md`
**触发场景：** 本机 next 检出快进合入 `feature/observable-macro` 之后，pin 是 SourceEditor `27.2.0-alpha.1`（`xcode-27` 线的预发布版）；此后不带版本号运行 `UpdateSourceEditorScript.sh`

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | `PinnedRelease.txt` 先是 `27.2.0-alpha.1`，运行脚本之后变成 `26.6.6`，`Frameworks/` 也换成了 26.6.6 |
| **影响范围** | pin 在预发布版上、又不带版本号运行脚本的检出。26.6 线上的 pin 不受影响 |
| **根因** | 脚本不带版本号时取 `gh release view` 的默认结果，即 GitHub 标成 Latest 的发布。Latest 不包括预发布版，此时是 26.6.6；脚本见它比钉的版本旧，只打一行 `moving back`，仍然照退 |
| **Status** | **Fixed** |

---

## 现场

本机（JH's Mac Studio）next 检出 `.worktrees/RuntimeViewer` 留下的痕迹：

- 引用日志：09:14:26 `merge feature/observable-macro: Fast-forward`。合入之后，提交里的 pin 是 `27.2.0-alpha.1`。
- `Frameworks/` 里的四个框架在 09:15:08 解压，旁边记录下载版本的 `Frameworks/PinnedRelease.txt` 写的是 `26.6.6`。取包脚本只按 `PinnedRelease.txt` 下载，所以下载时 pin 已经被改成 26.6.6。
- `PinnedRelease.txt` 在 09:16:58 又被写了一次，内容仍是 26.6.6，没有提交。
- 本机所有 Claude Code 与 Codex 会话记录里，这段时间都没有运行过这个脚本，是在终端里手动运行的。

能改写 `PinnedRelease.txt` 的只有 `UpdateSourceEditorScript.sh`：取包脚本、`RunScript.sh`、`TuistScript.sh`、`ArchiveScript.sh` 与构建步骤都只读它。09:15 那次是不带版本号的运行，选中了 26.6.6。09:16:58 的那次写入，与以下两种情况都对得上，结局都是 26.6.6：

- pin 被恢复成 27.2.0-alpha.1 之后，又一次不带版本号运行；
- 带 `27.2.0-alpha.1` 运行，但下载被中断或失败，脚本退出时把 pin 写回运行前的 26.6.6。

27.2.0-alpha.1 本身没有问题：同一天在功能 worktree 里下载，四个 zip 都通过了校验。

## 根因

改之前，不带版本号时取的是：

```bash
target_version="$(gh release view --repo "$REPOSITORY" --json tagName --jq .tagName)"
```

`gh release view` 不带 tag 时返回 Latest 发布，GitHub 从不把预发布版标成 Latest。2026-11-12 的发布列表里，`27.2.0-alpha.1` 是 Pre-release，Latest 是 `26.6.6`。SourceEditor 开了 `xcode-27` 线之后，27 线的预发布版比 26.6 线的正式版更新，「最新」却仍按 Latest 算，于是从 27 线退回 26 线。

脚本发现目标比钉的版本旧时，只打印 `26.6.6 is older than the pinned 27.2.0-alpha.1: moving back`，然后照样改写 pin、下载。用户说明里的用法 `./UpdateSourceEditorScript.sh   # move to the newest release`，与这个行为相反。

`version_is_after` 原先只用 `sort -V` 比较，它把 `27.2.0-alpha.1` 排在 `27.2.0` 之后。27 线的正式版出来以后，这会让脚本把正式版当成更旧的版本。

复现方法（只打印、不改文件）：在 pin 为 `27.2.0-alpha.1` 的检出里运行 `./UpdateSourceEditorScript.sh --dry-run`，旧脚本打印 `Would move SourceEditor 27.2.0-alpha.1 to 26.6.6`。

## 修复

- 不带版本号时，在钉的版本所在的线（主版本号相同，26 或 27）里，从全部非草稿发布中（含预发布版）取最新的一个。
- 不带版本号时绝不往回退：钉的版本比这条线上所有发布都新时报错退出（退出码 1），要求写明版本号；这条线上一个发布都没有时同样报错。
- 写明版本号的用法不变：可以移到任何一条线，也可以往回退，仍打印 `moving back`。
- `version_is_after` 改成按语义化版本比较：核心版本号不同时用 `sort -V`；相同时正式版排在它的预发布版之后，两个预发布版再按后缀比较。它挪到脚本开头，选版本时就能用到；列出 Breaking 章节时用的也是它。
- 脚本头部的说明与帮助、`RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md` 里移动 pin 的那一条同步改写。
- 提案 [0080](../Evolutions/0080-source-editor-release-update.md) 定的是「不给版本就取最新 Release」，当时 SourceEditor 只有一条线，也没有预发布版。这里改了这一条；提案作为当时的决策记录保持原样。

## 验证

`version_is_after` 逐条核对，九条全部符合：`27.2.0` 在 `27.2.0-alpha.1` 之后；`27.2.0-beta.1` 在 `27.2.0-alpha.2` 之后；`27.2.0-alpha.10` 在 `27.2.0-alpha.2` 之后；`27.2.0-alpha.1` 在 `26.6.6` 之后；`26.6.10` 在 `26.6.9` 之后；反方向与相同版本都判为「不在之后」。

用真实的发布列表跑 `--dry-run`，在临时目录里放脚本副本和不同的 pin：

| pin | 参数 | 旧脚本 | 新脚本 |
|---|---|---|---|
| `27.2.0-alpha.1` | 无 | 退到 26.6.6 | `already pinned`，退出码 0 |
| `26.6.4` | 无 | — | 前进到 26.6.6，列出 26.6.5 的 Breaking 章节 |
| `27.2.0-alpha.1` | `26.6.6` | — | 照旧退回，打印 `moving back` |
| `27.3.0`（比 27 线所有发布都新） | 无 | — | 报错，要求写明版本号，退出码 1 |
| `28.0.0`（没有这条线） | 无 | — | 报错，要求写明版本号，退出码 1 |

仓库里没有 shell 脚本的测试 target，这些核对没有留成自动测试。
