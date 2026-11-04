# 2026-11-04 工具栏进度环的轨道发黑：取到了给 vibrancy 叠加准备的颜色，叠加却没能穿过它的容器层

**调查日期：** 2026-11-04
**修复落地：** 本日，`next`
**Severity：** Low —— 只影响观感：Xcode 27 样式下，标题区进度环的轨道在深色窗口里近乎黑色，Xcode 的是灰色
**触发场景：** 用户拿 Xcode 27.2 解析包依赖时标题区的截图对照，指出我们的进度环轨道是黑的、Xcode 的是灰的。macOS 27.2，深色外观。第一轮修复之后用户重编 App 复看，轨道仍是黑的，又给了一张我们的截图

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 深色窗口里，标题区进度环的轨道比工具栏背景还暗，看上去是黑色；Xcode 的轨道比背景亮，是灰色 |
| **影响范围** | Xcode 27 样式的标题区进度环（`TitleActivityIndicatorView`）的轨道。Xcode 26 样式的胶囊进度环（`ActivityProgressRing`）有同类偏差：深色下比 Xcode 暗，浅色下比 Xcode 亮。弧（强调色）、图标、文字不受影响 |
| **根因** | 两层叠在一起。其一，工具栏给其中的视图 vibrant 外观，这种外观下系统的 fill 与 label 颜色是给叠加用的不透明灰——`secondarySystemFill` 深色是 (20,20,20)、浅色是 (230,230,230)——要用 plus-lighter / plus-darker 合成到背后的内容上，才是设计的样子；最初的实现按 vibrant 外观取了色却普通地画上去。其二，第一轮修复给轨道加了 plus-lighter，可轨道装在一个普通的 `CALayer`（环的容器层）里。Core Animation 的普通 layer 默认把子层的叠加关在自己里面（私有属性 `allowsGroupBlending` 默认为真），轨道只叠到了容器那块透明的底上，结果还是那块 (20,20,20)。视图自己的 layer 则不同：AppKit 把它的 `allowsGroupBlending` 关掉了，叠加能一路穿到工具栏背景上 |
| **Xcode 怎么做** | Xcode 27 的轨道是 SwiftUI 在 `backgroundMaterial = .regular` 下画的 `.fill.secondary`：vibrant 色加 plus-lighter（深色，背景 +20/255）或 plus-darker（浅色，背景 −25/255）。Xcode 26 的 `DVTProgressRing` 用 `tertiaryLabelColor`，但按 `NSApp.effectiveAppearance`（没有 vibrancy）解析，普通叠加 |
| **Status** | **Fixed** —— 两个环各照 Xcode 的做法取色；Xcode 27 样式的轨道直接挂在视图自己的 layer 下，失焦时逐层施加半透明 |

---

## 定位

1. **截图取样。** 用户的截图（Xcode 27.2 27B52，深色）里，工具栏背景是 #202027，轨道是 #34343A，正好亮 20。弧是 #427E82，与本机 `controlAccentColor` 在深色下的值一致（用户的强调色是 `NSColorSimulateHardwareAccent` 模拟出的青色），弧没有问题。
2. **系统颜色在各外观下的值。** `secondarySystemFill`：aqua 是黑色 7.8 %，darkAqua 是白色 7.8 %，vibrantDark 是不透明的 (20,20,20)，vibrantLight 是不透明的 (230,230,230)。`tertiaryLabelColor`：darkAqua 是白色 24.7 %，vibrantDark 是不透明的 (65,65,65)。在 darkAqua 下普通叠加白色 7.8 %，只会比背景略亮（32 → 49），不可能发黑；只有 vibrant 的那块不透明深灰会比背景暗，与用户看到的一致。
3. **SwiftUI 实际怎么画 Xcode 的轨道。** 用 `ImageRenderer` 在屏幕外把 `Circle().strokeBorder(.fill.secondary)` 画在已知的灰色上取像素。带 `backgroundMaterial` 时，深色下背景 32 → 52、120 → 140，恒为 +20，是相加而不是普通叠加；浅色下 236 → 211、150 → 125，恒为 −25。不带材质时是普通叠加（32 → 49，236 → 217）。深色的结果与 Xcode 的截图逐值吻合。Xcode 给失焦窗口的图标槽 `.opacity(0.5)`，SwiftUI 把它施加在轨道自己身上，轨道仍然叠到背景上（+10）。
4. **第一轮修复没生效。** 轨道改为 vibrant 色加 plus-lighter 后，用户重编复看（构建日志确认那次构建编进了修复），截图里我们的轨道仍是 #141414，即 (20,20,20) 本身，背景 #282829。App 正被 Xcode 的调试器挂着，lldb 挂不上去，改用两个探针：
   - **`CARenderer` 离屏渲染**（Core Animation 自己的渲染器，处理合成滤镜的方式与窗口服务器相同）：灰色背景 32 上，一个 (20,20,20)、plus-lighter 的 layer 隔着一个默认设置的普通 `CALayer` 渲染出来是 20；把中间那层的 `allowsGroupBlending` 关掉，是 52。中间那层透明度 0.999 时也是 20，再关掉 `allowsGroupOpacity` 仍是 20，说明拦住叠加的是 group blending，不是 group opacity。
   - **屏幕外的同配置窗口**（`.unified` 工具栏、隐藏标题、`fullSizeContentView`，从不激活、不进 Dock）：工具栏项里从我们的视图往上——`NSStackView`、`NSToolbarItemViewer`、`NSGlassContainerView`、`NSToolbarView`、`NSTitlebarView`、`NSTitlebarContainerView`、`NSThemeFrame`——每个视图的 backing layer 的 `allowsGroupBlending` 都是假；只有视图里自己建的普通 `CALayer` 是真。同一窗口里一个 `allowsVibrancy` 返回真的视图，AppKit 没给它的 layer 设任何合成滤镜，所以「交给 AppKit 做 vibrancy」在 macOS 27 的工具栏里不起作用。
5. **Xcode 26 的环。** `DVTProgressRingLayer.updateAppearance()`（DVTUserInterfaceKit 26.6，0x151FB0，伪代码与汇编一致）：不开增强对比度时，轨道是 `tertiaryLabelColor` 经 `dvt_colorResolvedInAppearance:` 按 `NSApp.effectiveAppearance` 解析；`setupLayer(size:)`（0x151930）做法相同，两处都没有设合成滤镜。我们的 `ActivityProgressRing` 按视图自己的外观解析，在工具栏里取到的是 vibrantDark 的 (65,65,65)，比 Xcode 的暗（#202027 背景上 Xcode 的约为 (87,87,92)）。这个环不做叠加，不受 group blending 影响。

## 修复

- **`NSAppearance+Vibrancy.swift`**（RuntimeViewerUI，internal）：`nonVibrantVariant` 把 vibrant 外观换成 aqua / darkAqua，`vibrantVariant` 反过来，`vibrancyCompositingFilter` 在深色下是 `plusL`、浅色下是 `plusD`。
- **`TitleActivityIndicatorView`**：轨道颜色取 `secondarySystemFill` 在 vibrant 外观下的值，轨道 layer 的 `compositingFilter` 按外观设 `plusL` / `plusD`。**轨道 layer 改为直接挂在视图自己的 layer 下**（在环的容器层之下），由 `layout()` 摆到中心；容器层只装弧与图标，它会转，可轨道是整圆，转不转看起来一样。视图自己的 layer 与容器层设 `allowsGroupOpacity = false`，失焦时的 0.5 透明度逐层施加。
- **`ActivityProgressRing`**：轨道颜色按非 vibrant 外观取 `tertiaryLabelColor`（`trackColor(in:increasesContrast:)`），开增强对比度时仍是 Xcode 的 0.869 灰。Xcode 按 `NSApp.effectiveAppearance` 取，这里取视图自己外观的非 vibrant 版本；两者只在某个窗口单独设了外观时才不同，RuntimeViewer 没有这样的窗口。
- 胶囊的灰色圆盘与标题文字的合成滤镜改用同一组 helper，行为不变。
- 规则写进 `RuntimeViewerUsingAppKit/AGENTS.md` 的「The Toolbar's Activity Display and Runtime Source Picker」一节；提案 [0071](../Evolutions/0071-xcode-activity-progress.md) 的决策日志登记了这次改正。

没有采用的写法：

- **让视图返回 `allowsVibrancy = true`，交给 AppKit 叠加**：探针表明 macOS 27 的工具栏里 AppKit 不为这样的视图设合成滤镜；就算设了，也会作用在整个视图上，连弧与图标一起提亮，而 Xcode 只叠加轨道，弧就是强调色本身（定位第 1 条）。
- **保留容器层，用 KVC 关掉它的 `allowsGroupBlending`**：这是 `CALayer` 的私有属性。挂到视图自己的 layer 下用的都是公开 API，效果相同。
- **深色下按 darkAqua 取白色 7.8 %、普通叠加**：结果是背景 +17，比 Xcode 的 +20 暗；浅色下是乘以 0.922，也对不上 Xcode 的 −25。

## 验证

- **回归测试**（swift-testing，`RuntimeViewerApplicationTests`）：
  - `TitleActivityIndicatorTests`「The track lightens what is behind it …」：一个显示四分之一进度的真实 `TitleActivityIndicatorView`，在四种外观（vibrantDark、darkAqua、vibrantLight、aqua）下，用 `CARenderer` 把它自己的 layer 树渲染到灰色背景上（`Support/LayerRendering.swift`），取九点钟方向的轨道像素，与 SwiftUI 对 Xcode 轨道的渲染（`Support/MaterialFillRendering.swift`）比较，每个通道相差不超过 1/255。轨道还装在容器层里时四例全部失败，深色 vibrant 是 20 对 52，正是用户截图里的值；浅色 vibrant 是 230 对 211。
  - 同一套件「Half transparent in a window that is not key …」：视图 `alphaValue` 为 0.5 时同样渲染，与 SwiftUI 在 `.opacity(0.5)` 下的渲染比较；修复前是 26 对 42。
  - `ToolbarActivityViewTests`「The ring's track is the tertiary label colour without vibrancy …」：深浅两种 vibrant 外观下，轨道颜色等于 darkAqua / aqua 下的 `tertiaryLabelColor`。修复前两例都失败。
  - 修复后上面三个测试与相关的 9 个套件（共 65 个测试）全部通过，原始退出码 0（JH's Mac Studio Ultra，macOS 27.2，Xcode 27.2，`swift build` / `swift test`）。
- **第一轮的测试为什么没拦住**：它把轨道的颜色和滤镜拿出来，在测试里按叠加公式算出屏幕上的结果，从没真正渲染过层树，所以看不到容器层把叠加关在里面。现在的测试渲染视图真实的 layer 树；屏幕外把 layer 画进位图（`render(in:)`）不执行合成滤镜，所以用 `CARenderer`。
- **目视验收**交给用户在 App 里做。浅色外观、增强对比度、失焦窗口都没有和 Xcode 的实拍对比过；屏幕外窗口的探针与用户的窗口配置相同，但用户窗口里还有分栏与侧栏，工具栏项上方的层没能在运行中的 App 里核对（调试器占着进程）。

## 同类

- `RuntimeViewerUI` 里自己给 layer 设系统颜色的，只有这两个环和胶囊的圆盘（圆盘本来就按非 vibrant 取色）。`performAsCurrentDrawingAppearance` 的其他用处在编辑器与内容区，那里没有 vibrant 外观。
- 标题文字那一列（`TitleToolbarItem` 的 `textStackView`）也设了 plus-lighter / plus-darker，它是视图自己的 layer，叠加能穿到背景上；标签用的颜色与 Xcode 的是否逐值一致，没有核对。
- 来源选择器（`RuntimeSourcePicker`）在 `draw(_:)` 里画文字和图标，也是按 vibrant 外观取色、不做叠加；它与 Xcode 的 scheme 选择器是否一致，没有核对。
- 识别方法：工具栏或侧栏里自绘的颜色在深色下比 Xcode 暗、在浅色下比 Xcode 亮，先查这个视图的 `effectiveAppearance.allowsVibrancy`，再查对应的 Xcode 视图是按非 vibrant 外观取色，还是 SwiftUI 在材质上叠加；要叠加的 layer，从它到视图自己的 layer 之间不能隔着普通 `CALayer`。
