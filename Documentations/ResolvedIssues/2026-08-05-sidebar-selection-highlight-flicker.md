# 2026-08-05 从 Inspector 跳转时 sidebar 选中高亮闪烁

**调查日期：** 2026-08-05
**修复落地：** 本日，见 `SidebarRuntimeObjectViewController.swift` / `SidebarRuntimeObjectListViewController.swift` / `StatefulOutlineView.swift` / `InspectorRelationshipsViewController.swift` / `InspectorSwiftSpecializationViewController.swift`
**Severity：** Minor —— 纯视觉问题，但每次从 Inspector 跳转都发生
**触发场景：** 用户反馈 —— "点击了 inspector 里的 RuntimeObject，sidebar 滚动到对应地方时候也闪烁了"

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 从 Inspector 点一个关联类型跳过去，sidebar 滚到目标行的过程中选中高亮会闪一下 |
| **根因** | 两个独立成因叠加：① 选中先于滚动，高亮和滚动结果落在不同帧；② 点击让 Inspector 列表接管了键盘焦点，sidebar 选中条被画成未激活的灰色，50 ms 后焦点又自己回来了 |
| **Status** | **Fixed** —— 先滚动后选中；Inspector 的导航列表不再接管 first responder |

---

## 诊断方法（这是本篇最该复用的部分）

前两轮都是**看代码推断**，两次都改错了方向。真正定位靠的是把用户的录屏拆成帧来量：

1. 用 AVFoundation 的 `AVAssetReader` 逐帧导出（**不是**按时间点采样 —— 采样密度不够会直接错过只有一两帧的瑕疵）。
2. 对相邻帧做逐像素 diff，输出「变化像素数 + 变化区域的 y 范围 + 连续变化行带」。
3. 只看变化量突增的那几帧。

第 3 步给出的东西是推断给不了的：**哪些像素在哪一帧变了**。本例中：

| 帧 | 时间 | 变化 |
|---|---|---|
| 019 | 0.365s | —— |
| 020 | 0.382s | 30904 px，全部集中在 y 785–833 一条带 |
| 021 | 0.398s | 0 px |
| 022 | 0.432s | 142378 px，跨 y 94–1525 |

一眼可读：帧 020 只有选中行那一条带变了（列表内容、Content 面板都没动）→ 这不是滚动，是**高亮自己变色**；然后停了 50 ms；帧 022 才整体滚动 + 新行高亮。

脚本留在会话 scratchpad 里，需要时重写即可，逻辑就是上面三步。

---

## 根因

### 一、选中先于滚动（第一段闪烁）

原代码：

```swift
outlineView.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
guard !outlineView.visibleRowIndexes.contains(row) else { return }
outlineView.box.scrollRowToVisible(row, animated: false, scrollPosition: .centeredVertically)
```

`NSOutlineView` 只在行被滚进可视区时才实体化它的 row view，而选中发生在行还不存在的时候。加之 `box.scrollRowToVisible` 是直接改 clip view 原点、绕过了 outline view 自己的行预备，滚动结果与高亮结果落在了不同帧上：目标行被画出来的那一帧带着未激活的灰色高亮，下一帧才翻成主题色。

把顺序倒过来（先滚动、强制一次 layout、再选中），两者就在同一帧完成。改后录屏确认：帧 022 上滚动到位与主题色高亮是同一帧。

### 二、点击让焦点离开了 sidebar（第二段闪烁）

倒序修完后仍有一段：帧 020 上 NSPanel 的高亮由主题色变灰，列表内容一点没动。这是 AppKit 的标准行为 —— `NSTableRowView.isEmphasized` 在所属 table view 不是 first responder 时为 false，选中条改用未激活的灰色。

点击 Inspector 的关联类型列表，那个 `NSTableView` 顺手接管了 first responder，于是 sidebar 的选中条立刻变灰；50 ms 后新选中落定时（帧 022）又是主题色 —— 说明**焦点最终回到了 sidebar，跟点击前完全一样**。也就是说这是一次无意义的焦点往返，代价是用户正盯着的那一行灰了三帧。

Inspector 的 Subclasses / Conforming Types 和 Specializations 都是「点一下就跳走」的导航列表，键盘焦点在里面没有任何作用对象。给它们设 `refusesFirstResponder = true` 后焦点不再移动，灰色消失。鼠标点击、行选中、`itemClicked` 均不受影响。

---

## 后续（2026-08-06）：Inspector 自己那一帧灰色高亮

上面第二条修的是**别人**（sidebar）被连累变灰。修完之后，Inspector 列表**自己**还会闪一下：点中的那一行会以未激活灰色画出来一帧，然后整个面板被导航后的新内容替换掉。

同样是逐帧量出来的。用户 4.48 s 的录屏共 183 帧，全程只有**第 100 帧**（pts 2.450 s → 2.467 s，正好一帧 16.7 ms）出现高亮：

| 帧 | 时间 | Inspector 内容 | 点中行 |
|---|---|---|---|
| 099 | 2.417s | Conforming Types / `_NSQuickActionTouchBarPicker` | 无高亮 |
| 100 | 2.450s | 同上 | **`srgb(60,60,60)` 灰色高亮** |
| 101 | 2.467s | 已换成 Subclasses | 无高亮 |

高亮取色是中性灰而非主题强调色（该配色下 `selectedContentBackgroundColor` = `srgb(39,93,96)` 青色），说明 `refusesFirstResponder` 起作用了 —— 表格确实没拿到 first responder，所以画的是未激活色。

**关键点：`refusesFirstResponder` 只挡焦点，不挡选中。** AppKit 照样会选中被点的行并把它画出来，只是画成灰的。这两件事要分开修：

- `refusesFirstResponder = true` —— 让 sidebar 保住它的强调色高亮（上面第二条）
- `selectionHighlightStyle = .none` —— 让 Inspector 列表自己不画高亮（本条）

两个 Inspector 导航列表都改用了 `SelfSizingTableView.scrollableNavigationListTableView()`，这两个属性由该工厂统一设置。安全性依据：

- `itemClicked()` 走的是 `clickedRow`（table 的 target/action），与选中状态无关，点击导航不受影响；
- 全仓库没有任何地方读这两个表的 `selectedRow` / `modelSelected` / `itemSelected`；
- 项目里本就有这个惯用法（`SpecializationViewController`、`BatchExportingImageSelectionViewController`、`BatchExportingCompletionViewController` 三处）。

**写法注意**：`selectionHighlightStyle` 必须写在 `style` 之后 —— 设置 `NSTableView.style` 会重置前者。

**横向排查**：全仓库用 `itemClicked()` / `modelDoubleClicked()` 的列表共四处。除这两个外，`SpecializationTypePickerViewController` 是带搜索框的选择器 popover（高亮是"当前候选项"的有效反馈，且它是独立 popover，不牵连任何人），`SidebarRootViewController` 的选中代表当前状态本身 —— 两者都**不**改。

---

## 下次遇到「闪烁」先查这两条

1. **高亮变灰再变回来** → 焦点被别的控件抢走又还回来了。查那个控件是不是「点一下就跳走」的导航列表；是的话让它 `refusesFirstResponder`。
2. **滚动结果和选中/内容结果不在同一帧** → 查两者的先后顺序。凡是要把某一行滚进来再选中的地方，**一律先滚动再选中**，否则 row view 还不存在，样式会晚一帧。

---

## 影响面与注意事项

- **`refusesFirstResponder` 的代价**：Inspector 那两个列表不能再用方向键上下移动。它们点一下就导航走了，键盘遍历没有意义，可以接受。若日后要给它们加键盘导航，得连带重新处理焦点归属。
- **横向排查**：全仓库 `selectRowIndexes` 只有两处，另一处是 `StatefulOutlineView.restoreSelectedItem()`（结束筛选后恢复选中），顺序同样是错的，已一并修正。
- **仍未处理**：从点击到 sidebar 跳过去之间仍有约 50 ms（帧 020 → 022）三个面板才一次性刷新。嫌疑是 `SidebarRuntimeObjectListViewModel.findCell(for:in:)` 在主线程对整棵节点树做递归线性扫描（AppKit 这类镜像上万个类），但**未经测量**，不要当结论用。
