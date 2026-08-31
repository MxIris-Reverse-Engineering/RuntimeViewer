# 2026-08-31 Sidebar 过滤的大小写开关，意思和图标反着

**调查日期：** 2026-08-31
**修复落地：** 本日，见 `RuntimeViewerUsingAppKit/.../Sidebar/RuntimeObject/SidebarRuntimeObjectViewController.swift` 与 `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectViewModel.swift`
**所属分支：** `next`
**Severity：** Minor —— 搜索结果本身是对的，错的是「哪一边算开」，用户按图标的通用含义去理解就会得到相反的预期
**触发场景：** 打开任意 image，看 sidebar 过滤框右侧那个 `textformat`（"Aa"）按钮

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | "Aa" 按钮默认就是高亮（强调色）的，点一下取消高亮，搜索反而**变严格**（结果变少）。Xcode / VS Code / Safari 里同一个图标是 Match Case——高亮才是严格 |
| **影响范围** | 只有 macOS sidebar 的文本过滤。iOS 侧没有这个控件，走常量 |
| **根因** | 不是算错，是极性起错了名字：按钮的 tooltip 是 "Case Insensitive"、默认 `.on`，于是「高亮 = 放宽」。这个默认值是 2026-08 修引擎那次反转 bug 时为了保住「默认忽略大小写」而翻上去的，行为对了，语义从此和图标拧着 |
| **Status** | **Fixed** —— 按钮改成 "Match Case"、默认不选中；`FilterContext.isCaseInsensitive` 的极性不动，两者之间的取反收在 `scheduleRefilter()` 一处 |

---

## 现象

sidebar 过滤框右侧的 `textformat` 按钮，App 一启动就是强调色高亮的。用户读到的是「区分大小写已开启」，实际含义是「忽略大小写」；把它关掉才开始区分大小写，也就是**取消高亮 = 搜索更严格**。

`FilterSearchField.addFilterButton` 给每个过滤按钮统一挂了 `contentTintColor = state == .on ? .controlAccentColor : nil`，所以高亮在这个控件族里就是「该选项已生效」的意思。一个默认生效、且生效时把搜索放宽的选项，跟这套视觉语言本身也是冲突的。

---

## 根因

分两截，第二截是这次要修的。

### 一、引擎那次反转（2026-08，已修）

`FilterEngine.match` 的 plain-contains 分支曾经把 `isCaseInsensitive` 用反了：`true` 选的是**区分**大小写的 `contains`。修引擎的时候，为了让「默认忽略大小写」这个既有行为不变，把按钮默认值从 `.off` 翻成了 `.on`。

那次的收尾留在 `FilterEngineCaseSensitivityTests`：它钉的是引擎自己的语义，`isCaseInsensitive == true` 必须真的忽略大小写。

### 二、控件的极性没人钉（这次）

引擎诚实了以后，UI 这一端的名字仍然是 `isSearchCaseInsensitive`，按钮仍然叫 "Case Insensitive"，默认仍然是 `.on`。整条链是自洽的，所以任何单元测试都看不出问题——问题只在于它和这个图标在别处的含义相反。

---

## 修复

把 UI 那一端翻成通用极性，引擎那一端不动，取反只发生一次：

- 按钮：`matchCaseButton`，tooltip `"Match Case"`，默认 `.off`（不高亮）。有效默认行为不变，仍是忽略大小写。
- `Input` / `@Observed`：`isSearchCaseInsensitive` → `isSearchCaseSensitive`，`true` 表示区分大小写。
- 唯一的取反点在 `SidebarRuntimeObjectViewModel.scheduleRefilter()`：`isCaseInsensitive: !isSearchCaseSensitive`。
- iOS 侧没有这个控件，常量随之从 `.just(true)` 翻成 `.just(false)`（含义都是「忽略大小写」）。

---

## 两个容易再踩的地方

1. **常量调用方必须跟着翻。** 上一次翻转就漏了 UIKit sidebar 的那个常量，给 iOS 发了个区分大小写的搜索（PR #88 review 抓到的）。这次的两个常量调用方是 `RuntimeViewerUsingUIKit/.../SidebarRuntimeObjectViewController.swift` 和 `SidebarFilterPerformanceBaselineTests`。
2. **只有 plain contains 模式读这个开关。** `FilterEngine.match` 的 `.fuzzySearch` / `.ifrit` 两个分支完全忽略 `isCaseInsensitive`。sidebar 的默认 `appDefaults.filterMode` 是 `nil`（即 plain contains），所以平时开关是有效的；一旦切到模糊模式，这个按钮就是个点了没反应的死开关。这次没动它——要么让模糊匹配也吃这个标志，要么在非 plain 模式下把按钮置灰，是另一个决定。

---

## 验证

新增 `SidebarSearchCaseSensitivityTests`（`RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/`），从 `Input` 的 driver 一路走到 `filteredNodes`，钉住「按钮关 = 忽略大小写、按钮开 = 区分大小写」这层映射——这是引擎级测试看不见、且已经被翻转过两次的那一半。

固定数据是三行：`CaseNeedle`、`caseneedle`、`Unrelated`，所以一个完全忽略标志的实现无论默认往哪边倒都会失败。测试会先把 `appDefaults.filterMode` 置为 `nil`，否则上一次运行留下的模糊模式会让整个 suite 变成一个仍然通过的空转。

红→绿实测：把 `scheduleRefilter()` 的取反去掉（还原成翻转前的映射），两个测试全部失败；取反加回来，全部通过。

```
USING_LOCAL_DEPENDENCIES=1 swift test --scratch-path /tmp/... \
  --filter "SidebarSearchCaseSensitivity|FilterEngineCaseSensitivity|SidebarFilterFastPath|SidebarCellAppearance|SidebarFilterPerformanceBaseline"
# 18 tests in 5 suites passed
```

`RuntimeViewer macOS` 与 `RuntimeViewer iOS` 两个 scheme 均构建通过。
