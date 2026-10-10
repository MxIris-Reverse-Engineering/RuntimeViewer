# CatalystXPCServiceProbe

两个最小实验工程，2026-10-09 在 Xcode 26.6 上跑过。它们回答两个问题：

1. **Mac Catalyst 版的 XPC service 能不能嵌在 macOS app 里用？**（`project.yml` + `build.sh`）
   这是为「把 `RuntimeViewerCatalystHelper.app` 换成 XPC service」做的可行性验证。结论是能，但迁移还没开始，见文末。
2. **Catalyst 产物和 iOS Simulator 产物能不能作为 macOS app 的普通 target 依赖，在一次 macOS destination 的构建里编出来？**（`project-single-build.yml`）
   结论是能，主工程已经这样改了，见 `AGENTS.md` 的「Embedded non-macOS products」。

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `.yml` 生成，生成出来的 `.xcodeproj` 和 `Generated/` 下的 `Info.plist` 都不进 git。

## 结构

每个 target 都对应 RuntimeViewer 里的一个真实产物：

| Target | 平台 | 对应 RuntimeViewer 里的 |
|---|---|---|
| `ProbeHost` | macOS app | `RuntimeViewer.app`。连接 service，把双方的平台号和 service 的回报打印出来 |
| `ProbeService` | Mac Catalyst `xpc-service` | Catalyst helper。它只负责让进程成为 Catalyst 进程，再加载插件 |
| `ProbePlugin` | macOS bundle | `RuntimeViewerCatalystHelperPlugin`。在 Catalyst 进程里调用 `xpc_main`，回报这个进程能看到、能加载什么 |
| `ProbeHelperApp` | Mac Catalyst UIKit app（只在 `project-single-build.yml` 里） | 现在的 `RuntimeViewerCatalystHelper.app`，只编不跑 |
| `ProbeSimulatorPayload` | iOS Simulator framework（只在 `project-single-build.yml` 里） | 模拟器注入载荷，只编、只拷贝，不加载 |
| `Packages/ProbeLibrary` | SwiftPM 包（`SDKROOT = auto`） | 载荷链接的 `RuntimeViewerCore` 等包 |

两个工程的差别只在 Catalyst 的写法：

- `project.yml` 用的是主工程改动之前 helper 的写法：`SDKROOT = iphoneos` + `SUPPORTS_MACCATALYST = YES`。这种写法只有 destination 选 Mac Catalyst 时才会编成 Catalyst，所以 `build.sh` 分三次构建，再手动组装、从里到外重签名。
- `project-single-build.yml` 让 Catalyst target 自己写死平台：`SDKROOT = macosx` + `SDK_VARIANT = iosmac`。这样它们就是 `ProbeHost` 的普通依赖，一次构建全部编完并嵌入。

## 怎么跑

命令里的 `queued-build` 和 `xcsift` 是本机的构建队列和日志过滤工具，没有的话去掉前缀即可。

**问题 1**：

```bash
./build.sh
# 跑它最后打印的那个路径，也就是组装好的 ProbeHost.app 里的可执行文件
```

DerivedData 默认放在 `/Volumes/DerivedData/Agents.noindex/claude/DerivedData/CatalystXPCServiceProbe`，可以用 `CATALYST_XPC_SERVICE_PROBE_DERIVED_DATA_PATH` 换位置。

**问题 2**：

```bash
xcodegen generate --spec project-single-build.yml
queued-build xcodebuild build \
    -project CatalystXPCServiceProbeSingleBuild.xcodeproj \
    -scheme ProbeHost -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath <DerivedData>
<DerivedData>/Build/Products/Debug/ProbeHost.app/Contents/MacOS/ProbeHost
vtool -show-build <可执行文件>   # 看每个产物的 platform
```

## 结果

| 问题 | 结果 |
|---|---|
| Xcode 能不能编出 Catalyst 的 `xpc-service` | 能。产物平台是 `MACCATALYST`，`Info.plist` 里 `CFBundlePackageType = XPC!`、`ServiceType = Application` 都对 |
| 嵌在 macOS app 的 `Contents/XPCServices/` 里，能不能被 launchd 拉起 | 能。宿主的平台号（`dyld_get_active_platform`）是 1，service 是 6，`isMacCatalystApp = true`。首次回复 412 ms，包含 service 冷启动；现在的 helper 握手超时设的是 15 秒 |
| service 里能不能加载 macOS 插件，再由插件调 `xpc_main` | 能。回复来自插件，不是 service 自己的兜底分支 |
| 没有 `UIApplication` 时 UIKit 能不能用 | 能。按 macOS 路径 `dlopen` UIKit 和 SwiftUI，dyld 都解析到了 `/System/iOSSupport/…`；`UIView` 来自 iOSSupport 下的 UIKitCore，有 2039 个实例方法；类总数从 9638 涨到 64696。AppKit 随 UIKitCore 一起载入，没有崩溃，也没有窗口 |
| 宿主退出后 service 怎么样 | 跟着退出 |
| 一次 macOS 构建能不能编出全部产物 | 能。service 和 `ProbeHelperApp` 是 `MACCATALYST`，插件是 `MACOS`，载荷是 `IOSSIMULATOR`；它链接的 `ProbeLibrary` 也被编成了模拟器版。`codesign --verify --deep --strict` 通过，这样编出来的 service 照样能被拉起 |

**和现在的 helper 有一处差别**：service 刚启动时只有 348 个镜像，UIKitCore 和 AppKit 都还没载入。换成 XPC service 后，「My Mac (Mac Catalyst)」一开始列出的镜像会比现在少。启动时先 `dlopen` 一次 UIKit 就能补上，上表已经证明这样做没问题。

## 如果要把 helper 换成 XPC service

能省掉的东西：helper 不再经特权 helper daemon 拉起和握手，launchd 按 app 实例查找 service，Debug / Debug-arm64e / Release 三个变体不会连错 daemon（`Documentations/ResolvedIssues/2026-09-09-catalyst-helper-wrong-daemon.md` 那类问题会消失）；启动前杀旧实例、15 秒轮询、app 退出后自行退出都交给 launchd；service 没有 `UIApplication`，藏窗口和 Dock 图标的 hack 可以删掉。连接代码可以照着 `RuntimeViewerLocalRuntimeService` 写。

API 方面：service 这边要用的 `xpc_main`、`NSXPCListener.service()`、`XPCListener(service:)` 在 Catalyst 上都可用。`NSXPCConnection(serviceName:)` 在 Catalyst 上不可用，但发起连接的是 macOS app，不受影响。

还没解决的：

- **命令行工具，这是硬冲突**。app 没在运行时，`runtime-viewer-cli` 会经 daemon 从已安装的 app 里拉起 Catalyst helper。XPC service 只有包含它的那个 app 能找到，命令行工具的 main bundle 不是 app，找不到它（`Documentations/Evolutions/draft-local-runtime-xpc-service.md` 里有同样的结论）。要么给命令行工具保留 `.app` 版 helper，等于维护两条路径；要么接受命令行工具单独运行时没有 Catalyst 来源。app 在运行时，命令行工具仍能通过 app 拿到 Catalyst 引擎。
- **正式签名没测**。实验用的是 ad-hoc 签名，关掉了 hardened runtime，也只编了 arm64。换成 Developer ID 签名后，插件和用户选的镜像能不能载入要再确认，可能要像 `RuntimeViewerLocalRuntimeService` 那样加 `disable-library-validation` entitlement。

迁移属于架构改动，要先写完整档提案，第一个要定的就是命令行工具那条路怎么处理。
