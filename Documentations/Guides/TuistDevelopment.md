# 使用指南：Tuist 开发 workspace

- **面向**: 在本仓库做日常开发、想让第三方依赖走二进制缓存的人；改原生工程的 target、依赖、嵌入方式或构建设置的人（同步规则）
- **对应提案**: [draft-tuist-coexistence](../Evolutions/draft-tuist-coexistence.md)
- **最后更新**: 2026-10-10

`RuntimeViewer-Tuist.xcworkspace` 是构建 macOS App 的第二条路，只供日常开发。它由
`./TuistScript.sh` 用 Tuist 生成，和原生工程用同样的 target、同样的源码、同一批
`Configurations/` 下的 xcconfig；差别在于约 85 个第三方依赖取自本机的 Tuist 二进制缓存，只编一次，
四个本地包（`RuntimeViewerCore` / `RuntimeViewerPackages` / `RuntimeViewerMCP` /
`RuntimeViewerCommandLine`）照常是源码、可跳转可编辑。

实测（Xcode 27，完整 App，按 `RunScript.sh` 的参数从空的 DerivedData 构建 Debug）：不用缓存 504 秒，走缓存
155 秒；预热一次约 8 分钟。没有预热过的 Debug-arm64e 与 Release 从源码编，分别约 9 分钟和 18 分钟（这两套配置下
包要多编一个 arm64e 切片，见「已知的坑」）。

**发版、CI、`RunScript.sh`、`ArchiveScript.sh` 和其余脚本只走原生工程**，Tuist 这边出问题不影响
它们。生成的工程文件都在 `.gitignore` 里，不提交。

## 第一次使用

```bash
mise install                                 # 装 mise.toml 钉的 Tuist（4.210.0）
./TuistScript.sh warm                        # 解析依赖 → 把第三方依赖编进缓存 → 生成 workspace
open RuntimeViewer-Tuist.xcworkspace
```

**Xcode 版本要和原生锁文件解析时用的一致**（`next` 上是 Xcode 27）。脚本和 Tuist 都用
`DEVELOPER_DIR` 或 `xcode-select` 选中的那个；不是默认那个时：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.app/Contents/Developer
./TuistScript.sh warm
```

打开 workspace 也用同一个 Xcode。原因：有些包按 Swift 版本选用不同的 `Package@swift-x.y.swift`
清单，换个 Xcode 解析出的是另一组包（实测 Xcode 26.6 解析出 `xctest-dynamic-overlay` 1.13，
Xcode 27 解析出 `swift-issue-reporting` 2.1），锁文件就和原生的对不上了；二进制缓存也按 Xcode
版本分开。

## 日常用法

| 要做的事 | 做法 |
|---|---|
| 编辑、构建、运行 | Xcode 里 scheme `RuntimeViewer macOS`，配置 Debug |
| 跑测试 | scheme `RuntimeViewer Tests`：四个本地包的全部测试 target 加 `RuntimeViewerSourceEditorBridgeTests` |
| 命令行构建（同 `RunScript.sh` 的参数） | `./TuistScript.sh build [--configuration Debug-arm64e] [--launch]` |
| 本地包里增删了源文件 | `./TuistScript.sh generate`（Tuist 转换包时按 glob 展开文件；只改已有文件不用） |
| 改了某个 `Package.swift`（依赖、target、设置） | `./TuistScript.sh install`，再 `generate` |
| 依赖升级 | `./UpdatePackagesScript.sh`（顺带更新 `Tuist/Package.resolved`），再 `./TuistScript.sh warm`（只重编变了的） |
| 换了 Xcode 版本 | `./TuistScript.sh warm` |
| 改了原生工程的结构或设置 | 同批更新 Tuist 描述，提交前 `./TuistScript.sh check`（见下文） |

缓存按配置分开预热：Debug 是默认；要在命令行编 Debug-arm64e 就先
`./TuistScript.sh warm --configuration Debug-arm64e`，否则第三方依赖会从源码编。

**生成出的工程只链接一套配置的缓存。** Xcode 里开着的 workspace 是按 Debug 生成的，拿它编 Debug-arm64e
会失败：Debug 缓存里的第三方库只有 arm64 与 x86_64，实测报的是不相干的
`cannot find 'SMGCopyAnswerAsString' in scope`。`build` 与 `check` 先按自己要编的配置生成，结束时不管成败再按
Debug 生成回来；`warm` 收尾也生成 Debug。要在 Xcode 里编别的配置，先
`./TuistScript.sh generate --configuration <配置>`，编完用不带参数的 `generate` 回到 Debug。

生成之后，四个本地包目录里各多一个 `<包名>.xcodeproj` 和 `Derived/`。直接在 Xcode 里打开包目录时，
Xcode 可能打开的是这个工程而不是 `Package.swift`；双击 `Package.swift` 不受影响。

## 必须遵守的约定

1. **App 只能用 `RuntimeViewer macOS` scheme 构建。** 模拟器注入载荷和 Catalyst helper 的插件不是任何
   target 的依赖（原因见「已知的坑」），由这个 scheme 按固定顺序先编。单独构建 App target，拷贝阶段
   会报文件不存在。
2. **构建设置写在 xcconfig 里，不写在工程文件里。** 两边的 target 都从 `Configurations/<target>/`
   取设置（daemon 在 `Configurations/LaunchDaemon/`，AppKit 工程级在
   `Configurations/RuntimeViewerUsingAppKitProject/`）。不要用 Xcode 的 Build Settings 编辑器或
   target 的 General 页改设置：它们把值写进工程文件的 target 层，盖过 xcconfig，Tuist 那边看不见。
   发版改版本号只改 `Configurations/Version.xcconfig`；daemon 的名字只在
   `Configurations/ServiceName/<配置>.xcconfig` 里。
3. **改原生工程的 target、依赖、嵌入方式或设置的提交，同批更新 Tuist 描述**
   （`RuntimeViewerUsingAppKit/Project.swift`、`Tuist/Package.swift`、`Workspace.swift`、
   `Tuist/ProjectDescriptionHelpers/LocalPackages.swift`、`Tuist.swift`），提交前 `./TuistScript.sh check`
   通过。
4. **`Tuist/Package.resolved` 与原生锁文件钉同样的版本。** `UpdatePackagesScript.sh` 更新完 Debug
   workspace 后会以它为初值重写 `Tuist/Package.resolved` 并跑 `tuist install` 核对。手动跑
   `./TuistScript.sh install` 后锁文件变了，多半是 Xcode 不对（见上文）。
5. **Tuist workspace 不用来归档或发版。**

## `check` 查什么

`./TuistScript.sh check` 先重新生成 workspace，再逐项核对，任何一项不符就以非零退出码结束并列出原因：

1. **设置的接线**（读工程文件，不编译）：原生工程里对应的 target 和 AppKit 工程级在工程文件里一项设置都
   没有；Tuist 工程的每个 target、每个配置引用的 xcconfig 与原生的相同；Tuist 在 target 层只写了已知的
   几类键（交还给 xcconfig 的 `${inherited}`、产物名、Tuist 链接依赖用的 search path 与 flags 且都以
   `$(inherited)` 开头、少数只属于 Tuist 的设置）；`RuntimeViewerServer.xcodeproj` 与 AppKit 工程的
   工程级设置有差别的键，两个载荷 target 的 xcconfig 都自己给出了值（Tuist 工程里它们处在 AppKit 的工程级
   之下）；Tuist 工程的每个 target 都带 `-ObjC`（见「已知的坑」）。
2. **本地 target 名单**：四个包的非测试 target（加 Tuist 为带资源的 target 生成的 `<包>_<target>`）与
   `Tuist.swift` 的缓存例外名单、helpers 里的名单一致；测试 target 都在测试 scheme 里；三个只给 macOS App
   用的包的 product 都声明成了 macOS；macOS 最低版本声明在 14 以下的包，测试 target 的部署版本抬到了 14.0；
   每个测试 target 都带 `-ObjC`。
3. **锁文件**：两份锁文件逐条一致。
4. **trait 宏**：按 SwiftPM 的规则从 `Tuist/Package.swift` 推算每个依赖开启了哪些 trait，凡是开启的
   trait 才定义的宏，都要在 `Tuist/Package.swift` 的 `targetSettings` 里补上（Tuist 会丢掉只以 trait
   为条件的设置）。
5. **`--build`（可选，慢）**：用两个 workspace 按 `RunScript.sh` 的参数各编一次 App，比较包内文件清单、每个
   Info.plist 的值、每个可执行文件的平台、架构、签名 identifier、entitlements 与定义的 ObjC 类（静态链接漏掉的
   代码不会让链接失败，只会在运行时出事，比的就是这个）。Catalyst helper 的插件版式不同，
   只比它的可执行文件和关键 Info.plist 键；第三方包的产物按「已知差异」一节放宽。

常见报错的意思：

| 报错 | 处理 |
|---|---|
| `… sets X in the project file` | 有人在 Xcode 里改了设置。把值挪进它说的那个 xcconfig，工程文件里删掉 |
| `Target … has no counterpart …` | 原生工程加了 target 而 `Project.swift` 没跟上（或反之） |
| `… localPackageTargetNames: X is missing` | 本地包加了 target：`Tuist.swift` 与 `LocalPackages.swift` 两处都加上 |
| 锁文件不一致 | 用原生锁文件那个 Xcode 跑 `./TuistScript.sh install`，或跑 `./UpdatePackagesScript.sh` |
| `… is missing from Tuist/Package.swift's targetSettings` | 某个依赖开启了新的 trait 宏，照 Capstone 的写法补进 `targetSettings` |
| `… lacks -ObjC` / `… leaves out N Objective-C class(es)` | 有 target 没带 `-ObjC`：新 target 走 `targetSettings`、新测试 target 进 `LocalPackages.testTargetNames` 就会带上 |
| `… needs MACOSX_DEPLOYMENT_TARGET 14.0` | 某个本地包把 macOS 最低版本降到了 14 以下：照 Core 的写法在 `localTestTargetSettings` 里给它的测试 target 抬部署版本 |

## 存放位置

`/Volumes/DerivedData` 挂载时，全部放在 `/Volumes/DerivedData/RuntimeViewer/Tuist/` 下；没挂载时放在
仓库内（`Tuist/.build/`、`DerivedData/Tuist/`，都已忽略）。`TUIST_SCRIPT_ROOT` 可以指定别处。

| 目录 | 内容 | 大小 |
|---|---|---|
| `Cache/` | Tuist 的二进制缓存与清单缓存，所有 checkout 共用（按内容寻址） | 每套配置、每个 Xcode 版本约 1.5 GB |
| `Dependencies/<checkout>/` | 依赖的 checkout 与 git 镜像，每个 checkout 一份 | 约 3.6 GB |
| `WarmScratch/<checkout>/` | 预热时的临时构建目录，每次预热前清空 | 预热期间 |
| `Work/<checkout>/` | `build` 与 `check` 的 DerivedData、`check` 的中间文件 | 视构建而定 |

`<checkout>` 是 checkout 目录名加路径的短 hash，同名的两个 worktree 不会混用。想从头来：删掉
`Dependencies/<checkout>/` 后 `install`，删掉 `Cache/` 后 `warm`。

Agent 运行时用 `TUIST_SCRIPT_ROOT=/Volumes/DerivedData/Agents.noindex/<agent>/Tuist`，并经
`queued-build` 运行脚本。

## 与原生构建的已知差异

- Catalyst helper 的插件是 framework 版式（`Versions/A`），不是平铺的 bundle；helper 按路径加载，行为不变。
- Catalyst helper 的插件在 Debug 与 Debug-arm64e 下只编当前架构（原生编全部架构）；原因见下一节。
- 模拟器载荷和插件靠 scheme 的固定顺序先编，不是 target 依赖。Xcode 会提示固定顺序已弃用，已用
  `DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING` 关掉。
- daemon 由构建阶段脚本拷进 `Contents/Library/LaunchServices/` 并重签名，原生是 Copy Files 阶段。
- 第三方包的 `.strings` 复制时不做校验，与 Xcode 自带的 SwiftPM 集成一致。
- 包的 target 是 Tuist 生成的普通 Xcode target（UIFoundation 的 Swift target 是静态库，其余默认静态
  framework），原生构建里是 SwiftPM 的产物、每个 target 整块链接。这里靠 `-ObjC` 把定义了类型、extension 或
  ObjC 类的成员都拉进来（见「已知的坑」），只剩没人引用、也不定义类型的成员不进 App；构建目录的布局也不同。
- `Tuist/Package.swift` 把三个只给 macOS App 用的本地包的 product 声明成 macOS，原生 workspace 里它们
  按包声明支持全部平台。
- **第三方包的产物形态不同**（2026-10-10 用 Xcode 27 两边各编一次 Debug、Debug-arm64e、Release 对比，自家产物全部一致，
  连每个可执行文件定义的 ObjC 类都一样，差别都在这里）：
  RxSwift 在 Tuist 里是动态 framework（`Contents/Frameworks/RxSwift.framework`），原生是静态链接、隐私清单放在
  `RxSwift_RxSwift.bundle`——这个包同时声明了一个动态 product，Tuist 因此把 target 编成动态的；第三方包资源
  bundle 的 Info.plist 由 Tuist 生成，`CFBundleIdentifier` 写法不同、多了版本号与版权两个键（代码按名字找这些
  bundle，不受影响）；第三方动态 framework 的切片与标识符也不同。`check --build` 对这三类只比是否存在，比 ObjC 类时
  把 RxSwift 的类算在它自己的 framework 里。

## 已知的坑：清单里那些看着奇怪的写法

都是为了绕开 Tuist 4.210 的行为，改之前先看这里。

- **`${inherited}` 而不是 `$(inherited)`**（`Project.swift`）：Tuist 会把含 `$(inherited)` 的值和它
  自己推导的值合并成列表（`SDKROOT` 会变成 `$(inherited) macosx`），不含时才整体替换。Xcode 对两种写法
  一视同仁。所以凡是要「交还给 xcconfig」的键都写 `${inherited}`；target 也都不传 `deploymentTargets`，
  免得 Tuist 推导部署版本。
- **生成时有两条 `PRODUCT_NAME … containing variables` 警告**：App 与 daemon 的产物名随配置变化，只能
  交给 xcconfig，警告是预期的。其余 target 直接把产物名写在 `productName` 里。
- **插件声明成 framework**：Tuist 不往 `.bundle` 里链静态库，会把插件的包依赖上提到 Catalyst helper，
  编成 Catalyst 版，插件找不到模块。
- **模拟器载荷和插件不建依赖**：Tuist 会把 App 能走到的每个动态 framework 嵌进 `Frameworks/`（不管链接
  状态），模拟器 framework 进了 macOS App 会校验失败；而开缓存后，插件那条 `status: .none` 依赖会整条
  消失。
- **`productDestinations`**（`Tuist/Package.swift`）：包没声明的平台在 SwiftPM 里算「全支持」，Tuist 给
  本地包测试 target 的平台取其依赖平台的并集。Core 的 product 因模拟器载荷要编 iOS，测试就被带上 iOS，
  又依赖着只有 macOS 的 target，于是 lint 报错。把三个只给 macOS App 用的包的 product 声明成 macOS，
  它们的测试也就只剩 macOS。
- **插件的 `ONLY_ACTIVE_ARCH = YES`（只在 Debug 两套配置）**：原生插件在 Debug 也编 x86_64。它的包依赖在这里是普通 target，只按 App 要的架构（Debug 下是当前架构）编一次；插件再要 x86_64，同一批 target 就被编成两套架构写进同一个产物目录，x86_64 的编译读到只含 arm64 的 `-Swift.h` 而失败。原生 workspace 里 SwiftPM 包会按依赖方各自特化，所以没事。
- **Core 的测试 target 部署版本抬到 macOS 14.0**（`Tuist/Package.swift` 的 `localTestTargetSettings`）：
  SwiftPM 给测试 target 的部署版本不低于 XCTest 与 Swift Testing 自身要求的版本（Xcode 26、27 都是 14.0，
  取自这两个框架的 `minos`），包声明的更低也一样；Tuist 照搬包声明的版本。Core 声明的是 10.15，测试里的
  `Duration`、`ContinuousClock`、`timeLimit` 于是全部报「only available in macOS 13.0 or newer」。其余三个包声明的是
  macOS 15，不受影响。`check` 第 2 项防它再次发生。
- **每个链接包的 target 都带 `-ObjC`**（`Project.swift` 的 `packageLinkingSettings`，`Tuist/Package.swift` 的
  `localTestTargetSettings`）：Tuist 把包编成静态库，链接器只拉被符号引用到的成员；原生的 SwiftPM 集成把每个包
  target 整块链进去。运行时按名字查找的代码因此会丢：RxCocoa 的 `DelegateProxy` 是泛型类，按名字找它的 ObjC
  父类 `_RXDelegateProxy`，类不在，realize 任何一个 `DelegateProxy` 子类都会 `abort`（测试进程在启动时把所有类
  realize 一遍，`RuntimeViewerApplicationTests` 就这样整个没跑起来）。Xcode 27 的链接器下 `-ObjC` 会拉进所有定义了
  ObjC 类或分类、Swift 类型或 extension 的成员。没用 `-all_load`：它会把部署到 macOS 10.15 的注入载荷自动链接的
  Swift 兼容静态库也整个拉进来，那是原生不做的。`check` 两层都查：静态核对查每个 target 都带这个参数，
  `check --build` 比对两边每个可执行文件定义的 ObjC 类。
- **包在 Debug-arm64e 与 Release 下都多编一个 arm64e 切片**（`Tuist/Package.swift` 的 `baseSettings`）：这两套配置里
  helper daemon 与 macOS 注入载荷是 arm64e。原生 workspace 按链接方各编一份包，Tuist 里一个包只有一个 target，
  只能让所有包都带上 arm64e，这两套配置下包的编译量因此翻倍。少了它，daemon 那一步报
  `Unable to resolve module dependency: 'RuntimeViewerService'`。
- **bridge 测试不依赖 bridge**：Tuist 不允许测试 target 依赖 bundle；测试在运行时从产物目录加载 bridge，
  由测试 scheme 顺带构建它。
- **UIFoundation 编成静态库**：同名静态 framework 会顶替 AppKit 转导出的私有 `UIFoundation.framework`，
  App 链接时 NSFont 等全部找不到。它的两个 ObjC target 按名字钉回静态 framework，否则缓存的
  xcframework 互相塞了对方的头文件。
- **`CAPSTONE_HAS_AARCH64` 手动补上**：Tuist 丢掉只以 trait 为条件的设置；不补的话 Swift 包装编不过，
  C 库能编过但没有任何架构可用。`check` 第 4 项防它再次发生。
- **预热要带 `--cache-profile development`**（`TuistScript.sh warm` 已经带上）：`tuist cache warm` 不读 `Tuist.swift`
  里的默认配置，不传就缓存一切能缓存的，包括本地包和模拟器载荷，后者在为真机构建缓存的那一轮必然失败。直接跑
  `tuist cache warm` 时别漏了这个参数。
- **`VALIDATE_STRINGS_FILES_WHILE_COPYING = NO`**：KeyboardShortcuts 2.4.0 的 `ar.lproj` 有一个未转义的
  引号，原生构建不校验所以没暴露。
