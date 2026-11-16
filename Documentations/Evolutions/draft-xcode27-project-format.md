# Draft - 原生工程改用 Xcode 27 的新工程格式

- **状态**: In Progress
- **创建日期**: 2026-11-16
- **最后更新**: 2026-11-16
- **所属愿景**: 无
- **实现分支 / PR**: 未定

## 摘要

三个原生工程（`RuntimeViewerUsingAppKit`、`RuntimeViewerServer`、`RuntimeViewerUsingUIKit`）在 Xcode 27 里转成了新的
`project.xcproj` 格式。新格式是一份近似 JSON 的文本，取代 `project.pbxproj`。转换之后有几处要跟着改：
Xcode 把复制进 App 的产物按 target 名去找，所以命令行工具的 target 要改名，Tuist 描述也要随之改名；
`TuistScript.sh` 有两处直接读 `project.pbxproj`，在新格式下用不了；转换还在 target 层带进了设置；
另有几处文档要更新。

## 方案

**已完成**

- 命令行工具的 target 从 `RuntimeViewerCommandLineTool` 改名为 `runtime-viewer-cli`，与它的产物同名。新格式下，
  App 的 "Embed RuntimeViewerCLI" 阶段按 target 名去产物目录取文件，改名前报
  `The file “RuntimeViewerCommandLineTool” couldn’t be opened`。scheme 文件仍叫 `RuntimeViewerCommandLineTool`，
  所以不会出现两个叫 `runtime-viewer-cli` 的 scheme；它的 xcconfig 目录也不改名。
- `RuntimeViewerUsingAppKit/Project.swift` 跟着改名，改了三处：target 本身、App 对它的依赖、复制阶段引用的产物。
  在 Ultra 上用 xcodebuild 实测（Debug、只编 arm64、不签名）：Tuist 冷编 202 秒，原生 184 秒；空构建 Tuist 6–7 秒，
  原生 31 秒。Tuist 依赖图里有 130 个 target，原生有 545 个。
- 删掉 `runtime-viewer-cli` target 层的 `CODE_SIGN_ENTITLEMENTS`。这是 Xcode 改名时写进去的，值与 xcconfig 里的相同。
- **`TuistScript.sh` 认两种格式。** 新增 `Tuist/ReadNativeProject.py`，接口与 `plutil -convert json` 相同：给一个
  `.xcodeproj`，输出 `project.pbxproj` 那种形状的 JSON。工程里有 `project.pbxproj` 时直接交给 `plutil`；只有
  `project.xcproj` 时换算成同样形状的对象表。换算只覆盖 `check` 与导航栏重排用到的部分：工程、target、
  配置列表与配置、组、文件、同步文件夹；构建阶段、依赖、包与成员例外不在其内。`check` 的 `ProjectFile` 与
  `arrange_project_like_native` 都改为经它读原生工程，其余逻辑不动。新格式有几处要特别处理：
  - 数组和对象允许结尾多一个逗号，要先去掉，才能当作 JSON 读。
  - 引用有三种写法：按导航栏路径（`Configurations/RuntimeViewerServer/Debug.xcconfig`）、按文件夹锚点加相对路径
    （`{ "anchor": …, "relative-path": … }`）、按 `id:<标识>`。
  - 路径前缀 `<PROJECT>` 对应旧格式的 `SOURCE_ROOT`，`<PRODUCTS>` 对应 `BUILT_PRODUCTS_DIR`。产物的 `type` 写成
    `explicitFileType`；新格式不记录的文件类型，按扩展名补上，本地包补成 `wrapper`。
  - 各配置取值不同的设置写成 `KEY[config=Debug]` 这样的条件键，换算时拆回到各个配置，其余条件（如
    `[sdk=iphoneos*]`）留在键里，与旧格式的写法相同。
  - target 在 `specialized-configurations` 里没有列出的配置，换算成没有基础 xcconfig 的配置。
- **删掉转换带进来的 target 层设置**：`RuntimeViewerSimulatorServer` 上的 `ARCHS = $(ARCHS_STANDARD)`。它与默认值相同，
  `check` 会把它当作违规报出来。
- **AppKit 工程级的两条设置**：`COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS` 挪进
  `Configurations/RuntimeViewerUsingAppKitProject/Shared.xcconfig`。写死的 `DEVELOPMENT_TEAM` 直接删掉：那个 xcconfig
  里本来就有 `DEVELOPMENT_TEAM = $(RUNTIME_VIEWER_DEVELOPMENT_TEAM)`，写死的值把它盖住了，`custom.xcconfig` 里的本地覆盖
  也就失效了。
- **文档**：根 `AGENTS.md` 改了 scheme 与 target 两处说明，并写明原生工程是新格式、只有 Xcode 27 能打开；
  `Documentations/Guides/TuistDevelopment.md` 写明 `check` 与导航栏重排两种格式都认；`Configurations/AGENTS.md` 里的
  `PBXTargetDependency` 改成不依赖格式的说法。

**验证**（2026-11-16）

- 换算结果与 `next` 上的 `project.pbxproj` 逐项对照，包括 target 顺序、每个 target 每个配置的基础 xcconfig 与设置、
  工程级配置、导航栏树（每项的类型、名字、解析出的位置与文件类型）。差别只有已知的几处：target 改名、工程级两条
  设置挪走、新加的空文件夹 `RuntimeViewerCommandLineTool`，以及 UIKit 工程里一个空字典与空值的写法。
- 转换刚完成时那版工程里，`RuntimeViewerSimulatorServer` 的 `ARCHS` 会被换算成四个配置各自的 target 层设置，
  所以 `check` 能抓到这类违规。
- 在 Ultra 上用新格式的工程，从新检出跑通 `install`、`generate` 与 `check`：导航栏照原生工程排好，`check` 报
  「the Tuist description agrees with the native projects」。

**没有询问就采用的假设**

- 原生工程今后只用 Xcode 27 打开。新格式是 Xcode 27 才有的，发版用的 CI 镜像已经是 Xcode 27。
- 除 `TuistScript.sh` 外，没有别的脚本读工程文件（`RunScript.sh`、`ArchiveScript.sh`、`release.yml` 都只调 xcodebuild），
  所以不受影响。
- `main` 上的 2.x 仍是旧格式；脚本两种格式都认，在那边照常可用。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-16 | Created as Draft | 原生工程转成 Xcode 27 新格式后，App 复制命令行工具时报找不到文件，Tuist 的 `check` 与导航栏重排也读不到 `project.pbxproj` |
| 2026-11-16 | 命令行工具的 target 改名为 `runtime-viewer-cli` | 新格式下复制进 App 的产物按 target 名查找；把产物引用改成 `id:`、给 target 加 `product-name` 都实测无效，只有 target 名与产物名一致才行 |
| 2026-11-16 | 删掉 `runtime-viewer-cli` 的 target 层 `CODE_SIGN_ENTITLEMENTS` | 与 xcconfig 中的值相同，违反「构建设置只写在 xcconfig 里」的约定 |
| 2026-11-16 | `TuistScript.sh` 换算新格式，而不是改写 `check` 与导航栏重排的逻辑 | 换算成原来的对象表后，两处既有逻辑与它们的自检都不用动，旧格式也照常可用 |
| 2026-11-16 | 用户批准，状态改为 In Progress | — |
| 2026-11-16 | 换算写成独立的 `Tuist/ReadNativeProject.py`，不内联进 `TuistScript.sh` | `check` 与导航栏重排是两段各自独立的内联 Python，都要用它；独立成一个文件只写一份，接口与 `plutil` 相同，两处只换一个调用 |
| 2026-11-16 | AppKit 工程级的 `COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS` 与 `DEVELOPMENT_TEAM` 挪进工程级 xcconfig，纳入本提案 | 这两条是 11-14 写进工程文件的，`check` 在 `next` 上已经因此失败；不挪走的话，适配后的 `check` 仍然过不了 |
