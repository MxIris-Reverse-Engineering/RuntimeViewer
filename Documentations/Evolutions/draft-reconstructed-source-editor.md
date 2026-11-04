# Draft - 直接链接重建的 SourceEditor，取代从 Xcode 加载

- **状态**: In Progress
- **创建日期**: 2026-11-03
- **最后更新**: 2026-11-03
- **所属愿景**: [自建代码视图引擎](../Visions/CodeViewEngine.md)
- **实现分支 / PR**: `feature/reconstructed-source-editor`（worktree `.worktrees/RuntimeViewer-ReconstructedSourceEditor`，从 `next` 切出）

## 摘要

内容视图的 SourceEditor 编辑器（[0009](0009-content-editor-engine-selection.md)）原来是在运行时从用户安装的 Xcode 里 `dlopen` 四个私有框架，再加载一个用手写接口桩编出来的桥接 bundle：用户必须装 Xcode，框架也不能随 App 分发。SourceEditor 仓库（`Mx-Iris/SourceEditor`，私有）已经照 Xcode 26.6 把这几个框架重建出来，以 xcframework 的形式发在它的 GitHub Release 上（目前是 26.6.1）。本提案让官方构建直接链接重建版：桥接层改成 App 直接链接、直接调用的 framework，它再直接链接重建版，框架随 App 带上；运行时加载和接口桩全部删掉。拿不到重建版的外部构建在编译时跳过这部分，只用 `NSTextView`。

## 方案

**一、取得框架**
- 版本号和四个 xcframework 的 SHA-256 钉在 `RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease.txt`；下载下来的框架放在同目录下被忽略的 `Frameworks/`。
- `FetchSourceEditorScript.sh` 用 `gh release download` 取 `SourceEditor`、`SourceModel`、`SourceModelSupport`、`_CodeCompletionFoundation` 四个 xcframework，校验 SHA-256 后解出 macOS 那一份。已经在位、对得上钉住的版本，就什么都不做。
- `RunScript.sh` 构建前先跑它：取不到（没装 `gh`、没登录、没有仓库权限）就打一行提示，照常构建。`ArchiveScript.sh` 取不到就失败，导出后还检查 App 里确实带着四个框架：正式发版必须带上重建版。
- CI 发版（`release.yml`）在 `ArchiveScript.sh` 之前单独拉一步，用仓库机密 `SOURCE_EDITOR_RELEASES_TOKEN`：工作流自带的 token 读不到私有仓库。
- 不用 SwiftPM 依赖私有包：没有权限的人连依赖都解析不了，整个 RuntimeViewer 都编不了。

**二、链接与嵌入**
- 桥接 target `RuntimeViewerSourceEditorBridge` 从运行时加载的 bundle 改成 framework：App 链接它、把它嵌进 `Contents/Frameworks/`，经 `SourceEditorBridgeFactory` 直接创建编辑器、直接调用；它再直接链接重建版。
- 只有桥接 framework 和它的测试把 `Frameworks/` 放进 `FRAMEWORK_SEARCH_PATHS`。桥接用 `internal import` 引入 SourceEditor 的几个模块，对外的接口（`SourceEditorBridging` 那几个协议和工厂）不出现它们的类型，所以 App 看不到这几个模块。这是必须的：重建版的公开头文件和 UIFoundation 的私有头文件都声明了 AppKit 的私有协议 `NSScrollViewDelegate`，写法不同，同一个模块同时看到两者就编不过。
- 拿不到重建版的构建，桥接的实现文件用 `#if canImport(SourceEditor)` 整块跳过：framework 里只剩协议和工厂，`isAvailable` 为 `false`，App 只用 `NSTextView`，什么也不链接。Intel 那一份同理：重建版没有 x86_64 的模块接口，x86_64 上编译时就没有这部分。
- App target 的脚本阶段 Embed SourceEditor Frameworks（`RuntimeViewerUsingAppKit/BuildPhases/EmbedSourceEditorFrameworks.sh`）把四个框架拷进 `Contents/Frameworks/`，用 App 的签名身份签名。没下载时只打一条 note；下载的框架和钉住的版本对不上时构建报错：编译时链接了旧版、嵌入时却跳过，App 会在启动时找不到框架。
- 这个阶段每次构建都跑：没下载时输入文件根本不存在，交给依赖分析会让构建报错；拷贝加签名约一秒。导出 Developer ID 版本时，`xcodebuild -exportArchive` 会连同这四个框架一起重签、加时间戳。
- 四个框架改由 dyld 在 App 启动时加载。原来是启动后在后台 `dlopen`，实测约 60 ms。
- 同一个 commit 更新 Tuist 描述，`./TuistScript.sh check` 要通过（根 `AGENTS.md` 的规定）。

**三、创建编辑器与设置**
- `SourceEditorLoader` 改名 `SourceEditorBridgeProvider`：不再加载任何东西，只经工厂创建编辑器，并在启动时预热一个。设置读进来以后，把显示选项补给预热好的那个，minimap 的 Metal 管线照旧在启动时编译。
- `XcodeSourceEditorLocator` 改名 `SourceEditorFrameworks`，只看 App 自己的 `Contents/Frameworks/`，给出三种结果：可用、没嵌入、嵌了但不支持当前架构（读框架可执行文件的头，不加载）。设置页和注释标签用它判断这个构建用的是哪个编辑器。
- 删掉从 Xcode 加载的部分：查找 Xcode 的逻辑和 `installedXcodes()`、`loadedFrameworksDirectory()`、`Settings.Editor.sourceEditorXcodePath`、设置页的 Xcode 选择器和「换 Xcode 要重启」的提示，连同对应的测试。
- 删掉 `Settings.Editor.usesSourceEditor` 开关：带了重建版就用 SourceEditor，否则用 `NSTextView`。每个构建只有一种编辑器。
- 设置页的 Engine 一节改成一句说明：这个构建用的是 SourceEditor，或者为什么用的是文本视图（没带框架、或者不是 Apple 芯片）。只在 SourceEditor 下才有意义的设置项照旧保留，用不了时置灰。
- 注释标签只在用得了 SourceEditor 时才向引擎要注释结构，和以前「开关打开」时一样。

**四、桥接代码与测试**
- 桥接代码直接对着重建版的真实模块编译，手写接口桩整个 `Stubs/` 目录删掉：`.swiftinterface`、`.tbd`、生成与审计脚本、`VerifyBridgeLoading`。对着真实接口有三处写法要改，都在 `SemanticNodeTypeAdjuster.swift`。
- 为 Xcode 27 准备的第二个 `adjustNodeType(for:) -> Bool` 删掉：现在只对着重建版（等于 Xcode 26.6）编译和运行。
- 桥接测试 target 直接链接桥接 framework（`@testable import`）和重建版，不挂在 App 上跑。测试文件同样用 `#if canImport(SourceEditor)`；检查 bundle 不带加载命令的 `SourceEditorBridgeLinkageTests` 删掉。
- 模块规则（原 `Stubs/AGENTS.md`）挪到 `RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`，去掉写接口桩的部分；根 `AGENTS.md` 跟着改。

**五、没问就采用的假设**
- 只嵌加载器用到的四个框架，不嵌 `SourceEditorRegExSupport`。
- 重建版只有 arm64：Intel Mac 上那一份编译时就没有 SourceEditor，用 `NSTextView`。App 本身仍是 universal。
- 重建版的 bundle ID 照抄了 `com.apple.dt.*`。公证会不会因此被拦，第一次正式发版前实测；被拦了再定怎么办。
- 设置里以前存下的 `usesSourceEditor`、`sourceEditorXcodePath`，读到了也忽略，不做迁移。
- `SourceEditorBridging` 协议和几个 `@objc` 值类型先保留：App 里其它文件靠它们交换主题、注释装饰这些数据。改成直接用具体类型是另一处清理。
- 文档一起更新：0009 标为「部分被本提案取代」；愿景《自建代码视图引擎》的现状表下加一段说明，方向受什么影响留给用户重新评估；术语表加「重建版 SourceEditor」；README 没有提到这个编辑器，不用改。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-03 | Created as Draft | 用户要在 RuntimeViewer 里接入重建的 SourceEditor，取代从 Xcode 加载 |
| 2026-11-03 | 彻底去掉从 Xcode 加载；官方构建嵌入重建版，外部构建只用 `NSTextView` | 用户决定只留一条加载路径。RuntimeViewer 是公开仓库，SourceEditor 是私有仓库，外部构建本来就拿不到重建版 |
| 2026-11-03 | 不用 SwiftPM 依赖私有包 | 没有 SourceEditor 权限的人和 CI，会在解析依赖时就失败，整个 RuntimeViewer 都编不了 |
| 2026-11-03 | 桥接层与 stub 不改 | 对照 26.6.1 的导出符号：bridge 强引用的符号全部存在；缺的那一个和 Xcode 26.6 一样缺，而且已经是弱引用 |
| 2026-11-03 | 用户批准，状态改为 Accepted | 方案与假设照草案执行，「用 SourceEditor」开关一并删掉 |
| 2026-11-03 | 开工，状态改为 In Progress | 在 `feature/reconstructed-source-editor` 上实现 |
| 2026-11-03 | CI 发版用单独的 token 拉框架 | 工作流自带的 token 读不到私有仓库；拉框架单独一步、只给这一步 `SOURCE_EDITOR_RELEASES_TOKEN`，`ArchiveScript.sh` 发 Release 照旧用 `github.token` |
| 2026-11-03 | `XcodeSourceEditorLocator` 改名 `SourceEditorFrameworks`，多一种「架构不支持」的结果 | 它已经和 Xcode 无关；Intel Mac 带着框架也加载不了，设置页要能说清楚为什么用的是文本视图 |
| 2026-11-03 | `VerifyAcrossXcodes` 改名 `VerifyBridgeLoading`，默认对下载的重建版跑 | 不再逐个 Xcode 验证；仍接受别的框架目录，方便拿 Xcode 原版对照 |
| 2026-11-03 | 嵌入阶段每次构建都跑 | 没下载时输入文件不存在，交给依赖分析会让构建报错；拷贝加签名约一秒 |
| 2026-11-03 | 第一轮验证（Ultra，Xcode 27.2，Debug-arm64e） | 设置包 40 个测试、注释装饰 4 个测试通过；`RunScript.sh` 构建通过，嵌入阶段把 26.6.1 拷进 App 并用开发证书签名，`codesign --verify --deep --strict` 通过；`VerifyBridgeLoading.sh` 对下载的和嵌进 App 的两份都跑完整个桥接接口；桥接单元测试 35 个通过 33 个，没过的 2 个是 `SourceEditorScrollerTests`——`next` 上从 `8f3414e0`（有意不再自动隐藏滚动条）起就不过，那次提交注明测试没跟着改，与本改动无关；`./TuistScript.sh check` 通过 |
| 2026-11-03 | 包的全量测试（`RuntimeViewerPackages`，706 个） | 704 个通过；超时的 2 个是后台索引的「从条目上去掉 Engine」和交叉引用的「Call Hierarchy 展开下一层」，都等引擎事件，单独重跑这两组（32 个）全部通过，是全量并行时的负载超时，与本改动无关 |
| 2026-11-03 | 改为直接链接：桥接代码并进 App，直接 `import SourceEditor` 调用；不再运行时 `dlopen` 框架、加载 bundle；手写接口桩删除 | 用户决定。运行时加载是为「从用户的 Xcode 里加载」设计的，框架随 App 带上以后用不着了；桥接代码对着重建版的真实模块编译只有三处要改 |
| 2026-11-03 | 桥接测试直接编译同一批源文件、直接链接重建版，不挂在 App 上 | 用户决定。App 没有「测试时不启动服务」的判断，挂上去每次测试都会启动 MCP 服务、接管 CLI host |
| 2026-11-03 | 外部构建和 Intel 那一份用 `#if canImport(SourceEditor)` 在编译时跳过 | 拿不到模块就不编、不链接，不再需要接口桩，也不需要运行时判断 |
| 2026-11-03 | 下载的框架和钉住的版本对不上时，嵌入阶段报错 | 直接链接以后，编译时用了旧版、嵌入时却跳过，App 会在启动时找不到框架 |
| 2026-11-03 | 上面「桥接层与 stub 不改」「`VerifyAcrossXcodes` 改名」两条和第一轮验证作废 | 它们属于运行时加载的那一版实现 |
| 2026-11-03 | 桥接改成 App 直接链接的独立 framework，不并进 App | 用户决定。并进 App 以后编不过：重建版的公开头文件和 UIFoundation 的私有头文件都声明了 AppKit 私有协议 `NSScrollViewDelegate`，写法不同（重建版把两个属性标成必须实现），App 同时看到两者。独立的 framework 只引入 SourceEditor、不碰 UIFoundation，并用 `internal import` 不让 App 看到它们 |
| 2026-11-03 | 桥接测试改为链接桥接 framework（`@testable import`），取代「直接编译同一批源文件」 | 桥接有了自己的 framework，测试直接链接它；同样不挂在 App 上跑 |
| 2026-11-03 | 桥接 framework 打开 library evolution（`BUILD_LIBRARY_FOR_DISTRIBUTION = YES`） | 不开的话，`internal import` 拦不住：App 的依赖扫描仍顺着桥接去找 SourceEditor 模块，报「Unable to resolve module dependency: 'SourceEditor'」 |
| 2026-11-03 | 第一轮验证里「桥接单元测试 35 个通过 33 个」作废 | 那一轮跑的是 Xcode 27.2 的框架，不是重建版：xcodebuild 跑测试时把 Xcode 的 `SharedFrameworks` 放进 `DYLD_FRAMEWORK_PATH`，它比 rpath 先查。`VerifyBridgeLoading` 那一轮按绝对路径加载重建版，结论仍然成立 |
| 2026-11-03 | 桥接 framework 构建时，把重建版也拷一份到构建产物目录（嵌入脚本加一个目标目录参数） | Xcode 跑测试或运行 App 时，`DYLD_FRAMEWORK_PATH` 里构建产物目录排在 Xcode 的 `SharedFrameworks` 前面；用环境变量改 `DYLD_FRAMEWORK_PATH` 会把整个值换掉，连桥接 framework 都找不到 |
| 2026-11-03 | 桥接 framework 关掉脚本沙盒（`ENABLE_USER_SCRIPT_SANDBOXING = NO`） | 拷到构建产物目录的那一步要读下载目录，外部构建里它根本不存在，没法声明成输入；App target 为嵌入阶段关掉沙盒也是这个理由 |
| 2026-11-03 | 直接链接版的验证（Ultra，Xcode 27.2，Debug-arm64e） | 官方构建：`RunScript.sh` 构建通过；App 链接 `@rpath/RuntimeViewerSourceEditorBridge.framework`，桥接 framework 链接 `SourceEditor`、`SourceModel`、`SourceModelSupport`，Contents/PlugIns 里不再有 bundle，`codesign --verify --deep --strict` 通过。桥接测试 34 个通过 32 个，跑的是重建版（桥接引用一个只有重建版导出的符号），没过的 2 个是 `next` 上早就不过的 `SourceEditorScrollerTests`。外部构建（藏起下载目录）：构建通过，嵌入阶段只打 note，App 里只有桥接 framework、它不链接任何 SourceEditor 框架。设置包 40 个、注释装饰 4 个测试通过；`./TuistScript.sh check` 通过。没验证：Release 的 universal 构建、公证、实际启动 App |
| 2026-11-03 | 不改成 SwiftPM 集成：既不直接依赖私有包，也不包一层本地包 | 直接依赖私有包：依赖解析在编译之前，没有 SourceEditor 权限的人和 CI 在这一步就失败，做不到退回 `NSTextView`，各台机器还要配 `.netrc`。本地包（清单按下载的 xcframework 在不在声明 `binaryTarget`）做了实验：`swift build` 和 `xcodebuild` 都按清单文字缓存解析结果，全机共享，换全新的构建目录也一样，下载前后不会切换；`touch` 清单无效，改清单文字才重新解析；框架删掉以后旧的构建产物还让 `canImport` 成立。用户事先同意过：实验不成就保持现状 |
| 2026-11-03 | 保持动态链接，不改成可合并库，也不改成静态链接 | 用户决定。目的是让 App 里看不到这几个框架，两种办法都做不到：可合并库在 Release 里把代码并进 App，但 Xcode 仍把框架目录（资源和 `com.apple.dt.*` 的 Info.plist）嵌进去，只去掉可执行文件，因为重建版靠 `Bundle(for:)` 找资源；静态链接能去掉目录，但重建版二十多处照原版写的 `Bundle(for:)` / `bundleForClass:` 会指向 App 自己的包，`Assets.car` 还与 App 的同名，得改重建版的资源查找。两种都要 SourceEditor 重新出一版，重建版的类名和模块名也仍留在 App 的可执行文件里 |
| 2026-11-03 | 加回归测试 `SemanticRetypingTests`：类型引用要按语义区间改写成类型 | 接上 26.6.1 后，接口里的类型引用不着色，关键字和声明正常。原因在重建版，不是接入改出来的：`SourceModelLanguageService.nodeTypeAdjuster` 漏了原版的 didSet（Xcode 26.6 的 setter 在 0x23908，调用 0x23734 的 didSet，把 adjuster 交给 syntax token provider），桥接装上的 adjuster 从没被调用。测试经桥接的 `setSource` 传入语义区间，再读编辑器给一行着色用的 `enumerateSyntaxTokensOnLine`。同一个测试二进制在 26.6.1 上失败（`Float` 是 `.identifier(nil)`，对照的关键字正常），换成 Xcode 26.6 原版的四个框架就通过：`TEST_RUNNER_DYLD_FRAMEWORK_PATH` 先指向只放这四个框架链接的目录，再接构建产物目录；不能放整个 `SharedFrameworks`，里面的 `Testing.framework` 会让测试包加载失败。修复由 SourceEditor 的 LanguageServices 区做，随 26.6.2 发布；换 pin 后这条测试应转为通过，与换 pin 同批提交 |
