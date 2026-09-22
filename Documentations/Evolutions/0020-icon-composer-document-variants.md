# 0020 - App 图标按 Icon Composer 版本分两份文档

- **状态**: Implemented
- **创建日期**: 2026-09-21
- **最后更新**: 2026-09-21
- **所属愿景**: 无

## 摘要

**Xcode 26 的 actool 打不开 Icon Composer 27 存出来的文档。** 只要 `icon.json` 顶层带
`"features"` 键，它就报 `Could not open "AppIconBeta.icon"`、抛一个 `NSPlaceholderArray` 异常，
然后**什么都不产出**——没有 `.icns`、没有 `Assets.car`、没有 partial `Info.plist`。Icon Composer 27
的其它新增字段（group 的 `refractivity` / `specular`、layer 的 `blend-mode`）它能解析并忽略，
只有 `"features"` 这一个键是致命的。

`AppIconBeta.icon` 在 2026-09-20 那次重建里已经被 Icon Composer 27 存过，所以**它当时就已经不能
用 Xcode 26 构建了**，只是 CI 恰好在前一天切到了 Xcode 27，没人撞上。

本提案把每个图标拆成两份文档：Icon Composer 27 的原件（人编辑的那份）和去掉 `"features"` 的
生成副本，由 xcconfig 按 `XCODE_VERSION_MAJOR` 选。

与本提案同批次落地的还有一个独立的 bug 修复（描边图形在 Icon Composer 1.6 下被当成填充），
根因见 [2026-09-21-icon-strokes-rendered-as-fills](../ResolvedIssues/2026-09-21-icon-strokes-rendered-as-fills.md)。
两件事都在图标上，但互不依赖：描边那个修完之后单份文档在两个渲染器上就都正确了，分版本解决的
是构建期能不能打开文件的问题。

## 方案

### 1. 四份文档

| 文档 | 格式 | 谁来维护 |
|---|---|---|
| `Resources/AppIcon.icon` | Icon Composer 27 | 人。用 Icon Composer 27 打开编辑 |
| `Resources/AppIconBeta.icon` | Icon Composer 27 | 人。同上 |
| `Resources/AppIconXcode26.icon` | Icon Composer 1.6 | 脚本生成，勿手改 |
| `Resources/AppIconBetaXcode26.icon` | Icon Composer 1.6 | 脚本生成，勿手改 |

四份都在 App target 的 Resources 构建阶段里。`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS=NO`
（工程里本来就设了）保证只有被选中的那份进 bundle。

### 2. 生成脚本

`Resources/AppIconTools/GenerateXcode26IconDocuments.swift`，从仓库根运行：

```bash
swift Resources/AppIconTools/GenerateXcode26IconDocuments.swift [--dry-run]
```

复制整个 `.icon` 目录，再把 `icon.json` 顶层的 `"features" : [ … ],` 块**按文本**删掉，最后用
`JSONSerialization` 解析一遍证明结果仍是合法 JSON。改完任一原件就重跑一次，两边同批次提交。

对已经没有 `"features"` 的文档，脚本原样输出（幂等）。

### 3. xcconfig 的两轴选择

`Configurations/RuntimeViewerUsingAppKit/{Debug,Release}.xcconfig`：

```
RUNTIME_VIEWER_APP_ICON_BASE_NAME = AppIcon
RUNTIME_VIEWER_APP_ICON_VARIANT_2600 = Xcode26
RUNTIME_VIEWER_APP_ICON_NAME = $(RUNTIME_VIEWER_APP_ICON_BASE_NAME)$(RUNTIME_VIEWER_APP_ICON_VARIANT_$(XCODE_VERSION_MAJOR))
```

- **渠道轴**：`ArchiveScript.sh` 在 beta / RC 渠道把 `RUNTIME_VIEWER_APP_ICON_BASE_NAME` 覆盖成
  `AppIconBeta`（原先覆盖的是 `RUNTIME_VIEWER_APP_ICON_NAME`，那样会绕过版本轴）
- **工具链轴**：`XCODE_VERSION_MAJOR` 在 Xcode 26.6 上是 `2600`、27.0 上是 `2700`。未定义的
  `RUNTIME_VIEWER_APP_ICON_VARIANT_2700` 展开成空串，所以 27 以及之后的每个 Xcode 都自动拿原件

四种组合实测：

| | Xcode 26.6 | Xcode 27.0 |
|---|---|---|
| 正式渠道 | `AppIconXcode26` | `AppIcon` |
| beta 渠道 | `AppIconBetaXcode26` | `AppIconBeta` |

### 4. 归档校验

`ArchiveScript.sh` 原本就会读回导出 bundle 的 `CFBundleIconName` 和预期值比对——因为 actool 在
找不到指定图标时**退出码为 0 且写一个空的 partial plist**，不校验就会发出一个没有图标的 app。
现在预期值要带上版本后缀，脚本用 `xcodebuild -version` 独立复述一遍 xcconfig 的规则。故意不从
`-showBuildSettings` 读同一个值：两处各算一次，写错一处就会在归档时失败。

## 决策日志

**不做 staging 目录。** 最初担心 Xcode 26 的 actool 会因为输入目录里存在 27 格式文档而整体失败，
那样就得像 Catalyst helper 那样把选中的那份拷到固定路径再编译。实测否定了这个担心：四份文档一起
喂给 Xcode 26 的 actool、选 `AppIconXcode26`，编译正常通过；只有把 27 格式那份**选为** app icon
才会失败。所以四份文档可以平摊在 Resources 里。

**去掉 `"features"` 用文本删除，不用 JSON 往返。** `JSONSerialization` 读写一轮会把 `0.07` 写成
`0.070000000000000007`——每跑一次生成脚本，所有没动过的字节都会跟着 churn。文本删除只动那四行，
其余字节逐字保留；合法性由事后解析一次来保证。

**默认是 27 格式，Xcode 26 才是特例。** 反过来写（默认 1.6、Xcode 27 加后缀）会让将来的 Xcode 28
落回 1.6 文档。现在这个方向下，没有为某个版本显式声明变体，就意味着「用原件」。

**运行时切换不成立。** 一个 app bundle 只能带一份图标，Dock 和 Finder 读的是 bundle 的
`CFBundleIconName`。所以这是纯构建期的分版本，不是按运行的 macOS 版本挑图标。好在也不需要——
实测 27 格式编出的 `Assets.car` 在 macOS 26 上渲染完全正常，只是新特性不生效。

**`AppIcon.icon` 暂时还是 1.6 格式。** 机制先立起来，但主图标还没用上 Icon Composer 27 的折射与
高光参数，所以此刻 `AppIconXcode26.icon` 与它逐字节相同。参数得在 Icon Composer 27 里看着调，
本机是 macOS 26，没有可靠的验证手段，不适合凭空填数。等主图标真用上新特性，重跑一次生成脚本
即可，无需改任何构建配置。`AppIconBeta.icon` 那对已经有真实差异（BETA 徽章那组带
`refractivity` 与 `specular`）。

## 未完成

- `AppIcon.icon` 用上 Icon Composer 27 的 `refractivity` / `specular-location`（需要在
  Icon Composer 27 里调参并肉眼验收）
- 生成结果没有 CI 校验。如果哪天原件改了而没重跑脚本，两份文档会静默不同步——加一个「重跑脚本后
  `git diff` 必须为空」的检查即可堵住，但目前构建流程里没有合适的挂载点
