# 0012 - 迁移到 Tuist 并启用二进制缓存

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-08-17
- **最后更新**: 2026-08-17
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `feature/tuist-migration`（基线 `next`，非 `main`）
- **配套文档**: 待定 —— 落地时登记实现说明的链接

## 摘要

把三个本地 SPM 包（`RuntimeViewerCore` / `RuntimeViewerPackages` / `RuntimeViewerMCP`）改由 Tuist
生成，第三方依赖改走 `tuist install` 的 external 集成，从而启用 Tuist 的二进制缓存
（`tuist cache`）。目标是消除每次 clean build 重编 80+ 个第三方包的开销 —— POC 实测 clean build
从 110 秒降到 7.7 秒。

**本次只迁包，三个 `.xcodeproj` 保持手写不动**，改由 workspace 跨项目引用 Tuist 生成的 framework。
`.xcodeproj` 自身的 Tuist 化（含两处 Tuist 表达不了的 pbxproj hack）留待后续提案，
理由见「非目标」与「前期调研」。

## 动机

**构建时间的 86% 花在不属于本项目的代码上。**

统计 `Products/Logs/04-build-main.log`（2026-08-06 的一次真实主 app 构建），5939 个编译任务的归属：

| 归属 | 编译任务数 | 占比 |
|---|---|---|
| 第三方依赖 | ~5100 | 86% |
| 本项目代码 | ~840 | 14% |

前七名全部是外部依赖：UIFoundation 1005、swift-nio 810、SwiftMCP 657、RxAppKit 462、
swift-certificates 387、swift-helper-service 216、MachOSwiftSection 213。本项目最大的
`RuntimeViewerPackages` 只有 546，`RuntimeViewerUsingAppKit` 257。

这批依赖版本很少变，却在下列场景被反复全量重编：

- `RunScript.sh` 用 `/Volumes/DerivedData/RuntimeViewer/Debug-arm64e`，`ArchiveScript.sh` 用
  `/Volumes/DerivedData/RuntimeViewer/Archive` —— **两套 DerivedData 互不共享**，来回切就各重编一次
- 切分支导致 DerivedData 失效
- CI 的全新环境

**已有的手工缓解措施证明这个痛点是真实的，而且手工路线走不通。**
`RuntimeViewerPrecompiledLibraries/swift-syntax` 已经把 swift-syntax 全套换成了
`MxIris-DeveloperTool/swift-syntax-builder` 发布的预编译 xcframework（`.binaryTarget` +
`_Aggregation` 空壳 target）。这条路每覆盖一个包就要自建一条 release 流水线，而
`tuist cache` 一次覆盖 104 个 target（实测数字，见下）—— 手工路线不可能铺到这个规模。

## 前期调研

全部结论来自 2026-08-17 用 Tuist 4.204.0 在 scratchpad 中搭建的 POC，未改动本仓库任何文件。

### 缓存收益（已实测）

POC 依赖图含 47 个包（UIFoundation 全套、SwiftNIO、swift-crypto/BoringSSL、SwiftMCP、
swift-syntax、X509 等，覆盖本项目的主要重量级依赖）：

| 场景 | 耗时 |
|---|---|
| 无缓存 clean build | **110 秒** |
| 缓存命中 clean build | **7.7 秒** |
| `tuist cache` 预热（一次性） | 163 秒，产出 851 MB，104 个 target |
| `tuist generate`（缓存命中） | 3.6 秒 |

`tuist cache` 判定可缓存的 104 个 target 覆盖了全部宏 target
（`SwiftMCPMacros`、`FoundationToolboxMacros`、`JSONFoundationMacros`、
`ObjCRuntimeToolboxMacros`、`AssociatedObjectPlugin` 等）与 swift-syntax 全套
（`SwiftSyntax` / `SwiftParser` / `SwiftSyntaxMacros` / `SwiftSyntax509`–`603` 六个版本兼容层）。

### 依赖图兼容性（已实测，推翻了原先的顾虑）

- **package traits 不是阻塞点。** 原以为 Swift 6.1 的 package traits（`RuntimeViewerPackages` 的
  `UIFoundationTraits`、`RuntimeViewerMCP` 的 SwiftMCP 三项）Tuist 处理不了。实测
  `tuist install` 解析成功，且 traits 被正确翻译成 `SWIFT_ACTIVE_COMPILATION_CONDITIONS`：
  UIFoundation 得到 `AppleInternal, FilterUI, IDEIcons, NSAttributedStringBuilder, QuickActionBar, TabBar`，
  SwiftMCP 得到 `Client, OpenAPI, Server`。
  （注：UIFoundation 的实际 trait 集合是**七项** —— 上列六项加 `Settings`，由提案 0011 引入。
  POC 当时只覆盖了六项，落地的 `Tuist/Package.swift` 已按七项声明。）
- `tuist install` 解析 47 包成功，`tuist generate` 生成 47 个 Xcode 项目耗时 22.9 秒，
  **真实编译通过**（110 秒，零错误）。

### Tuist 表达不了的两处 pbxproj hack（已实测确认）

**这两处是「本次不迁 `.xcodeproj`」的直接依据** —— 它们全部位于主 app 项目，
只要 `.xcodeproj` 保持手写，本次迁移就完全不触碰它们。以下结论留档，供后续提案使用。

这两处是主 app 现有 `.xcodeproj` 中手工雕琢、Xcode GUI 做不出来的构造：

1. **Catalyst helper 嵌入主 app。**
   `RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj:115` 的
   `E9C9E9EF2C2D379200C4AA34 /* RuntimeViewerCatalystHelper.app */` 是一个
   `sourceTree = "<group>"` 的**普通文件引用**（指向 `RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper.app`，
   已在 `.gitignore` 中），而非 build product 引用。`Embed Helpers`（`dstSubfolder = Executables`,
   `dstPath = ../Applications`）拷的是它。这样刻意不建立 target dependency，绕开了
   "Xcode 把 Mac Catalyst helper 视作 iOS-family 内容、拒绝其成为 macOS app 依赖" 的限制
   （此限制已记录在 `AGENTS.md` 的 Catalyst helper build order 一节）。

   Tuist 的 `copyFiles` 的 `.buildProduct(name:)` 强制要求该 target 被声明为依赖，否则报
   `no product reference was found`；而一旦声明，Tuist 的 graph linter 直接拒绝：

   > Target POCApp has platforms 'macOS' and product 'application' and depends on target
   > POCCatalystHelper of type 'application' and platforms 'iOS' which is an invalid or not yet
   > supported combination.

2. **XPC service 产物名是 build setting 插值。**
   `project.pbxproj:116` 的 `E9CAFE020000000000000002 /* $(RUNTIME_VIEWER_SERVICE_NAME) */`
   是一个 `path` 为 `$(RUNTIME_VIEWER_SERVICE_NAME)`、`sourceTree = BUILT_PRODUCTS_DIR` 的
   文件引用，`Embed LaunchServices`（`dstPath = Contents/Library/LaunchServices`）拷的是它。
   该变量按配置取三个值（`Configurations/RuntimeViewerUsingAppKit/` 下
   Debug=`dev.mxiris.runtimeviewer.service`、Debug-arm64e=`dev.arm64e.mxiris.runtimeviewer.service`、
   Release=`com.mxiris.runtimeviewer.service`），service target 的 `PRODUCT_NAME` 逐配置对应。

   Tuist 的 `.buildProduct(name:)` 只接受静态 target 名，无法表达 `$(VAR)` 插值。

### `USING_LOCAL_DEPENDENCIES` 在 Tuist 下的处境（已实测）

三个包的 `Package.swift` 共用一套 `Package.Dependency.package(local:remote:)` 机制：
`USING_LOCAL_DEPENDENCIES=1` 时把依赖切到 sibling 目录的本地检出
（`../../UIFoundation`、`MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("RxAppKit")` 等），
配合 `#filePath` 判断自身是否作为 cloned dependency 被求值。这是同时改上游库时的核心工作流
（`RuntimeViewer-Debug.xcworkspace` 引用 sibling 检出是同一目的的另一套机制）。

实测结论：

- ✅ `Context.environment` 在 `Tuist/Package.swift` 中**可读**，`#filePath` 探测同样成立
  （Tuist 的 checkouts 落在 `Tuist/.build/checkouts/`，原有的 `/checkouts/` 判断继续有效）
- ❌ **Tuist 4.204.0 的 `Tuist/Package.swift` 不支持 `.package(path:)` 本地路径依赖**。
  硬编码绝对路径同样失败：

  > failed to load the manifest for the local package siblinglib, declared as
  > "…/SiblingLib" by "…/App/Tuist": no Package.swift in "…/App"

  **对照实验坐实这是 Tuist 特有的限制**：同一份 manifest 交给纯 `swift package resolve`
  解析成功（exit 0），Tuist 失败。
- ✅ 改用 `file://` URL 可行：`.package(url: "file:///path/to/Lib", branch: "main")`
  被 Tuist 正常解析并 checkout。代价是走 git clone，**只能拿到已提交的 commit，
  看不到工作区未提交的改动** —— 这与 `.package(path:)` 的语义有实质差别。
- ✅ **`.external` 与 `.local(path:)` 可以在同一个 target 上混用**：POC 中主 app 同时依赖
  104 个缓存 xcframework 与一个 `.local(path:)` 的工作区包，`tuist generate` 缓存命中，
  构建成功（8.4 秒，比纯 external 的 7.7 秒多出的部分即编译该本地包本身）。

### worktree 的本地依赖机制与它对缓存范围的限制（已查证）

实现在 `.claude/worktrees/RuntimeViewer` 这个 worktree 中进行，因为只有那里的本地依赖能编译成功。
其机制是：`.claude/worktrees/` 下放了 5 个**符号链接**，使各包 `Package.swift` 里的
`../../<Lib>` 相对路径在 worktree 中也能解析到真实库 ——

| 符号链接 | 指向 |
|---|---|
| `MachOKit` | `/Volumes/Code/Personal/MachOKit` |
| `MachOObjCSection` | `/Volumes/Code/Personal/MachOObjCSection` |
| `MachOSwiftSection` | 该库**自己的 worktree** |
| `swift-demangling` | 该库**自己的 worktree** |
| `swift-semantic-string` | 该库**自己的 worktree** |

**归属查证的结论直接决定缓存范围**：这批本地依赖**全部集中在 `RuntimeViewerCore`**
（MachOKit / MachOObjCSection / MachOSwiftSection / swift-semantic-string，
swift-demangling 为传递依赖）。`RuntimeViewerPackages` 与 `RuntimeViewerMCP`
**一个都没有** —— 它们的依赖全走远程 pin。

因此：

- `RuntimeViewerCore` 的这 4 个依赖必须走 `Project.swift` 的 `.local(path: "../../<Lib>")`
  （Tuist 不支持 `Tuist/Package.swift` 中的 `.package(path:)`，见上一节），**这部分不进缓存**。
  路径基准正确：`RuntimeViewerCore/Project.swift` 与 `RuntimeViewerCore/Package.swift`
  同在仓库根的一级子目录下，`../../<Lib>` 解析结果一致。
- 编译量大头 —— UIFoundation 1005、swift-nio 810、SwiftMCP 657、RxAppKit 462、
  swift-certificates 387 —— 全部属于后两个包，**缓存收益基本不受影响**。
  退出缓存的部分约占总编译任务的 6%（MachOSwiftSection 213 及三个较小的库）。

**另需防范的既有陷阱**：`a540f4fe` 记录过 SwiftPM 按**内容 hash** 缓存 manifest 求值结果，
主 checkout 与 worktree 的 `Package.swift` 字节相同但 `../../` 解析到不同路径，
导致一侧被喂了另一侧的缓存（现象是本地路径依赖**静默退化成远程 tag**），
当时以一段尾部注释制造内容差异规避。
新增的 `Tuist/Package.swift` 若两侧内容相同，会重演同一问题；
**落地时必须显式处理这层缓存**，见落地步骤第 1 步。

（另一层 `~/.cache/tuist/Manifests` 经第 3 步复测**不构成问题**：环境变量开关在不清缓存时
也如实生效。早前一次「疑似缓存导致开关失效」的观察系变量名缺少 `TUIST_` 前缀所致，
非缓存问题，已在「详细设计」中更正。）

### 第 1 步的落地验证结果（2026-08-17，worktree 内实测）

`Tuist/Package.swift` 汇总三个包的远程依赖后，`tuist install` 解析出 **83 个包**，
与现有 `RuntimeViewer.xcworkspace` 的 79 条 pin 比对：**零版本冲突**。全部差异均可解释：

- **仅存在于 Tuist 一侧（6 个）**：`MachOKit` / `MachOObjCSection` / `MachOSwiftSection` /
  `swift-semantic-string` / `swift-demangling` —— 即上一节那批本地依赖，workspace 里由符号链接
  覆盖故无远程 pin；外加 `swift-syntax`，原因见下。
- **仅存在于 workspace 一侧（2 个）**：`sparkle`（主 app 层依赖，本次不涉及）、
  `swift-snapshot-testing`（MachOSwiftSection 与 swift-memberwise-init-macro 的**测试**依赖 ——
  Tuist 的 external 集成不解析依赖包的测试依赖，属预期行为而非遗漏）。

**新发现：预编译 swift-syntax 的覆盖机制在 external 集成下失效。**
三个包的 `Package.swift` 中**没有任何一处**引用 `RuntimeViewerPrecompiledLibraries/swift-syntax`；
该预编译包是靠 **workspace 成员关系**覆盖同名 `swift-syntax` 生效的。
Tuist 的 external 集成不经由 workspace 解析依赖，因此覆盖不生效，
`tuist install` 拉取的是源码版 `swift-syntax 603.0.2`。

后果可接受，不构成阻塞：宏所依赖的 swift-syntax 首次需从源码编译，但它**整套都在
`tuist cache` 的可缓存范围内**（POC 中 `SwiftSyntax` / `SwiftParser` / `SwiftSyntaxMacros` 及
六个版本兼容层均已缓存），预热后效果与预编译 xcframework 相当。
是否在迁移完成后弃用 `RuntimeViewerPrecompiledLibraries`，按「非目标」留待单独评估。

### 落地中发现的 SPM → Tuist 语义缺口（已实测）

SwiftPM 隐式提供、而生成的 Xcode target 必须显式声明的东西：

- **`SWIFT_PACKAGE_NAME`**：源码使用 Swift 的 `package` 访问级别
  （`RuntimeViewerCore` 4 处、`RuntimeViewerPackages` 2 处，如 `package enum DyldUtilities`）。
  其作用域由编译器的 `-package-name` 标志界定，SwiftPM 自动传递，生成的 target 没有，
  于是这些声明解析失败 —— 报错信息是误导性的
  `'DyldUtilities' is inaccessible due to 'fileprivate' protection level`。
  同一包的所有 target 必须设相同值。
- **系统框架需显式链接**：`Network` 在 `RuntimeViewerCommunication` 与 `RuntimeViewerCore`
  **两处**都要声明（`RuntimeConnectionCredential` 的内存布局内嵌 `NWEndpoint`，
  故使用方也需链接），另有 `SystemConfiguration`、`Security`。
- `.when([...])` 返回 `PlatformCondition?` 而非 `PlatformCondition`；
  平台过滤枚举是 `.catalyst`，不是 `.macCatalyst`。

### 已知阻塞：`OpenUXKit` 的 `UXKit` product 无法经 external 集成构建

`RuntimeViewerUI` / `RuntimeViewerArchitectures` 依赖 `OpenUXKit` 包的 `UXKit` product
（`USING_SYSTEM_UXKIT` 默认开启时选用它，即系统私有 UXKit 的 `.tbd` shim）。
经 Tuist external 集成生成后构建失败：

> error: The file "UXView.h" couldn't be opened because there is no such file.
> (in target 'UXKit' from project 'OpenUXKit')

查证结论：

- 该包的 `UXKit` target 通过 `Sources/UXKit/include` **符号链接**复用 `OpenUXKit` 的头文件，
  并以 `.unsafeFlags` 链接 `UXKit.tbd`。
- **符号链接不是原因** —— 已实测把它替换为真实目录，报错完全相同。
- 真正的缺陷在生成结果：Tuist 为同名头文件生成了**多份重复 fileRef**
  （`UXView.h` 出现 4 次，因该头文件在 `include/OpenUXKit/`、`PrivateHeaders/OpenUXKit/`、
  `Components/Public/` 三处各有一份），且 `path` 仅保留文件名、**丢失目录层级**
  （`path = UXView.h; sourceTree = "<group>"`），Xcode 因而找不到文件。

出路（均未实施，待定）：调整上游 `OpenUXKit` 的目录结构；等待 / 提交 Tuist 侧修复；
或将 `OpenUXKit` 排除出 external 集成 —— 但最后一条会重新引入两套解析器混用的
「Multiple commands produce」问题，需谨慎。

### 其他实测细节

本次适用：

- **Tuist 的 target UUID 是确定性的**：对同一 `Project.swift` 连续 `generate` 两次，
  `PBXNativeTarget` 的 UUID 完全一致；改动 target 内容（新增源文件、修改 `deploymentTargets`）
  后仍不变 —— UUID 只与项目名 + target 名相关。这是「手写 `.xcodeproj` 跨项目引用 Tuist 生成的
  framework」可行的前提。
- **external 依赖是静态的**：生成的 external target 为 `MACH_O_TYPE = staticlib` 的 framework，
  缓存产物是 `.xcframework`。这决定了包 target 必须产出 dynamic framework，见「详细设计」。
- **缓存按配置分桶**：`tuist cache warm --configuration <name>`。本项目四套配置
  （Debug / Debug-arm64e / Release / Distribution）需各自预热；`Debug-arm64e` 因 ARCHS 不同
  必然与 Debug 分桶。另有 `--cache-profile only-external`，只缓存依赖、自有代码照常编译。
- **objectVersion**：Tuist 生成 55。本次仅三个**包**项目由 Tuist 生成，
  三个 app / server 的 `.xcodeproj` 保持手写、版本不变
  （`RuntimeViewerUsingAppKit` 90、`RuntimeViewerServer` 77、`RuntimeViewerUsingUIKit` 70）。

留给后续提案（`.xcodeproj` 层，本次用不到）：

- **Icon Composer 的 `.icon` 可用**：`Resources/AppIcon.icon` 以 `.folderReference` 声明后，
  actool 正确带 `--app-icon AppIcon` 编译，无需额外处理。
- **`buildableFolders` 可生成 `PBXFileSystemSynchronizedRootGroup`**，与现有三个项目已采用的
  Xcode 16+ 同步文件夹一致。
- **bundle 类型依赖会被 Tuist 自动 embed**：`RuntimeViewerCatalystHelperPlugin` 这类 bundle 只需
  声明为依赖，再手写 `copyFiles` 会导致
  `error: Unexpected duplicate tasks`（实测构建失败）。

## 提议方案

### 依赖与本地包 Tuist 化

1. 新建仓库根的 `Tuist.swift` 与 `Tuist/Package.swift`，把三个包 `Package.swift` 中的**远程依赖**
   声明合并进来，保留 traits 与版本约束。
2. 三个本地包改写为 Tuist 项目：`RuntimeViewerCore/Project.swift`、
   `RuntimeViewerPackages/Project.swift`、`RuntimeViewerMCP/Project.swift`，
   target 拓扑与现有 `Package.swift` 一一对应（合计 15 个源码 target + 6 个测试 target）。
   包间依赖用 `.project(target:path:)`，第三方依赖用 `.external(name:)`，
   平台条件依赖 `.when(platforms: appkitPlatforms)` 映射为 `condition: .when([.macos])`。
3. 包 target 产出 **dynamic framework**（`.framework` 而非 `.staticFramework`），
   使 static 的 external 依赖被链入包自身，现有 `.xcodeproj` 无须感知传递依赖 ——
   理由与代价见「详细设计 — 包产物形态」。
4. 三个手写 `.xcodeproj` 改为经 workspace **跨项目引用**这些 framework，
   取代原先的 SPM product 引用。这是本次唯一需要改动 `.xcodeproj` 的地方。
5. 各包的 `Package.swift` 保留还是删除，见「详细设计 — 本地包的双形态问题」。
6. `RunScript.sh` / `ArchiveScript.sh` / `BuildRuntimeViewerServerXCFramework.sh`
   在 xcodebuild 之前插入 `tuist install` + `tuist generate`；
   引入 `tuist cache warm` 的使用约定（四套配置各自预热）。

### 非目标

- **不迁移三个 `.xcodeproj` 自身。** 它们保持手写、继续入库，只改依赖引用方式。
  两处 Tuist 表达不了的 pbxproj hack（Catalyst helper 假文件引用、
  `$(RUNTIME_VIEWER_SERVICE_NAME)` 插值，详见「前期调研」）因此在本次**完全不受影响** ——
  这正是先做包层的价值：收益全部落袋，风险最高的部分一点不碰。
  `.xcodeproj` 的 Tuist 化留待后续提案。
- **不引入顶层 `Workspace.swift`。** 现有三份 `contents.xcworkspacedata` 保持手工维护，
  只把成员从 SPM 包目录换成 Tuist 生成的 `.xcodeproj`。
- **不引入 Tuist Server / 远程缓存。** 本地缓存（`~/.cache/tuist/Binaries`）已足够，
  远程缓存要账号与额度，单人开发拿不到额外收益。需要时另开提案。
- **不改动任何运行时行为。** 本提案只动构建系统，不碰 app 的功能、UI 与架构。
  唯一的形态变化是包从静态链接变为 dynamic framework，见「影响」。
- **不迁移 `RuntimeViewerPrecompiledLibraries/swift-syntax`。** 它与 Tuist Cache 目标重叠，
  但取舍需要单独评估（见「替代方案考量」），本次保持原样。
- **不动 Sparkle 发布流程与公证流程本身**，只保证它们在新构建系统下行为不变。

## 详细设计

### 包产物形态：必须是 dynamic framework

实测：`tuist install` 生成的 external 依赖是 `MACH_O_TYPE = staticlib` 的**静态** framework
（POC 中 UIFoundation、SwiftMCP 等全部如此）。这决定了包 target 的产物形态：

- 若包 target 也用 `.staticFramework`，静态库不传递链接，手写的 `.xcodeproj` 就必须显式链接
  **全部传递依赖** —— POC 中是 104 个 target 的量级，手工维护 pbxproj 不可行。
- 因此包 target 一律用 `.framework`（dynamic）。静态的 external 依赖被链入包自身，
  `.xcodeproj` 只需链接并嵌入这几个包 framework。

**代价（行为变化，需在验收中确认）**：现状是 SPM library 被静态链进 app 可执行文件，
改为 dynamic framework 后，产物多出 `Contents/Frameworks/RuntimeViewer*.framework`，
且必须 embed + code sign。这会影响 app bundle 结构、启动时的 dyld 加载数量，
以及公证时的签名对象数量。

### 现有 `.xcodeproj` 的引用改造

三个 `.xcodeproj` 保持手写，仅把依赖引用从 SPM product 换成跨项目 framework 引用：
workspace 纳入 Tuist 生成的 `RuntimeViewerCore.xcodeproj` / `RuntimeViewerPackages.xcodeproj` /
`RuntimeViewerMCP.xcodeproj`，app target 链接并嵌入其中的 framework。

该引用靠 pbxproj 的 `PBXContainerItemProxy` 按 target UUID 锚定，因此**要求 Tuist 生成的 UUID
稳定**。已实测确认：Tuist 的 target UUID 是确定性的，连续 `generate` 完全一致，
且在改动 target 内容（新增源文件、修改 `deploymentTargets`）后仍不变 ——
UUID 只与项目名 + target 名相关。改名 target 会使引用失效，须与 `.xcodeproj` 同批次更新。

### `USING_LOCAL_DEPENDENCIES` 的替代

保留环境变量语义，但底层机制按用途拆成两条：

- **默认路径（`USING_LOCAL_DEPENDENCIES` 未开启）**：`Tuist/Package.swift` 全部走
  `.package(url:)` 远程 pin，`.external(name:)` 引用，缓存全量生效。
- **联调路径**：需要改哪个上游库，就在对应包的 `Project.swift` 里把那一个依赖从
  `.external(name:)` 换成 `packages: [.local(path: "../../UIFoundation")]` +
  `.package(product:)`。只有该库退出缓存，其余 100+ target 仍命中。

这条路径是实测过的混用方案，且**保留了 `.package(path:)` 直连工作区的语义**
（改上游源码无需 commit 即可生效）—— 这是 `file://` URL 方案做不到的，因此不采用后者。

为此提供 `Tuist/ProjectDescriptionHelpers/LocalDependencies.swift`，把「读环境变量决定
某依赖走 external 还是 local」的判断集中一处。**该方案已于落地第 3 步实测通过**
（生成 `XCLocalSwiftPackageReference` 并构建成功），但环境变量名有一处关键约束：

```swift
import Foundation
import ProjectDescription

public enum LocalDependencies {
    /// Tuist only forwards `TUIST_`-prefixed variables into manifest evaluation,
    /// so this reads TUIST_USING_LOCAL_DEPENDENCIES — not USING_LOCAL_DEPENDENCIES.
    public static var isEnabled: Bool {
        Environment.usingLocalDependencies.getBoolean(default: false)
    }

    public static func isAvailable(_ relativePath: String, from manifestDirectory: String) -> Bool {
        guard isEnabled else { return false }
        let resolved = URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: manifestDirectory)).path
        return FileManager.default.fileExists(atPath: resolved)
    }

    public static func dependency(
        productName: String,
        localPath: String,
        manifestDirectory: String
    ) -> TargetDependency {
        isAvailable(localPath, from: manifestDirectory)
            ? .package(product: productName)
            : .external(name: productName)
    }

    public static func packages(_ entries: [(path: String, manifestDirectory: String)]) -> [Package] {
        entries.compactMap {
            isAvailable($0.path, from: $0.manifestDirectory) ? .local(path: .relativeToManifest($0.path)) : nil
        }
    }
}
```

**两层 manifest 认的变量名不同，必须同时设置**（实测结论）：

| manifest | 读取方式 | 认的变量名 |
|---|---|---|
| `Tuist/Package.swift`（SwiftPM） | `Context.environment` | `USING_LOCAL_DEPENDENCIES` |
| `Project.swift` / helpers（Tuist） | `Environment.xxx` | **`TUIST_`**`USING_LOCAL_DEPENDENCIES` |

实测：只设 `USING_LOCAL_DEPENDENCIES=1` 时，`Project.swift` 内 `Environment` 与
`ProcessInfo` 三种读法**全部读不到** —— Tuist 只把 `TUIST_` 前缀的变量透传进 manifest
求值进程。因此联调时两个都要设，建议由脚本统一导出。

> 缓存说明（修正）：Tuist 的 `~/.cache/tuist/Manifests` **不会**阻碍该开关 ——
> 实测在不清缓存的情况下来回翻转，生成结果每次都如实跟随。
> 需要留意的是另一层：SwiftPM 对 `Tuist/Package.swift` 的内容哈希缓存，
> 见「worktree 的本地依赖机制」一节。

### 本地包的双形态：`Package.swift` 与 `Project.swift` 并存（已决定）

**决定：保留 `Package.swift`**，与新增的 `Project.swift` 并存。
理由是保住三个包的 SPM 形态 —— 仍可被 `swift build` 单独构建，
仍可作为 SPM 依赖被外部仓库消费。曾评估过的「删除 `Package.swift` 只留 `Project.swift`」
更干净，但会永久放弃这两项能力，代价不可逆。

代价是**两重漂移源**，必须有机制约束，不能只靠人工同步：

1. **target 拓扑**：target 名、target 之间的依赖、平台条件，两份声明各写一遍。
2. **依赖版本约束**：各包 `Package.swift` 的 `.package(url:from:)` 与
   `Tuist/Package.swift` 的同名声明各有一份 pin，可能指向不同版本。
   **这一重比拓扑更危险** —— 拓扑漂移会编译失败，版本漂移则可能悄无声息地
   让 `swift build` 与 `tuist generate` 构建出行为不同的产物。

**防护机制：一致性校验脚本**（落地步骤新增一步）。两侧都能输出机器可读的 JSON：

```bash
swift package dump-package --package-path RuntimeViewerCore   # targets + dependencies + 版本约束
tuist dump project --path RuntimeViewerCore                    # targets + packages
```

脚本比对三项并在不一致时以非零码退出：

- 两侧 target 名集合相等（测试 target 一并比对）
- 每个 target 的内部依赖集合相等
- 每个外部依赖的 URL 与版本约束在两侧一致

该校验接入 CI 与发布前检查，使漂移变成**构建失败**而非静默行为差异。
若某项差异是有意为之（例如某 target 只在 Tuist 侧存在），
在脚本的白名单里显式登记并注明理由，不允许直接放宽比对规则。

## 替代方案考量

- **连同三个 `.xcodeproj` 一并 Tuist 化（本提案初稿的方案，已推迟）。**
  推迟原因：收益全部来自包层（缓存只作用于依赖），而 `.xcodeproj` 层集中了全部风险 ——
  两处 Tuist 表达不了的 pbxproj hack 需改写成自维护的 run script，
  并连带重新验证 SMJobBless 签名链、公证与 Sparkle。
  先做包层可以把收益全部拿到手而完全不碰这些，因此拆分为两个提案。

  > 初稿曾以「跨项目引用需长期手工维护、每次 `tuist generate` 后都要确认引用未断」
  > 为由否决只迁包层。**该理由已被实测推翻**：Tuist 的 target UUID 是确定性的，
  > 连续生成与内容变更后均不变，跨项目引用不会自行断裂。
  > 真正的代价不是引用维护，而是包必须改为 dynamic framework（见「详细设计」）。

- **继续扩展预编译 xcframework 路线（现有 `RuntimeViewerPrecompiledLibraries` 的做法）。**
  否决原因：每覆盖一个包需自建一条 release 流水线并手工维护 checksum，
  而缓存目标是 104 个 target，规模上不可行。
  （该目录本次保持原样。**它不可被取代，理由见下条**。）

- **改用 SwiftPM 官方的 swift-syntax prebuilts（`IDEPackageEnablePrebuilts` / `--enable-experimental-prebuilts`）。**
  否决原因：**官方 prebuilt 二进制不含 arm64e slice，启用后打包会失败。**
  本项目的 `RuntimeViewerServer.framework` 与特权 service 必须带 arm64e 才能检查 arm64e 进程
  （`Debug-arm64e` 配置即为此存在），因此官方 prebuilts 在本项目不可用。

  > **这是 `RuntimeViewerPrecompiledLibraries/swift-syntax` 存在的真正理由** ——
  > 自建 xcframework 带 arm64e slice，官方的不带。引入它的 commit（`7ec30f7a`，2026-01-06）
  > 只写了 "for faster compilation times"，没有记录这条架构约束，
  > 因此 `IDEPackageEnablePrebuilts` 被显式设为 `NO` 的原因从代码与历史中均无从得知。
  > 在此留档，避免日后有人"顺手"打开该开关或删除这个目录。
  >
  > 附带影响：命令行 `swift build` 的 `--enable-experimental-prebuilts` 在 Swift 6.3 **默认开启**，
  > 与 Xcode 侧的 `NO` 不一致。凡是要产出 arm64e 的命令行构建，都需显式传
  > `--disable-experimental-prebuilts`。
  >
  > 反过来说，**基于本机编译的缓存方案不受此限制** —— Tuist Cache 与 Xcode 编译缓存
  > 缓存的都是本机编译产物，架构由本项目的配置决定，因此都能覆盖 arm64e。

- **让两个脚本共用一个 DerivedData。**
  成本极低，能消除「Debug-arm64e 与 Archive 来回切各重编一次」这一项。
  否决原因：只覆盖部分场景（clean build、切分支、CI 仍然全量重编），
  且两套配置的 ARCHS 不同，共用目录并不能让产物互相复用。可作为迁移期间的临时缓解。

- **用 `file://` URL 表达本地依赖。**
  实测可行，但走 git clone 只能拿到已提交的 commit，改上游库必须先 commit 才能被看见，
  联调体验显著劣于 `.package(path:)`。已被「external + local 混用」方案取代。

- **`.package(path:)` 直接写进 `Tuist/Package.swift`。**
  实测不可行（见前期调研），Tuist 4.204.0 的限制。

## 影响

### 用户可见变化

无。本提案只改构建系统，不改 app 的任何界面、交互与行为。

### 可发现性

不适用（无用户可见功能）。

对**开发者**而言可发现性有变化：三个包的 `.xcodeproj` 由 Tuist 生成、不入库，
clone 后必须先跑 `tuist install && tuist generate` 才能用 Xcode 打开 workspace。
须在 `README.md` 与 `AGENTS.md` 的 Build Commands 一节明确写出这一步。

三个 app / server 的 `.xcodeproj` 与三份 `.xcworkspace` **仍然入库**，本次不变。

### 数据与配置兼容

不涉及。用户文档、偏好设置、缓存、钥匙串条目均不受影响。

**但 bundle identifier 与 XPC service 名必须逐配置保持不变** ——
`Configurations/CodeSigning.xcconfig` 定义的
`RUNTIME_VIEWER_APP_*_BUNDLE_IDENTIFIER`、
`RUNTIME_VIEWER_PRIVILEGED_HELPER_BUNDLE_IDENTIFIER` 与
`RUNTIME_VIEWER_SERVICE_NAME` 若在迁移中漂移，已安装的 SMJobBless helper 会失配、
Sparkle 会把新版本视为不同 app。本次不触碰这些 target 的配置，
它们理应零变化，验收仍须逐项比对（落地第 6 步）。

### 平台与最低版本

不变。各包 target 的 deployment target 原样搬迁，验收时以 `-showBuildSettings` 比对。

### 发布

- 不新增权限、entitlement 或隐私清单条目；现有 entitlements 文件原样引用。
- **本次最高风险项是包由静态链接改为 dynamic framework**：app bundle 新增
  `Contents/Frameworks/RuntimeViewer*.framework`，需正确 embed + code sign，
  公证的签名对象随之增多。`ArchiveScript.sh` 的 archive → export → notarize 全链路
  必须完整跑通一次并实际安装验证 helper 授权，才能认为迁移完成。
- 原有两处 Embed phase（LaunchServices 的 XPC service、Catalyst helper）**本次完全不动**，
  仍由 Xcode 的 `CodeSignOnCopy` 处理，不承担改写风险。
- Sparkle appcast 生成依赖 `$DERIVED_DATA/SourcePackages/artifacts/sparkle` 下的
  `generate_appcast`；Sparkle 改经 external 集成后产物布局可能变化，
  `ArchiveScript.sh` 中这段查找逻辑需确认，必要时调整。

## 落地步骤

1. **建立 Tuist 骨架**：仓库根 `Tuist.swift` + `Tuist/Package.swift`，仅含远程依赖声明。
   验证 `tuist install` 能解析出与现有 `Package.resolved` 一致的版本集合。
   同时处理 SwiftPM 的 manifest 内容哈希缓存（见「前期调研 — worktree 的本地依赖机制」）：
   `Tuist/Package.swift` 比照 `a540f4fe` 的做法加入 worktree 专属的内容差异标记。
   ✅ **已完成**（`fd59a305`）：解析 83 包，与现有 pin 零版本冲突。
2. **迁移 `RuntimeViewerCore`**（4 源码 + 2 测试 target）。验证：`tuist generate` 后该项目
   单独构建通过，测试可运行。
3. **验证 `ProjectDescriptionHelpers` 的环境变量方案**。
   ✅ **已完成**：方案可行 —— 生成 `XCLocalSwiftPackageReference` 且构建通过。
   实测发现变量名必须带 `TUIST_` 前缀，详见「详细设计 —— `USING_LOCAL_DEPENDENCIES` 的替代」。
4. **迁移 `RuntimeViewerMCP`**（1 源码 + 1 测试 target）。
5. **迁移 `RuntimeViewerPackages`**（10 源码 + 3 测试 target，26 个直接依赖、
   60 处 product 引用、34 处平台条件）。验证：三个包互相引用正确，全部构建通过。
   三个包的 `Package.swift` 一律保留（见「详细设计 — 本地包的双形态」），
   验证 `swift build` 在三个包上仍然可用。
5b. **一致性校验脚本**：比对 `swift package dump-package` 与 `tuist dump project` 的
   target 拓扑与依赖版本约束，不一致即非零退出；接入 CI 与发布前检查。
   与第 5 步同批次落地 —— 校验缺席则双形态从第一天起就开始漂移。
6. **改造三个 `.xcodeproj` 的依赖引用**（本次唯一触碰 `.xcodeproj` 的一步）：
   workspace 成员从 SPM 包目录换成 Tuist 生成的 `.xcodeproj`，
   app / framework target 改为链接并嵌入包 framework。
   验收清单（逐项核对，不得省略）：
   - Debug / Debug-arm64e / Release 三套配置下，app bundle 结构与迁移前逐路径比对；
     **新增**的 `Contents/Frameworks/RuntimeViewer*.framework` 是唯一允许的差异
   - 原有嵌入项**原样保留**（`Contents/Library/LaunchServices/<service>`、
     `Contents/PlugIns/*.bundle`、`Contents/Applications/RuntimeViewerCatalystHelper.app`、
     `Contents/Frameworks/RuntimeViewerServer.framework`）—— 本次不改这些 Embed phase，
     它们理应零变化，出现差异即为回归
   - 三套配置的 bundle identifier 与 `RUNTIME_VIEWER_SERVICE_NAME` 与迁移前一致
   - `codesign -dvvv` 核对新增 framework 已正确签名，SMJobBless helper 实际安装并取得授权
7. **首次 `tuist cache warm`，记录实测加速比**，与本提案 POC 数字比对并回填。
8. **脚本接入**：三个 `.sh` 插入 `tuist install` / `tuist generate`；
   确认 `ArchiveScript.sh` 的 Sparkle `generate_appcast` 查找路径仍然有效
   （Sparkle 现经 external 集成，产物布局可能变化）。
9. **完整发布演练**：`ArchiveScript.sh` 走通 archive → export → notarize，
   产物安装后验证 helper 授权与 Sparkle 更新检查。
   重点确认新增的 dynamic framework 不破坏公证与 SMJobBless 授权链。
10. **文档同批次更新**：`README.md`（clone 后需 `tuist generate`）、
    `AGENTS.md`（Build Commands 一节）、本提案状态改 `Implemented`。

### 交付路径

本分支基线是 `next`。按现行分支模型，改动以 PR 形式合入 `next`，`next` 最终整体合入 `main`
（`AGENTS.md` 的 Branching Model 一节仍写着旧模型「next 永不合入 main」，需另行修正）。

据此，本次迁移**按上述 10 步拆成多个 PR 依次合入 `next`**。
但每个 PR 必须让 `next` 处于**整体可构建**的状态，这带来一条硬约束：

- **三个包的 Tuist 化（第 2、4、5 步）与 `.xcodeproj` 的引用改造（第 6 步）必须在同一个 PR 内闭合。**
  包一旦从 SPM 形态改为 Tuist 项目，原先经 workspace 引用它的 `.xcodeproj` 立刻失效，
  中间态构建不通。因此这四步合为一个 PR；第 1、3 步（骨架与机制验证）可先行独立合入，
  第 7–10 步（缓存、脚本、发布演练、文档）可各自独立成 PR。

`next` 合入 `main` 之前还有一件未决事项：

- **`main` 的验收方式需要补充。** `AGENTS.md` 要求「`main` 上的一切必须能对着**已发布的**
  远程 SPM pin 编译，用 `RuntimeViewer-Distribution.xcworkspace` 验证，
  而非 Debug workspace（其本地检出会掩盖 pin 不匹配）」。
  本次不删除该 workspace，规则本身继续成立，但需增加一条前置：
  「`USING_LOCAL_DEPENDENCIES` 未设置时 `tuist install` 必须解析成功」——
  否则包的依赖来源是本地检出还是远程 pin 将不再由 workspace 成员关系决定，
  而是由 `Tuist/Package.swift` 的求值结果决定，原规则会失去约束力。
  **具体措辞待定，合入 `main` 前需确认。**

**收尾时必须判断两件事**（结果写进决策日志）：

- **配套专题文章**：「包为什么必须是 dynamic framework 而非 staticFramework」
  与「`USING_LOCAL_DEPENDENCIES` 在 Tuist 下如何联调上游库」都属于
  「下次维护会踩、代码本身看不出来的决策」，**倾向写一篇实现说明**覆盖两者。
- **新术语**：`external 集成` / `binary cache` / `cache 分桶` 等若在项目文档中反复出现，
  登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-17 | Created as Draft | 用户批准「全部迁移到 Tuist」并要求在独立分支进行。提案基于同日的 POC 实测：缓存命中使 clean build 从 110s 降至 7.7s；确认 package traits 可用、两处 pbxproj hack 需改写为 run script、Tuist 不支持 `Tuist/Package.swift` 中的本地路径依赖。 |
| 2026-08-17 | 分支基线改为 `next` | 原从 `main` 切出，按用户要求改为基于 `next`。提案编号随之从 `0007` 改为 `0012`（`next` 上 0007/0008/0011 已占用，索引明确要求新提案从 0012 起）。同时按 `next` 实际内容校正 target 计数与 `README.md` 行号引用。 |
| 2026-08-17 | 交付路径按现行分支模型重写 | 用户指出 `AGENTS.md` 的「next 永不合入 main」已过时，现行模型是 PR 合入 `next`、`next` 整体合入 `main`。原「无法渐进合入、需一次性切换」的判断作废。`AGENTS.md` 该节待另行修正。 |
| 2026-08-17 | **范围收窄为只迁包层** | 用户要求先只做三个本地 SPM 包，`.xcodeproj` 暂不迁。收益全部落在包层而风险集中在 `.xcodeproj` 层，故拆分。新增实测依据：Tuist target UUID 确定性稳定（跨 generate、跨内容变更均不变），跨项目引用可靠；external 依赖为 `MACH_O_TYPE = staticlib`，故包必须产出 dynamic framework。初稿否决「只迁包层」的理由（跨项目引用需长期维护）据此推翻，已在「替代方案考量」中留档。 |
| 2026-08-17 | 保留三个包的 `Package.swift` | 用户拍板：`Package.swift` 与 `Project.swift` 并存，保住 SPM 形态（可 `swift build`、可被外部仓库消费）。代价是 target 拓扑与依赖版本约束两重漂移源，故新增落地第 5b 步：用 `swift package dump-package` 与 `tuist dump project` 的 JSON 比对做一致性校验，接入 CI，使漂移表现为构建失败而非静默的行为差异。 |
| 2026-08-17 | 实现改在 worktree 中进行，查明本地依赖机制 | 用户指出只有 `.claude/worktrees/RuntimeViewer` 里的本地依赖能编译成功。查明机制为 `.claude/worktrees/` 下的 5 个符号链接使 `../../<Lib>` 在 worktree 中可解析。归属查证结论：这批本地依赖**全部集中在 `RuntimeViewerCore`**，`RuntimeViewerPackages` / `RuntimeViewerMCP` 一个都没有，故编译量大头仍可缓存，退出缓存的部分约占 6%。同时记录 `a540f4fe` 的 SwiftPM manifest 内容哈希缓存陷阱对新增 `Tuist/Package.swift` 同样适用，且 Tuist 另有一层 `~/.cache/tuist/Manifests`。 |
| 2026-08-17 | 状态 → `Accepted` | 用户已批准迁移方向、只迁包层的范围收窄，以及保留 `Package.swift` 的处置。实现可以开始。 |
