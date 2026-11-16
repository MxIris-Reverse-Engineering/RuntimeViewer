# 代码库体检账本

由 `audit-codebase` 维护。每轮体检先读它决定范围，跑完再更新。

## 模块表

行数按 Swift / Objective-C 源码计（不含测试），取自深审时的提交。

| 模块 | 路径 | 源码行数 | 最近深审 | 深审时的提交 | 未结的严重问题 |
|------|------|---------|---------|-------------|---------------|
| RuntimeViewerCore | `RuntimeViewerCore/Sources/RuntimeViewerCore/` | 24,220 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerCommunication | `RuntimeViewerCore/Sources/RuntimeViewerCommunication/` | 7,509 | 2026-11-16 | `0a0003b8` | 0 |
| RuntimeViewerCrossReferences | `RuntimeViewerCore/Sources/RuntimeViewerCrossReferences/` | 2,897 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerInjection | `RuntimeViewerCore/Sources/RuntimeViewerInjection/` | 940 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerUtilities | `RuntimeViewerCore/Sources/RuntimeViewerUtilities/` | 148 | 从未 | — | — |
| RuntimeViewerService | `RuntimeViewerCore/Sources/RuntimeViewerService/` | 39 | 2026-11-16 | `0a0003b8` | 0 |
| RuntimeViewerAppCore | `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/` | 23,994 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerAppUI | `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/` | 2,596 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerUI | `RuntimeViewerPackages/Sources/RuntimeViewerUI/` | 6,216 | 从未（只做过机械扫描） | — | — |
| RuntimeViewerEngineManagement | `RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/` | 2,921 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerSettings | `RuntimeViewerPackages/Sources/RuntimeViewerSettings/` | 1,660 | 2026-11-16 | `0a0003b8` | 0 |
| RuntimeViewerSettingsUI | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/` | 2,812 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerHelperClient | `RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/` | 1,306 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerDeviceInjection | `RuntimeViewerPackages/Sources/RuntimeViewerDeviceInjection/` | 1,287 | 从未 | — | — |
| RuntimeViewerSimulatorInstaller | `RuntimeViewerPackages/Sources/RuntimeViewerSimulatorInstaller/` | 816 | 从未 | — | — |
| RuntimeViewerArchitectures | `RuntimeViewerPackages/Sources/RuntimeViewerArchitectures/` | 309 | 2026-11-16 | `0a0003b8` | 0 |
| RuntimeViewerCatalystExtensions | `RuntimeViewerPackages/Sources/RuntimeViewerCatalystExtensions/` | 57 | 2026-11-16 | `0a0003b8` | 0 |
| RuntimeViewerUsingAppKit（App） | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/` | 20,120 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerSourceEditorBridge | `RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/` | 3,284 | 从未（只看过 `CommentDecorationController`） | — | — |
| RuntimeViewerServicePlugin 与各服务外壳 | `RuntimeViewerUsingAppKit/RuntimeViewerServicePlugin/` 等 | 322 | 2026-11-16 | `0a0003b8` | 0 |
| RuntimeViewerCommandLine | `RuntimeViewerCommandLine/Sources/` | 5,482 | 2026-11-16（部分） | `0a0003b8` | 0 |
| RuntimeViewerMCP | `RuntimeViewerMCP/Sources/` | 1,412 | 2026-11-16 | `0a0003b8` | 0 |
| RuntimeViewerUsingUIKit（iOS App） | `RuntimeViewerUsingUIKit/` | 1,194 | 2026-11-16（略读） | `0a0003b8` | 0 |
| RuntimeViewerServer（注入载荷） | `RuntimeViewerServer/` | 207 | 2026-11-16 | `0a0003b8` | 0 |

「部分」的模块里没读到的文件列在每轮报告的「下一轮」一节，下一轮从那里接着深审。

**不审**：`RuntimeViewerPrecompiledLibraries/`（预编译的 swift-syntax 与下载的 SourceEditor 框架）、`Stubs/`、`Experiments/`、`Products/`、`docs/`（Sparkle 发布源）、`Resources/`（图标与资源）、`Tuist/`、`Tuist.swift`、`Workspace.swift`（工程描述）、`RuntimeViewerPackages/Derived/`（生成代码），以及各包的 `Tests/`。

## 规则检查式

在仓库根目录对 `RuntimeViewerCore/Sources`、`RuntimeViewerPackages/Sources`、`RuntimeViewerUsingAppKit`、`RuntimeViewerCommandLine/Sources`、`RuntimeViewerMCP/Sources`、`RuntimeViewerUsingUIKit`、`RuntimeViewerServer` 下的 `*.swift` 运行（`git grep -nE '<式子>' <提交> -- <路径>`）。

| 规则 | 来源 | 检查式 | 2026-11-16 |
|------|------|--------|-----------|
| 任何闭包都不用 `[unowned self]` | 根 `AGENTS.md`「Closures & Self Capture」 | `\[unowned self\]` | 0 |
| Rx 订阅一律用尾随闭包写法 | 根 `AGENTS.md`「RxSwift Subscription Style」 | `\.(emit\|drive\|subscribe)\(onNext:` | 0 |
| `[weak self]` 之后用 `guard let self` | 根 `AGENTS.md`「Closures & Self Capture」 | `strongSelf` | 0 |
| 不用 `print` 打日志 | 全局指令「编码风格」 | `^[^/]*[^.a-zA-Z/]print\(` | 0 |
| 日志与埋点只用 `#log` / `#signpostInterval` | 全局指令「编码风格」 | `(os\.Logger\|Logger\(subsystem\|OSSignposter\(\|NSLog\()`，排除 `///` 行 | 4 |
| `#log` 消息不以手写的 `[Tag]` 开头 | 根 `AGENTS.md`「Logging」 | `#log\([^"]*"\[` | 15 |
| `static let shared` 一律 `fileprivate` | 根 `AGENTS.md`「Singletons & Dependency Injection」 | `static (let\|var) shared`，排除 `fileprivate static` 行（外层类型本身 `private` 的不算违规） | 3 |
| `layout` / `setup` 写成一个词 | 根 `AGENTS.md`「Naming Conventions」 | `\b(layOut\|setUp)[A-Z(]`，排除 `override func setUp()` | 0 |
| 泛型参数不用单字母 | 全局指令「编码风格」 | `<[A-Z](: [A-Za-z.]+)?(, ?[A-Z](: [A-Za-z.]+)?)*>` | 13 |

只保留最近 6 轮的计数列。规则改了就新增一行；旧行保留到计数归零或规则作废，作废时在「规则」栏注明。

## 运行记录

| 日期 | 分支 | 提交 | 范围 | 严重 bug | 结构类 | 报告 |
|------|------|------|------|---------|--------|------|
| 2026-11-16 | `next` | `0a0003b8` | 首次体检：全仓分六块深审（每块都有没读到的部分） | 6（已全部修复） | 40 余条 | [CodebaseAudit20261116.md](CodebaseAudit20261116.md) |
