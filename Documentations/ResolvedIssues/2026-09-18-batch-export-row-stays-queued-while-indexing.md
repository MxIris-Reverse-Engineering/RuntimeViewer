# 2026-09-18 批量导出：镜像明明在索引，行却一直显示 Queued；进度条复用时带着上一行的动画

**调查日期：** 2026-09-18
**修复落地：** 本日，见 `BatchExportingProgressViewModel.swift`、`BatchExportingProgressRowViewModel.swift`、`BatchExportingProgressViewController.swift`，以及 `RuntimeEngine.swift` / `RuntimeEngine+Requests.swift` / `RuntimeEngineRequest.swift` 新增的带进度 `loadImage`
**所属分支：** `next`
**Severity：** Minor —— 结果正确，但大镜像那一行会有几十秒看起来什么都没发生，用户第一反应是「卡住了」
**触发场景：** 用户反馈 —— 批量导出 PhotosUI 家族 9 个镜像，其余 8 个几秒内完成，PhotosUICore 那一行一直是空心圆加 "Queued"，但磁盘上文件在增长

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 行状态停在 Queued，头部的 "8 / 9 completed" 却是对的；等足够久那一行会直接跳成 succeeded，中间从不显示进度条 |
| **影响范围** | 只影响批量导出的每行状态展示。导出本身、并发数、结果统计全部正常 |
| **根因** | 单镜像导出的顺序是「问引擎是否已加载 → `loadImage` → 把行标成 running → 导出」。而引擎的 `loadImage` 不只是 `dlopen`，它顺手把这个镜像的 ObjC section 和 Swift section 都建出来，也就是完整索引；对 PhotosUICore 这种体量的 Swift 框架，索引是整个导出里最长的一步。这一步既在 running 之前，又没有任何进度回传，行就整段时间停在 Queued |
| **附带问题** | 行进入 running 后，cell 把第二行文字藏起来只留进度条，所以 "Preparing…" / "Writing files…" 这些阶段文字从来没显示过；另外同一个 `NSProgressIndicator` 被多行复用时，滚动会把上一行的进度值动画到下一行的值 |
| **Status** | **Fixed** —— 先标 running 再加载；引擎新增带进度的 `loadImage`，把索引各阶段的计数喂给行；cell 同时显示阶段文字和进度条；每次绑定新行换一个新的进度条实例 |

---

## 根因

### 为什么是 Queued 而不是别的

`BatchExportingProgressViewModel.exportOne` 修复前的顺序：

```
isImageLoaded(path)        ← 只看 dyld 的镜像列表
loadImage(at:)             ← dlopen + 建 ObjC section + 建 Swift section + reloadData
markRunning()              ← 行到这里才离开 Queued
exportInterfaces(...)
```

`RuntimeEngine._loadImage(at:)` 的两次 `section(for:)` 调用各自走 `RuntimeObjCSection.init` /
`RuntimeSwiftSection.init`，后者会跑 `indexer.prepare()` 加 `allObjects()`，即解析全部 Swift 元数据、
建继承与遵循关系表、枚举全部对象。这和侧栏双击一个镜像时那条进度条背后做的事**完全相同**，
区别只是侧栏走 `objectsWithProgress(in:)` 带了 `progressContinuation`，而 `loadImage` 没有。

### 为什么 9 个镜像全部走了 `loadImage`

9 个任务同时起跑，每个先问 `isImageLoaded`。引擎里的 `imageList` 只在 `reloadData` 时刷新，
起跑那一刻没有任何镜像加载过，9 个回答全是「未加载」，全部进入 `loadImage`。小镜像几秒索引完，
察觉不到；PhotosUICore 要几十秒，就成了唯一停在 Queued 的那一行。

顺带一提，`isImageLoaded` 是错误的门槛：被 dyld 作为依赖顺手拉进来的镜像算「已加载」，但它没有
section，导出时 `objects(in:)` 还是要索引，只是这次索引发生在 `exportInterfaces` 内部、同样没进度。
修复后改问 `isImageIndexed`，两种情况统一走带进度的加载。

### 头部计数没错的原因

每个镜像结果里的 `totalDuration` 只统计 `exportInterfaces` 那一段，索引时间不在里面。所以其余 8 行
显示的 1.7 s 到 4.5 s 让整件事看起来「都很快」，实际上索引这段是隐形的。

---

## 修复

### 引擎侧：`loadImage(at:onProgress:)`

- `RuntimeEngine._loadImage(at:progressContinuation:)` 把 continuation 透传给两个 section factory，
  它们本来就接受这个参数。
- 新增 `LoadImageWithProgressRequest`，遵循 `RuntimeEngineProgressRequest`，命令名
  `loadImageWithProgress`。**没有把现有 `LoadImageRequest` 改成 progress request**：progress request
  在线上走的是 `RuntimeEngineProgressEnvelope` 信封，改现有命令等于改它的 wire 格式。
- 公开接口 `loadImage(at:onProgress:)`，闭包收到 `RuntimeObjectsLoadingProgress`，和
  `objectsWithProgress(in:)` 吐出来的是同一种事件。
- 原来 `_objects(in:reportProgress:)` 里那段「把 continuation 桥接成闭包」的泵抽成
  `pumpingIndexingProgress(to:_:)`，两个入口共用。

### App 侧

- `exportOne` 先 `markRunning()`（文字 "Loading image…"），再判断 `isImageIndexed`，未索引就走带进度的
  `loadImage`，把每条进度写进行的 `progress` / `progressText`，格式与侧栏一致：
  `"<阶段描述> <当前>/<总数>"`。加载完成后把进度归零并显示 "Preparing…"，再进入原有的导出事件流。
- cell 第二行改成 `HStackView { detailLabel; progressBarContainer }`：running 时文字和进度条并排，
  进度条固定 160 pt 靠右；其它状态隐藏进度条容器，stack view 自动把它摘掉，文字占满整行。

---

## 附带修复：进度条复用时的动画

### 现象

同一个 `NSProgressIndicator` 跟着 cell 被复用。滚动时 cell 从 A 行换到 B 行，`doubleValue` 从 A 的值
写成 B 的值，AppKit 把这次变化做成动画，B 行的进度条会从 A 的位置滑过来。

### 为什么公开 API 关不掉（macOS 26.5.2，AppKit dump + IDA）

`-[NSProgressIndicator setDoubleValue:]`（`0x184A57AC8`）只存值并调 `_updateNormalizedValue`
（`0x1854E5170`），后者把归一化值写进 `NSProgressIndicatorConfiguration` 再交给 visual provider 的
`updateConfiguration:`，provider 只 `setNeedsDisplay:`。真正的更新发生在
`-[NSProgressIndicatorSolariumVisualProvider updateLayer]`（`0x184EB6158` → `sub_184EB5B00`）：

1. `CATransaction.begin()` 并设 `kCATransactionDisableActions = true` —— AppKit 自己已经把隐式动作关了；
2. 把 `progress` 写进私有 `ProgressIndicatorLayer`，调 `sub_184EB7A0C` 处理确定/不确定切换，
   再调 `sub_184EB7358` 应用状态；
3. 确定态最终落到 `sub_184EB6E3C`，它的分支是：
   - `previousProgress == nil` → 直接设 `determinatePill.bounds`，`state = .stopped`，
     `previousProgress = progress`；**这是唯一不动画的路径**；
   - `progress == previousProgress` 且没有进行中的动画 → 直接设 bounds；
   - 其余 → `sub_184EB7B30(from, to)` 造一个 `CAAnimation`，`pillBaseLayer.addAnimation(_:forKey: determinateAnimationKey)`，
     `state = .updatingDeterminate`；`animationDidStop` 后把 `previousProgress` 推到终值。

动画是显式 `addAnimation:forKey:`，`CATransaction.setDisableActions` 与 `NSAnimationContext` 都管不到。
`previousProgress` 只在两处回到 nil：layer 刚创建，或 `isIndeterminate` 翻转时的特定状态；而翻转要经过
一次 display pass 才会被 layer 看到，同一个 run loop 里 `isIndeterminate = true` 再 `= false` 会被
configuration 合并掉，layer 根本看不见。

macOS 15 的 `NSProgressIndicatorLegacyVisualProvider.setProgress:`（`0x1859BB2F0`）同样只存
configuration 加 `setNeedsDisplay:`，动画在绘制阶段用 `_animationStartTime` 自己算，公开 API 一样没有开关。

### 采用的做法

每次 `bind(to:)` 换一个新的 `NSProgressIndicator`（`installFreshProgressBar()`）。新实例的 layer 没有
`previousProgress`，第一次写值走上面的直接路径；同一行之后的更新继续动画，这是想要的。
代价是每次复用多一次分配，对几十行的列表可以忽略。

---

## 验证

- 构建：`RuntimeViewer-Debug.xcworkspace` / `RuntimeViewer macOS` / Debug-arm64e，agent 私有 DerivedData。
- 未做模拟器或交互式 UI 验证；进度条动画一节的结论来自反编译而非录屏。

## 未做的事

- 写文件阶段（`RuntimeInterfaceExportWriter`）是同步 I/O，跑在 `RuntimeEngine` actor 里；一个大镜像写几千个
  文件时会把其它并发导出和侧栏一起卡住。与本次现象无关，另行处理。
- 侧栏的 `tryLoadImage()` 仍用无进度的 `loadImage(at:)`，那里本来就只显示一个 loading 态，暂不改。
