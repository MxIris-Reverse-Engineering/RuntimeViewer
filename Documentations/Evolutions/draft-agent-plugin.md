# Draft - 把 `runtime-viewer-cli` 的用法做成 agent 插件随仓库发布

- **状态**: Implemented
- **创建日期**: 2026-10-05
- **最后更新**: 2026-10-05
- **实现分支 / PR**: `feature/agent-plugin`（从 `next` 切出），合入 `next`，随 3.0 进 `main`

## 摘要

教 coding agent 用 `runtime-viewer-cli` 的说明，原先只在维护者本机的全局 agent skill 里，
别人装不到，CLI 改了也没人同步。现在改为仓库自带的插件 `runtime-viewer`（skill 名
`runtime-viewer-cli`），Claude Code 与 Codex 都能从 GitHub 安装；CLI 的命令面一变，skill 在同一个
commit 里跟着改。做法与 MachOSwiftSection 的 `swift-section` 插件相同。

## 方案

- **布局**：`AgentPlugins/runtime-viewer/` 下放两个工具各自的插件清单
  （`.claude-plugin/plugin.json`、`.codex-plugin/plugin.json`）与一份 skill
  `skills/runtime-viewer-cli/SKILL.md`；仓库根目录放两个工具的 marketplace 清单
  （`.claude-plugin/marketplace.json`，名 `runtimeviewer`；`.agents/plugins/marketplace.json`）。
  文件结构与字段逐一照搬 MachOSwiftSection 的 `swift-section` 插件。
- **skill 内容**：由原全局 skill 的 CLI 参考、`Documentations/Guides/CommandLineInterface.md` 与
  CLI 源码整理成面向任意使用者的英文版：命令一览、`--image` / 类型名 / `--source` 的解析规则、
  三档生成选项与地址注释、`--json` 与退出码契约、`export` 的目录布局、后台 host 与 App 接管、
  attach 的前提、已知的坑。维护者本机的路径与工作流全部去掉。每条行为都对照了 `next` 的源码与
  3.0.0-beta.6 随 App 发布的二进制。
- **整理时发现、已写进 skill 的两点**：Swift 类型要用带模块名的 `displayName`
  （`Combine.Just`，裸名 `Just` 报 `typeNotFound`）；`help host run` 会退回顶层帮助，`host`
  的子命令要写 `host <子命令> --help`。
- **README**：Getting Started 下紧跟「Command Line Interface」新增「Agent Plugin」一节（锚点
  `#agent-plugin`，即两份清单里的 `homepage`）。「Command Line Interface」一节补上 3.0.0-beta.5 起
  CLI 随 App 发布的位置——原文只写了从源码构建。
- **同步规则**：`AGENTS.md` 的 `RuntimeViewerCommandLine` 一节加一条：CLI 命令面的改动同一个
  commit 更新 skill，并把两份插件清单的 `version` 一起升——两个工具都只在版本号变化时才更新
  已安装的插件。
- **未问而定的假设**：插件版本号从 `1.0.0` 起，与 App、CLI 的版本号无关；3.0 正式发布前插件
  只在 `next` 上，安装命令带 `#next`（Claude Code）/ `--ref next`（Codex），发布后去掉。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-05 | 插件放 `next`，不放 `main` | CLI 与其使用指南都只在 `next` 上，`main` 当前版本没有这个工具 |
| 2026-10-05 | 插件版本号独立于 App / CLI 版本，从 `1.0.0` 起 | skill 可能在两次发版之间修订；跟 App 版本走则修订无法送达已安装的用户 |
| 2026-10-05 | Implemented | 两个工具的校验器均通过，与插件同一个 commit 落地 |
