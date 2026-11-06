# Draft - 离线模式打开文件夹：列出其中全部二进制，按需打开

- **状态**: Accepted
- **创建日期**: 2026-11-06
- **最后更新**: 2026-11-06
- **关联提案**: [0069](0069-offline-mode.md)（离线模式本身：Mach-O 文件、bundle 与 dyld cache 的读法，每个文件一个进程，配对 cache）
- **实现分支 / PR**: `feature/offline-folders`（从 `next` 切，并回 `next`）

## 摘要

离线模式能打开单个 Mach-O、`.app` / `.framework` 包和 dyld cache，选普通文件夹却报「The bundle “…” has no
executable.」：`RuntimeOfflineFile(contentsOf:)` 把每个目录都当成 bundle，找不到主程序就拒绝（打开面板本来就允许选
目录）。本提案让不是 bundle 的目录按文件夹打开：它和所有子目录里（包括其中的 `.app`、`.framework`）的可执行文件、
动态库与插件都列进侧栏。同时把离线读文件改成按需打开：打开时只遍历、读文件头，点进去或被索引用到时才真正打开那个
二进制。现在一开包就把里面每个二进制都打开并一直不关，每个占一个文件描述符，文件夹一大就会耗尽；改了之后打开大的
`.app` 也跟着变轻。

## 方案

**判定**（Core，`RuntimeOfflineFile`）

- `RuntimeOfflineFile.Content` 加 `case folder`，名字照 `UTType.folder`（用户能浏览、不是包的目录）。目录照旧先问
  `Bundle(url:)?.executableURL`：有主程序是 `.bundle`，否则是 `.folder`——普通文件夹，也包括 `.xcframework`、
  `.xcarchive` 与没有主程序的包。
- 平台取「按名字排序、广度优先遇到的第一个二进制」的平台，按 0069 的规则挑配对的 cache；一个都找不到就在开窗口之前
  报错（新错误 `folderWithoutMachOFiles`）。这一步在 App 里跑，遇到第一个二进制就停。

**遍历**（Core，`RuntimeFileImageCatalog`，文件夹与 bundle 共用）

- 跳过符号链接（不跟进链接的目录，框架的 `Versions/Current` 不重复）；进入包内容与隐藏目录（SwiftPM 的 `.build`
  里就是产物）；读不了的子目录跳过，不中止遍历。
- 小于 4 KB 的文件不读（链接好的镜像至少有一整页 `__TEXT`），其余只读文件头：Mach-O 或胖文件的魔数，再取本机优先
  切片的 `filetype`。只收 dyld 能加载的镜像：`MH_EXECUTE`、`MH_DYLIB`、`MH_BUNDLE`；`.o`（`MH_OBJECT`，指针没有
  重定位）与 dSYM 里的 DWARF 文件（`MH_DSYM`，代码段在文件里没有内容）不收。单独打开一个文件的行为不变。
- 实测（单线程 `head` 读每个文件的前 4 字节，热缓存）：Xcode.app 有 126,027 个文件、3,227 个二进制，全部读一遍
  17.5 秒；先按大小筛掉后剩 58,259 个，4.1 秒。实现时可以并发遍历子目录。
- 镜像按路径排序。文件夹没有主程序，引擎的 `mainExecutablePath()` 返回空串，打开时不启动「主程序依赖闭包」那一批
  后台索引（打开 dyld cache 时就是这样）；点开某个镜像触发的索引照常进行。

**按需打开**

- 目录只记下每个镜像的路径与 `filetype`，不留任何打开的文件。`machO(forImagePath:)` 第一次被问到时才打开并缓存：
  点开镜像、后台索引走到它、批量导出用到它、依赖解析读它的加载命令。侧栏、镜像清单与 `isImageLoaded` 都只用路径。
- 按名字找 ObjC 类（`image(definingObjCType:)`）现在挨个查每个镜像的导出符号。改为第一次需要时把文件里的镜像逐个
  打开、记下导出的 `_OBJC_CLASS_$_` 名字、随即关掉，建成一张表，之后查表。配对 cache 的镜像照旧：它们共用 cache
  文件的映射，不额外占描述符。
- 不设数量上限。描述符只跟打开过的镜像有关（每个约 3 个：MachOKit 与 Swift、ObjC 两个读取层各一个），点开几十上百
  个不成问题。剩下的边界是一次会话里真正读过两三千个二进制（例如把一个大文件夹整个批量导出），写进使用指南。

**依赖查找按 App 划范围**

- MachOSwiftSection 的依赖定位器建闭包时，会把搜索路径里的每个 `.machOFile` 都打开。现在目录把包里每个二进制都放进
  搜索路径，解析 Swift 镜像时一用到依赖闭包，就把它们全部打开一遍；文件夹里装着几个 App 时，还会把别的 App 里同名
  的框架当成依赖。
- 改为每个镜像一份搜索路径（`RuntimeImageCatalog.dependencySearchPaths(forImageAt:)`，Swift 工厂按镜像建索引配置与
  静态布局的依赖解析）：先是它所在 App（往上最外层、主程序为 `MH_EXECUTE` 的包）里的二进制，再是不属于任何 App 的
  二进制，最后是配对的 cache；别的 App 的不进来。打开一个 `.app` 时所有镜像都在同一个 App 里，结果与现在相同。

**`@executable_path` 按镜像所在的 App 展开**（文件夹与 bundle）

- 一个镜像的主程序，是它往上最近的、主程序为 `MH_EXECUTE` 的包（`.app`、`.appex`、`.xpc`；`.framework` 的主程序是
  动态库，跳过）里的那个可执行文件；镜像本身是可执行文件就是它自己；都不是时用后台索引传进来的那个。文件夹里有几个
  App 时各按各的展开，`.app` 里的 `.appex`、`.xpc` 也不再借用外层 App 的主程序。命令的线上格式不变。

**App**

- `Info.plist` 的 Viewer 文档类型加 `public.folder`（类型名改为「Mach-O File, Bundle or Folder」），文件夹能拖到
  Dock 图标上打开；Finder 里每个文件夹的「打开方式」都会列出 RuntimeViewer，`Alternate` 级别，不抢默认。
- File › Open… 面板的说明加上文件夹；Open Recent 记的是 URL，不用改。
- 文件夹的 Dependency Cache 子菜单列出本机 cache 与全部登记的 cache，不按平台过滤：一个文件夹可能混着几个平台的
  二进制（如 `.xcframework`），自动挑的那份只按第一个二进制定。这段筛选挪进 `Settings.Offline`，以便测试。

**测试**（swift-testing）

- Core：临时文件夹里放测试 bundle 二进制的副本、指向它的符号链接、小于 4 KB 的文件、补齐到 4 KB 以上的
  `MH_OBJECT` 与 `MH_DSYM` 文件头、一个非 Mach-O 文件：判定为 `.folder`、平台是 macOS、只列出副本；空文件夹报
  `folderWithoutMachOFiles`。
- Core 按需打开：exit test 的子进程把描述符软、硬上限都压到 256，打开一个装着 300 个小 Mach-O 文件的文件夹并读其中
  的真实二进制。改前目录只列得出不到 256 个，改后 300 个全列出、读取成功。
- Core：仿 App 的目录（`Foo.app/Contents/MacOS`、`PlugIns/Bar.appex`、`Frameworks/X.framework`，`Info.plist`
  写 `CFBundleExecutable`）里各镜像的主程序与依赖搜索路径；按名字找 ObjC 类经新表找到文件夹里二进制导出的类。
- Settings：文件夹的 Dependency Cache 候选不按平台过滤。
- 界面、Dock 拖放与 Open Recent 归人工验收：打开一个装着几个第三方 App 的文件夹、一个 `.xcframework`，再按
  bundle 打开 Xcode.app，确认按需打开之后照常浏览。

**文档**：使用指南 `Guides/OfflineMode.md`（能打开什么、报错、文件夹的 Dependency Cache、描述符的边界）；根
`AGENTS.md` 与 `RuntimeViewerUsingAppKit/AGENTS.md` 里列离线文件种类的几处；README 两处；术语表「离线文件」「镜像
目录」两条；两份索引。

**不做**：`.a` 静态库（ar 归档，MachOKit 不读）；`.ipa`（zip，要先解压）；文件夹内容变了自动刷新（与现有离线文件
一致）；让读取层不常驻描述符、让依赖定位器按需打开搜索路径（上游 swift-fileio、MachOKit、MachOSwiftSection 的改动，
另立提案）。

**落地步骤**（每步构建通过、相关测试通过后提交一次）

| 步骤 | 内容 | 状态 |
|------|------|------|
| 1 判定与遍历 | `Content.folder`、`folderWithoutMachOFiles`、平台探测；文件夹与 bundle 共用的遍历（符号链接、4 KB、`filetype`、排序） | 未开始 |
| 2 按需打开 | 目录只记路径与 `filetype`，`machO(forImagePath:)` 首次打开并缓存；ObjC 类名表 | 未开始 |
| 3 按 App 划分 | 每个镜像一份依赖搜索路径（目录与 Swift 工厂）；`@executable_path` 按镜像所在的 App 展开 | 未开始 |
| 4 App | `Settings.Offline` 的文件夹候选 cache 与 `OfflineFileController`；打开面板说明；`Info.plist` 的 `public.folder` | 未开始 |
| 5 文档与验证 | 使用指南、`AGENTS.md`、README、术语表；Core 与 Packages 测试、App 构建 | 未开始 |

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-06 | Created as Draft | 离线模式能打开 App 却打不开普通文件夹：目录一律按 bundle 判定，找不到主程序就报错 |
| 2026-11-06 | 文件夹与 bundle 都改成按需打开，去掉初稿的 2,000 个上限 | 用户指出侧栏只需列出、点进去才加载。上限是现有实现一开就把每个二进制都打开、一直占着描述符造成的，不是列出本身的代价；同一套读法让打开大的 `.app` 也变轻 |
| 2026-11-06 | `Info.plist` 声明 `public.folder` | 用户选定：文件夹能拖到 Dock 图标上打开，代价是 Finder「打开方式」里多一项 |
| 2026-11-06 | 依赖搜索路径按镜像所在的 App 划范围 | 按需打开之后，依赖定位器仍会把搜索路径里的文件全部打开；文件夹里有几个 App 时还会混用别的 App 里同名的框架 |
| 2026-11-06 | 用户批准，开始实现；补上落地步骤 | 精简提案原先只有方案，开工前拆成五步，每步各自构建、测试通过后提交 |
