# 2026-06-25 Theme Settings Panel Review Findings

**Review date:** 2026-06-25
**Branch reviewed:** `feature/theme-settings-panel` @ PR [#80](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/pull/80)
**Method:** `/code-review` (medium effort, 3+5 angles × 6 candidates × 1-vote verify)
**Scope:** 12 files changed since `main`, 862 insertions / 91 deletions

本轮 review 共产出 6 条 findings，其中 2 条（`themeObservable` 泄漏 + 双订阅）已在 commit
[`be18ee8`](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/commit/be18ee8)
（`feat(architecture): bridge Apple Observation framework to RxSwift`）一并修掉
——通过新增 `Observable.tracking { ... }` 桥接 + `.share(replay: 1, scope: .whileConnected)`。
剩余 4 条都集中在 Theme 设置面板 UI 层 + 工具栏字号控件，本文档跟踪它们。

## 概览

| Class | Count | Notes |
|---|---:|---|
| Major（追踪在此） | 1 | 颜色拖动 / 命名输入时的写入风暴，触发全量 re-render + autosave |
| Minor（追踪在此） | 3 | 初始变体选择、名称去重、字号 read-modify-write 合并 |

## 使用说明

- 每条 finding 有稳定 ID `TS.<N>`，便于在 commit 信息里引用（`fix(TS.1): …`）。
- "Reproduction" 列描述触发场景；当前阶段都不需要构造单元测试，手动验证即可（标 **Manual**）。
- 修复落地后，在对应行追加 `Fixed by <commit>`，**不要**删除条目，保留历史。

---

## Major issues

| ID | Title | Where | Why | Fix | Reproduction |
|---|---|---|---|---|---|
| **TS.1** | `ThemeDetailsView.onChange(of: draft)` 写入风暴 | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift:909` | `onChange(of: draft) { _, newValue in onUpdate(newValue) }` 在每一帧 ColorPicker 拖动 / 每一字符 Name 框输入时都触发：`onUpdate` 把整个 `Preset` 写回 `Settings.theme.customPresets[index] = updated` → `Settings.theme` 整体重新赋值 → `theme.didSet { scheduleAutoSave() }` 触发持久化 → 同时 `Observable.tracking` 链路 fire → 每个打开的文档的 `ContentTextViewModel` 走全量 `combineLatest` 重渲染 attributedString。颜色拖动 1 秒可能产生 60 次写入 + 60 次 autosave 调度 + 60 次 attributedString 全量重算。在文档内容较大时主线程会明显卡顿。 | 在写回侧做合并：(a) 用 `.onChange` + Combine `debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)` 把 draft 变更去抖；或 (b) draft 改动只更新本地 `@State`，在 "Done" 按钮 / sheet 关闭时一次性 `onUpdate(draft)`；(c) 更彻底——把 ColorPicker 的 binding 从 draft 改成直接绑到 `customPresets[index]`，让 SwiftUI 自己合并连续写入（但要先解决 binding 的 index 稳定性问题）。推荐 (a) + 在 "Done" 时强制 flush。 | **Manual.** 打开任一较大的源码文档（如 1k+ 行的 `.h`），进入 Theme 编辑器，按住 ColorPicker 拖动 1–2 秒，观察主线程 hang / FPS 下降；或在 Instruments Time Profiler 里抓 `attributedString(for:)` 的调用频率。 |

---

## Minor issues

| ID | Title | Where | Why | Fix | Reproduction |
|---|---|---|---|---|---|
| **TS.2** | `editingAppearance` 硬编码为 `.dark` | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift:842` | `@State private var editingAppearance: EditingAppearance = .dark` 与系统 / 列表预览的当前外观脱节。当系统在 Light 模式下，列表里的 `ThemeColorPreview` 显示的是 light 变体颜色，但用户点 "Edit…" 进入 sheet，默认编辑的却是 dark 变体——首次拖颜色改的是看不见的变体，体验割裂。 | 用 `@Environment(\.colorScheme)` 注入当前外观，并在 `init` 把 `editingAppearance` 从环境推断初值；或者直接用 `colorScheme == .dark ? .dark : .light`。注意 `@State` 初始值只能取一次，可考虑把 `editingAppearance` 提到外层 `ThemeSettingsView` 让它跟随环境绑定。 | **Manual.** 系统切到 Light 模式，进入 Settings → Theme → 复制 Xcode 预设 → Edit，观察分段控件默认选中 Dark 而非 Light。 |
| **TS.3** | duplicate preset 名字不去重 | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift:711` | `copy.name = "\(preset.name) copy"` 没有冲突检测。连续复制同一个内置 Xcode 预设两次，列表里会出现两行显示名都是 "Xcode copy"（ID 不同所以列表能正确区分，但 UI 上看到的名字完全相同），用户无法分辨。 | 在 `theme.customPresets` 里查重，冲突时追加数字后缀（`"Xcode copy 2"`、`"Xcode copy 3"`），或者改用 `"Copy of Xcode"` + 同样的去重。`SettingsRootView` / NSDocument 通常用 `Untitled`、`Untitled 2` 的惯例可以借鉴。 | **Manual.** 在 Theme 设置里连续点同一行的 `⋯` → Duplicate 两次，观察列表里两行名字相同。 |
| **TS.4** | 工具栏字号 +/- 的 read-modify-write 没合并 | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift:139` | `input.fontSizeSmallerClick.emitOnNext { … settings.theme.fontSize = max(min, settings.theme.fontSize - 1) }` 每次点击 / 自动重复都执行完整的 read-modify-write：读 `settings.theme.fontSize` → 修改 → 写回 `settings.theme`（整体赋值）→ `theme.didSet { scheduleAutoSave() }` → `Observable.tracking` 主题流 fire → 每个文档走 `combineLatest` 重渲染。按住工具栏 +/- 按钮自动重复时，每 tick 一次全量 attributedString 重算 + 一次 autosave 调度。 | 与 TS.1 同源——在 `themeObservable` 之后接 `.debounce(.milliseconds(120), scheduler: MainScheduler.instance)` 或 `.throttle(.milliseconds(120), latest: true, scheduler: MainScheduler.instance)` 给字号 / 颜色变更去抖；或者在 `MainViewModel` 这一侧用 `.throttle(.milliseconds(120))` 合并连击。autosave 同理可以做 trailing debounce（现有 `scheduleAutoSave` 是否已经做了合并需要核查 `Settings.swift`）。 | **Manual.** 按住工具栏的字号缩小 / 放大按钮 1–2 秒，观察 Instruments Time Profiler 里 `attributedString(for:)` 的调用频率，或在 `MainViewModel.swift:139` 处加 `#log` 看每秒触发次数。 |

---

## Reproduction summary (2026-06-25)

| ID | Status | Evidence |
|---|---|---|
| TS.1 | Manual | 拖 ColorPicker 时主线程 hang；Time Profiler 中 `attributedString(for:)` 频次飙升。 |
| TS.2 | Manual | Light 系统下打开编辑器，分段控件停在 Dark。 |
| TS.3 | Manual | 连续 Duplicate 同一预设，列表行名重复。 |
| TS.4 | Manual | 按住工具栏字号按钮，每 tick 触发完整重渲染。 |

---

## Planned fixes

无排期。TS.1 + TS.4 同源（写入风暴 → 全量 re-render），建议合并为一次「设置变更去抖」的修复一并处理；TS.2 / TS.3 可独立落地，工作量都在 10 行以内。
