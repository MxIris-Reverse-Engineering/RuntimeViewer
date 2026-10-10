# Draft - 私有类型的鉴别器收进可点击的 Private tag

- **状态**: In Progress
- **创建日期**: 2026-10-10
- **最后更新**: 2026-10-10

## 摘要

从 825db142 起，侧栏会把私有 Swift 类型连同它的私有鉴别器一起列出，例如
`SwiftUI.(EnabledKey in _09CE35833F3876FE3A3A46977D61FC64)`，目的是区分不同源文件里的同名私有类型。
SwiftUICore 的 4091 个类型里有 1402 个带这一串，每个名字因此长出 38 个字符；这一串还会污染过滤，因为模糊匹配
会去匹配那 32 位十六进制和 ` in `，像 `in`、`face` 这样的短查询几乎命中所有私有类型。本提案让引擎打印名字时
不再打印鉴别器，鉴别器改从 demangle 出的 Node 里取（`privateDeclName` 节点），随对象一起交给 App；侧栏在行尾放
一个只写 `Private` 的小 tag，点 tag 弹出 popover，里面是完整鉴别器，以及能反推出来时的源文件名。为此
`RuntimeObjectCellView` 改成一个通用结构：行首放图标，行尾可以挂多个 tag，`Private` 是第一个用上它的 tag。

源文件名能反推，是因为鉴别器就是 `MD5(模块名 + 源文件名)`，大写十六进制，前面加一个 `_`（Swift
`lib/AST/Module.cpp` 的 `SourceFile::getPrivateDiscriminator`）。拿候选文件名算 MD5 比对，候选有两个来源：开源
项目里的真实文件名（OpenSwiftUI 为 SwiftUI 复原的文件名、swift-foundation、Swift 标准库），以及用镜像里已有的
名字按几条规则拼出的文件名。macOS 26.7 上，SwiftUICore 的 439 个鉴别器能还原 408 个（92%，例如 `_09CE35…`
对应 `Enabled.swift`），SwiftUI 709 个里 576 个（81%），Foundation 86 个里 84 个（97%）；只用最初的规则时
SwiftUICore 约 68%。128 位哈希一旦对上就等于确认，所以结果只会「猜不出」，不会「猜错」。

## 方案

**`RuntimeObjectCellView`：图标在前，tag 在后。**

- 布局：前面是图标，仍是原来的三个位置；中间是标题和副标题；后面是任意多个 tag，按给定顺序排列，靠行尾右对齐。
  名字放不下时截断的是名字，tag 不截断。右对齐靠的是 tag 那一列的 stack view 用自己的 hugging priority
  （`.defaultHigh`）贴住内容，多出来的宽度都给标题那一列。stack view 没有固有尺寸，content hugging 对它不起
  作用；两列都停在默认的 `.defaultLow` 时，Auto Layout 随意拉宽其中一列，多数行的 tag 就紧跟在标题后面。
- 数据：`RuntimeObjectCellAppearance` 新增 `tags: [RuntimeObjectCellTag]`，和其余显示状态一起由同一个
  `@RxObserved` 发布，「一行只有一个 Appearance」的规矩不变。`RuntimeObjectCellTag` 带一个标识（`Identifier`，
  目前只有 `.privateDeclaration`）、文字、tooltip，以及能不能点。
- 视图：每个 tag 是一个 `TagButton`（`RuntimeViewerUI`），即 UIFoundation `BadgeButton` 的子类：系统的 badge
  胶囊样式，small 尺寸，不拿键盘焦点（否则点一下，列表的选中就变成非活动的灰色）。不能点的 tag 不参与命中测试，
  点击落到这一行。选中行变成强调色时的配色交给系统的 badge 样式，不另外画。
- 点击：cell 的 `tagClicked` 报出被点 tag 的标识；VC 在 cell provider 里把它和这一行的 cell ViewModel 配成
  `SidebarRuntimeObjectViewModel.TagClick`，经 `PublishRelay` 交给 ViewModel。
- 另外三个用这个 cell 的面板（Inspector 的 Relationships / Specializations、类型选择器）不传 tag，外观不变。

**名字与鉴别器：在引擎里从 Node 取。**

- 引擎打印 `displayName` 时不再打印私有鉴别器：`SwiftUI.(EnabledKey in _09CE…)` 回到 825db142 之前的
  `SwiftUI.EnabledKey`。
- 鉴别器从 demangle 出的名字里取：每个 `privateDeclName` 节点的第一个子节点是鉴别器，第二个是声明名。按阅读顺序
  （前序遍历）放进 `RuntimeObject.privateDeclarations`，重复的只留一个。`RuntimeSwiftSection` 里所有构造 Swift
  对象的地方都填这个字段：列表、嵌套类型，以及跳转和关系树按 mangled 名重新物化的对象。所以同一个类型不管从哪条
  路径拿到，名字和私有声明都一样。
- `privateDeclarations` 是 `RuntimeObject` 的新字段，带 `@Default([])`：旧版本引擎发来的对象解出来是空数组，
  旧版本 App 收到新字段会忽略。不新增引擎命令。

**`Private` tag。** 侧栏的对象列表、书签和 Open Quickly 共用 `SidebarRuntimeObjectCellViewModel`，改动落在这里。

- 对象的 `privateDeclarations` 不空，`tags` 里就放一个 `Private`，一行最多一个。Open Quickly 里它不能点，因为
  点那一行就是打开它。
- 标题、过滤、高亮和排序都不用另外处理：名字里本来就没有鉴别器了。

**popover。** 点 tag 时弹出，行为是 `.transient`。

- 内容：对象的名字；每个私有声明各列一组，包括名字、完整鉴别器、源文件名，以及哈希用的模块名。还原不出文件名
  时写 `Unknown`，鉴别器照原值给出，不做缩写。文字可以选中复制。
- 结构照 `SpecializationCoordinator.showTypePicker` 的先例：上面汇总的点击是 `Signal<TagClick>`（只带数据）；
  ViewModel 看到 `.privateDeclaration` 就触发 `SidebarRuntimeObjectRoute.privateDeclaration(cellViewModel)`（只带
  数据）；coordinator 先问对象列表、再问书签的 VC 要锚点（`anchorView(forTag:of:)`：按 cell ViewModel 找到这一行，
  取出那个 tag）。ViewModel 的 Input 和路由都不带视图。
- popover 有自己的一对 `PrivateDeclarationViewController` / `PrivateDeclarationViewModel`。它的状态是一个枚举：
  初始不显示占位，反推超过 0.15 秒才出现 `Recovering…`（`withLoadingPlaceholder`），快的时候不闪占位。耗时见
  「数据」里的实测。

**数据。**

- `displayName` 不再带鉴别器，这一点不只影响侧栏：标签页标题、工具栏、前进/后退菜单、MCP、CLI 与导出的文件名，
  都回到 825db142 之前的写法。批量导出拿 `displayName` 当文件名，同一镜像里同名的私有类型会落到同一个文件名上；
  825db142 之前就是这样。要精确指到某一个类型时，MCP 与 CLI 都接受 `RuntimeObject.name`（mangled 名）。
- 反推（`RuntimePrivateDiscriminatorSourceFiles`）放进 `RuntimeViewerCore`，写成纯函数，输入是要还原的鉴别器
  （popover 那一行的 `privateDeclarations`）和镜像的对象列表：
  - 模块名的候选是镜像文件名（`SwiftUICore`，哈希用的是它，不是 ABI 名 `SwiftUI`），加上私有对象名字里的模块名。
    哈希用 CryptoKit 的 `Insecure.MD5`。合成文件的鉴别器是 `MD5(所属文件的鉴别器 + "SYNTHESIZED FILE")`，
    顺带一起解出。
  - 候选文件名分五步，按代价从低到高，要的鉴别器全部找到就停：
    1. 已知文件名（见下）。
    2. 镜像里所有名字的标识符：原样、去掉前导下划线，以及其中任意一段连续的驼峰单词，加 `.swift`。
       `RBDisplayListInterpolatorOptionKey` 中间的一段给出 `DisplayListInterpolator.swift`。最初的规则只取前缀和
       后缀。
    3. 同一鉴别器下声明的名字里的单词，两两拼成 `类型+分类.swift`：`DateTextStorage` 在 `Text+Date.swift` 里。
    4. 第 2 步的每个候选接一个常见的结尾词（`Additions`、`Utils`、`Helpers`、`Style` 等十个，取自 SwiftUICore
       里前几步还原不出的文件名）或复数 `s`：`Signpost` 给出 `Signposts.swift`。
    5. 镜像里任一类型名，接 `+` 再接第 3 步的单词：`ObjectLocation` 在 `Binding+ObjectLocation.swift` 里。
  - 一个模块名是另一个的前缀时（`SwiftUI` 与 `SwiftUICore`），同一段哈希输入有两种读法：`SwiftUICoreGlue.swift`
    既是 SwiftUICore 的 `Glue.swift`，也是 SwiftUI 的 `CoreGlue.swift`。一律按模块名的先后取前一种，结果不随候选
    的尝试顺序变。
  - 候选只是猜测，128 位哈希对上才算数，所以这里按文本切词不会产生错的结果，最多是还原不出。
- 已知文件名清单（`RuntimePrivateDiscriminatorSourceFiles+KnownFileNames.swift`，2007 个）由
  `RuntimeViewerCore/Scripts/GenerateKnownSwiftSourceFileNames.sh` 生成：经 `gh` 读下面几个仓库的文件树，取其中的
  Swift 文件名（测试、基准与示例除外），每个来源钉在一个 commit 上，写进生成文件的文件头。只收文件名，不收代码。
  清单不手改，要更新就重跑脚本。
  - OpenSwiftUI（MIT）：它为 SwiftUI 与 SwiftUICore 复原出的文件名。文件头写了 `ID:`（即鉴别器）的 533 个文件里，
    519 个用 MD5 验证得上。
  - swift-foundation、Swift 标准库，以及 `stdlib/public/Darwin/` 下已经删掉的 Darwin overlay 的两个历史版本（都是
    Apache 2.0）。
- 候选必须来自整张对象表：只用类型自己名字里的单词，SwiftUICore 只能还原 31%。对象列表的 ViewModel 已经拿到了
  这张表，coordinator 打开 popover 时把它交给 `PrivateDeclarationViewModel`，由它在主线程以外现算
  （`@concurrent`）；列表手里没有对象时，改向引擎要 `objects(in:)`。不缓存。在最初的规则下，把候选扩大到 dump 里的
  全部标识符也只从 68% 涨到 71%，不值得为此新增引擎命令。
- 实测（macOS 26.7，Debug 构建，即不开优化）。后两列是打开一行 popover 的耗时，每个镜像抽 10 个还原得出的和 3 个
  还原不出的：

  | 镜像 | 鉴别器 | 最初的规则 | 只用镜像里的名字 | 加上已知文件名 | 还原得出 | 还原不出 |
  |---|---|---|---|---|---|---|
  | SwiftUICore | 439 | 约 68% | 382（87%） | 408（92%） | 平均 81 毫秒 | 2.9–4.2 秒 |
  | SwiftUI | 709 | 约 73% | 561（79%） | 576（81%） | 平均 341 毫秒 | 3.4–3.8 秒 |
  | Foundation | 86 | 约 44% | 64（74%） | 84（97%） | 平均 45 毫秒 | 0.8–0.9 秒 |
  | libswiftCore | 4 | — | 3 | 4 | 5 毫秒 | — |

  「最初的规则」一列只能当约数：SwiftUICore 那个数是旧实现量的，当时按名字里的文本数鉴别器，数出 478 个，与这里
  的 439 个口径不同；SwiftUI 与 Foundation 的是用 Python 照旧规则复算的。还原不出的一行要把五步的候选全部算完，
  所以最慢。一次算完整个镜像的全部鉴别器要 30 秒（SwiftUICore）到 144 秒（SwiftUI），这是只算 popover 那一行的
  原因。Release 构建没有测。

**不做。**

- Find 结果行、工具栏副标题、标签页标题、前进/后退历史菜单和 Inspector 不加 tag；它们的名字跟着 `displayName`
  一起不再带鉴别器。
- 行首的图标不改成数组，仍是原来的三个位置；现有的 `C` / `G` / `Sp` 角标也不挪成 tag。

**测试。**

- Core，真实引擎（`RuntimeSwiftPrivateDeclarationsTests`）：Foundation 的 `__JSONEncoder` 列为
  `Foundation.__JSONEncoder`，`privateDeclarations` 是 `__JSONEncoder` 与 `_12768CA1…`；列表里没有一个名字含有
  自己的鉴别器。`RuntimeTypeRelationshipsProtocolCopyTests.swiftFaceKeepsItsSidebarName` 改为断言：从 ObjC 类找到
  的 Swift 面与侧栏那份的名字、私有声明都相同，关系树的根也一样。
- Core，反推（`RuntimePrivateDiscriminatorSourceFilesTests`）：用 SwiftUICore 与 Foundation 的真实鉴别器，期望值
  全部用 `md5 -s` 在代码之外算出。每条规则都不带已知文件名单独测：「哈希用镜像文件名而非 ABI 名」「文件名来自镜像
  里另一个类型的名字」「嵌套在别的对象里的私有类型」「缩写词」「名字中间的一段单词」「常见结尾词」「复数」「同一
  鉴别器下的 类型+分类」「任一类型名接分类」「合成文件」「模块名取自名字」「只算要的鉴别器」与「还原不出」。另有
  「已知文件名」「默认带上的清单」，以及「两种读法取前一个模块名」，最后这条的鉴别器是编出来的。
- 还原率与耗时用一个临时测试量：真实引擎加载四个镜像，结果见「数据」。量完删掉，不提交。
- Application（`SidebarPrivateDeclarationTagTests`、`PrivateDeclarationViewModelTests`，以及
  `SidebarRuntimeObjectViewModelTests` 新增的用例）：有私有声明的行带 tag、没有的不带，嵌套的私有类型只标它自己
  那一行，Open Quickly 的 tag 不可点；点 tag 触发 `.privateDeclaration` 并带上这一行；popover 列出鉴别器与反推
  结果，还原不出时为 `unrecovered`，没交对象时去问引擎（Foundation 的 `__JSONEncoder` → `JSONEncoder.swift`）。
- UI（`TagButtonHitTestingTests`）：在真实的 `StatefulOutlineView` 行里做命中测试（hit-test）——点在可点的 tag 上
  命中 tag，点在不可点的 tag 上落回这一行。
- tag 右对齐没有自动测试：`RuntimeObjectCellView` 在 App target 里，App 没有单元测试 target。
- 手工验证：macOS 27 上表格行内控件的点击路径变过，命中测试只能证明点击落在了 tag 上；tag 的动作有没有真的触发、
  会不会顺带选中这一行，badge 样式在选中行上的配色，以及 tag 是否贴着行尾，要在 App 里实测。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-10 | Created as Draft：「带私有鉴别器的 Swift 类型太长了，看看能不能缩成一个 token/tag 展示」 | 用户的原始描述 |
| 2026-10-10 | tag 放在行尾，名字截断时 tag 仍然可见 | 用户的选择；放在行内的话，私有段在末尾时（最常见）tag 会被截掉 |
| 2026-10-10 | tag 只写 `Private`，点开 popover 看完整信息；popover 里给原始鉴别器，不做缩写 | 用户先后否掉了「tag 写文件名，还原不出时退回 6 位短哈希」和「短哈希」 |
| 2026-10-10 | 只改侧栏（对象列表、书签）和 Open Quickly | 用户没有勾选 Find 结果行和纯文本位置 |
| 2026-10-10 | 分支从 `next` 切出：`feature/private-discriminator-tag` | 用户的选择 |
| 2026-10-10 | 反推写成 Core 里的纯函数，在 App 侧调用，不新增引擎命令 | 侧栏已经有整张对象表；候选扩大到全部标识符只多 3 个百分点 |
| 2026-10-10 | `RuntimeObjectCellView` 改成图标在前、可以挂多个 tag 在后，`Private` 是第一个 tag | 用户的要求 |
| 2026-10-10 | Accepted，随即转 In Progress | 用户批准：「可以，开工」 |
| 2026-10-10 | tag 用 `TagButton`：UIFoundation `BadgeButton`（系统 badge 胶囊）的子类，不自绘 cell | 项目规定优先用 UIFoundation 的包装类型；系统样式在选中行与 macOS 27 的手势识别器路径上都是原生行为 |
| 2026-10-10 | 源文件名在打开 popover 时现算，不缓存 | SwiftUICore 一次几十毫秒；缓存要跟着引擎切换与镜像重载失效，为一个按需打开的 popover 不值得 |
| 2026-10-10 | popover 的初始状态不显示占位 | 反推通常快于 0.15 秒；一打开就显示 `Recovering…` 会闪一下 |
| 2026-10-10 | tag 那一列的 stack view 改用 `.defaultHigh` 的 hugging，tag 贴住行尾 | 用户在 App 里看到多数行的 tag 紧跟在标题后面，只有个别行在行尾。两列 stack view 的 hugging 都是默认的 `.defaultLow`，原来写的 content hugging 对 stack view 不起作用，Auto Layout 随意拉宽其中一列 |
| 2026-10-10 | 鉴别器改从 Node 取：引擎打印 `displayName` 时不再打印它，`privateDeclName` 节点另存进 `RuntimeObject.privateDeclarations`。删掉按文本解析名字的 `RuntimeDisplayName`，以及侧栏为「去掉鉴别器的名字」改的过滤、高亮、排序和 Open Quickly 排名 | 用户：「私有鉴别器要利用Node来获取，文字匹配不够靠谱」「取到私有鉴别器节点然后打印的时候不要打印它就好了，很简单，不需要你写的那些逻辑」 |
| 2026-10-10 | 推翻「`displayName` 不动」：标签页、MCP、CLI 与导出里的名字一起回到 825db142 之前不带鉴别器的写法；同名私有类型在批量导出时重新共用一个文件名 | 这是「打印时不打印鉴别器」的直接结果；825db142 加鉴别器本来就只为了侧栏 |
| 2026-10-10 | 提高还原率：候选改成五步规则，再加上从开源项目收集的已知文件名 | 用户问「还原率还能提高吗」，指出 OpenSwiftUI 里有很多猜出来的文件名，随后批准「可以，两样都做」。实测 SwiftUICore 由约 68% 到 92%，Foundation 由约 44% 到 97% |
| 2026-10-10 | 改为只算 popover 那一行的鉴别器，全部找到就停；原来每次打开都算整个镜像 | 新规则的候选多了一个数量级，Debug 构建里一次算完整个镜像要 30 秒（SwiftUICore）到 144 秒（SwiftUI） |
| 2026-10-10 | 已知文件名写成生成的 Swift 源文件，不用 SwiftPM 资源 | 注入载荷与 CLI 里没有资源包，`Bundle.module` 找不到时直接崩；清单只有 56 KB |
| 2026-10-10 | 一段哈希输入有两种读法时，取先试的那个模块名 | 改代码时发现：`SwiftUI` 是 `SwiftUICore` 的前缀，原来读成哪一种取决于候选的遍历顺序。macOS 26.7 的四个镜像里没有实际撞上 |
| 2026-10-10 | 按现状提交推送，包括还原不出时 Debug 构建里 3–4 秒的耗时；反推与已知文件名清单以后下沉到 MachOSwiftSection | 用户：「先提交推送」。下沉的拆法（取鉴别器进 `SwiftDeclaration`，反推进一个新 target，`swift-section` 加子命令）与接法（仍在 App 进程里算，或新增引擎命令、在引擎进程里按镜像缓存）都未定，到 MachOSwiftSection 另写提案 |
