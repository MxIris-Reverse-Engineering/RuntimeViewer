# Draft - Debug 构建的图标：主图标加 DEBUG 角标

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-24
- **最后更新**: 2026-11-24
- **所属愿景**: 无
- **关联提案**: [0020 App 图标按 Icon Composer 版本分两份文档](0020-icon-composer-document-variants.md)、[0028 Catalyst helper 的图标](0028-catalyst-helper-icon.md)
- **实现分支 / PR**: `feature/debug-app-icon`（worktree `.worktrees/RuntimeViewer-DebugAppIcon`）
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

Debug 与 Debug-arm64e 构建出来的 App（`RuntimeViewer-Debug.app`、`RuntimeViewer-Debug-arm64e.app`）改用一份新图标 `Resources/AppIconDebug.icon`：**主图标原样照搬，右下角叠一个和 BETA 同款的黑底白字角标，写「DEBUG」**。画法完全照 BETA 角标——同一个胶囊外形（两端圆头保持 Xcode 的原曲线，只按字长伸缩直边）、同样的颜色与图层组设置、同一个位置（右边缘与底边对齐 BETA）。角标的两层 SVG 由现有的 CATALYST 角标脚本生成，脚本改为按「角标预设」生成，CATALYST 的输出逐字节不变。Xcode 26 变体照 0020 的机制生成。Release 构建与 beta 渠道的图标不变。

## 动机

- 开发时常同时开着发布版 RuntimeViewer 和自己编的 Debug 版（Debug 版的 bundle 标识、产品名、helper daemon 名都已与发布版分开，见 `Configurations/RuntimeViewerUsingAppKit/Debug.xcconfig`），但两者的图标完全相同：Dock、⌘-Tab 切换器、Finder、欢迎窗口里分不出哪个是哪个，只能靠窗口标题或菜单栏的 App 名辨认。
- 现状：`Debug.xcconfig` 与 `Release.xcconfig` 都写 `RUNTIME_VIEWER_APP_ICON_BASE_NAME = AppIcon`，只有 `ArchiveScript.sh` 在 beta 渠道把它覆盖成 `AppIconBeta`。所以本地 Debug 构建一律拿到正式版图标。
- 项目里已有两个「主图标加角标」的先例：beta 渠道的 BETA（取自 Xcode 自己的图标），Catalyst helper 的 CATALYST（0028）。DEBUG 照同一套画法，三者一眼看得出是同一家族。

## 前期调研

- **图标怎么选出来**（已读）：`Configurations/RuntimeViewerUsingAppKit/Shared.xcconfig:11` 写 `ASSETCATALOG_COMPILER_APPICON_NAME = $(RUNTIME_VIEWER_APP_ICON_NAME)`；`Debug.xcconfig:30-32` 与 `Release.xcconfig:33-35` 各自定义 `RUNTIME_VIEWER_APP_ICON_BASE_NAME = AppIcon`、`RUNTIME_VIEWER_APP_ICON_VARIANT_2600 = Xcode26`、`RUNTIME_VIEWER_APP_ICON_NAME = $(RUNTIME_VIEWER_APP_ICON_BASE_NAME)$(RUNTIME_VIEWER_APP_ICON_VARIANT_$(XCODE_VERSION_MAJOR))`。`Debug-arm64e.xcconfig` 第一行 `#include "Debug.xcconfig"`，没有覆盖图标设置，所以改 `Debug.xcconfig` 一处就同时管两个 Debug 配置。`Shared.xcconfig:17` 的 `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = NO` 保证只编选中的那一份，多加文档不会让包变大。
- **Tuist 构建走同一套 xcconfig**（已读）：`RuntimeViewerUsingAppKit/Project.swift:71-83` 的 Debug / Debug-arm64e / Release 三个配置引用同名 xcconfig；资源清单在 `Project.swift:157-162`，逐个列出四份 `.icon`。
- **原生工程的资源条目**（已读）：`RuntimeViewerUsingAppKit.xcodeproj/project.xcproj:51-54`，Xcode 27 新格式，每份 `.icon` 一行 `{ "path": "<PROJECT>/../Resources/<名字>.icon", "target-membership": [ "RuntimeViewerUsingAppKit/resources" ] }`，按名字排序。本会话没有官方 Xcode MCP 与 xcodeproj MCP 可用，`xcrun xcodeproj` 的写入会改坏这个工程（不读 xcconfig、重算产品路径），所以这两行手工加。
- **BETA 角标的构成**（已读 `Resources/AppIconBeta.icon/icon.json`）：四个可见图层组，最上面一组是角标（`Beta Wordmark` + `Beta Lozenge` 两层，平移 (-33, 40)、scale 1，折射 depth 0.07 / strength 0.39，半透 0.42，阴影 neutral 1，胶囊 `#0C0C0C` 系、字白色），下面三组与 `AppIcon.icon` 相同。四组已是 actool 的上限（`Too many visible groups`），DEBUG 文档同样是四组，不超。
- **CATALYST 角标就是同一组设置换了两层 SVG**（已比对）：`CatalystHelperIcon.icon` 的角标组与 BETA 的角标组逐键比较，只有两层的 `image-name` 与 `name` 不同。
- **生成脚本**（已读 `Resources/AppIconTools/GenerateCatalystBadgeLayers.swift`）：字体是 SF Pro 半窄体（字宽 -0.1）Black，脚本自带「按 BETA 字高排 BETA 得 424、Xcode 原版 426」的对照；胶囊取 BETA 的外形按字高比例缩放，直边按字长伸缩；右边缘 929、底边 898 与 BETA 对齐。CATALYST 写死在脚本里：字 `CATALYST`、字高 96、左右留白都取 BETA 两侧的平均值 71.5（脚本注释：BETA 左 79、右 64，是给 B 的直竖笔做的视觉补偿，以圆形 C 开头的词不需要）。
- **DEBUG 的字形特征**：开头的 D 与 BETA 的 B 一样是直竖笔，所以左右留白直接用 BETA 的 79 / 64，比 CATALYST 的平均值更贴近 Xcode 原版。字母数 5，介于 BETA（4）与 CATALYST（8）之间。
- **字高还没定**（推测，待渲染）：按 BETA 的 136 排，估计字宽约 560、角标约 700 宽 × 260 高，与 CATALYST 角标一样宽但更高，可能显得过大；120 左右约 620 宽。实现第一步渲染几档给用户挑。
- **Xcode 26 变体**（已读 `GenerateXcode26IconDocuments.swift` 与 0020）：Xcode 26 的 actool 打不开带顶层 `features` 的 Icon Composer 27 文档，所以每份原件都要一份去掉 `features` 的 `…Xcode26.icon`，由该脚本生成。
- **发版校验**（已读 `ArchiveScript.sh:329-358, 417-432`）：脚本自己推一遍应得的图标名（beta 渠道 `AppIconBeta`，否则 `AppIcon`，再按 Xcode 版本加 `Xcode26`），与导出包的 `CFBundleIconName` 比对，不符就失败。脚本支持 `--configuration Debug` 做本地演练（`ArchiveScript.sh:16`），那时 xcconfig 会给出 `AppIconDebug`，而脚本仍推出 `AppIcon`，校验必然失败——所以脚本的推导要跟着加上配置这一维。
- **没有代码按名字取图标**（`git grep` 查过 `"AppIcon"`、`applicationIconImage`、`CFBundleIconName`）：只有 `ArchiveScript.sh` 与生成脚本提到图标名。欢迎窗口等处显示的是系统给的 App 图标，Debug 版自然显示 DEBUG 角标。

## 提议方案

1. **新文档 `Resources/AppIconDebug.icon`**：复制 `AppIconBeta.icon`，角标组的两层换成 `DebugWordmark.svg` / `DebugLozenge.svg`，层名改为 `Debug Wordmark` / `Debug Lozenge`；组设置、颜色、平移全部照 BETA，下面三组与素材原样保留（与 `AppIcon.icon` 相同）。
2. **角标 SVG 由通用脚本生成**：`GenerateCatalystBadgeLayers.swift` 改名为 `GenerateBadgeLayers.swift`，第一个参数选预设（`catalyst` / `debug`），第二个参数是 `.icon` 的 Assets 目录。预设只含字、字高、左右留白和文件名前缀；字体、BETA 的几何量、胶囊画法、SVG 输出全部共用。改完先用 `catalyst` 预设重新生成，确认 `CatalystLozenge.svg` / `CatalystWordmark.svg` 与已提交的逐字节相同。
3. **DEBUG 预设**：字 `DEBUG`，左右留白取 BETA 原值 79 / 64，字高在第一步渲染后由用户挑（候选 136、120、108）。
4. **Xcode 26 变体**：`GenerateXcode26IconDocuments.swift` 多生成一对 `AppIconDebug` → `AppIconDebugXcode26`。
5. **选择规则**：`Debug.xcconfig` 的 `RUNTIME_VIEWER_APP_ICON_BASE_NAME` 改为 `AppIconDebug`（`Debug-arm64e` 经 include 继承）；`Release.xcconfig` 不变。`ArchiveScript.sh` 的 beta 覆盖是命令行设置，优先级高于 xcconfig，所以 beta 渠道不论什么配置都仍是 `AppIconBeta`。
6. **两个工程都登记新文档**：`project.xcproj` 的 `files` 加两行，`Project.swift` 的 `resources` 加两行。
7. **发版校验跟上**：`ArchiveScript.sh` 的图标名推导在非 beta 渠道时按配置取基名——`Debug`、`Debug-arm64e` 取 `AppIconDebug`，其余取 `AppIcon`。
8. **文档同批更新**：`Resources/AGENTS.md`、根目录 `AGENTS.md` 的 App Icon 一节、两个 xcconfig 与 `ArchiveScript.sh` 的注释、生成脚本头注释。

### 非目标

- **Catalyst helper 不加 DEBUG 版**：它是 `LSUIElement` 后台程序，只在活动监视器、权限弹窗这类地方露面，而且 App 自己的 Catalyst 引擎已改走内嵌 XPC service、平时不会启动它。仍用 `CatalystHelperIcon`。
- **iOS、越狱版 iOS、visionOS App 不加**：它们各有自己的图标设置，不在本提案范围。
- **不改 BETA 与 CATALYST 的外观**：CATALYST 由新脚本重新生成，但输出必须逐字节相同。
- **不做「从 AppIcon.icon 自动拼出带角标的文档」的生成器**：AppIconBeta、CatalystHelperIcon、AppIconDebug 三份的下三组都是手工复制的，改共享图层要改四处。这是既有的维护方式，这里只把 AppIconDebug 加进 `Resources/AGENTS.md` 那句「要一起改」的名单。
- **不换角标颜色**：照 BETA 的黑底白字。用颜色区分 Debug 与 Beta 见「替代方案考量」。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `Resources/AppIconTools/GenerateCatalystBadgeLayers.swift` → `GenerateBadgeLayers.swift` | 移动 + 修改 | 改名；字、字高、左右留白、文件名前缀收成 `BadgePreset`，命令行第一个参数选 `catalyst` / `debug`；头注释改写，记下 DEBUG 的字高取舍与留白理由 | 同一套画法生成两种角标，避免复制一份 200 行的脚本 | 1 |
| `RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper/CatalystHelperIcon.icon/Assets/Catalyst*.svg` | 修改（只改注释） | 用新脚本重新生成：路径数据逐字节相同，文件头的 `Generated by` 注释换成新脚本名 | 证明重构没改 CATALYST；注释指向现存的脚本 | 1 |
| `Resources/AppIconDebug.icon/` | 新增 | 复制 `AppIconBeta.icon`；`icon.json` 角标两层的 `image-name` / `name` 改为 Debug；删掉 `BetaLozenge.svg` / `BetaWordmark.svg` | Debug 构建的图标 | 2 |
| `Resources/AppIconDebug.icon/Assets/DebugLozenge.svg`、`DebugWordmark.svg` | 新增 | `GenerateBadgeLayers.swift debug` 生成 | 角标两层 | 2 |
| `Resources/AppIconDebugXcode26.icon/` | 新增 | `GenerateXcode26IconDocuments.swift` 生成 | Xcode 26 的 actool 打不开原件 | 2 |
| `Resources/AppIconTools/GenerateXcode26IconDocuments.swift` | 修改 | 加一行 `generate(original: "AppIconDebug", variant: "AppIconDebugXcode26")`，头注释提到它 | 变体与原件同批生成 | 2 |
| `CatalystHelperIconXcode26.icon/Assets/Catalyst*.svg` | 修改（只改注释） | 重新生成变体时从原件复制过来，头注释随之换成新脚本名 | 变体与原件保持一致 | 2 |
| `Configurations/RuntimeViewerUsingAppKit/Debug.xcconfig` | 修改 | `RUNTIME_VIEWER_APP_ICON_BASE_NAME = AppIconDebug`；注释改为「配置与渠道两维」 | Debug / Debug-arm64e 选 DEBUG 图标 | 3 |
| `Configurations/RuntimeViewerUsingAppKit/Release.xcconfig` | 修改 | 只改注释：「every other build keeps AppIcon」改成说明 Debug 配置用 AppIconDebug | 注释与事实一致 | 3 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.xcproj` | 修改 | `files` 加 `AppIconDebug.icon`、`AppIconDebugXcode26.icon` 两行，资源成员 | actool 只认资源阶段里的文档，漏了会静默产出无图标的包 | 3 |
| `RuntimeViewerUsingAppKit/Project.swift` | 修改 | `resources` 加同样两项 | Tuist workspace 与原生工程一致，`TuistScript.sh check` 才过 | 3 |
| `ArchiveScript.sh` | 修改 | 非 beta 渠道时按 `$CONFIGURATION` 取基名（`Debug*` → `AppIconDebug`）；注释「All four」→ 六份 | `--configuration Debug` 演练时校验不误报 | 3 |
| `Resources/AGENTS.md` | 修改 | 四份 → 六份；「渠道」一维补上配置；共享图层要一起改的名单加 AppIconDebug；生成脚本改名与用法 | 规则文件与事实一致 | 4 |
| `AGENTS.md`（根目录）· App Icon 一节 | 修改 | 「four Icon Composer documents」→ 六份，点出 AppIconDebug | 同上 | 4 |
| `Documentations/Evolutions/draft-debug-app-icon.md` / `.html` | 新增 | 本提案与网页版 | 提案制 | 0 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记草案；落地时改编号 | 文档索引 | 0 / 4 |

## 架构图

图标名怎么解析（改了什么）：

```text
Configurations/RuntimeViewerUsingAppKit/
  Shared.xcconfig        ASSETCATALOG_COMPILER_APPICON_NAME = $(RUNTIME_VIEWER_APP_ICON_NAME)
~ Debug.xcconfig         RUNTIME_VIEWER_APP_ICON_BASE_NAME = AppIcon  ->  AppIconDebug
  Debug-arm64e.xcconfig  #include "Debug.xcconfig"            (inherits AppIconDebug)
  Release.xcconfig       RUNTIME_VIEWER_APP_ICON_BASE_NAME = AppIcon
  ArchiveScript.sh       CHANNEL=beta: RUNTIME_VIEWER_APP_ICON_BASE_NAME=AppIconBeta  (command line, wins)

RUNTIME_VIEWER_APP_ICON_NAME = BASE_NAME + RUNTIME_VIEWER_APP_ICON_VARIANT_$(XCODE_VERSION_MAJOR)

                             Xcode 27+         Xcode 26
  Release                    AppIcon           AppIconXcode26
  any configuration, beta    AppIconBeta       AppIconBetaXcode26
+ Debug / Debug-arm64e       AppIconDebug      AppIconDebugXcode26
```

文档与生成脚本：

```text
Resources/
  AppIcon.icon                 groups: 3 shared
  AppIconBeta.icon             groups: [Beta badge]  + 3 shared
+ AppIconDebug.icon            groups: [Debug badge] + 3 shared   (copied from AppIconBeta.icon)
+   Assets/DebugLozenge.svg  <- GenerateBadgeLayers.swift debug
+   Assets/DebugWordmark.svg <- GenerateBadgeLayers.swift debug
  AppIconXcode26.icon          <- GenerateXcode26IconDocuments.swift
  AppIconBetaXcode26.icon      <- GenerateXcode26IconDocuments.swift
+ AppIconDebugXcode26.icon     <- GenerateXcode26IconDocuments.swift
  AppIconTools/
-   GenerateCatalystBadgeLayers.swift
+   GenerateBadgeLayers.swift        presets: catalyst, debug
~   GenerateXcode26IconDocuments.swift
RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper/
  CatalystHelperIcon.icon      groups: [Catalyst badge] + 3 shared
    Assets/Catalyst*.svg     <- GenerateBadgeLayers.swift catalyst   (byte-identical)
```

## 详细设计

### 生成脚本的预设

```swift
struct BadgePreset {
    /// The word set on the badge.
    let word: String
    /// Cap height of the wordmark, in the 1024-unit viewBox.
    let capHeight: CGFloat
    /// Gap between the wordmark's ink and the lozenge's outer edge, in BETA's units: scaled by
    /// capHeight / 136 like every other BETA measurement.
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    /// Prefix of the two files written: <prefix>Lozenge.svg and <prefix>Wordmark.svg.
    let fileNamePrefix: String
}

let badgePresets: [String: BadgePreset] = [
    // Twice BETA's letters: smaller, and the averaged padding, since a round C wants no
    // optical offset for a flat stem.
    "catalyst": BadgePreset(word: "CATALYST", capHeight: 96, leadingPadding: 71.5, trailingPadding: 71.5, fileNamePrefix: "Catalyst"),
    // D opens with a flat stem like BETA's B, so BETA's own 79 / 64.
    "debug": BadgePreset(word: "DEBUG", capHeight: 120, leadingPadding: 79, trailingPadding: 64, fileNamePrefix: "Debug"),
]
```

用法：

```bash
swift Resources/AppIconTools/GenerateBadgeLayers.swift catalyst "RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper/CatalystHelperIcon.icon/Assets"
swift Resources/AppIconTools/GenerateBadgeLayers.swift debug "Resources/AppIconDebug.icon/Assets"
```

胶囊宽度 = 字的墨迹宽 + (左留白 + 右留白) × 缩放比；字的横向位置改为「胶囊左缘 + 左留白 × 缩放比 − 墨迹左缘」。左右留白相等时它与原来「墨迹在胶囊里居中」的公式在数学上相同，输出保留两位小数，CATALYST 的路径数据逐字节不变（已验证）；SVG 文件头的 `Generated by` 注释随脚本改名而变，是两份文件唯一的差异。

另有一个可选参数 `--cap-height <units>` 放在目录之后，临时覆盖预设的字高，用来在定下预设之前渲染几档对比。

脚本仍每次打印「按 BETA 字高排 BETA 的宽度 vs Xcode 原版 426」的对照，以及本次角标的墨迹与胶囊尺寸。

### `AppIconDebug.icon/icon.json`

与 `AppIconBeta.icon/icon.json` 只差四个值：

```text
"image-name" : "BetaWordmark.svg"  ->  "DebugWordmark.svg"
"name"       : "Beta Wordmark"     ->  "Debug Wordmark"
"image-name" : "BetaLozenge.svg"   ->  "DebugLozenge.svg"
"name"       : "Beta Lozenge"      ->  "Debug Lozenge"
```

### `ArchiveScript.sh` 的推导

```bash
APP_ICON_BASE_NAME="AppIcon"
if [[ "$CHANNEL" == "beta" ]]; then
    APP_ICON_BASE_NAME="AppIconBeta"
    MAIN_APP_XCODEBUILD_SETTINGS+=("RUNTIME_VIEWER_APP_ICON_BASE_NAME=$APP_ICON_BASE_NAME")
elif [[ "$CONFIGURATION" == Debug* ]]; then
    # Debug.xcconfig picks the DEBUG-badged icon, and Debug-arm64e includes it.
    APP_ICON_BASE_NAME="AppIconDebug"
fi
```

只改推导，不传覆盖：Debug 配置的图标由 xcconfig 决定，脚本独立复述一遍，两处推导对不上时归档失败，这正是现有校验的设计。

### 验证

- 渲染：`ictool` 出 `AppIconDebug.icon` 的 Default / Dark / Tinted 三种外观，512 与 64 像素各一张，与 `AppIconBeta.icon` 并排比较；64 像素（Dock 小尺寸）下 DEBUG 要可辨认。
- 字高候选 136 / 120 / 108 各渲染一张给用户挑。
- 构建（公司那台不编本工程，到 Ultra 上做）：三个配置的 `-showBuildSettings` 分别解析出 `AppIconDebug` / `AppIconDebug` / `AppIcon`；Xcode 27 与 26.6 的 actool 各自以绝对路径编 `AppIconDebug.icon` / `AppIconDebugXcode26.icon`，有图标产出；`TuistScript.sh check` 通过；Tuist workspace 编一次 Debug App，产物的 `CFBundleIconName` 是 `AppIconDebug`、`Assets.car` 里没有别的 App 图标。

## 替代方案考量

- **只换角标颜色或整张换色区分 Debug**：0028 渲染过换主色的方案，深色外观的背景渐变由系统决定，只换背景色在深色模式下与正式版分不出来。角标颜色可以换（比如橙底），但用户要求照 BETA 的画法，先保持黑底白字；渲染后若觉得 Debug 与 Beta 难分，再改胶囊颜色，只动 `icon.json` 的两个 fill。
- **复制一份 `GenerateDebugBadgeLayers.swift`**：两份脚本九成相同，以后改画法要改两处。否。
- **在 `GenerateCatalystBadgeLayers.swift` 原名上加参数**：文件名会与它的用途不符。改名的代价是 0028 里的脚本路径变成历史名字；提案是决策快照，不回头改，`Resources/AGENTS.md` 写新名字。
- **用 Xcode 原版 BETA 的 B、E 轮廓拼 DEBUG**：D、U、G 没有原版轮廓，混用两种字形会不协调。全部用 SF Pro 半窄体 Black，与 CATALYST 一致（这套字形量 BETA 宽 424，Xcode 原版 426）。
- **Debug 构建在命令行覆盖图标名**（像 beta 渠道那样）：Debug 构建大多来自 Xcode 界面和 `RunScript.sh`，没有统一的命令行入口，只能写在 xcconfig 里。

## 影响

### 用户可见变化

- 只影响自己编 Debug / Debug-arm64e 的开发者：Dock、⌘-Tab、Finder、欢迎窗口里的 App 图标带 DEBUG 角标。
- 发布版（Release）与 beta 渠道的图标不变，终端用户看不到任何变化。

### 可发现性

无需发现：构建出来就是新图标。

### 数据与配置兼容

不涉及设置、文档或缓存。系统的图标缓存可能让已经在 Dock 里的旧 Debug 版暂时显示旧图标，重新启动 App 或 Dock 后更新。

### 平台与最低版本

不变。只涉及 macOS App。

### 发布

- 不需要新的权限、entitlement 或隐私清单条目。
- Release 归档不受影响：`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = NO`，未选中的文档不进包。
- `ArchiveScript.sh` 的图标校验多认一种配置；正式发版用 Release，结果不变。公证与 Sparkle 不受影响。

## 落地步骤

1. **脚本改为预设并渲染候选**（已完成）—— 改动地图第 1、2 行
   - 行为：`catalystPresetRegeneratesCommittedLayersByteForByte`
   - 行为：`debugPresetWritesLozengeAndWordmarkIntoGivenAssetsDirectory`
   - 行为：`debugCandidatesAt136And120And108AreRenderedForReview`（候选写到 agent 临时目录，不进仓库；用户选定字高后写进预设）
   - 结果：CATALYST 两层的路径数据与已提交的逐字节相同，只有文件头注释里的脚本名随改名变了；三档候选的尺寸见决策日志
2. **新文档与 Xcode 26 变体**（已完成）—— 第 3–6 行
   - 行为：`appIconDebugDiffersFromAppIconBetaOnlyInBadgeLayers`
   - 行为：`xcode26VariantOfAppIconDebugHasNoFeaturesKey`
   - 行为：`debugIconRendersInDefaultDarkAndTintedAppearances`
   - 结果：`ictool` 渲染了原件与变体的 Default、Dark、TintedLight、TintedDark、ClearLight、ClearDark 与 design generation 26，全部正常；变体与原件只差 `features`，素材逐字节相同
3. **选择规则、工程登记与发版校验**（已完成）—— 第 7–11 行
   - 行为：`debugAndDebugArm64eResolveAppIconDebug`
   - 行为：`releaseStillResolvesAppIcon`
   - 行为：`betaChannelStillResolvesAppIconBetaInAnyConfiguration`
   - 行为：`debugBuildProductHasCFBundleIconNameAppIconDebug`
   - 行为：`archiveScriptExpectsAppIconDebugForDebugConfiguration`
   - 行为：`tuistCheckPassesWithBothNewDocuments`
   - 结果（Ultra，Xcode 27.2）：Tuist workspace 的 `-showBuildSettings` 给出 Debug、Debug-arm64e 为 `AppIconDebug`，Release 为 `AppIcon`；`TuistScript.sh check` 通过；Debug 构建成功，`RuntimeViewer-Debug.app` 的 `CFBundleIconName` 是 `AppIconDebug`，`Assets.car` 里只有它；actool 直接编 `AppIconDebug.icon`（Xcode 27.2）与 `AppIconDebugXcode26.icon`（Xcode 26.6）都产出图标；`ArchiveScript.sh` 的推导逐个配置求值，Release → `AppIcon`、beta 渠道 → `AppIconBeta`（任何配置）、Debug 与 Debug-arm64e → `AppIconDebug`。没有实际跑一次归档
4. **文档**（已完成）—— 第 12–15 行
   - 行为：`resourcesAgentsDescribesSixDocumentsAndTheConfigurationAxis`

**收尾时必须判断两件事**：

- **要不要配套专题文章**：预计不需要——用法与约束写进 `Resources/AGENTS.md`，字高与留白的取舍写进生成脚本头注释，与 0028 相同。
- **有没有引入新术语**：预计没有。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-24 | Created as Draft | 用户要求照 BETA 图标的画法，给 Debug 构建做一个带 DEBUG 角标的图标 |
| 2026-11-24 | 状态改为 Accepted | 用户批准，开始实现。功能分支从本地 `next` 切出；本地 `next` 上还有 swift-type-indexing 一线未推送的提交，提案提交只留在本地 `next`，随功能分支推送 |
| 2026-11-24 | 状态改为 In Progress | 建 worktree `.worktrees/RuntimeViewer-DebugAppIcon`，开始第一步 |
| 2026-11-24 | CATALYST 的 SVG 只有文件头注释变化 | 原计划「逐字节不变」，但生成的 SVG 头注释写着生成脚本的路径，改名后必然跟着变；路径数据逐字节相同，注释指向现存脚本更有用，所以接受这一行变化 |
| 2026-11-24 | 脚本加 `--cap-height` 参数 | 渲染候选要多次改字高，临时覆盖比反复改预设常量干净；以后调整任何角标的字高也用得上 |
| 2026-11-24 | DEBUG 字高定为 120 | 渲染了 136 / 120 / 108 三档（64 像素下都可辨认）：136 角标宽 718、盖住放大镜下半圈；108 与 BETA 同宽（570）但字明显比 BETA 小；120 角标约 634 × 229，覆盖面与 BETA 接近。用户选了推荐的 120 |
| 2026-11-24 | 实现完成，待用户看过后收尾 | 四步都已提交并推送功能分支。文档判断：不需要使用指南或实现说明，用法与约束写进了 `Resources/AGENTS.md`，字高与留白的取舍写在 `GenerateBadgeLayers.swift` 的注释里；没有新术语 |
