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

**Status (2026-06-25)：** 剩余 4 条 (TS.1 / TS.2 / TS.3 / TS.4) 均已在 commit
[`ab73a49`](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/commit/ab73a49)
`fix(theme): address TS.1-TS.4 from 2026-06-25 review` 落地。各条详见下表。

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
| **TS.1** | `ThemeDetailsView.onChange(of: draft)` 写入风暴 | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift:909`（review 当时；实际文件只有 366 行，对应位置 `:262`） | `onChange(of: draft) { _, newValue in onUpdate(newValue) }` 在每一帧 ColorPicker 拖动 / 每一字符 Name 框输入时都触发：`onUpdate` 把整个 `Preset` 写回 `Settings.theme.customPresets[index] = updated` → `Settings.theme` 整体重新赋值 → `theme.didSet { scheduleAutoSave() }` 触发持久化 → 同时 `Observable.tracking` 链路 fire → 每个打开的文档的 `ContentTextViewModel` 走全量 `combineLatest` 重渲染 attributedString。颜色拖动 1 秒可能产生 60 次写入 + 60 次 autosave 调度 + 60 次 attributedString 全量重算。在文档内容较大时主线程会明显卡顿。 | 在写回侧做合并：(a) 用 `.onChange` + Combine `debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)` 把 draft 变更去抖；或 (b) draft 改动只更新本地 `@State`，在 "Done" 按钮 / sheet 关闭时一次性 `onUpdate(draft)`；(c) 更彻底——把 ColorPicker 的 binding 从 draft 改成直接绑到 `customPresets[index]`，让 SwiftUI 自己合并连续写入（但要先解决 binding 的 index 稳定性问题）。推荐 (a) + 在 "Done" 时强制 flush。 | **Fixed by `ab73a49`** —— `onChange(of: draft)` 触发一个可取消的 `pendingFlushTask`，`Task.sleep(.milliseconds(150))` 后才回调 `onUpdate(newValue)`；下一次 draft 变化会先 `cancel()` 上一个 Task 再排队，所以连续拖颜色 / 输入名字只在停顿 150ms 后写一次。Done 按钮和 `.onDisappear` 都会 cancel 待 flush 的 Task 并立即同步 `onUpdate(draft)`，保证关闭瞬间数据已落地。 |

---

## Minor issues

| ID | Title | Where | Why | Fix | Reproduction |
|---|---|---|---|---|---|
| **TS.2** | `editingAppearance` 硬编码为 `.dark` | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift:842`（review 当时；实际位置 `:194`） | `@State private var editingAppearance: EditingAppearance = .dark` 与系统 / 列表预览的当前外观脱节。当系统在 Light 模式下，列表里的 `ThemeColorPreview` 显示的是 light 变体颜色，但用户点 "Edit…" 进入 sheet，默认编辑的却是 dark 变体——首次拖颜色改的是看不见的变体，体验割裂。 | 用 `@Environment(\.colorScheme)` 注入当前外观，并在 `init` 把 `editingAppearance` 从环境推断初值；或者直接用 `colorScheme == .dark ? .dark : .light`。注意 `@State` 初始值只能取一次，可考虑把 `editingAppearance` 提到外层 `ThemeSettingsView` 让它跟随环境绑定。 | **Fixed by `ab73a49`** —— `ThemeDetailsView.init` 新增 `initialAppearance: EditingAppearance` 入参，内部 `@State private var editingAppearance` 由 `State(initialValue: initialAppearance)` 注入。外层 `ThemeSettingsView` 注入 `@Environment(\.colorScheme)`，调用 sheet 时按 `colorScheme == .dark ? .dark : .light` 推断。`EditingAppearance` 提到 file scope，外层视图可见。 |
| **TS.3** | duplicate preset 名字不去重 | `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift:711`（review 当时；实际位置 `:64`） | `copy.name = "\(preset.name) copy"` 没有冲突检测。连续复制同一个内置 Xcode 预设两次，列表里会出现两行显示名都是 "Xcode copy"（ID 不同所以列表能正确区分，但 UI 上看到的名字完全相同），用户无法分辨。 | 在 `theme.customPresets` 里查重，冲突时追加数字后缀（`"Xcode copy 2"`、`"Xcode copy 3"`），或者改用 `"Copy of Xcode"` + 同样的去重。`SettingsRootView` / NSDocument 通常用 `Untitled`、`Untitled 2` 的惯例可以借鉴。 | **Fixed by `ab73a49`** —— 新增 `uniquePresetName(basedOn:)` 私有方法，从 `theme.allPresets`（含内置）取所有名字 → 若与基名冲突则迭代追加 ` 2 / 3 / ...` 后缀，否则直接用基名。`duplicate(_:)` 调用 `uniquePresetName(basedOn: "\(preset.name) copy")` 后再 append。 |
| **TS.4** | 工具栏字号 +/- 的 read-modify-write 没合并 | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift:139` | `input.fontSizeSmallerClick.emitOnNext { … settings.theme.fontSize = max(min, settings.theme.fontSize - 1) }` 每次点击 / 自动重复都执行完整的 read-modify-write：读 `settings.theme.fontSize` → 修改 → 写回 `settings.theme`（整体赋值）→ `theme.didSet { scheduleAutoSave() }` → `Observable.tracking` 主题流 fire → 每个文档走 `combineLatest` 重渲染。按住工具栏 +/- 按钮自动重复时，每 tick 一次全量 attributedString 重算 + 一次 autosave 调度。 | 与 TS.1 同源——在 `themeObservable` 之后接 `.debounce(.milliseconds(120), scheduler: MainScheduler.instance)` 或 `.throttle(.milliseconds(120), latest: true, scheduler: MainScheduler.instance)` 给字号 / 颜色变更去抖；或者在 `MainViewModel` 这一侧用 `.throttle(.milliseconds(120))` 合并连击。autosave 同理可以做 trailing debounce（现有 `scheduleAutoSave` 是否已经做了合并需要核查 `Settings.swift`）。 | **Fixed by `ab73a49`** —— `fontSizeSmallerClick` / `fontSizeLargerClick` 在 `emitOnNext` 前各串入 `.throttle(.milliseconds(120), latest: true)`（Signal 上的 throttle，scheduler 内置 `MainScheduler.instance`）。常量 `fontSizeThrottleMilliseconds = 120` 集中在 `MainViewModel`。按住按钮自动重复时每 120ms 才触发一次 read-modify-write，settings.theme 的整体赋值频率从 ~60Hz 降到 ~8Hz。 |

---

## Reproduction summary (2026-06-25)

| ID | Status | Evidence |
|---|---|---|
| TS.1 | **Fixed by `ab73a49`** | 拖 ColorPicker / 输入名字时 150ms 内只 flush 一次；Done / dismiss 时立即同步落地。 |
| TS.2 | **Fixed by `ab73a49`** | Light 系统下打开编辑器，分段控件初始选中 Light；Dark 系统下选中 Dark。 |
| TS.3 | **Fixed by `ab73a49`** | 连续 Duplicate 同一预设产生 `Xcode copy`、`Xcode copy 2`、`Xcode copy 3` ...。 |
| TS.4 | **Fixed by `ab73a49`** | 按住工具栏字号按钮自动重复时每 120ms 触发一次 `theme.fontSize` 写回，下游 attributedString 重算同步收敛。 |

---

## Planned fixes

**全部已修——见 commit [`ab73a49`](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/commit/ab73a49) `fix(theme): address TS.1-TS.4 from 2026-06-25 review`。**

- **TS.1 + TS.4**（写入风暴同源）：实际拆成两套独立的写回合并机制 —— TS.1 用 SwiftUI 侧的可取消 `Task` 在 150ms 静默窗后才 flush；TS.4 用 Signal `.throttle(.milliseconds(120), latest: true)`。原始建议是在 `themeObservable` 下游统一去抖，但那会延迟"系统外观切换"等期望立即生效的 theme 变更——选择在源头（draft / 字号按钮）合并更安全。
- **TS.2 / TS.3**：按 review 建议落地，均在 ThemeSettingsView 内 10 行以内的局部改动。

Review 文档中 4 条 finding 的 `Where` 列原始行号（909 / 842 / 711）来自当时的 unified diff 累积行号，实际位置在 366 行的 `ThemeSettingsView.swift` 内分别是 `:262 / :194 / :64`；保留原始行号并加括注以记录这次行号偏移现象。
