# Draft - Tuist 与原生工程共存：日常开发的缓存加速通道

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-10-10
- **最后更新**: 2026-10-10
- **所属愿景**: 无
- **关联提案**: [0015](0015-build-embedded-products-in-app-phase.md)（嵌入产物曾用嵌套 xcodebuild 产出，已撤回；本提案沿用撤回之后「平台写死 + 普通 target 依赖」的结构）、[0025](0025-update-packages-script.md)（`UpdatePackagesScript.sh` 要顺带更新 Tuist 的锁文件）
- **实现分支 / PR**: `feature/tuist-integration`（worktree `.worktrees/RuntimeViewer-TuistIntegration`），从 `next` @ 2ac90984 切出；PR 待定
- **配套文档**: 使用指南 [`Guides/TuistDevelopment.md`](../Guides/TuistDevelopment.md)；`AGENTS.md`「Build Settings and the Tuist Development Workspace」一节

## 摘要

在原生 Xcode 工程旁边加一套 Tuist 描述，生成一个独立的 `RuntimeViewer-Tuist.xcworkspace`，专供日常开发使用：85 个第三方依赖经 Tuist 的二进制缓存编一次之后直接复用，四个本地包（`RuntimeViewerCore` / `RuntimeViewerPackages` / `RuntimeViewerMCP` / `RuntimeViewerCommandLine`）始终以源码出现、可跳转可编辑。原生的三个 `.xcodeproj`、三个 workspace、`RunScript.sh` / `ArchiveScript.sh` 与 CI 一概不变，发版与 CI 只走原生工程，Tuist 那边出问题不影响发版。两边共用同一份 xcconfig、Info.plist、entitlements、同步文件夹和四个 `Package.swift`；共用不了的部分（target 图、嵌入方式）各写一份，靠「同批同步」规则和一个手动运行的一致性检查脚本兜底。

## 动机

**构建时间的大头是第三方依赖，而它们几乎从不改。**

- 本次在 `JHs-Mac-Studio`（10 核，构建经 `queued-build` 限到 8 个并发）上用当前 `next` 的真实 App 源码实测：从空目录构建 Debug 共 7677 个编译任务，其中 **6965 个（90%）属于第三方依赖**（MachOSwiftSection 998、swift-crypto 603、UIFoundation 482、FrameworkToolbox 339、RxSwift 327、swift-nio 308 …），自有代码只有 712 个。不用缓存 175 秒；第三方依赖走缓存、四个本地包照常从源码编，**43 秒、721 个编译任务**。缓存每台机器每套配置预热一次，约 6 分钟、1.4 GB（详见「前期调研 §3.3」）。实现后用 Xcode 27、含全部嵌入产物的完整 App 复测：不用缓存 504 秒，走缓存 155 秒，预热约 8 分钟、1.6 GB（见决策日志）。
- 工作方式放大了这笔开销：这个仓库按任务开 worktree（此刻就有四个以上），新 worktree 的构建目录是空的，原生构建要把这些依赖重新编一遍（Xcode 自带的编译缓存能否跨 worktree 命中，没有测，见「替代方案考量」）。

**为什么是「共存」而不是迁移**：原生工程承载着发版链路上一串只在原生工程里验证过的细节——`SKIP_INSTALL` 与 Developer ID 导出、`CFBundleIconName` 复核、Catalyst helper 与模拟器载荷的平台写死、`-IDEEnableNewPackagePIFBuilder=NO`。用户的决定是长期双轨：Tuist 只承担「开发时更快」，发版与 CI 继续只认原生工程。

## 前期调研

以下除标注「推测」的条目外，均已在源码或探针中核实。Tuist 源码引用的路径相对于 tag `4.210.0` 的 `cli/Sources/`。

### 1. 现状：原生工程

- **三个真实工程、三个 workspace**。`RuntimeViewerUsingAppKit.xcodeproj`（objectVersion 90，配置 Debug / Debug-arm64e / Release）、`RuntimeViewerServer.xcodeproj`（objectVersion 77，多一个 Distribution）、`RuntimeViewerUsingUIKit.xcodeproj`（objectVersion 70，只有 Debug / Release）。三个 workspace 的成员完全相同，差别只在 `WorkspaceSettings.xcsettings`：Debug 与 Distribution 有 `iOSPackagesShouldBuildARM64e = true`（`RuntimeViewer-Debug.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings:7`），普通 workspace 没有。
- **本地包不在任何 `.xcodeproj` 里声明**：三个工程都没有 `XCLocalSwiftPackageReference`，`XCSwiftPackageProductDependency` 只写 `productName`，靠 workspace 成员关系解析。`RuntimeViewerPrecompiledLibraries/swift-syntax` 作为 workspace 成员，按包 identity 顶替了所有宏包对远程 swift-syntax 的依赖。
- **主 App 的嵌入方式**（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj`）：
  - Catalyst helper：target 写死 `SDKROOT = macosx` + `SDK_VARIANT = iosmac`（:1325 等三处），作为普通 target 依赖，`Embed Catalyst Helpers`（:192）拷到 `Contents/Applications/`。helper 自己再把 macOS 的 `RuntimeViewerCatalystHelperPlugin.bundle` 拷进 `PlugIns/`。
  - iOS Simulator 载荷：`RuntimeViewerServer.xcodeproj` 里的 `RuntimeViewerSimulatorServer` 写死 `SDKROOT = iphonesimulator`（`RuntimeViewerServer.xcodeproj/project.pbxproj:1036`），跨工程 target 依赖，`Embed RuntimeViewerMobileServer Framework`（:201）只拷贝不链接，进 `Contents/Resources/`。macOS 载荷 `RuntimeViewerServer.framework` 同样只拷进 `Resources/`（:148）。
  - 特权 daemon：产物名按配置不同（`dev.mxiris…` / `dev.arm64e.mxiris…` / `com.mxiris…`）。`Embed LaunchServices`（:174）拷的不是 daemon 的产物引用，而是一个路径为 `$(RUNTIME_VIEWER_SERVICE_NAME)` 的假文件引用（:226）；另有 shell 阶段 `Generate LaunchDaemon plist`（:834）。
  - XPC service（:130）、命令行工具（:157，拷到 `Contents/Applications/runtime-viewer-cli`）、SourceEditor bridge（:139，`PlugIns/`）。
- **大量设置写死在 target 层**，没有进 xcconfig：部署版本、`MARKETING_VERSION`、签名与加固选项、`PRODUCT_NAME` 等。`ArchiveScript.sh:277-288` 依赖 `-showBuildSettings` 读出的 `MARKETING_VERSION` 与 tag 比对，而它每次发版都要改。
- **只存在于命令行的行为**：`RunScript.sh:199` 的 `EXCLUDED_ARCHS=x86_64`、`ArchiveScript.sh:210` 的 `-IDEEnableNewPackagePIFBuilder=NO`、`USING_LOCAL_DEPENDENCIES` 环境变量。

### 2. Tuist 4.210 的能力与限制（读源码）

- **本地包可以不改写**。`Tuist/Package.swift` 里 `.package(path:)` 声明的本地包，`SwiftPackageManagerGraphLoader` 记为 external（origin `.local`、hash 为 nil），`PackageInfoMapper` 把它和远程包一样转成 Xcode target；`TargetContentHasher` 对 hash 为 nil 的项目按源文件内容计算 hash，改源码即换 hash。8 月实验「本地包必须改写成 `Project.swift`」的结论只对 `Project.packages: [.local(path:)]`（Xcode 原生 SwiftPM 集成）成立。
- **external 一律可被缓存替换，例外只能按名字精确列出**。`TuistCache/TargetReplacementDecider.swift`：`project.type == .external` 在 `onlyExternal` / `allPossible` 下都会被替换；`except` 只认 `.named` 精确匹配或 `.tagged` 标签，而 Tuist 只给本地包的**测试** target 打标签（`TuistCore/Graph/TargetTags.swift`）。要让本地包保持源码，必须在缓存配置里逐个列出它们的 target 名。
- **graph linter 不允许 macOS App 依赖 iOS 平台的 target**（含 `.macCatalyst`，它的平台算 iOS），没有开关可关（`TuistGenerator/Linter/GraphLinter.swift` 的 `validLinks`）。target 自己的 settings 会覆盖 Tuist 推导的 `SDKROOT`；放在 xcconfig 里的会被 Tuist 写在 target 层的推导值压住。
- **`.bundle` 不能链接静态产物**：`XcodeGraph/Models/Target.swift:198` 的 `canLinkStaticProducts()` 不含 `.bundle`，bundle 的静态依赖会被上提到宿主去链接。社区报过同一场景（Catalyst App 加载 macOS 插件 bundle：tuist/tuist#5760、#5796），无人修复后因过期关闭。
- **任何从 App 能走到的动态 framework 都会被自动嵌进 `Frameworks/`**：`GraphTraverser.embeddableFrameworks` 不看 `LinkingStatus`，`status: .none` 只去掉链接、不去掉嵌入，中间隔一层命令行工具也一样。
- **trait 条件的设置会被丢掉**：`TuistLoader/SwiftPackageManager/SettingsMapper.swift` 的 `settings(for:)` 只收「无条件」或「带平台条件」的设置，`.define(X, .when(traits: [...]))` 这种只带 trait 条件的设置两头都不进。trait 本身会被翻译成同名编译条件，但包里依据 trait 定义的宏不会。
- **生成物**：`<Project.swift 所在目录>/<名字>.xcodeproj`、`<Workspace.swift 所在目录>/<名字>.xcworkspace`，每个本地包目录下另写 `<包名>.xcodeproj` 与 `Derived/`；`WorkspaceSettings.xcsettings` 只生成两个键，写不出 `iOSPackagesShouldBuildARM64e`；pbxproj 固定是 objectVersion 55。
- **缓存与隐私**：`Tuist.swift` 不写 `fullHandle` 时只用本地缓存，命令统计也不上报（`TrackableCommand.run`）。本地缓存目录由 `TUIST_XDG_CACHE_HOME` 决定，预热时的临时构建目录由 `TUIST_CACHE_WARM_SCRATCH_DIRECTORY` 决定，依赖的 checkout 目录（默认 `Tuist/.build`）可用 `SWIFTPM_BUILD_DIR` 挪走（`TuistSupport/SwiftPackageManager/SwiftPackageManagerScratchDirectoryLocator.swift`）。

### 3. 探针（2026-10-10，`JHs-Mac-Studio`，Xcode 26.6，Tuist 4.210.0）

两个一次性工程都在 `/Volumes/DerivedData/Agents.noindex/claude/Scratch/TuistProbe/`，构建目录与 Tuist 缓存都在 `/Volumes/DerivedData/Agents.noindex/claude/` 下，没有碰任何 worktree 与用户自己的缓存。

#### 3.1 嵌入探针（`EmbedProbe/`）

用 Tuist 重写仓库里的 Catalyst / 模拟器嵌入实验（`Experiments/CatalystXPCServiceProbe/`，`feature/catalyst-xpc-service-probe` 分支），补上 daemon、XPC service、命令行工具、macOS 载荷与 bridge。最终三套配置都构建通过，产物平台为：helper `MACCATALYST`、helper 里的插件 `MACOS`、模拟器载荷 `IOSSIMULATOR`；`codesign --verify --deep --strict` 通过；开二进制缓存（依赖换成 xcframework）后同样通过，模拟器载荷链接的是缓存里的模拟器切片。走到这一步之前被否掉的写法：

| 写法 | 结果 | 改成 |
|---|---|---|
| helper 插件声明为 `.bundle` 并依赖包 | 包的链接被上提到 Catalyst helper，包被编成 Catalyst 版，插件编译时找不到模块 | 插件声明为 `.framework`，设 `WRAPPER_EXTENSION = bundle`；helper 现有的 `Bundle(path:)` + `principalClass` 加载照常成功（版式是 framework 的 `Versions/A`） |
| 模拟器载荷作为 App 的 `status: .none` 依赖 | 被自动嵌进 App 的 `Frameworks/`，Xcode 校验报「expected Versions/Current/Resources/Info.plist since the platform does not use shallow bundles」 | 不建依赖，由 scheme 按手动顺序先构建（下一行） |
| 经一个不嵌入的命令行工具转一道依赖 | 依然被嵌进 App 的 `Frameworks/` | 同上 |
| 不建依赖、scheme 用「按依赖排序」 | 构建成功，但日志里 App 与载荷之间没有依赖边，是竞态赢了 | scheme 用 `buildOrder: .manual`（Xcode 提示该选项已弃用，可用 `DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING` 关掉提示） |
| daemon 用 `.buildProduct` 拷贝 | Debug-arm64e 与 Release 下拷的仍是 Debug 的产物名 `dev.probe.service`：产物引用的文件名按默认配置求值（原生工程那个假文件引用正是为此存在） | 改为 App 的构建后脚本按当前配置的 `$(RUNTIME_VIEWER_SERVICE_NAME)` 拷贝并重签名，三套配置都正确 |
| helper → 插件用 `status: .none` 依赖排顺序 | 开二进制缓存后，Tuist 生成的工程里这条依赖整条消失，插件没被构建 | 插件也交给 scheme 的手动顺序；顺带去掉了它在 helper `Frameworks/` 里的多余拷贝 |

macOS 载荷不需要任何依赖：App 的拷贝阶段引用它的产物，Xcode 就把它识别为隐式依赖（「Implicit dependency … via file … in build phase 'Copy Files'」）；跨平台的产物（模拟器载荷、被 Catalyst helper 拷贝的 macOS 插件）则不会被识别。

#### 3.2 包层探针（`PackageProbe/`）

`git archive` 拷一份 `feature/tuist-integration`，加上 `Tuist.swift`、`Workspace.swift`、`Tuist/Package.swift`，以及一个只含主 App 与 SourceEditor bridge 两个 target、用真实源码与真实 xcconfig 的 `RuntimeViewerUsingAppKit/Project.swift`。

- `tuist install` 2 分 47 秒解析出 85 个依赖；以原生 Debug workspace 的锁文件为初值，结果 84 条一致，差 1 条：原生是 `swift-issue-reporting` 2.1.1，这里是旧名 `xctest-dynamic-overlay` 1.13.1（同一个仓库改过名）。推测与工具链有关：pointfree 的包按 Swift 版本选用不同的 `Package@swift-x.y.swift`，本机 Swift 6.3 选中的清单仍引用旧名，原生锁文件则可能是在 Xcode 27 上解析的。
- `tuist generate` 18 秒，生成 34 个项目。生成物：根目录的 `RuntimeViewer-Tuist.xcworkspace`、`RuntimeViewerUsingAppKit/RuntimeViewer-Tuist.xcodeproj` 与 `Derived/`，以及五个本地包（含预编译 swift-syntax）目录下各一个 `<包名>.xcodeproj` 与 `Derived/`。`Tuist/.build` 占 3.4 GB（二进制产物 2.4 GB、git 镜像 847 MB）。
- 主 App 的 Debug 构建经三处修正后通过：
  1. **KeyboardShortcuts 2.4.0 的 `ar.lproj/Localizable.strings` 第 5 行有未转义的引号**。Xcode 自带的 SwiftPM 集成复制包里的 `.strings` 时不做校验，Tuist 把包转成普通 target 后走 Xcode 默认的 `VALIDATE_STRINGS_FILES_WHILE_COPYING = YES` 而失败。外部 target 统一设 `NO`，与原生行为一致。
  2. **MachOSwiftSection 打开的 `AARCH64` trait 没有变成 `CAPSTONE_HAS_AARCH64`**：即 §2 那个丢 trait 条件设置的问题。swift-capstone 的 Swift 代码因此编不过；更危险的是 capstone 的 C 库同样拿不到这个宏，会「编得过、运行时没有任何架构」。在 `PackageSettings.targetSettings` 里给 `Capstone` 与 `Ccapstone` 补上。逐个扫过 85 个依赖的清单，用到「按 trait 条件定义宏」且该 trait 处于开启状态的只有这两个包（SFSymbols 也有一处，但 `SwiftUI` trait 没开）。
  3. **Mx-Iris 的 UIFoundation 包撞上 Apple 的私有框架**：Tuist 默认把包编成同名静态 framework，`UIFoundation.framework` 出现在框架搜索路径上；AppKit 转导出 `/System/Library/PrivateFrameworks/UIFoundation.framework`（NSFont、NSParagraphStyle、各种文本属性名都在里面），链接器把这个转导出解析到了我们的包上，App 链接时 AppKit 的文本符号全部未定义。把 `UIFoundation` 的产物类型改成 `.staticLibrary` 即解决；AppKit / Foundation / SwiftUI / QuartzCore 等转导出的框架里，只有它与我们的包同名。
     这一改有个连带：`PackageSettings.productTypes` 按 product 名命中时，会套到该 product 在包内依赖链上的**每一个** target（`PackageInfoMapper` 的 `targetToProducts`），于是 UIFoundation 的 13 个 target 全成了静态库。其中两个 ObjC target（`UIFoundationAppleInternalObjC`、`UIFoundationCarbonInternal`）作为静态库会把头文件发布到共享的 `include/` 目录，而二进制缓存打包时把整个目录装进了它们各自的 xcframework，两份 xcframework 各含同样的 21 个私有头文件，用缓存构建时报「Multiple commands produce …/include/CABackdropLayer.h」。按 target 名把这两个钉回 `.staticFramework`（target 名的匹配优先于 product 名）。
- **缓存配置生效**：`tuist generate` 打印的「使用缓存二进制」名单里没有任何一个本地包的 target。
- **测试 scheme 必须写在 `Workspace.swift`**：包的测试 target 在生成的包项目里，项目级 scheme 引用它会被 linter 拒绝（「not defined in the project … Consider using a workspace scheme」）。
- **预热的临时目录必须是空的**：`TUIST_CACHE_WARM_SCRATCH_DIRECTORY` 指向的目录里有上一次的残留时，`tuist cache` 直接报错退出，Tuist 不会自己清。
- **包测试能跑**：workspace 级 scheme 跑 `RuntimeViewerArchitecturesTests`（swift-testing），9 个测试全部通过，`xcodebuild test` 退出码 0。只挑了这一个套件，因为它不碰设置文件（项目记忆里有测试进程覆盖 Debug 设置的前车之鉴）。
- **Debug-arm64e 可行**：Tuist 写不出 `iOSPackagesShouldBuildARM64e`，但包已经是 Xcode target，在 `PackageSettings` 的 Debug-arm64e 配置里设 `ENABLE_POINTER_AUTHENTICATION = YES` 即可。按 `RunScript.sh` 的方式（`generic/platform=macOS`、`EXCLUDED_ARCHS=x86_64`）不用缓存构建成功：macOS 注入载荷 `RuntimeViewerServer.framework` 是 `arm64 arm64e`、链接上了 arm64e 的包，App 本身是 `arm64`（与原生一致）；宏插件照常执行。Debug-arm64e 的缓存要单独预热，未实测。

#### 3.3 测量

同一台机器（`JHs-Mac-Studio`，10 核，8 个并发），Debug，`platform=macOS,arch=arm64`，构建目录每次清空；时间已扣除排队等待，编译任务数取日志里 `SwiftCompile` / `CompileC` / `SwiftDriverJobDiscovery` 的行数。

| 场景 | 时间 | 编译任务 |
|---|---|---|
| `tuist install`（首次，85 个依赖） | 2 分 47 秒 | — |
| `tuist generate`（首次） | 18 秒 | — |
| 不用缓存，从空目录构建 | 175 秒 | 7677 |
| 首次预热缓存（244 个 target） | 约 6 分 20 秒，1.3 GB | — |
| 改动两个 target 后再预热 | 55 秒（236 命中、9 未命中），1.4 GB | — |
| **第三方走缓存、本地包从源码，从空目录构建** | **43 秒** | **721** |
| 什么都不改再构建一次 | 15 秒 | — |
| Debug-arm64e，不用缓存，从空目录构建 | 293 秒 | — |

剩下的 721 个编译任务对应自有代码的 712 个（四个本地包与 App），而 Core → Packages → App 是一条串行的依赖链，所以是 4× 而不是更多。8 月实验报告的 14×（110 秒 → 7.7 秒）出自另一个实验工程（47 个包，本地包没有接进 Tuist 的缓存），两组数字不能直接比。

## 提议方案

1. **角色**：Tuist 生成的 `RuntimeViewer-Tuist.xcworkspace` 只用于日常开发（Xcode 里编辑、构建、运行、跑测试）。发版、CI、XCFramework、越狱版打包与现有的所有脚本只走原生工程。
2. **范围**：完整的 macOS App——主 App 与它嵌入的全部产物（Catalyst helper 及插件、macOS 与 iOS Simulator 两个注入载荷、特权 daemon、XPC service、命令行工具、SourceEditor bridge），从 Tuist workspace 运行出的 App 与原生 Debug 构建功能一致；四个本地包与 SourceEditor bridge 的测试可在 Tuist workspace 里跑。配置为 Debug、Debug-arm64e、Release。
3. **依赖**：四个本地包与预编译 swift-syntax 写进 `Tuist/Package.swift`，各自的 `Package.swift` 仍是唯一定义；第三方依赖走 Tuist 的二进制缓存，四个本地包始终是源码。`Tuist/Package.resolved` 提交进仓库，版本与 Debug / Distribution workspace 的锁文件一致，由 `UpdatePackagesScript.sh` 顺带更新。
4. **设置共用**：原生工程做一次行为不变的整理，把写死在 target 层的设置搬进 `Configurations/` 下的 xcconfig，两边引用同一份；每一处改动都用 `xcodebuild -showBuildSettings` 前后对比，证明构建设置零差异。
5. **同步**：改原生工程的 target、依赖、嵌入方式或设置的提交，必须同批更新 Tuist 描述（写进 `AGENTS.md`）；新增 `TuistScript.sh check` 做一致性检查，提交前手动运行。
6. **缓存**：只用本地缓存，不注册 Tuist 账号、不上报数据。`/Volumes/DerivedData` 挂载时，Tuist 的缓存、预热临时目录与依赖 checkout 都放在它下面。

### 非目标

- 不替换、不削减原生工程；`RunScript.sh`、`ArchiveScript.sh`、`BuildRuntimeViewerServerXCFramework.sh`、`BuildJailbrokenIPAScript.sh`、`BuildSimulatorScript.sh` 与 `.github/workflows/release.yml` 不改。唯一被改的脚本是 `UpdatePackagesScript.sh`（顺带更新 Tuist 锁文件）。
- 不覆盖 iOS / visionOS / 越狱版 App、Distribution 配置与 XCFramework、已不再嵌入的旧特权 helper `com.JH.RuntimeViewerService`。
- 不用 Tuist 归档发版（Tuist 文档本身也建议归档时 `--cache-profile none`）。
- 不用远程缓存，不注册 Tuist 账号。
- 不支持本地兄弟仓库模式（`USING_LOCAL_DEPENDENCIES`）：该模式自 2026-10-06 起在原生工程里也解析不过。
- 不追求 Tuist 构建的产物与原生构建逐字节一致；已知差异列在「详细设计 §11」。

## 详细设计

> 下面的清单片段取自探针并已实际构建通过；落地时按本节整理，不直接复制探针代码。

### 1. 文件布局

```
mise.toml                                  # [tools] tuist = "4.210.0"
Tuist.swift                                # 根标记；缓存配置 development（本地包保持源码）
Workspace.swift                            # → RuntimeViewer-Tuist.xcworkspace；跑包测试的 scheme
Tuist/Package.swift                        # 依赖层：四个本地包 + 预编译 swift-syntax + Sparkle
Tuist/Package.resolved                     # 提交；版本跟随原生锁文件
Tuist/ProjectDescriptionHelpers/           # 各 target 共用的设置拼装
RuntimeViewerUsingAppKit/Project.swift     # → RuntimeViewerUsingAppKit/RuntimeViewer-Tuist.xcodeproj
TuistScript.sh                             # install / generate / warm / build / check
```

`Project.swift` 放在 `RuntimeViewerUsingAppKit/`、与原生 `RuntimeViewerUsingAppKit.xcodeproj` 同目录，是为了让两边的 `$(SRCROOT)` 指向同一处——AppKit 工程有 9 处设置用 `$(SRCROOT)` 开头的路径（如 bridge 的 `FRAMEWORK_SEARCH_PATHS = $(SRCROOT)/../Stubs`），搬进共用 xcconfig 后必须两边解析一致。生成的工程叫 `RuntimeViewer-Tuist.xcodeproj`，与原生工程不同名，永远不会覆盖它；workspace 与另外三个并排，命名一致。

`.gitignore` 按路径精确列出生成物，不用通配 `*.xcodeproj`：

```
/RuntimeViewer-Tuist.xcworkspace
/RuntimeViewerUsingAppKit/RuntimeViewer-Tuist.xcodeproj
/RuntimeViewerUsingAppKit/Derived/
/RuntimeViewerCore/RuntimeViewerCore.xcodeproj
/RuntimeViewerCore/Derived/
/RuntimeViewerPackages/RuntimeViewerPackages.xcodeproj
/RuntimeViewerPackages/Derived/
/RuntimeViewerMCP/RuntimeViewerMCP.xcodeproj
/RuntimeViewerMCP/Derived/
/RuntimeViewerCommandLine/RuntimeViewerCommandLine.xcodeproj
/RuntimeViewerCommandLine/Derived/
/RuntimeViewerPrecompiledLibraries/swift-syntax/swift-syntax.xcodeproj
/RuntimeViewerPrecompiledLibraries/swift-syntax/Derived/
/Tuist/.build/
```

### 2. 依赖层：`Tuist/Package.swift`

```swift
// swift-tools-version: 6.2
import PackageDescription

#if TUIST
    import ProjectDescription

    let packageSettings = PackageSettings(
        // AppKit re-exports Apple's private UIFoundation.framework; a static framework
        // of the same name on the search path captures that re-export at link time.
        // A product's type reaches its whole in-package closure, so the two Objective-C
        // targets are pinned back by target name: as static libraries their headers go to
        // the shared include/ directory, which the binary cache packs into both.
        productTypes: [
            "UIFoundation": .staticLibrary,
            "UIFoundationAppleInternalObjC": .staticFramework,
            "UIFoundationCarbonInternal": .staticFramework,
        ],
        baseSettings: .settings(
            base: [
                // Xcode's own SwiftPM integration copies package .strings unvalidated.
                "VALIDATE_STRINGS_FILES_WHILE_COPYING": "NO",
            ],
            configurations: [
                .debug(name: "Debug"),
                // Replaces the native workspaces' iOSPackagesShouldBuildARM64e, which Tuist
                // cannot write: the package targets are Xcode targets here.
                .debug(name: "Debug-arm64e", settings: ["ENABLE_POINTER_AUTHENTICATION": "YES"]),
                .release(name: "Release"),
            ]
        ),
        // Tuist drops settings whose condition is traits-only; restate the ones that matter.
        targetSettings: [
            "Capstone": .settings(base: [
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["$(inherited)", "CAPSTONE_HAS_AARCH64"],
                "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "CAPSTONE_HAS_AARCH64=1"],
            ]),
            "Ccapstone": .settings(base: [
                "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "CAPSTONE_HAS_AARCH64=1"],
            ]),
        ],
        includeLocalPackageTestTargets: true
    )
#endif

let package = Package(
    name: "RuntimeViewerTuistDependencies",
    dependencies: [
        .package(path: "../RuntimeViewerCore"),
        .package(path: "../RuntimeViewerPackages"),
        .package(path: "../RuntimeViewerMCP"),
        .package(path: "../RuntimeViewerCommandLine"),
        .package(path: "../RuntimeViewerPrecompiledLibraries/swift-syntax"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
    ]
)
```

落地时另加一项（探针未做）：本地包的 target 取消 Tuist 对 external 项目默认的 `SWIFT_SUPPRESS_WARNINGS = YES` / `GCC_WARN_INHIBIT_ALL_WARNINGS = YES`，让自有代码的警告照常可见。

> 实现时调整：另加了 `productDestinations`，把 Packages / MCP / CommandLine 三个包的 product 声明成 macOS（本地包测试 target 的平台问题）；本地 target 名单放进 `Tuist/ProjectDescriptionHelpers/LocalPackages.swift`。Release 配置也设 `ENABLE_POINTER_AUTHENTICATION = YES`（daemon 与 macOS 注入载荷在 Release 下同样是 arm64e）；Core 的测试 target 补 `MACOSX_DEPLOYMENT_TARGET = 14.0`。见决策日志。

### 3. 缓存配置：`Tuist.swift`

```swift
// Cache-profile exceptions match target names exactly; TuistScript.sh check keeps this list
// in step with the four Package.swift files.
let localPackageTargetNames = ["RuntimeViewerObjC", "RuntimeViewerCore", /* … 共 22 个 … */]

let tuist = Tuist(
    project: .tuist(
        cacheOptions: .options(
            profiles: .profiles(
                ["development": .profile(.onlyExternal, except: localPackageTargetNames.map { .named($0) })],
                default: "development"
            )
        )
    )
)
```

不写 `fullHandle`：只用本地缓存，不上报统计。

### 4. App 层：`RuntimeViewerUsingAppKit/Project.swift`

一个 Tuist 项目装下主 App 与它嵌入的全部 target——`.buildProduct` 只能引用同一项目里的 target，跨项目依赖又只靠 Xcode 的隐式依赖识别。target 名与原生工程保持一致，方便 `check` 逐个对照。

| 原生 target | Tuist 声明 | 嵌入方式 |
|---|---|---|
| `RuntimeViewerUsingAppKit` | `.app`，`buildableFolders` 对应原生同步文件夹（排除 `Info.plist`），Info.plist / entitlements / xcconfig 沿用原文件 | — |
| `RuntimeViewerCatalystHelper` | `.app`，destinations `.macOS`（graph linter 的要求），target settings 写死 `SDKROOT = macosx`、`SDK_VARIANT = iosmac`、`SUPPORTED_PLATFORMS = macosx` 等（必须在 target 层，放 xcconfig 会被 Tuist 推导值压住） | App 依赖它（Tuist 不自动拷 `.app`），`.wrapper(subpath: "Contents/Applications")` 拷 `.buildProduct` |
| `RuntimeViewerCatalystHelperPlugin` | **`.framework`** + `WRAPPER_EXTENSION = bundle`（`.bundle` 链接不了静态包）；实现时加了 Debug 两套配置的 `ONLY_ACTIVE_ARCH = YES`（见决策日志） | 不建依赖；scheme 手动顺序先构建；helper 用 `.plugins` 拷 `.buildProduct` |
| `RuntimeViewerSimulatorServer` | `.framework`，destinations `.iPhone`，`SDKROOT = iphonesimulator`、`PRODUCT_NAME = RuntimeViewerMobileServer` | 不建依赖；scheme 手动顺序先构建；App 用 `.resources` 拷 `.buildProduct` |
| `RuntimeViewerServer` | `.framework`（macOS） | 不建依赖；App 用 `.resources` 拷 `.buildProduct`，Xcode 自动识别为隐式依赖 |
| `com.mxiris.runtimeviewer.service` | `.commandLineTool`，`productName: "$(RUNTIME_VIEWER_SERVICE_NAME)"` | App 依赖它排顺序；**构建后脚本**按当前配置拷进 `Contents/Library/LaunchServices/` 并重签名（`--preserve-metadata=identifier,entitlements,flags`） |
| `Generate LaunchDaemon plist` 阶段 | App 的 `.post` 脚本，`basedOnDependencyAnalysis: false`，App 的 `ENABLE_USER_SCRIPT_SANDBOXING = NO` | — |
| `RuntimeViewerLocalRuntimeService` | `.xpc` | Tuist 自动生成 Embed XPC Services |
| `RuntimeViewerCommandLineTool` | `.commandLineTool`，`productName: "runtime-viewer-cli"` | App 依赖它；`.wrapper(subpath: "Contents/Applications")` 拷 `.buildProduct` |
| `RuntimeViewerSourceEditorBridge` | `.bundle`（不依赖包，可以是 bundle） | Tuist 自动生成 Embed PlugIns；`SourceEditorBridging.swift` 用 `.exception(target: "RuntimeViewerUsingAppKit", included:)` 同时归属 App，对应原生的跨 target 成员例外 |
| `RuntimeViewerSourceEditorBridgeTests` | `.unitTests`；实现时发现 Tuist 不允许它依赖 bundle，改由测试 scheme 构建 bridge | — |

### 5. scheme

`automaticSchemesOptions: .disabled`，只定义一个 `RuntimeViewer macOS`：

- 构建：`[RuntimeViewerSimulatorServer, RuntimeViewerCatalystHelperPlugin, RuntimeViewerUsingAppKit]`，`buildOrder: .manual`；这三个 target 设 `DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING = YES`。
- 运行：`RuntimeViewerUsingAppKit`。

测试另起一个 workspace 级 scheme（写在 `Workspace.swift`），列出四个本地包的测试 target 与 `RuntimeViewerSourceEditorBridgeTests`——包的测试 target 在生成的包项目里，项目级 scheme 引用不到。会读写设置的测试套件照项目现有规则注入 in-memory 的 `SettingsAccess`，与 `swift test` 时一样。

**这条约束要写进使用指南**：Tuist 这边只能用这个 scheme 构建 App。单独构建 App target 不会先编两个跨平台产物，拷贝阶段会报文件不存在——这是「不让 Tuist 把它们嵌进 `Frameworks/`」的代价。

其余要写进使用指南的约束：

- **本地包里增删源文件后要重新 `generate`**：Tuist 转换包时按 glob 展开源文件，不用同步文件夹；只改已有文件的内容不受影响。
- **改了某个 `Package.swift`**（依赖、target、设置）要先 `install` 再 `generate`。
- **Debug-arm64e 照 `RunScript.sh` 的方式构建**（`generic/platform=macOS`、`EXCLUDED_ARCHS=x86_64`，已实测），由 `TuistScript.sh build` 封装；在 Xcode 界面里直接选 Debug-arm64e 运行的行为没有验证。
- 生成之后，四个包目录里各多一个 `<包名>.xcodeproj`；直接打开包目录时 Xcode 可能打开它而不是 `Package.swift`（双击 `Package.swift` 不受影响）。

### 6. 设置共用：原生工程的 xcconfig 整理

- 为每个被 Tuist 镜像的 target 建 `Configurations/<Target>/` 下的 xcconfig（沿用现有 `Configurations/RuntimeViewerUsingAppKit/` 的分法：`Shared.xcconfig` 加每个配置一份），把 target 层的设置整体搬过去，pbxproj 里只留 `baseConfigurationReference`。
- daemon 的 `PRODUCT_NAME` 从三个字面量改成 `$(RUNTIME_VIEWER_SERVICE_NAME)`、取值来自共用 xcconfig——数值不变，但服务名从此只写一处（现在写在三处）。
- Tuist 那边用同一批 xcconfig 作为各配置的基础；Tuist 会在 target 层写出推导值的那几个键（`PRODUCT_BUNDLE_IDENTIFIER`、`SDKROOT`、`PRODUCT_NAME`、`INFOPLIST_FILE`、`CODE_SIGN_ENTITLEMENTS`、部署版本），在 manifest 里显式给出，其中能引用 xcconfig 变量的就引用（如 `bundleId: "$(RUNTIME_VIEWER_APP_BUNDLE_IDENTIFIER)"`）。
- **验证**：整理前后对每个 target × 每个配置跑 `xcodebuild -showBuildSettings`，差异必须为空；这一步单独成批提交，与 Tuist 无关，也可以先行合入。

### 7. 锁文件

- `Tuist/Package.resolved` 提交进仓库。`UpdatePackagesScript.sh` 更新完三个 workspace 之后，把 Debug workspace 的锁文件作为初值写入 `Tuist/Package.resolved`，再跑 `tuist install`，结果与原生锁文件逐条对比、差异列进脚本输出。
- 已知会出现的差异是包身份改名（`swift-issue-reporting` / `xctest-dynamic-overlay`），在 `check` 里登记为允许项；其余任何差异都算不一致。
- 实现时调整：这条差异证实是 Xcode 版本所致，用解析原生锁文件的同一个 Xcode 解析即完全一致，`check` 因此不设允许项。见决策日志。

### 8. `TuistScript.sh`

沿用仓库脚本的命名与参数风格（`--dry-run` 等）。子命令：

- `install`：`tuist install`。
- `generate`：`tuist generate --no-open`（默认缓存配置即 `development`）。
- `warm [--configuration …]`：`tuist cache`，默认 Debug。每次先清空预热临时目录（Tuist 要求它为空，自己不清）。
- `build [--configuration …] [--launch]`：照 `RunScript.sh` 的参数构建（Debug-arm64e 用 `generic/platform=macOS` 与 `EXCLUDED_ARCHS=x86_64`，构建元数据 `RUNTIME_VIEWER_BUILD_DATE` 等同样从命令行传入），可选构建后启动。
- `check`：一致性检查，见下节。

环境：`/Volumes/DerivedData` 挂载时设 `TUIST_XDG_CACHE_HOME`、`TUIST_CACHE_WARM_SCRATCH_DIRECTORY`、`SWIFTPM_BUILD_DIR` 到 `/Volumes/DerivedData/RuntimeViewer/Tuist/` 下（`SWIFTPM_BUILD_DIR` 按 worktree 区分），沿用 `RunScript.sh` 的「卷在就用卷」做法；不在就用 Tuist 默认位置。agent 运行时改用各自的 `Agents.noindex` 目录，并经 `queued-build`。

### 9. 同步规则与 `check`

`AGENTS.md` 新增一节：改原生工程的 target、依赖、嵌入方式或设置的提交，同批更新 Tuist 描述，提交前跑 `./TuistScript.sh check`。`check` 做五件事：

1. **构建设置**：每个被镜像的 target × 三个配置，对比原生与 Tuist 的 `-showBuildSettings`，过滤掉合理差异（路径类、Tuist 自带的项目级默认值等，清单落地时确定）。实现时改为读工程文件的静态核对，原因见决策日志。
2. **本地 target 名单**：四个 `Package.swift` 的非测试 target 与 `Tuist.swift` 的 `localPackageTargetNames` 一致。
3. **锁文件**：`Tuist/Package.resolved` 与 Debug workspace 的锁文件一致（允许项除外）。
4. **丢失的 trait 宏**：扫描所有依赖清单里「只带 trait 条件、且 trait 处于开启状态」的设置，确认都在 `targetSettings` 里补上了——防的是上游 Tuist 的那个丢设置问题再咬一次。
5. **`--build`（可选）**：两边各构建一次 Debug，对比 App 包内的文件清单（已知差异除外）。

### 10. 构建产物与缓存位置

见 §8。补充：`Tuist/.build` 不挪走时每个 worktree 约 3.4 GB，都在仓库目录里；挪到 DerivedData 卷之后仓库目录只剩生成的工程文件。

### 11. 已知差异（Tuist 构建 vs 原生构建）

- helper 插件是 framework 版式（`Versions/A`）而不是平铺的 bundle；加载方式不变。
- Tuist 生成的工程是 objectVersion 55（原生 AppKit 工程是 90）。
- 构建依赖的顺序靠 scheme 手动顺序（模拟器载荷、helper 插件），而不是 target 依赖。
- daemon 的嵌入是脚本而不是 Copy Files 阶段。
- 外部 target 不校验 `.strings`（与原生 SwiftPM 集成一致）。
- 包 target 是独立的 Xcode target（默认静态 framework，UIFoundation 的 Swift target 是静态库），原生构建里它们是 SwiftPM 产出的目标文件；链接进 App 的代码相同，构建目录的布局不同。

## 替代方案考量

- **整体迁到 Tuist，退役原生工程**：用户选择长期双轨。发版链路的大量细节只在原生工程里验证过，迁移的风险集中在发版上，而动机只在开发构建。
- **只把包层 Tuist 化、App 留在原生工程**（8 月记下的岔路之一）：两套系统要靠手工跨项目链接拼起来，而 App 的链接仍走 Xcode 自带的 SwiftPM，第三方依赖依旧不进缓存，换不来收益。
- **把本地包改写成 Tuist `Project.swift`**（8 月实验的结论）：已证实不必要，见前期调研 §2。改写意味着每个包的结构写两份。
- **XcodeGen**：仓库里的嵌入实验就是用它写的，但它不提供二进制缓存，与动机不符。
- **共享 Xcode 自己的编译缓存**（`COMPILATION_CACHE_ENABLE_CACHING` / `COMPILATION_CACHE_CAS_PATH`）：原生 AppKit 工程已开启编译缓存，但本提案没有测量它能否跨 worktree 命中、是否覆盖包 target。未评估，不作为否决理由；值得单独做一次对比实验。
- **Tuist 云端缓存**：用户否决。需要账号与 token，构建产物上传到 Tuist 的服务器。
- **嵌入层的几种被否写法**（插件用 `.bundle`、载荷用 `status: .none` 依赖、daemon 用 `.buildProduct`）：见前期调研 §3.1 的表。

## 影响

### 用户可见变化

无。改动只涉及开发者的构建方式，发布出去的 App 仍由原生工程构建。

### 可发现性

开发者从 `AGENTS.md` 的新一节与使用指南 `Guides/TuistDevelopment.md` 得知 Tuist 通道；入口是 `./TuistScript.sh generate`，生成后打开 `RuntimeViewer-Tuist.xcworkspace`。不替代任何现有入口。

### 数据与配置兼容

Tuist 构建的 Debug App 与原生 Debug 构建使用同一个 bundle id、同一个设置文件（`~/Library/Application Support/RuntimeViewer-Debug/settings.json`）与同一个 helper daemon 名，两者会互相覆盖 daemon 的注册——与今天多个 DerivedData 里各有一份 Debug App 的情况相同。

### 平台与最低版本

不变。

### 发布

不影响。归档、导出、公证、Sparkle 更新流程都只走原生工程；`ArchiveScript.sh` 不改。原生工程的 xcconfig 整理以「构建设置零差异」为验收标准，不改变任何产物。

## 落地步骤

每一步都能单独构建、单独验证。

1. **原生工程的 xcconfig 整理**：逐个 target 搬设置，每个 target 整理完即跑 `-showBuildSettings` 对比，差异为空才提交。与 Tuist 无关，可以先行合入。
2. **工具与忽略规则**：`mise.toml`、`.gitignore`。
3. **依赖层**：`Tuist.swift`、`Workspace.swift`、`Tuist/Package.swift`、`Tuist/Package.resolved`；验收：`tuist install` + `tuist generate` 通过，锁文件与原生一致（允许项除外）。
4. **App 层**：`RuntimeViewerUsingAppKit/Project.swift` 与 scheme；验收：三套配置都构建通过，App 包内文件清单与原生 Debug 构建一致（已知差异除外），产物平台与签名校验同探针。
5. **测试**：本地包与 bridge 的测试在 Tuist workspace 里跑通（按退出码判定，不认 xcsift 摘要）。
6. **`TuistScript.sh`**：`install` / `generate` / `warm` / `build` / `check`。
7. **`UpdatePackagesScript.sh`**：顺带更新并对比 `Tuist/Package.resolved`。
8. **文档**：`AGENTS.md` 新一节、`Guides/TuistDevelopment.md`、`Documentations/README.md` 与本索引；判断是否需要术语表条目（候选：「Tuist 开发通道」）。
9. ~~**上游反馈**~~（用户决定不提，见决策日志）：Tuist 丢 trait 条件设置、`status: .none` 依赖在开缓存后丢失、`.bundle` 不能链接静态产物、静态库 C target 的缓存 xcframework 装进了共享 `include/` 里别人的头文件；KeyboardShortcuts 的 `ar.lproj` 引号问题。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-10 | Created as Draft | 用户原话：「开一个新的worktree，把tuist集成过来，并不是把原生工程干掉，两个共存」。worktree `.worktrees/RuntimeViewer-TuistIntegration`，分支 `feature/tuist-integration`，从 `next` @ 2ac90984 切出。 |
| 2026-10-10 | 定位：长期双轨 | Tuist 只做日常开发的加速通道，发版 / CI / 脚本只走原生工程。否决「过渡到 Tuist」与「仅本地实验」。 |
| 2026-10-10 | 范围：功能完整的 macOS App | 含全部嵌入产物。否决「精简版（不含 Catalyst helper 与模拟器载荷）」「加入 iOS 系列」「只做包层」。 |
| 2026-10-10 | 允许原生工程做行为不变的整理 | 设置搬进 xcconfig 两边共用，`-showBuildSettings` 零差异验收。否决「原生工程一字不动」（`MARKETING_VERSION` 这类每次发版都改的值会两边漂移）。 |
| 2026-10-10 | 同批同步 + 手动检查 | 写进 `AGENTS.md`，`TuistScript.sh check` 提交前手动跑。否决 CI 自动检查与「尽力而为」。 |
| 2026-10-10 | 只用本地缓存 | 否决 Tuist 云端缓存。 |
| 2026-10-10 | 锁文件与原生一致 | 否决「Tuist 独立维护」与「不锁版本」。 |
| 2026-10-10 | Tuist workspace 能跑测试 | 四个本地包与 SourceEditor bridge 的测试。 |
| 2026-10-10 | 未提问、按默认处理的项 | 配置 Debug / Debug-arm64e / Release；生成物与 workspace 命名；默认缓存配置让本地包保持源码；缓存放 DerivedData 卷；`mise.toml` 钉 4.210.0；不改 RunScript / ArchiveScript / CI。用户确认了包含这些默认的共识。 |
| 2026-10-10 | `Project.swift` 改放 `RuntimeViewerUsingAppKit/` | 原默认放仓库根目录；为让共用 xcconfig 里的 `$(SRCROOT)` 两边一致而移到原生 AppKit 工程同目录。 |
| 2026-10-10 | 探针结论（嵌入） | 插件改 `.framework` + `.bundle` 扩展名；模拟器载荷与插件改由 scheme 手动顺序构建；daemon 改脚本拷贝。被否写法见前期调研 §3.1。探针代码在 `/Volumes/DerivedData/Agents.noindex/claude/Scratch/TuistProbe/EmbedProbe/`。 |
| 2026-10-10 | 探针结论（包层） | 三处修正：外部 target 不校验 `.strings`、补 `CAPSTONE_HAS_AARCH64`、UIFoundation 改静态库（两个 ObjC target 钉回静态 framework）。包测试与 Debug-arm64e 均验证可行。探针代码在 `…/TuistProbe/PackageProbe/`。 |
| 2026-10-10 | 测量 | 从空目录构建 Debug：不用缓存 175 秒 / 7677 个编译任务，第三方走缓存 43 秒 / 721 个；预热约 6 分钟、1.4 GB。 |
| 2026-10-10 | Accepted | 用户批准提案（原话「批准，先实现，不上报问题」）。 |
| 2026-10-10 | 取消落地步骤 9（上游反馈） | 用户决定不向 Tuist 与 KeyboardShortcuts 报告探针发现的问题；绕法照常落地。 |
| 2026-10-10 | In Progress | 开始实现落地步骤 1–8。 |
| 2026-10-10 | 落地步骤 1：xcconfig 整理完成 | 两个原生工程里对应的 10 个 target 与 AppKit 工程级，target 层设置全部搬进 `Configurations/`。`-showBuildSettings` 前后对比两个工程全部 14 个 target（含不归 Tuist 管的旧 helper 与 `RuntimeViewerMobileServer`）× 全部配置：唯一差异是 daemon 多了 `RUNTIME_VIEWER_SERVICE_NAME`（它的 `PRODUCT_NAME` 改为引用这个变量，值不变）。 |
| 2026-10-10 | 整理时顺带收拢、解析值不变的几处 | ① `DEVELOPMENT_TEAM` 一律写 `$(RUNTIME_VIEWER_DEVELOPMENT_TEAM)`（145632b3 的本意；此前 Debug-arm64e 配置、CLI、XPC service 与工程级仍是字面量或缺省，`custom.xcconfig` 覆盖不到）；② `MARKETING_VERSION` 收进 `Configurations/Version.xcconfig` 一处（原先散在 6 个 target 的每个配置里）；③ daemon 名收进 `Configurations/ServiceName/`，App、Catalyst helper、daemon 三方 include（原先写在三处）。另把 `RuntimeViewerServer.xcodeproj` 工程级的 `VERSIONING_SYSTEM` / `VERSION_INFO_PREFIX` 在两个载荷 target 的 xcconfig 里重写一遍：Tuist 工程里它们处在 AppKit 的工程级之下。 |
| 2026-10-10 | `Generate LaunchDaemon plist` 抽成共用脚本 | `RuntimeViewerUsingAppKit/BuildPhases/GenerateLaunchDaemonPlist.sh`，原生与 Tuist 的构建阶段都调用它，免得两份内联脚本各自漂移。超出 §6 的原计划。 |
| 2026-10-10 | `ArchiveScript.sh` 改了两行文字 | 注释与报错提示里「去 project.pbxproj 改 MARKETING_VERSION」改为指向 `Configurations/Version.xcconfig`，逻辑未动。偏离了「非目标：不改 ArchiveScript」的字面，不改的话报错会把人指错地方。 |
| 2026-10-10 | 锁文件改为「同一个 Xcode 解析即全等」，取消允许项 | 探针里那 1 条差异（`swift-issue-reporting` 2.1.1 / `xctest-dynamic-overlay` 1.13.1）证实是工具链所致：swift-dependencies 等包按 Swift 版本选清单，Swift 6.3（Xcode 26.6）用的 `Package@swift-6.3.swift` 引用旧名 1.x，Swift 6.4（Xcode 27）用的 `Package.swift` 引用新名 2.x，原生锁文件是 Xcode 27 解析的。用 Xcode 27 跑 `tuist install`，85 条与原生锁文件完全一致。`check` 因此逐条比、不设允许项；`UpdatePackagesScript.sh` 以 Debug workspace 的锁文件为初值，用它自己的 Xcode 跑 `tuist install`。 |
| 2026-10-10 | 实现中新发现的三处 Tuist 限制与绕法 | ① 清单里含 `$(inherited)` 的值会被 Tuist 与它推导的值合并成列表（`SDKROOT` 变成 `$(inherited) macosx`），不含才替换：交还给 xcconfig 的键改写成同义的 `${inherited}`，并且不传 `deploymentTargets`。② Tuist 给本地包测试 target 的平台取其依赖平台的**并集**（`LocalPackageTestDestinationResolver`）：模拟器载荷让 Core 的 product 带上 iOS，同时依赖 macOS-only target 的测试就被 lint 拒绝；用 `productDestinations` 把 Packages / MCP / CommandLine 三个包的 product 声明成 macOS。③ 单元测试 target 不能依赖 `.bundle`：bridge 测试去掉对 bridge 的依赖，改由测试 scheme 构建 bridge。 |
| 2026-10-10 | `check` 第 1 项改为静态核对 | 原计划对比两边的 `-showBuildSettings`，走不通：原生 `RuntimeViewerServer.xcodeproj` 单独打开时会用它内嵌的过期 `Package.resolved` 解析本地包而失败（`-disableAutomaticPackageResolution` 也一样，属原生工程既有的问题），workspace + scheme 又只列出 scheme 显式写的 target。改为读工程文件核对「接线」：原生对应 target 在工程文件里零设置、两边每个配置引用同一份 xcconfig、生成工程的 target 层只出现已知的几类键、两个工程级有差别的键都由载荷 target 的 xcconfig 给出。端到端的对比由 `check --build`（两边各编一次、比对产物）承担。 |
| 2026-10-10 | `check` 第 4 项按 SwiftPM 的规则推算开启的 trait | 从 `Tuist/Package.swift` 往下传播（包的默认 trait、trait 连带开启的 trait、依赖声明里按条件开启的 trait），凡是开启的 trait 才定义的宏，都必须出现在 `tuist dump package` 的 `targetSettings` 里。当前只带 trait 条件的设置：capstone / swift-capstone 每个架构一条、SFSymbols 一条；开启的只有 AARCH64。 |
| 2026-10-10 | 存放位置 | `/Volumes/DerivedData/RuntimeViewer/Tuist/` 下：`Cache/` 各 checkout 共用；`Dependencies/`、`WarmScratch/`、`Work/` 按 checkout 分（目录名加路径短 hash，同名的两个 worktree 不会混用）；`TUIST_SCRIPT_ROOT` 可改到别处。 |
| 2026-10-10 | 插件在 Debug 两套配置只编当前架构（Tuist 专有设置） | 首次完整构建失败：原生插件沿用 `ONLY_ACTIVE_ARCH = NO`，在 Debug 也要编 x86_64；它的包依赖在 Tuist 里是普通 target，App 只要 arm64，同一批 target 于是被要求两套架构、产物写进同一个目录，x86_64 的编译读到只含 arm64 的 `-Swift.h`（swift-collections 的 `InternalCollectionsUtilities`）。原生 workspace 里 SwiftPM 包按依赖方特化，没有这个问题。Tuist 这边给插件的 Debug 与 Debug-arm64e 加 `ONLY_ACTIVE_ARCH = YES`；Release 下 App 与包都是全架构，不冲突。 |
| 2026-10-10 | 预热必须显式指定缓存配置 | `tuist cache warm` 不传 `--cache-profile` 时不读 `Tuist.swift` 的默认配置，而是 `allPossible`，连本地包与 App 层 target 一起缓存；模拟器载荷（SDK 写死 iphonesimulator）在缓存的「真机」那一轮里找不到为真机编的依赖而失败。`TuistScript.sh warm` 一律传 `--cache-profile development`。 |
| 2026-10-10 | 实测（Xcode 27，完整 App 含全部嵌入产物） | `JHs-Mac-Studio`，按 `RunScript.sh` 的参数（`generic/platform=macOS`、排除 x86_64），DerivedData 每次为空：不用缓存 504 秒、9735 个编译任务；预热 Debug 缓存约 7 分 50 秒、新增 1.6 GB；走缓存 155 秒、1886 个编译任务（剩下的是自有代码，四个本地包为 macOS 与模拟器各编一份）；什么都不改再编一次 24 秒；`tuist install` 首次 169 秒、依赖 checkout 3.6 GB；`tuist generate` 约 14 秒。探针时的 175 秒 → 43 秒是 Xcode 26.6、且工程里没有模拟器载荷与 Catalyst 插件，以本行为准。 |
| 2026-10-10 | 两边产物对比 | 用 Xcode 27 按 `RunScript.sh` 的参数各编一次 Debug（Tuist 那边不用缓存与走缓存各一次）：App、Catalyst helper 与插件、两个注入载荷、daemon、XPC service、CLI、bridge 的平台、架构、签名 identifier、entitlements 与 Info.plist 全部一致，`codesign --verify --deep --strict` 通过。差异只在第三方包：RxSwift 被 Tuist 编成动态 framework（它同时声明了动态 product），第三方资源 bundle 的 Info.plist 由 Tuist 生成，第三方动态 framework 的切片不同；`check --build` 对这三类放宽。 |
| 2026-10-10 | 发现原生工程的一个既有问题（未修，不属本提案） | Xcode 27 下用 `RuntimeViewer-Debug.xcworkspace` 以 `platform=macOS,arch=arm64` 构建 Debug，模拟器载荷报 `Unable to resolve module dependency`：它要编 arm64 + x86_64，而包只为模拟器编了 arm64。在改动前的 HEAD（2ac90984）上同样复现，两次的编译任务完全相同，与本提案的改动无关；`RunScript.sh` 的 `EXCLUDED_ARCHS=x86_64` 恰好绕开了它。Xcode 界面里用 My Mac 构建 Debug 是否同样失败未验证。 |
| 2026-10-10 | 脚本的验证方式 | 按用户的规矩，`TuistScript.sh` 与改过的 `UpdatePackagesScript.sh` 没有整体运行。各子命令背后的命令都单独跑过（`tuist install` / `generate` / `cache warm --cache-profile development` / `xcodebuild`）；`check` 的核对逻辑以只读方式对真实工作区跑过并通过，另在副本上造了两个反例（工程文件里多一项 target 层设置、缺一个 trait 宏）都被报出；`check --build` 的比对逻辑对上述两次构建跑过并通过。 |
| 2026-10-10 | Core 的测试 target 部署版本在 Tuist 里抬到 macOS 14.0 | 第一次跑测试时 Core 的测试编不过（`Duration` 等「only available in macOS 13.0 or newer」）。SwiftPM 给测试 target 的部署版本不低于 XCTest 与 Swift Testing 自身的 `minos`（Xcode 27 下是 14.0，见 `PlatformVersionProvider` 与 `MinimumDeploymentTarget.computeXCTestMinimumDeploymentTarget`），原生 workspace 因此编得过；Tuist 照搬包声明的 10.15。`Tuist/Package.swift` 给 Core 的测试 target 补 `MACOSX_DEPLOYMENT_TARGET = 14.0`，`check` 核对每个声明低于 14 的本地包。 |
| 2026-10-10 | 生成按配置进行，workspace 常驻 Debug | 第一次编 Debug-arm64e 用的是按 Debug 生成的 workspace，失败在 `RuntimeViewerUtilities`：`cannot find 'SMGCopyAnswerAsString' in scope`。生成出的工程只链接一套配置的缓存，Debug 缓存的 macOS 库只有 arm64 与 x86_64。`TuistScript.sh` 的 `generate` 改为带 `--configuration`；`build` 与 `check` 先按要编的配置生成，退出时（成败都算）再按 Debug 生成回来，`warm` 收尾也生成 Debug，免得 Xcode 里开着的 workspace 被悄悄换成别的配置。 |
| 2026-10-10 | Release 配置的包也编 arm64e | 第一次编 Release 失败：`Unable to resolve module dependency: 'RuntimeViewerService' (in target 'com.mxiris.runtimeviewer.service' …)`。daemon 与 macOS 注入载荷 `RuntimeViewerServer` 在 Release 下都开着 `ENABLE_POINTER_AUTHENTICATION`（已安装的 3.0.0 正式版里两者都是 `x86_64 arm64 arm64e`），原生 workspace 按链接方各编一份包，所以它们链接的包带 arm64e；Tuist 里一个包只有一个 target，原先只在 Debug-arm64e 下补了 arm64e。`PackageSettings` 的 Release 配置照 Debug-arm64e 设 `ENABLE_POINTER_AUTHENTICATION = YES`，代价是这两套配置下所有包多编一个切片。设计里「替代 `iOSPackagesShouldBuildARM64e`」的说法未经核实，代码注释改为上述已核实的机制。 |
| 2026-10-10 | 测试结果（Xcode 27，scheme `RuntimeViewer Tests`，选了七个测试 target） | （这一轮其实漏了 `RuntimeViewerApplicationTests`：它在启动阶段崩溃，xcodebuild 只在末尾报 `encountered an error`，失败列表里没有它，见下文 `-ObjC` 一行与最终验证一行。）855 个测试，3 个失败，都是基线上本来就红的：Core 的 Relationships 快照多一个 `Foundation.AttributeScopes._DefaultScopeRegistration`，这台机器是 macOS 26.7，它的 arm64e shared cache 里根本没有这个名字，快照是在 macOS 27 上录的；bridge 的两条 `SourceEditorScroller` 断言滚动条自动隐藏，而 8f3414e0（10 月 7 日「stop autohiding the editor's scrollers」）把那一行注释掉了，测试没跟着改。测试前后用户的 `RuntimeViewer-Debug/settings.json` 哈希不变。 |
| 2026-10-10 | 链接包的 target 一律加 `-ObjC` | 跑测试时 `RuntimeViewerApplicationTests` 在启动阶段崩溃：xctest realize 所有类时轮到 RxAppKit 的 `RxNSOutlineViewDataSourceProxy`，补全其父类、RxCocoa 的泛型类 `DelegateProxy` 时找不到它的 ObjC 父类 `_RXDelegateProxy`（`getSuperclassMetadata` → `fatalError`）。泛型类按名字找父类，链接器看不到这个引用；Tuist 把包编成静态库，只拉被符号引用的成员，原生的 SwiftPM 集成则把每个包 target 整块链进去。查 App 本身也一样：Tuist 版只有 `_symbolic So16_RXDelegateProxyC` 这个按名引用，原生版有 `+[_RXDelegateProxy initialize]` 等实现；整体比下来 Tuist 版少 70 个 ObjC 类、1909 个 Swift 类型描述符、3678 条协议一致性记录，也就是说 Tuist 版 App 一用到 delegate proxy（侧栏的 outline 数据源）就会崩，而此前的产物比对只看文件、plist、架构与签名，没发现。修法：`Project.swift` 的每个 target 与本地包的每个测试 target 加 `OTHER_LDFLAGS = $(inherited) -ObjC`；Xcode 27 的链接器下 `-ObjC` 会拉进定义了 ObjC 类或分类、Swift 类型或 extension 的所有成员。没选 `-all_load`：部署到 macOS 10.15 的注入载荷会自动链接 Swift 兼容静态库，`-all_load` 会把它们整个拉进来，原生不这样。`check` 静态核对每个 target 带这个参数，`check --build` 加比两边每个可执行文件定义的 ObjC 类。只动 App 工程 target 与本地测试 target，第三方包的缓存哈希不变，已预热的缓存仍然有效。 |
| 2026-10-10 | 最终验证（Xcode 27，`JHs-Mac-Studio`，macOS 26.7） | 加 `-ObjC` 后，Debug、Debug-arm64e、Release 三套配置各用两个 workspace 按 `RunScript.sh` 的参数编一次，用 `check --build` 的比对逻辑逐项对照：包内文件、每个 Info.plist、每个自家可执行文件的平台、架构、签名 identifier、entitlements 与定义的 ObjC 类全部一致（RxSwift 的类在 Tuist 里算在它自己的动态 framework 里）；daemon 与 macOS 注入载荷在 Debug-arm64e 与 Release 下两边都是 `arm64 arm64e`；Tuist 产物 `codesign --verify --deep --strict` 通过。Tuist 一侧在已有 DerivedData 上只需重新链接，40–61 秒；原生 Debug-arm64e 与 Release 从空目录各 398 秒、490 秒。测试：七个 target 共 1312 个，`RuntimeViewerApplicationTests` 的 457 个这次跑起来了；4 个失败都是这台机器上基线本来就红的——Relationships 快照、两条 `SourceEditorScroller`（见上文），以及 `PopUpPathControlTests.squeezedComponentWidensUnderThePointer`（在 macOS 26.7 上稳定失败，`next` @ 2ac90984 的干净基线同样红）。测试前后用户的 Debug 设置文件哈希不变。 |
