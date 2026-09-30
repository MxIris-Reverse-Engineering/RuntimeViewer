# 0028 - Catalyst helper 的图标：主图标加 CATALYST 角标

- **状态**: Implemented
- **创建日期**: 2026-09-28
- **最后更新**: 2026-09-30

## 摘要

`RuntimeViewerCatalystHelper` 一直没有图标：它的 `AppIcon.appiconset` 里只有一个不含任何图片的 `Contents.json`，所以在活动监视器、Finder（打开 App 包内容时）、隐私权限弹窗这些地方显示的是系统的空白图标。helper 是 `LSUIElement` + `LSBackgroundOnly`，不上 Dock 也不上菜单栏，但这些地方还是会露面。本提案给它做一个图标：**主 App 的图标原样照搬，右下方叠一个和 BETA 同款的黑底白字角标，写「CATALYST」**。

## 方案

- **文档**：`RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper/CatalystHelperIcon.icon`。
  - 四组图层：角标一组，下面三组与 `Resources/AppIcon.icon` 的三组逐字相同，素材也是复制过来的。
  - 顶层 `features` 与角标组的设置（折射、高光、半透、阴影、各外观的填充）照抄 `AppIconBeta.icon` 的 BETA 角标组。
  - 放在 helper 自己的同步目录（Xcode 16 起的 file-system synchronized group：目录里的文件自动归入目标）里，而不是 `Resources/`。这样不必手改 `project.pbxproj` 的文件引用，也不会被误加进主 App 目标。
- **Xcode 26 变体**：`CatalystHelperIconXcode26.icon`，由 `GenerateXcode26IconDocuments.swift` 生成（去掉 `features`），与主 App 的两对文档同一套机制。
  - helper 目标没有 xcconfig，所以选择规则写在它三套构建配置的目标级设置里：`ASSETCATALOG_COMPILER_APPICON_NAME = CatalystHelperIcon$(RUNTIME_VIEWER_CATALYST_HELPER_ICON_VARIANT_$(XCODE_VERSION_MAJOR))`，配 `RUNTIME_VIEWER_CATALYST_HELPER_ICON_VARIANT_2600 = Xcode26`。
  - 同时显式写 `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = NO`，只编选中的那一份。
  - 已用 `xcodebuild -showBuildSettings` 验证：Xcode 27 解析为 `CatalystHelperIcon`，Xcode 26.6 解析为 `CatalystHelperIconXcode26`。
- **角标**：由新脚本 `Resources/AppIconTools/GenerateCatalystBadgeLayers.swift` 生成 `CatalystLozenge.svg` 与 `CatalystWordmark.svg`。
  - 字：SF Pro 半窄体（SemiCondensed，字宽取值 -0.1）Black。Xcode 的 BETA 字标本身就是轮廓，没有可以直接引用的字体；按 BETA 的字高排「BETA」，半窄体 Black 宽 424，Xcode 原版 426，是所有组合里最接近的。脚本每次运行都会打印这组对照。
  - 尺寸：CATALYST 的字母数是 BETA 的两倍，按 BETA 的字高（136）排会宽约 840，盖住图标下半部。字高取 96，角标约 700 宽。
  - 胶囊外形：取 BETA 的外形按同比例缩小，两端圆头保持 Xcode 的原曲线，只拉长中间的直边。
  - 位置：右边缘和底边都与 BETA 对齐，贴在同一个角上，多出来的长度向左延伸；`icon.json` 里两层的平移与 BETA 相同，都是 (-33, 40)。

验证（2026-09-28）：
- 用 `ictool` 渲染了浅色、深色两种外观；在 32 pt（64 像素）下 CATALYST 仍可辨认。
- Xcode 27 构建 helper（Debug，Mac Catalyst）成功：产物的 `CFBundleIconName` 是 `CatalystHelperIcon`，`Assets.car` 里没有把 Xcode 26 变体一起编进去。
- Xcode 26.6 的 actool 能编 `CatalystHelperIconXcode26.icon`，带 `features` 的原件则报 `Could not open`，证明变体是必需的。
- 两份文档连同 `Assets.xcassets` 一起、以绝对路径交给 Xcode 26.6 的 actool，只选变体时编译正常。
  - 注意：以相对路径调用时，Xcode 26.6 的 actool 无论输入是什么都会抛 `NSPlaceholderArray` 异常且退出码为 0。手工复现时一律用绝对路径，Xcode 自己传的也是绝对路径。
- **发版校验**：`ArchiveScript.sh` 原本只检查主 App 的 `CFBundleIconName`，现在也检查内嵌 helper 的。actool 找不到图标时会静默产出一个没有图标的包，helper 同样适用。

假设（未单独确认）：
- helper 不随发布渠道变化，beta 渠道也用同一个图标；
- 代码列表沿用主 App 的 NSObject 头文件，不换成 UIKit 的。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-28 | Created as Draft | 用户：「给 CatalystHelper 也做一个图标吧」 |
| 2026-09-28 | 否决「只换主色」（紫 / 橙 / 青三种渲染过） | 用户选择「底座和主 App 相同」。另外深色外观下的背景渐变由系统决定，只换背景色的方案在深色模式下与主 App 无法区分，要靠给外环和放大镜着色来补 |
| 2026-09-28 | 采用「主图标 + CATALYST 角标」 | 用户在「整张主图标 + 角标 / 背景相同换前景 / 完全相同」中选了第一种，角标内容在 HELPER / CATALYST / iPad 外形中选了 CATALYST |
| 2026-09-28 | 角标不用 SF Symbol | SF Symbols 的许可禁止用于 App 图标 |
| 2026-09-28 | 文档放进 helper 的同步目录，不放 `Resources/` | 免去手改 `project.pbxproj`；同步目录自动归入 helper 目标，也不会被加进主 App 目标 |
| 2026-09-28 | 状态改为 In Progress | 用户确认设计后开工 |
| 2026-09-28 | 字体从窄体 Heavy 改为半窄体 Black | 第一版用窄体（condensed），渲染后 CATALYST 明显比 BETA 窄高，不像同一家族；按字宽、字重逐档量「BETA」的宽度，半窄体 Black（424）与 Xcode 原版（426）吻合 |
| 2026-09-28 | 字高从 104 改为 96 | 换成半窄体 Black 后，104 的角标宽 754，离图标两侧只剩 135，显得拥挤；并排渲染后取 96 |
| 2026-09-28 | 角标从水平居中改为与 BETA 右对齐 | 用户：「CATALYST 不要放中间，和主 App 一样往右边靠」 |
| 2026-09-28 | 状态改为 Implemented，随代码提交到 `next` | 不另写使用指南或实现说明：用法与约束已写进 `AGENTS.md` 的 App Icon 一节，生成脚本头注释记录了字体与尺寸的测量依据。没有需要进术语表的新术语 |
| 2026-09-30 | 落地编号 0028 | 已是 Implemented、实现在 `next` 上，按落地编号规则取 `origin/next` 与 `origin/main` 的全局最大值 0025 往后排；三份同批，按实现日期排序。 |
