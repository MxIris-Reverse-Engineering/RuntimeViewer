# 2026-09-27 发版归档：包丢了 x86_64，归档又变成了通用归档

**调查日期：** 2026-09-19（首次失败）、2026-09-27（定位与修复）
**修复落地：** 本日，`ArchiveScript.sh`（关掉新的 package PIF builder、归档后校验归档类型）与 `RuntimeViewerUsingAppKit.xcodeproj`（`RuntimeViewerCommandLineTool` 加 `SKIP_INSTALL = YES`）
**所属分支：** `next`
**Severity：** Critical —— v3.0.0-beta.5 一直发不出去：tag 推送后三次 CI 全挂，最终删 tag 重来
**触发场景：** 第一次用 Xcode 27 在 CI 上归档发版（`release.yml` 切到 `xcode-27` 镜像之后）

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象 1** | 归档 Catalyst helper 时，`RuntimeViewerCatalystHelperPlugin` 报 `Unable to resolve module dependency: 'RuntimeViewerCore'`（`RuntimeViewerCommunication`、`RuntimeViewerCatalystExtensions` 同样），前面伴随 arm64 / arm64e 的 `.swiftmodule` "built for incompatible target" 警告 |
| **根因 1** | Xcode 27 新的 package PIF builder 给每个 Swift 包写死 `ARCHS[macos] = arm64 arm64e arm64e.x1`，旧 builder 写的是 `$(inherited) arm64e`。x86_64 从所有包里消失，而插件自己仍按 `arm64 x86_64` 编译，x86_64 那一趟找不到任何依赖模块 |
| **为什么只在部分机器上出现** | 用哪个 builder 由 Xcode 用户默认值 `IDEEnableNewPackagePIFBuilder` 决定。开发机设过 `0`（旧 builder），自托管 runner 和 GitHub 镜像都是默认值（新 builder） |
| **现象 2** | 关掉新 builder 之后，前面全部通过，最后导出主 App 时失败：`exportArchive exportOptionsPlist error for key "method" expected one {} but found developer-id` |
| **根因 2** | `RuntimeViewerCommandLineTool`（7f4a7239，2026-09-10 把 CLI 内嵌进 App）没设 `SKIP_INSTALL`。命令行工具默认会安装，于是归档里除了 `Applications/RuntimeViewer.app` 还多出 `usr/local/bin/runtime-viewer-cli`，Xcode 把它当成 Generic Xcode Archive，Developer ID 等所有 App 分发方式都被拒绝 |
| **Status** | **Fixed** —— `ArchiveScript.sh` 给每条解析或构建包图的 `xcodebuild` 传 `-IDEEnableNewPackagePIFBuilder=NO`；CLI target 三个配置加 `SKIP_INSTALL = YES`；脚本在两次归档之后各校验一次归档类型，不是 App 归档就直接列出多出来的文件 |

---

## 第一个错误诊断

beta.5 的 tag 本身就打在 9302b01f 上，那个提交给插件补声明了 `RuntimeViewerCommunication` 产品依赖。提交说明认为这是一个构建顺序竞态：插件在依赖模块写完之前就去读。理由是本机四次归档都成功，而两台 CI runner 都失败。

这个判断是错的。补完依赖之后，CI 在同一个提交上照样挂。依赖声明本身是对的，保留不动，但它和这次失败无关。

「本机能过、CI 不能过」看起来像竞态，实际上是两台机器的 Xcode 默认值不一样。

## 怎么定位的

**先确认本机不是红灯回路。** 在 Mac Studio（M3 Ultra）上用 Distribution workspace 从零归档 Catalyst helper 两次：当前 next（删锁文件重新解析）与 beta.5 原样代码，都成功。本机的成功不能当证据。

**再对比日志里每个 target 的架构。** CI 上传的原始 `01-archive-catalyst-helper.log` 与本机日志对比：

| 机器 | `RuntimeViewerCore` / `Communication` / `CatalystExtensions` | 插件 |
|---|---|---|
| Mac Studio（通过） | `arm64 x86_64 arm64e` | `arm64 x86_64` |
| MacBook Pro 自托管 runner（失败） | `arm64 arm64e arm64e.x1` | `arm64 x86_64`（x86_64 那一趟失败） |

`arm64e.x1` 以 `-target-arch-variant arm64e.x1` 的形式出现在编译命令里。插件报错的正是 x86_64 那一趟 `SwiftDriver`：目录里只有 arm64 / arm64e 两份模块，它把这两份都试了一遍，报 "incompatible target"，然后放弃。日志里插件报错之后 `RuntimeViewerCore` 才 `CreateUniversalBinary`，这就是当初被读成「竞态」的那一行，其实只是调度顺序。

**两台机器的 Xcode 完全一样**（27.0，27A266a），差别在用户默认值：

| 键 | Mac Studio | MacBook Pro |
|---|---|---|
| `IDEEnableNewPackagePIFBuilder` | `0` | 未设置 |
| `IDEPackageEnablePrebuilts` | `0` | 未设置 |

**红灯回路。** 在 Mac Studio 上只加一个 `-IDEEnableNewPackagePIFBuilder=YES` 从零归档：同样三条 `Unable to resolve module dependency`，包的架构同样变成 `arm64 arm64e arm64e.x1`。命令行参数能盖过持久化的默认值（这台机器存的是 `0`），这也说明脚本里传 `=NO` 能盖过其它机器的默认值。

**机制在 PIF 缓存里**（`Build/Intermediates.noindex/XCBuildData/PIFCache/project/`）。180 个包工程的项目级设置：

| builder | `ARCHS[__platform_filter=macos]` |
|---|---|
| 旧 | `["$(inherited)", "arm64e"]` |
| 新 | `["arm64", "arm64e", "arm64e.x1"]` |

iOS、watchOS 也是同样写死的列表；visionOS 是 `arm64 arm64e`。Xcode 27 的 `ARCHS_STANDARD` 在 macOS 上仍然是 `arm64 x86_64`，所以问题不在「标准架构去掉了 Intel」，而在新 builder 没有保留 `$(inherited)`。

包为什么要编 arm64e：Release 下两个 helper daemon target（`com.mxiris.runtimeviewer.service`、`com.JH.RuntimeViewerService`）开了 `ENABLE_POINTER_AUTHENTICATION`，并链接包产物 `RuntimeViewerService`。它们是不是 Xcode 给**所有**包加 arm64e 的唯一原因，没有单独验证。

**修复验证。** 在自托管 runner 上把该默认值设为 `NO` 后重跑演练（run 36312876243）：Catalyst helper 归档与导出、模拟器载荷、主 App 归档全部通过，一路走到第二个问题。

## 第二个问题

`IDEDistribution.verbose.log` 里 Developer ID、Mac Application 等二十多种分发方式全部是 "doesn't support distributing archive"，只有 `SaveBuiltProducts` 和 `ExportArchive` 被接受。这是 Generic Xcode Archive 的特征。主 App 归档日志里装进 `InstallationBuildProductsLocation/` 的产物只有两类：`Applications/RuntimeViewer.app` 和 `usr/local/bin/runtime-viewer-cli`，后者全部来自 `RuntimeViewerCommandLineTool`。

beta.4 之前没有这个 target，所以以前的发版从没遇到过。本机的日常构建（`build` 而不是 `archive`）也不会暴露这个问题。

新加的归档类型检查：只读 `Info.plist` 的 `ApplicationProperties:ApplicationPath`，读不到就列出 `Products/` 下所有不在 `.app` 里的文件并失败。用手工造的 App 归档与通用归档各测一次：前者放行，后者报出 `./usr/local/bin/runtime-viewer-cli`。

## 顺带修掉的三件事

- **发布锁文件落后**（bc2b20ad）：`RuntimeViewer-Distribution.xcworkspace` 的 `Package.resolved` 钉着 UIFoundation 0.34.0（清单要求 0.37.0）、MachOSwiftSection eeb20303（没有 `ObjCImplementationClasses`）、swift-capstone 5.0.0（MachOSwiftSection 的 next 要求 6.0.0），CI 又从不刷新它。按 `--update-packages` 的做法重新生成。
- **自托管 runner 卡在 sudo**：`setup-xcode` 即使目标 Xcode 已经选中，也会执行 `sudo xcode-select -s`，在没有免密 sudo 的机器上就一直等终端里的密码。`release.yml` 改为先比对 `xcodebuild -version`，一致就跳过。
- **自托管 runner 睡眠后签名卡死**：临时签名钥匙串建成 `-lut 21600`，其中 `-l` 表示睡眠即上锁。演练中 MacBook Pro 在 20:04:52 睡眠、20:08:43 醒来（`pmset -g log`），之后两个 `codesign`（`RuntimeViewerLocalRuntimeService.xpc`、`runtime-viewer-cli`）弹出「codesign 想使用 app-signing 钥匙串」并一直等了 40 多分钟。那个钥匙串的密码是随机生成后丢掉的，登录密码不对，只能取消。改为 `-ut 21600`，并用 `caffeinate -i` 包住归档那一步。

## 留下的约束

- **任何发版归档都要关掉新的 package PIF builder**，除非项目放弃 x86_64。手工归档不走 `ArchiveScript.sh` 时也要带上 `-IDEEnableNewPackagePIFBuilder=NO`。这个开关是 Xcode 的旧路径，以后的 Xcode 可能把它删掉。到那时要么新 builder 已经修好（重新比对 PIF 缓存里的 `ARCHS[__platform_filter=macos]`），要么只能放弃 Intel。
- **新加任何会产出独立产物的 target**（命令行工具、框架）都要设 `SKIP_INSTALL = YES`，由 App 的拷贝阶段把它带进包里。`ArchiveScript.sh` 会在归档之后马上拦住，并指出是哪个文件。
