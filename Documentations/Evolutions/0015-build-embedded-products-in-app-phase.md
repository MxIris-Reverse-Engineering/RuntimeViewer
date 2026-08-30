# 0015 - 让主 App 的构建阶段自己产出嵌入的 iOS-family 产物

- **状态**: Withdrawn
- **作者**: JH
- **创建日期**: 2026-08-29
- **最后更新**: 2026-08-30
- **所属愿景**: 无
- **关联提案**: [0014](0014-inject-ios-simulator-process.md)（它引入了第二个需要预先构建的 iOS-family 产物）
- **实现分支 / PR**: `next`
- **配套文档**: 无（撤回时已把 `CLAUDE.md` 的对应段落改回手动预建的说明）

> **本提案已于 2026-08-30 撤回，构建阶段已从 `project.pbxproj` 删除。** 下面的方案与决策日志
> 保留原样，作为「这条路走过、代价是什么」的记录。撤回理由见文末「撤回记录」。

## 摘要

主 App 嵌入两个非 macOS 产物 —— `RuntimeViewerCatalystHelper`（Mac Catalyst）与
`RuntimeViewerMobileServer` 产出的 iOS Simulator 注入载荷。两者都不能作为 target dependency，
Xcode 会把它们当 iOS-family 嵌入内容、直接拒绝进 macOS app target。此前只有 `RunScript.sh` /
`ArchiveScript.sh` 按正确顺序预先构建了它们；在 Xcode GUI 里直接构建主 App 的人必须自己记得先
建一遍，忘记的代价是拿到过期产物，且**没有任何提示**——排查成本远高于重建成本。

本提案给主 App 加一个 **Build Embedded iOS-Family Products** 构建阶段，用嵌套的顶层
`xcodebuild` 把两者建好并拷到现有嵌入阶段已经在找的位置。GUI 从此只需构建主 App。

## 方案

阶段排在主 App `buildPhases` 的**最前面**，`alwaysOutOfDate = 1`（自己做新旧判断，不走 Xcode 的
输入输出依赖分析）。它做三件事：

1. **判新旧**：产物不存在，或任一输入目录里有比产物更新的文件，才重建。输入是精确的依赖闭包，
   不是整个仓库：
   - helper ← 自身源码、`RuntimeViewerCatalystHelperPlugin` 源码，以及该 plugin 链接的
     `RuntimeViewerCore/Sources` 与 `RuntimeViewerPackages/Sources/RuntimeViewerCatalystExtensions`
     （helper 自身的 `Frameworks` 阶段是空的，没有任何 SPM 依赖）
   - 载荷 ← `RuntimeViewerServer/RuntimeViewerServer` 源码与 `RuntimeViewerCore/Sources`
     （`RuntimeViewerUtilities` 也在 `RuntimeViewerCore/Sources` 之下，已被覆盖）
2. **建**：`env -i` 干净环境 + 独立 DerivedData（详见决策日志）。
3. **拷**：`rm -rf` 后 `ditto` 到 `${BUILD_DIR}/${CONFIGURATION}-{maccatalyst,iphonesimulator}/`，
   也就是既有的 `Embed Helpers` / `Embed iOS Simulator Payload` 阶段已经在找的位置。**那两个阶段
   不动。**

两者的失败语义不同，与既有约定一致：helper 构建失败即中断（`set -e`），因为它是必需的；载荷失败
只打 warning 并删掉过期产物，因为缺它只是模拟器注入不可用。

`RunScript.sh` / `ArchiveScript.sh` 仍在主 App 之前构建这两个产物，用的是同一个 DerivedData，
所以脚本路径下新旧判断直接命中「已是最新」，本阶段什么都不做，不会重复构建。

## 决策日志

方案里三个约束都是实测出来的，不是推断的。记录在此，因为它们看起来都像可以省掉的复杂度。

**为什么不能把 helper 加进主 App 的 scheme。** 试过：把 helper 与主 App 一起列进
`BuildActionEntries`、关掉并行、destination 给 `platform=macOS`。两个 target 都构建了、没有任何
平台报错，但 helper 的产物落在 `Debug-iphoneos/` —— Xcode 在 macOS destination 下把它编成了 iOS
设备版，而嵌入阶段要的是 `Debug-maccatalyst/`。**这比不构建更危险**：看起来成功，却给出错平台的
产物。一次构建只有一个 destination，而两者需要的 destination 不同，scheme 这一层解决不了。

**为什么必须 `env -i`。** 嵌套 `xcodebuild` 会继承外层 Xcode 注入的构建环境，`PRODUCT_NAME` 之类
使每个 SPM target 都以为自己在产出主 App：

```
error: Multiple commands produce '.../RuntimeViewer-Debug.app/Contents/MacOS/__preview.dylib'
    note: Target 'AssociatedObject' (project 'AssociatedObject') has link command with output ...
    note: Target 'ApplicationsServiceInterface' (project 'swift-helper-service') has link command ...
```

加 `env -i` 后冲突计数从 2 降到 0。`DEVELOPER_DIR` 要显式转发，否则嵌套构建会退回到
`xcode-select` 指向的 Xcode，可能与当前这次构建用的不是同一个。

**为什么必须用独立 DerivedData。** 这条没有回旋余地。环境干净之后，共用 DerivedData 的失败变成：

```
".../Build/Intermediates.noindex/XCBuildData/build.db": database is locked
Possibly there are two concurrent builds running in the same filesystem location.
```

外层构建正握着这个锁。这也解释了为什么本阶段不能照抄 `RunScript.sh`：脚本跑的是两次**先后独立**
的顶层构建，任何时刻只有一个持锁；构建阶段则是在外层构建**运行途中**再嵌一个，时序上必然相撞。

**独立 DerivedData 的代价**。以下数字均在仓库的实际配置下测得，即
`COMPILATION_CACHE_ENABLE_CACHING` 与 `SWIFT_ENABLE_EXPLICIT_MODULES` 都为 `YES`：

| 场景 | 耗时 |
|---|---|
| 全新 DerivedData 首次构建 helper | 88 秒 |
| 全新 DerivedData 首次构建载荷 | 50 秒 |
| helper 改动后重建 | 35 秒 |
| 两者均未改动（日常绝大多数构建） | ~0 秒 |

**不要把编译缓存当成这套方案便宜的理由。** 起初有过这个论断，实测不成立：把这两项关掉再测，
helper 的冷启动是 52 秒，比开启时的 88 秒**更快**——explicit modules 首次要建自己的模块缓存，
第二个 DerivedData 得从头付这笔钱。真正让日常构建不痛的是下面的新旧判断，不是缓存。首次那
一分半是一次性成本。

**为什么要新旧判断。** 没有它，每次构建主 App 都要白付一次嵌套 `xcodebuild` 的钱——即便什么都
没改，进程启动与重新解析 package graph 也跑不掉。有了它，日常构建的开销是 0。

**为什么 `ditto` 前要 `rm -rf`。** `ditto` 不会删除目标里存在而源里没有的文件，重命名或删除过的
文件会在旧 bundle 里残留。既有的 `Embed iOS Simulator Payload` 阶段正是这么做的，此处保持一致。

**被否决的备选：scheme 的 Build Pre-action。** 它在外层构建开始**之前**运行，时序上等价于
`RunScript.sh`，因此可以共用 DerivedData、不必重复一份依赖构建。否决它的原因是失败语义：
pre-action 失败**不会**中断构建，而本提案要解决的痛点恰恰是「产物不对但没人告诉你」。构建阶段
失败会直接让构建变红，输出也进主 build log。此外 `xcodebuild` 根本不执行 pre/post action，只有
GUI 会，这让它无法被命令行验证。

## 影响

- **用户可见变化**：无。仅影响开发者构建流程。
- **GUI 构建**：不再需要手动预先构建 helper；首次构建多 ~2.3 分钟（helper 88 秒 + 载荷 50 秒），
  改动 helper 后多 ~35 秒，其余情况 ~0 秒。
- **命令行构建**：不受影响，`RunScript.sh` / `ArchiveScript.sh` 路径下本阶段直接跳过。
- **磁盘**：多一个 `NestedProductsBuild` DerivedData 目录。
- **维护约束**：helper 的依赖闭包一旦变化（例如它开始链接新的 SPM 包），新旧判断的输入列表必须
  同步更新，否则会重现「改了却没重建」这一类问题——正是本提案要消灭的那一类。

## 撤回记录

**日期**: 2026-08-30 · **决定人**: JH

撤回，构建阶段整个从 `project.pbxproj` 删除。GUI 构建从此**不再**代为产出这两个产物：没有模拟器
载荷就不嵌入（`Embed iOS Simulator Payload` 阶段本就是 warning 后 `exit 0`，行为不变），要连同
载荷一起测就跑 `RunScript.sh`。

两个理由：

1. **代价太高。** 嵌套 `xcodebuild` 用的是独立 DerivedData，冷启动时实测把一次 Release 构建从
   86 秒拖到 554 秒。方案里估的「首次多 ~2.3 分钟、其余 ~0 秒」低估了它——新旧判断只在产物落在
   本次构建的 `BUILD_DIR` 时才命中，而换一个 DerivedData 就等于每次都是首次。

2. **helper 那一半从来没有生效过。** 阶段把 helper 拷到
   `${BUILD_DIR}/${CONFIGURATION}-maccatalyst/RuntimeViewerCatalystHelper.app`，而
   `Embed Catalyst Helpers` 拷的是另一个文件引用——`sourceTree = "<group>"` 的
   `SRCROOT/RuntimeViewerCatalystHelper.app`，也就是 `ArchiveScript.sh` 的 `-exportArchive`
   输出位置。两者是 `project.pbxproj` 里不同的 `PBXFileReference`
   （`BUILT_PRODUCTS_DIR` 那个是 helper target 自己的 `productReference`，嵌入阶段不用它）。
   删掉阶段后 helper 照样嵌进去了，这正是它一直没起作用的证据。

方案与决策日志里那三个约束（`env -i`、独立 DerivedData、失败语义）仍然成立，只是不再有代码依赖
它们。谁将来再想自动化这件事，先读它们，别重新踩一遍。
