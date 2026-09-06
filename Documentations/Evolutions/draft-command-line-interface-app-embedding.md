# Draft - `runtime-viewer-cli` 嵌入 App 包与设置页

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-09-06
- **最后更新**: 2026-09-06
- **所属愿景**: [无头 RuntimeViewer](../Visions/HeadlessRuntimeViewer.md)
- **关联提案**: 依赖 [draft-command-line-interface-foundation](draft-command-line-interface-foundation.md)；「允许命令行访问」开关依赖 [draft-command-line-interface-multi-source](draft-command-line-interface-multi-source.md)；[0015](0015-build-embedded-products-in-app-phase.md)（嵌入产物的教训：能做 target 依赖就不要用脚本 staging）
- **实现分支 / PR**: 待定 —— 在 `feature/command-line-interface` 上继续
- **配套文档**: 待定 —— 落地时更新 `Guides/CommandLineInterface.md`（安装方式）

## 摘要

把同一份 `RuntimeViewerCommandLineInterface` 以 Xcode command-line tool target `runtime-viewer-cli`
编进 App，随 App 签名公证，Copy Files 到 `Contents/Helpers/`。Settings 新增「Command Line Tool」
页：显示嵌入工具的路径与 `/usr/local/bin/runtime-viewer-cli` 符号链接的状态，提供 Install /
Repair / Uninstall；另有开关「Allow command-line access while the app is running」（默认开），关掉即
App 不再充当 host。

## 动机

完整动机见愿景《无头 RuntimeViewer》取舍六。这一步特有的理由：独立 SwiftPM 包要求用户自己
`swift build`，且要靠 bundle identifier 去找 App 包里的载荷；嵌进 App 包后工具随发布版一起到达
用户手里、天然知道自己所在的 App、并且与 App 同一签名。GUI 用户需要一个不开终端就能装好的入口。

## 前期调研

1. **macOS 工具可以是 target 依赖**：`AGENTS.md`「Embedded iOS-family products」说明 Catalyst helper
   与 Simulator 载荷不能成为依赖是因为它们是 iOS-family；0015 记录了用构建阶段代替依赖的代价
   （新旧判断永不命中、Release 构建从 86 s 涨到 554 s）。一个 macOS command-line tool 没有这个限制。
2. **既有 Copy Files 先例**：`project.pbxproj` 的 `Embed Catalyst Helpers`（`dstPath = ../Applications`）
   与 `Embed LaunchServices`（`dstPath = Contents/Library/LaunchServices`）。
3. **App 的 entitlements 含 `com.apple.security.cs.disable-library-validation`**
   （`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.entitlements`）。
   嵌入的工具随 App 开启 hardened runtime，若缺这一条，本地引擎 `dlopen` 第三方镜像会被库校验拦下。
4. **Settings 的持久化契约**：新持久化属性必须登记进 `Settings.accessPersistedValues()`，
   `SettingsPersistenceTests` 会逐属性验证（`AGENTS.md`「Settings Integration」）。
5. **`Bundle.main` 对 `Contents/Helpers/` 里的可执行文件不解析为 App 包**（CoreFoundation 只识别
   `Contents/MacOS/` 布局）。*推测（高置信，实现时实测）*。因此嵌入形态也走多来源提案的定位顺序
   里「从自身可执行路径向上找 `.app`」这一步，不依赖 `Bundle.main`。
6. **发布脚本**：`ArchiveScript.sh` 用 `xcodebuild -exportArchive` 导出并 `notarytool` 公证整个 App
   （:398-427）；作为 target 依赖构建的嵌套可执行文件由导出流程签名，公证覆盖嵌套代码。
   `RunScript.sh` 同理。两个脚本预期无需改动，落地时实测确认。

## 提议方案

- **Xcode**：新增 command-line tool target `runtime-viewer-cli`（product name 同名），源码只有
  `main.swift`（与 SwiftPM 可执行 target 同内容），链包产品 `RuntimeViewerCommandLineInterface`；
  entitlements 文件复制 App 的 `disable-library-validation`，不开 sandbox；App target 加 Target
  Dependency 与 Copy Files 阶段「Embed Command Line Tool」（`dstPath = Contents/Helpers`，Code Sign
  On Copy）。
- **安装器**：`App/CommandLineToolInstaller.swift`（`@MainActor`，`@Dependency` 注册），负责
  `/usr/local/bin/runtime-viewer-cli` 符号链接的状态判断、创建、修复、移除。
- **设置页**：`RuntimeViewerSettingsUI` 新增「Command Line Tool」页。
- **开关**：`Settings.commandLine.allowsAccessWhileRunning`（默认 `true`），
  `CommandLineHostController.start()` 读它决定是否绑定；运行中切换即时生效（关 → `stop()`，
  开 → `start()`）。

### 非目标

- 不把符号链接装到 `/usr/local/bin` 以外的位置；用户要别的位置自己 `ln -s`。
- 不用特权 helper 写 `/usr/local/bin`：目录不可写时退回显示可复制的 `ln -s` 命令。
- 不改 `ArchiveScript.sh` / `RunScript.sh`（预期不需要；实测若需要，改动限于确认嵌套产物存在）。

## 详细设计

### 1. 安装器

```swift
@MainActor
public final class CommandLineToolInstaller {
    public enum Status: Equatable {
        case notInstalled
        case installed(URL)                  // 链接指向本 App 内的工具
        case pointsElsewhere(URL)            // 链接存在但指向别处（旧安装位置、别的副本）
        case destinationNotWritable          // /usr/local/bin 不可写
        case embeddedToolMissing             // 本 App 包内没有工具（不完整的构建）
    }
    public var embeddedToolURL: URL? { get } // Bundle.main.bundleURL/Contents/Helpers/runtime-viewer-cli
    public func status() -> Status
    public func install() throws            // 创建或覆盖符号链接
    public func uninstall() throws
    public var manualInstallCommand: String { get } // "ln -sf '<embedded>' /usr/local/bin/runtime-viewer-cli"
}
```

目标路径与嵌入路径都可注入（`init(embeddedToolURL:destinationURL:)`），测试在临时目录里跑。

### 2. 设置页

- 状态行：嵌入工具路径；符号链接状态五种文案；按钮按状态切换 Install / Repair / Uninstall；
  `destinationNotWritable` 时显示 `manualInstallCommand` 与 Copy 按钮。
- 开关「Allow command-line access while the app is running」，副标题说明关掉后 CLI 会自己拉起独立
  host、看不到 App 里已 attach 的进程。
- 遵循 `AGENTS.md`：SwiftUI 只用于 Settings；页面走 `AppSettings` typealias；新属性登记进
  `accessPersistedValues()` 与 `SettingsPersistenceTests`。

### 3. 测试

- 安装器五种状态与 install / uninstall 在临时目录下的行为（含覆盖指向别处的旧链接）。
- 新持久化属性纳入 `SettingsPersistenceTests`。
- 开关切换驱动 `CommandLineHostController` 的 `start()` / `stop()`（对控制器打桩）。

## 替代方案考量

- **用脚本 staging + Copy Files（Catalyst helper 的做法）。** 那是 iOS-family 产物被迫的路线；
  macOS 工具能做 target 依赖，0015 的代价不必再付。
- **放 `Contents/MacOS/` 让 `Bundle.main` 直接解析为 App。** 省一步定位，但把非主可执行文件放进
  `MacOS/` 会让 `CFBundleExecutable` 之外的二进制与主程序混在一起；多来源提案已经有「向上找
  `.app`」的定位步骤，不值得为此改布局。
- **用特权 helper 写 `/usr/local/bin`。** 多数开发机上该目录对用户可写；不可写时给出命令比引入
  一条特权写文件路径更安全。
- **开关默认关。** 与愿景取舍三（App 优先）相悖：默认关等于默认两个 Bonjour 客户端。

## 影响

### 用户可见变化

- 设置窗口多一页「Command Line Tool」。
- App 包内多一个 `Contents/Helpers/runtime-viewer-cli`。

### 可发现性

设置页是 GUI 内的入口；README「Command Line Interface」一节补「从 Settings 安装」的路径。开关
默认开，理由见替代方案末条。

### 数据与配置兼容

Settings 新增一个键，旧 `settings.json` 缺键时按默认值处理（现有解码已容忍缺键）。
`/usr/local/bin` 的符号链接指向 `/Applications/RuntimeViewer.app/...`，升级不失效；用户移动 App
后失效，设置页识别为 `pointsElsewhere` 并提供 Repair。

### 平台与最低版本

macOS 15+，仅 macOS。

### 发布

- 新增一个随 App 签名的嵌套可执行文件，entitlements 复制 App 的 `disable-library-validation`；
  不访问受保护资源，无新隐私清单条目。
- 公证自动覆盖嵌套代码；Sparkle 增量只是包体积多几 MB。落地时用 `ArchiveScript.sh` 本地归档一次
  确认公证不被嵌套可执行文件卡住。

## 落地步骤

1. Xcode tool target、entitlements、Target Dependency、Copy Files 阶段。`RunScript.sh` 产物内
   `Contents/Helpers/runtime-viewer-cli` 存在且 `codesign -dv` 显示与 App 同一签名；直接运行它能
   `interface NSObject --image /usr/lib/libobjc.A.dylib`（验证 `disable-library-validation` 生效
   要再加载一个非 Apple 签名的 dylib）。
2. `CommandLineToolInstaller` 与测试。
3. 设置页、新持久化属性、两处登记、开关接到 `CommandLineHostController`。
4. 文档：指南「安装」一节、README、`AGENTS.md` Build Schemes 加新 target。
5. 验证：Settings 安装后 `which runtime-viewer-cli` 指向嵌入工具；关闭开关后 `host status` 由
   `application` 变为独立 host；`ArchiveScript.sh` 本地 Release 归档通过公证。

**收尾时必须判断**：配套文档——指南更新即是；术语表——不引入新术语。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-09-06 | Created as Draft | 从单篇草案「RuntimeViewer 命令行工具」拆出，用户要求分 3-4 个提案 |
| 2026-09-06 | 嵌入 App 包与独立包都要 | 用户选定（愿景取舍六） |
| 2026-09-06 | 放 `Contents/Helpers/`，设置页做 `/usr/local/bin` 符号链接，开关默认开 | 用户在收尾确认轮确认 |
