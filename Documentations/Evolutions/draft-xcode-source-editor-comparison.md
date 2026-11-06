# Draft - Debug 版换用 Xcode 26.6 原版 SourceEditor，与重建版对照

- **状态**: Accepted
- **实现分支**: `feature/xcode-source-editor-comparison`
- **创建日期**: 2026-11-06
- **最后更新**: 2026-11-06

## 摘要

[0072](0072-reconstructed-source-editor.md) 之后，内容面板只用随 App 带上的重建版 SourceEditor，再也看不到 Xcode 原版的表现，没法拿两者对照。本提案给开发者一条路：同一个 Debug 版 App，启动时让 dyld 改从 Xcode 26.6 加载四个原版框架，桥接层不用改；可以和正常启动的实例同时开着，左右对比。Release 版用不了，设置界面里也看不到，不对外公开。

## 方案

**一、为什么换框架就够了，不用恢复旧的运行时加载**
- Xcode 26.6 的四个原版框架（`SourceEditor`、`SourceModel`、`SourceModelSupport`、`_CodeCompletionFoundation`）只互相依赖，安装名与重建版相同，都是 `@rpath/<名字>.framework/Versions/A/<名字>`（`otool -L`）。
- 现在的桥接 framework 从这四个框架引用 225 个符号，Xcode 26.6 的原版全部导出（在 Ultra 上用 `nm -um` 比对 `nm -gU`，桥接取自 2026-11-06 的 Debug 构建）。同一份桥接换上原版就能装上。
- dyld 加载 framework 时先查 `DYLD_FRAMEWORK_PATH`，再查 rpath（[模块规则](../../RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md)「Tests and debug runs」一条）。所以只要让这个变量指向只放这四个原版框架的目录，App 就会加载原版，不加载 `Contents/Frameworks` 里的重建版。
- 0009 时代的接口桩、运行时加载的桥接 bundle、Xcode 选择器都不恢复：它们是为了「不链接也能编」，现在桥接已经直接对着同一套接口编译。

**二、启动脚本 `LaunchWithXcodeSourceEditorScript.sh`**
- 参数：`--xcode <Xcode.app>`，不给就在已安装的 Xcode 里找 26.6；`--app <RuntimeViewer.app>`，不给就用 `RunScript.sh` 的产物；`--dry-run` 只打印要做什么。
- 只认 26.6：Xcode 的 `CFBundleShortVersionString` 不是 26.6 就报错退出。重建版对应的就是这一版。27 的原版少 3 个桥接要用的符号，桥接装不上。
- 启动前检查：
  - 四个框架都在。
  - 再比对一次符号，App 里桥接引用的符号原版缺哪个就列出来、退出，不让 dyld 在启动时才崩。
  - 确认 App 能被调试（签名带 `get-task-allow`）或者没签名；发版签名的 App 会忽略这个变量，照样加载重建版，所以拒绝它。
- 在临时目录里放四个指向 Xcode 里原版框架的符号链接，只放这四个：直接指向整个 `SharedFrameworks` 的话，里面同名的别的框架也会被换掉。
- 带着 `DYLD_FRAMEWORK_PATH` 另起一个实例（`open -n`），然后看这个进程实际映射的是哪一份 `SourceEditor`，打印出来；不是原版就报错。

**三、App 里看得到当前用的是哪一份**
- `SourceEditorFrameworks` 加回 0072 删掉的 `loadedFrameworksDirectory()`（扫 dyld 已加载的镜像，找 `SourceEditor.framework/Versions/A/SourceEditor`），再把目录归成三类：App 自带的重建版、某个 Xcode 的原版（带版本号）、其他位置。
- Settings › Developer（只有 Debug 版有这一页）加一节 SourceEditor，写明当前加载自哪里、怎么换成原版；不受这一页的总开关影响，因为它只是显示。
- 测试：归类逻辑放进 `RuntimeViewerSettingsTests`。

**四、文档**
- 模块规则（`RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`）加一节「与 Xcode 原版对照」，根 `AGENTS.md` 的构建命令里加一行。

**没问就采用的假设**
- 两个实例共用同一份设置文件，后启动的那个会接管命令行工具的 host 和 MCP 桥。拿来对照没有影响，文档里写明。
- 窗口里不加标记；分不清两个窗口时，看 Developer 页或脚本的输出。
- 验证在 Ultra 上做：
  - 编 Debug 版 App，用临时签名模拟开发签名（hardened runtime 加 `get-task-allow`），用脚本启动，确认加载的是原版，再退出。这会在 Ultra 的屏幕上开一次 App。
  - 再用不带 `get-task-allow` 的签名确认脚本会拒绝。

## 决策日志
| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-06 | Created as Draft | 用户要在 RuntimeViewer 里重新用上 Xcode 原版 SourceEditor，与重建版对照，只给自己用、不对外公开 |
| 2026-11-06 | 用启动脚本换框架，不恢复 0009 的运行时加载；放进 `next`，只在 Debug 版可用；只支持 Xcode 26.6 | 用户在三个选项里都选了推荐的做法：换框架不用改桥接，两个实例能同时开；26.6 与重建版同一版本，符号全部对得上，27 少的符号要另改桥接 |
| 2026-11-06 | 用户批准，状态改为 Accepted，开始实现 | 照方案与假设执行，包括在 Ultra 上启动一次 App 确认加载的是原版 |
