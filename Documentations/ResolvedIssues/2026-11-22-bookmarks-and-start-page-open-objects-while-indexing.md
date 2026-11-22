# 2026-11-22 image 还在索引，书签页和起始页的条目就能点开

**调查日期：** 2026-11-22
**修复落地：** 本日，`next`
**Severity：** Low —— 不崩溃、不丢数据；侧栏对象列表还显示 loading 时，同一个 image 的对象已能从书签页、起始页的 Recent Objects 打开，两处的表现和侧栏对不上
**触发场景：** 侧栏进入一个还没索引的 image（例如第一次打开的大框架），在对象列表显示进度条期间切到书签页，或看编辑区里空白标签页的起始页

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 对象列表在显示索引进度，书签页已列出这个 image 的书签，起始页已列出它的 Recent Objects，都能双击打开 |
| **影响范围** | 只影响 macOS 版。书签页一直如此，历史上没有针对它的修复；起始页的 Recent Objects 从提案 0106（空编辑栏起始页）起。iOS 版没有书签页，起始页也不列最近条目。别处列出的这个 image 的对象都经引擎、要等索引（跳转栏、image 页），或只来自已索引的镜像（Find、Open Quickly），不受影响 |
| **根因** | 两处各自取数据：书签来自本地保存的书签，最近对象来自本地保存的浏览记录，都不经过引擎，所以不等索引 |
| **Status** | **Fixed** —— 对象列表把自己是否在加载报给 `DocumentState`，书签页和起始页在列表加载完之前只显示同款进度视图 |

---

## 根因

侧栏进入 image 后，`SidebarRuntimeObjectCoordinator` 一次建好四个页面，其中对象列表（`SidebarRuntimeObjectListViewModel`）和书签页（`SidebarRuntimeObjectBookmarkViewModel`）同一个基类。基类的 `reloadData()` 先问引擎 image 加载了没有，加载了就显示 loading，再迭代 `buildRuntimeObjectsStream()`：

- 对象列表的流是 `runtimeEngine.objectsWithProgress(in:)`，没索引的 image 要等索引完，进度一路显示在加载页上。
- 书签页的流只是把 `AppDefaults.objectBookmarksByScopeAndImagePath` 里的书签读出来，几毫秒就结束，于是书签页立刻显示列表。

起始页（`ContentPlaceholderViewModel`）在侧栏进入 image 后列出 `AppDefaults.recentRuntimeImagesByEngine` 里这个 image 的最近对象，同样从本地存储读，`$currentImageNode` 一变就列出来。

两处都不知道对象列表在干什么：`DocumentState` 只有 `currentImageNode`，没有任何东西说这个 image 的列表加载到了哪一步。

## 修复

- **`DocumentState.sidebarImageListLoad`**（新增）：侧栏 image 的对象列表现在处于什么阶段——`.loading(progress?)` 或 `.settled`（列出了对象、image 没加载，或加载失败）。`.switchImage` 在改 `currentImageNode` 之前先把它置成这个 image 的 `.loading(nil)`，所以起始页一看到新 image 就知道要等，不会先把条目列出来再收回；`.switchEngine` 和回到 image 列表把它清成 `nil`。
- **上报者**：对象列表在 `init` 里取一个 `SidebarImageListLoadReporter`，跟着自己的 `loadState` 上报（`.unknown`、`.loading` 报等待，其余报 `.settled`），构建流的每个进度事件在列表确实显示加载页时也报上去。`DocumentState` 只听最后取的那个上报者：同一个 image 退出又进入时，上一次的列表可能还在加载，它加载完不能结束这一次的等待。
- **书签页**：覆写 `buildRuntimeObjectsStream()`，列表没 settled 之前一直等，把列表的进度原样转成自己的进度事件，基类照常显示加载页；settled 之后才读出书签。没有列表上报（例如测试里单独建书签页）就不等。image 没加载时基类照旧显示 Load 页，不受影响。
- **起始页**：等待是起始页 `Placeholder` 的一种（`.waitingForImageList`），与读文件时的 `.readingFile` 同一写法：等待期间整页只显示一块 `ImageIndexingProgressView`，Open Quickly 栏和最近列表都不显示，焦点也离开起始页；读文件优先于等待。进度单独放在 `imageListLoadingProgress`，与 image 页的写法一致。等待经共用的 `LoadingPlaceholderTiming`：列表 150 ms 内加载完就不显示等待，显示了就至少停 300 ms；一次等待走完才处理下一次（与读文件占位的 `placeholders(for:)` 同一写法）。等待期间最近列表为空，等待结束时先放好这个 image 的最近对象、再显示起始页。列表之后再次进入加载（image 原本没加载，用户在侧栏点了 Load）也会重新等。最初的写法只把条目区换成进度视图、标题和 Open Quickly 照旧显示，看过之后改成整页等待。
- `ContentImageViewModel.IndexingProgress` 提成公用的 `ImageIndexingProgress`，起始页与 image 页共用。

## 验证

- `SidebarImageListLoadWaitTests` 两条回归测试只用修复前就有的 API：一个由测试控制何时加载完的对象列表（`GatedSidebarListViewModel`）挡着时，书签页的 `loadState` 一直是 `.loading`、起始页不列任何对象，放行后两处都列出来。修复前两条都失败，修复后通过。
- `SidebarImageListLoadTests` 覆盖新接口：进入 image 先等待、列表加载完或失败都结束等待、回到 image 列表清空、只听最后一个上报者、别的 image 的上报不算；书签页转发列表进度；起始页等待时整页换成等待、显示列表的进度、最近列表为空，等待结束时最近对象已经放好，快速加载不显示等待，再次加载重新等待。
- `ContentStartPageViewModelTests` 的 `enterImage` 改为进入 image 后报一次 `.settled`，表示列表已加载完。
- 在 JH's Mac Studio Ultra（macOS 27.2、Xcode 27.2）上，两个新套件连同起始页、Open Quickly、image 页、书签页、对象列表、重载失效、`DocumentState` 当前镜像、`AppCoreBoundaryTests`、`CrossPlatformSourceGuardTests` 共 12 个套件 91 条测试全部通过。界面没有在 App 里目视验收。

## 与侧栏重载修复的关系

同日另一处修复（`2026-11-22-sidebar-selection-cleared-by-indexing-reloads.md`）让已在屏幕上的对象列表重载时不再切到加载页。没有那处修复时，后台索引每个批次结束对象列表都会短暂回到加载页，这里的上报也随之短暂回到等待：书签页跟着重载一次，起始页只在那次重载超过 150 ms 时才显示等待。两处修复互不依赖，上报只跟随列表实际显示的 `loadState`。
