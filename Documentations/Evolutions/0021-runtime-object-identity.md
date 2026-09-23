# 0021 - RuntimeObject 的相等性只表达身份

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-09-23
- **最后更新**: 2026-09-23
- **所属愿景**: 无
- **关联提案**: [给 @objc @implementation 实现的 ObjC 类加粉色角标](draft-objc-implementation-class-badge.md)（`secondaryKind` 折叠成 `Properties.isSwiftClass` 在那份里）
- **实现分支 / PR**: `feature/runtime-object-identity`（从 `next` 切，并回 `next`）；复审修复在 `feature/runtime-object-identity-review-fixes`
- **配套文档**: 无 —— 判定理由见决策日志

## 摘要

`RuntimeObject` 的 `==` 现在比较**全部**存储属性：`name`、`displayName`、`kind`、`imagePath`、
`children`、`properties`。但代码里真正想问的问题有两个——「是不是同一个类型」和「这个对象的内容
变了没」——而 `Equatable` 只有一个槽位，于是两者被迫共用一套语义，结果是问「是不是同一个」的
那九处全部得到了错误答案。

本提案把 `==` / `hash` / `Identifiable.id` 改成只表达身份，即 `RuntimeObjectKey` 的
`(imagePath, name, kind)`；「内容变了没」搬到一个显式的 `hasSameContent(as:)` 上。

## 动机

### 一个已经在线上的缺陷

在一个**桥出的 Swift 类**（sidebar 上带蓝色 `C` 角标的 Objective-C 类）的接口里 ⌘-点击一个
同镜像的普通类，内容面板和标签页都正确，但 **sidebar 的高亮停在原处不动**。

链路上每一环都可读：

1. `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Theme/SemanticString+ThemeProfile.swift:104`
   —— Objective-C 接口里每个类型 token 都会建一个 `.link` 载荷对象，载荷把宿主的
   `Properties.isSwiftClass` 复制了过去。
2. `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift:139` 与 `:205`
   —— 引擎返回的是 `object.withImagePath(imagePath)`，而 `withImagePath`
   （`RuntimeObject.swift:56`）原样保留 `properties`。引擎修正了 `imagePath`，**没有**修正
   `properties`。
3. `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentTextViewModel.swift:279`
   —— `.push(interface.object)`，伪造的标记就此进入 `selectedRuntimeObject`。
4. `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectListViewModel.swift:124`
   —— `findCell` 用的是 `node.runtimeObject == object`。
5. `@Equatable` 宏（FrameworkToolbox 的 `SwiftStdlibToolbox`）比较所有未标注
   `@EquatableIgnored` 的存储属性，而 `RuntimeObject` 一个都没标。于是 `properties` 参与相等
   判定，比较失败，找不到 cell。

macOS 上 sidebar 的高亮只有这一条路——`SidebarCoordinator.swift` 的 `.selectedObject` 分支注释
写明「on macOS the runtime-object list scrolls to and highlights the root selection by observing
`documentState.$selectedRuntimeObject` directly」。

### 同一个病，另外三处

横向排查后发现这不是孤例，而是「把载荷型对象和权威型对象放在一起用 `==` 比」这个模式的四个实例：

- **Swift 同镜像跳转**：`resolveSwiftLinkTargets` 造的载荷 `properties` 为空、`children` 为空、
  `displayName` 是从 token 拼出的限定名；而 sidebar 里的权威对象
  （`RuntimeSwiftSection.swift:232-247`）带 `.isGeneric` / `.isSpecialized`，`children` 是真实
  子树。`RuntimeSwiftSection.swift:368` 同样原样把载荷当作结果返回。失配面比 Objective-C 那半
  **大得多**。
- **历史栈重复入栈**：`DocumentState.swift:373` 的 `selectionStack.last != object` 想表达「同一个
  对象连续 push 不重复记一笔」。全字段比较下，同一个类的载荷型和权威型被判为两个不同的对象，
  于是历史里出现两条同名记录，后退一次回到自己。
- **面板无谓重取**：`InspectorClassViewModel.swift:78`、`InspectorRelationshipsViewModel.swift:109`、
  `InspectorSwiftSpecializationViewModel.swift:59` 的
  `guard self.runtimeObject != runtimeObject else { return }`。这三处守卫正是
  `CLAUDE.md`「Reusable panes」一节要求的「re-entering the same object must not refetch」，
  而全字段比较让它形同虚设——同一个对象的两种形态会穿过守卫，重新取一次接口并闪一次 loading
  占位。`ContentCoordinator.swift:129` 的重绑守卫同理。

### 这不是设计，是补齐参数时随手填的

`git log -S` 定位到 `0bebce4a`（2026-01-05，*Improve performance and bug fixes for
RuntimeObjCSection*）。那次给当时还叫 `RuntimeObjectName` 的类型新增 `secondaryKind` 字段，
`MemberwiseInit` 生成的构造器要求填满每个参数，于是链接载荷那一行的 diff **只多了
`secondaryKind: runtimeObjectName.secondaryKind` 一项**，其余原样——从上下文抓了个同名字段填
进去。`secondaryKind` 后来折叠成 `Properties.isSwiftClass`（见关联提案），这个复制也跟着换了
形态，病根没动。

### 设计上本来就该分开

引擎自己其实知道该怎么做：`RuntimeEngine.swift:733` 的 `resolveSwiftReferenceInterface` 在跨镜像
解析时**显式重建**权威对象，连 `properties` 一起重算（`RuntimeSwiftSection.swift:545-567`），
注释原话是 "Each arm rebuilds the target as its defining section's authoritative `RuntimeObject`
… so the resulting navigation push lands on a real sidebar/tab entry"。

也就是说，「push 进去的对象必须能在 sidebar 里被找到」这个契约是被认识到的，只是四条解析路径里
只有一条做了权威化。与其要求每条路径都记得重建，不如让**比较本身**不去看那些会漂移的字段。

`RuntimeObjectKey` 的存在本身也是这个认识的产物——它的文档注释写着「Use this as a dictionary /
set key when lookups must survive `parent.withAppendedChild(child)` replacements」。已经有两处
调用点手工绕到了它上面（`SidebarRuntimeObjectViewModel.swift:555`、
`SidebarRuntimeObjectCellViewModel.swift:371`），其余九处没有。

## 前期调研

### `@Equatable` 的语义

`@Equatable` 来自 FrameworkToolbox 的 `SwiftStdlibToolbox`
（`Sources/SwiftStdlibToolbox/Macros/Equatable.swift`，源出 ordo-one/equatable）。它比较所有未标注
`@EquatableIgnored` 的存储属性，并且——因为类型同时声明了 `Hashable`——同步生成一致的
`hash(into:)`。`RuntimeObject` 上没有任何 `@EquatableIgnored`，所以 `children` 和 `properties`
都参与相等与哈希。

### 谁在依赖「全字段相等」

查遍 `RuntimeViewerCore` / `RuntimeViewerPackages` / `RuntimeViewerUsingAppKit` /
`RuntimeViewerMCP` / `RuntimeViewerCommandLine` 后，依赖「内容相等」语义的只有四处，且全部集中在
两个 cell ViewModel 家族里：

| 位置 | 作用 |
|------|------|
| `SidebarRuntimeObjectCellViewModel.swift:40` | `runtimeObject` 的 `didSet` 守卫。特化类型插入走的是 `runtimeObject = parent.withAppendedChild(child)`，靠这个守卫判断「真的变了」才重建 children 树 |
| `SidebarRuntimeObjectCellViewModel.swift:416` | DifferenceKit 的 `isContentEqual` |
| `InspectorRelationshipsCellViewModel.swift:63` | 同上 |
| `InspectorSwiftSpecializationCellViewModel.swift:52` | 同上 |

第一处是整个改动里最要紧的一环：`withAppendedChild` 只改 `children`，身份不变。如果 `==` 变成
身份语义而这处守卫不动，`guard` 会直接 return，**新生成的特化类型永远不会出现在 sidebar 里**。

### 间接依赖

不直接写 `==`，但通过合成的 `Hashable` 或容器吃到这套语义的：

- `RuntimeRelationshipsResolver.swift:78-79` 的 `OrderedSet<RuntimeObject>`（子类 / 遵循者去重）
- `RuntimeBookmark.swift:21` —— `RuntimeObjectBookmark` 持有 `RuntimeObject`，其 `Hashable` 由编译器合成
- `DocumentState.swift:373` 的历史栈、`:409` 的 tab 对象同步
- DifferenceKit 的 `differenceIdentifier`：两处 Inspector cell 直接返回整个 `RuntimeObject`
  （`InspectorRelationshipsCellViewModel.swift:60`、`InspectorSwiftSpecializationCellViewModel.swift:49`）

### 已验证的事实

- **`displayName` 可以安全地排除出相等判定**。`name` 是 mangled name，`displayName` 由同一个
  `typeName` 打印而来，两条构造路径（`RuntimeSwiftSection.swift:215` 与 `:545`）用的是同一套判定
  与打印选项，所以同一个 mangled name 必然算出同一个 `displayName`。唯一的例外正是链接载荷——
  它的 `displayName` 是从 token 拼出来的限定名——而那恰恰是我们要让它与权威对象相等的场景。
- **`RuntimeObject.id` 当前无人读取**。全代码库的 `.id` 引用都属于 tab、批次、索引项等其它类型。
- **Sidebar 的 `isContentEqual` 在特化插入路径上本来就是空转**：
  `SidebarRuntimeObjectViewModel.applySpecializationAdded` 的注释写明两次快照里是同一个 cell 实例
  （`isContentEqual` 恒真，适配器跳过），真正驱动刷新的是 `reloadRowRelay`。
- **Inspector 两处 cell 的行只渲染 `displayName` 与图标**，不渲染 `children`。
- **`OrderedSet` 去重不会遇到「同身份而 `properties` 不同」**：
  `RuntimeRelationshipsResolver` 在 `objcKey` 与 `swiftMangledKey` 同时存在时会跳过 Swift 臂，
  正是为了避免同一个类被 materialize 两次。**这是当前代码的性质，不是类型层面的保证。**
- **`@EquatableIgnored` 不可用——实测推翻了原先的推测。** 原以为冲突会出现在 `@Default` /
  `@Init` 上，实际冲突方是 `@MemberwiseInit`：它也读这个 peer macro，被标注的属性直接从生成的
  构造器里消失，`withImagePath` 与 `withAppendedChild` 当场编译失败
  （`extra arguments at positions #2, #5 in call`）。因此走备选路径，手写 `==` 与
  `hash(into:)`。

## 提议方案

**一、`RuntimeObject` 的相等性只看身份。** `name`、`kind`、`imagePath` 参与 `==` 与 `hash`；
`displayName`、`children`、`properties` 用 `@EquatableIgnored` 排除。这三个字段正好是
`RuntimeObjectKey` 已经排除掉的那三个，所以改完之后 `a == b` 与 `a.key == b.key` 等价。

**二、`Identifiable.id` 改成 `RuntimeObjectKey`。** 当前的 `id: RuntimeObject { self }` 是个自指的
空转；改完之后 `id` 既是正确的身份，也不会在真正被用到时（SwiftUI `ForEach`、rx 适配器）拖着
整棵子树。

**三、新增 `hasSameContent(as:)` 承接「内容变了没」。** 四处调用点改用它。比较是**浅层**的：
`children` 按元素身份逐个比，能发现子节点的增、删、替换，发现不了孙辈内部的变化。依据是特化
插入总是发生在被定位到的那个父 cell 的直接 children 层
（`SidebarRuntimeObjectViewModel.applySpecializationAdded` 定位到的就是要加子节点的父），而
Inspector 两处只决定一行要不要重画，那一行根本不渲染 children。

**四、九处身份比较统一写 `==`。** 包括把现有那两处手写的 `.key ==` 化简掉。`.key` 从此只出现在
字典键场合。

**五、两处 Inspector cell 的 `differenceIdentifier` 改成 `RuntimeObjectKey`。** 理由与保留
`RuntimeObjectKey` 作字典键一样：别让 DifferenceKit 长期持有整棵子树。

**六、删掉链接载荷那行 `properties` 复制**
（`SemanticString+ThemeProfile.swift:104`）。换成身份语义之后它已经影响不了任何比较，是纯粹的
死值；而在 `isSwiftClass` 这个名字下，把宿主的标记贴到一个不相关的目标类型上，比原先的
`secondaryKind` 更具误导性。

### 非目标

- **不动 `Codable`**。编码仍是全字段，跨进程负载与书签文件格式一字不变。
- **不动 `ComparableBuildable`**。它只服务 sidebar 的排序顺序，与身份语义是两回事（用户明确）。
- **不删 `RuntimeObjectKey`**。哈希只算三个字段不等于字典只存三个字段：把
  `[RuntimeObjectKey: …]` 换成 `[RuntimeObject: …]` 会让每个键持有整棵 children 子树，在 14k
  对象的镜像上是实打实的内存。
- **不重建引擎的解析路径**。让四条解析路径都产出权威对象是另一条可走的路，本提案选择让比较
  不看会漂移的字段，理由见「替代方案考量」。
- **不动 `runtime-viewer-cli` 与 MCP 的输出模型**。

## 详细设计

### 类型定义

```swift
@Codable
@Equatable
@MemberwiseInit(.public)
public struct RuntimeObject: Hashable, Identifiable, Sendable {
    public struct Properties: OptionSet, Codable, Hashable, Sendable { /* 不变 */ }

    public let name: String

    /// 展示用名称。不参与身份：同一个 mangled name 必然算出同一个 displayName，
    /// 唯一的例外是内容面板的链接载荷，而那正是要与权威对象相等的场景。
    @EquatableIgnored
    public let displayName: String

    public let kind: RuntimeObjectKind

    public let imagePath: String

    /// 子树。不参与身份：`withAppendedChild(_:)` 之后仍是同一个类型。
    @EquatableIgnored
    public let children: [RuntimeObject]

    /// 展示属性。不参与身份：同一个类型在不同构造路径下可能携带不同的标记。
    @Default([])
    @Init(default: [])
    @EquatableIgnored
    public let properties: Properties

    public var id: RuntimeObjectKey { key }
}
```

`@EquatableIgnored` 若无法与 `@Default` / `@Init` 共存，退化为手写：

```swift
extension RuntimeObject {
    public static func == (lhs: RuntimeObject, rhs: RuntimeObject) -> Bool {
        lhs.imagePath == rhs.imagePath && lhs.name == rhs.name && lhs.kind == rhs.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(imagePath)
        hasher.combine(name)
        hasher.combine(kind)
    }
}
```

### 内容比较

```swift
extension RuntimeObject {
    /// `==` 回答「是不是同一个类型」，这个方法回答「这个对象的内容变了没」。
    ///
    /// 比较是**浅层**的：`children` 按元素身份逐个比，所以能发现子节点的增、删、替换，
    /// 发现不了某个孙辈自己内部的变化。够用是因为唯一的写入路径
    /// （`SidebarRuntimeObjectViewModel.applySpecializationAdded`）总是定位到要加子节点的
    /// 那个父 cell，变化必然出现在直接 children 层。若将来出现「祖辈不动而孙辈变化」的
    /// 写入路径，这里要改成递归。
    public func hasSameContent(as other: RuntimeObject) -> Bool {
        self == other
            && displayName == other.displayName
            && properties == other.properties
            && children == other.children
    }
}
```

### 调用点改写

| 文件:行 | 现在 | 改成 |
|---|---|---|
| `SidebarRuntimeObjectCellViewModel.swift:40` | `guard oldValue != runtimeObject` | `guard !oldValue.hasSameContent(as: runtimeObject)` |
| `SidebarRuntimeObjectCellViewModel.swift:416` | `runtimeObject == source.runtimeObject` | `runtimeObject.hasSameContent(as: source.runtimeObject)` |
| `InspectorRelationshipsCellViewModel.swift:63` | 同上 | 同上 |
| `InspectorSwiftSpecializationCellViewModel.swift:52` | 同上 | 同上 |
| `InspectorRelationshipsCellViewModel.swift:60` | `differenceIdentifier: RuntimeObject` | `differenceIdentifier: RuntimeObjectKey { runtimeObject.key }` |
| `InspectorSwiftSpecializationCellViewModel.swift:49` | 同上 | 同上 |
| `SidebarRuntimeObjectViewModel.swift:555` | `viewModel.runtimeObject.key == object.key` | `viewModel.runtimeObject == object` |
| `SidebarRuntimeObjectCellViewModel.swift:371` | `contains(where: { $0.key == child.key })` | `contains(child)` |
| `SemanticString+ThemeProfile.swift:104` | `properties: …intersection(.isSwiftClass)` | 整行删除 |

其余七处身份比较（`SidebarRuntimeObjectListViewModel.swift:124`、三个 Inspector ViewModel 的
`update(for:)` 守卫、`ContentCoordinator.swift:129`、`DocumentState.swift:373` 与 `:409`）**一个字
不改**——它们写的就是 `==`，语义翻转之后自动变正确。这正是本方案与逐点修改的区别所在，也是它需要
characterization 测试兜底的原因。

## 替代方案考量

**保持 `==` 全字段，把九处身份比较逐个改成 `.key ==`。** 改动同样能修好那些 bug，而且不会静默
翻转任何现存语义。否掉的理由：`==` 会继续是一个**默认给出错误答案**的运算符，下一个写身份比较的
人仍然会掉进去（过去九次有七次掉进去了）；而需要内容语义的只有四处，且全部在明确的「内容变化
检测」语境里，把它们写成显式方法反而更清楚。

**让四条解析路径都产出权威对象。** 即照 `resolveSwiftReferenceInterface` 的样子，让
`RuntimeObjCSection.interface(for:)` 与 `RuntimeSwiftSection.interface(for:)` 也重建权威对象再
返回。这修的是数据源而不是比较，方向更正。否掉的理由：它要求每一条现有和将来的解析路径都记得
重建，而漏一条的症状是隐蔽的 UI 失配；本提案的做法是让比较对这类漂移免疫，两者不冲突，数据源的
清理可以另案推进。

**给 `RuntimeObject` 加一个 `Content` 投影类型**（`a.content == b.content`）。语法上最贴近现状，
否掉的理由：多一个类型，而它的字段必须与 `RuntimeObject` 手工保持同步，加字段时漏掉不会有任何
编译错误。

**删掉 `RuntimeObjectKey`，统一用 `RuntimeObject`。** 概念确实更少，但字典键会因此持有整棵
children 子树，见「非目标」。

**`hasSameContent` 做全递归深比较。** 不依赖「变化总在直接 children 层」这个推理，漏报不了。
否掉的理由：`didSet` 每次赋值都要跑一遍，在 14k 对象的镜像上是真实开销，而且很容易变成没人注意
的热点。推理若被证伪，characterization 测试里钉特化插入的那条用例会先红。

## 影响

### 用户可见变化

没有新增、改变或移除任何界面、交互、快捷键或菜单项。三个隐蔽缺陷会被修好：

- 在桥出的 Swift 类的 Objective-C 接口里跳转后，sidebar 高亮会跟随（此前停在原处）
- 同一个类型连续跳转不再在导航历史里留下两条记录
- Inspector 与内容面板重新进入同一个对象时不再重取接口、不再闪一次 loading 占位

### 可发现性

不适用——没有新功能，没有新设置项。

### 数据与配置兼容

`Codable` 编码不变，所以书签文件（`RuntimeObjectBookmark`）、跨进程负载、导出元数据都保持
逐字节兼容，旧版本写的文件新版本照读，反之亦然。

书签的**去重**语义会从「全字段相同才算同一条」变成「身份相同就算同一条」。已存书签不受影响；
唯一可能的行为变化是：若某个镜像里存在两条身份相同而 `properties` 不同的书签（需要它们在不同
版本的 app 里分别添加），新版本会把它们视作同一条。没有迁移逻辑，也不需要回退路径。

### 平台与最低版本

无变化。改动全部在 `RuntimeViewerCore` 与 `RuntimeViewerPackages` 的纯 Swift 代码里，不涉及
系统 API。

### 发布

不需要新的权限、entitlement 或隐私清单条目；不影响公证、App Store 审核或 Sparkle 更新流程。

## 落地步骤

1. **建 worktree 与分支** —— `.worktrees/RuntimeViewer-ObjectIdentity`，分支
   `feature/runtime-object-identity`，基线是 `next`（含尚未推送的两个提交）。按 `create-worktree`
   skill 建本地依赖符号链接。
2. **写 characterization 测试，全绿** —— 锁住改动前的当前行为，**包括那些已知是 bug 的行为**。
   覆盖十处直接调用点，外加间接依赖那一圈：`OrderedSet` 去重、`RuntimeObjectBookmark` 的合成
   `Hashable`、`DocumentState` 的历史栈与 tab 同步、DifferenceKit 的 diff 路径。这一步单独提交，
   它是后面所有判断的基线。
3. **翻语义** —— `@EquatableIgnored` 标注（或手写 `==` / `hash`）、`id` 改 `RuntimeObjectKey`、
   加 `hasSameContent(as:)`。此时 characterization 会红一批。
4. **改四处内容比较调用点** —— 第 3 步红的那批里，属于「内容比较」的应当由此转绿。
5. **逐条裁决剩余的红** —— 每一条要么保持原状（说明语义没被意外改动），要么显式翻转断言，并在
   决策日志里留一行说明为什么当初那个断言锁的是 bug 行为。**不允许静默删掉一条红的断言。**
6. **清理** —— 化简两处 `.key ==`、改两处 `differenceIdentifier`、删链接载荷那行死值。
7. **整包验证** —— `./RunScript.sh --no-launch --derived-data /tmp/claude/DerivedData/…`
   跑完整 workspace；`RuntimeViewerCoreTests` 与 `RuntimeViewerApplicationTests` 全量，认原始
   退出码而非 xcsift 摘要。
8. **合回 `next`**，并在本提案里把状态推到 `Implemented`。

**收尾时必须判断两件事**（结论写进决策日志）：

- 要不要配套实现说明 —— 倾向要：「`==` 是身份、`hasSameContent` 是内容」这条契约从签名看不出来，
  而违反它的后果（特化类型不显示 / sidebar 不高亮）离原因很远。
- 有没有引入新术语 ——「身份（identity）」与「内容（content）」这对区分若在别处复用，登记进
  `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-09-23 | Created as Draft | 用户：「把 RuntimeObject 的 Hashable, Identifiable 全部换成比较 RuntimeObjectKey 可行吗，目前这几个实现和 Equatable 都不合理」 |
| 2026-09-23 | `==` / `hash` / `id` 归身份，内容比较另开入口 | 代码里有两类使用者而 `Equatable` 只有一个槽位；九处要身份、四处要内容，多数派归 `==`，少数派显式命名 |
| 2026-09-23 | 内容比较做成 `hasSameContent(as:)` 实例方法，而非 `Content` 投影类型或让调用点各写各的 | 「身份 vs 内容」这对概念明写在类型上；投影类型的字段要手工与 `RuntimeObject` 同步，漏了不报错 |
| 2026-09-23 | `hasSameContent` 浅层比较，`children` 按元素身份比 | 特化插入总是发生在被定位到的父 cell 的直接 children 层；Inspector 两处只决定一行要不要重画，而那一行不渲染 children。全递归的代价是 `didSet` 每次赋值都跑一遍 |
| 2026-09-23 | 保留 `RuntimeObjectKey` 作字典键类型 | 哈希只算三个字段不等于字典只存三个字段——换成 `[RuntimeObject: …]` 会让每个键持有整棵子树 |
| 2026-09-23 | `Identifiable.id` 改成 `RuntimeObjectKey`，而非删掉 conformance 或保持 `self` | 当前无人读取，改的代价为零；真用到时不会拖着整棵子树 |
| 2026-09-23 | 九处身份比较统一写 `==`，现有两处 `.key ==` 一并化简 | `==` 已经是身份语义，再写 `.key ==` 是冗余，且会让人误以为不写 `.key` 就是全字段比较 |
| 2026-09-23 | 链接载荷那行 `properties` 复制在本提案一起删，不另案 | 它与本提案是同一个问题的两个面：载荷型对象不该携带显示属性 |
| 2026-09-23 | 测试先全量 characterization 锁住当前行为（含 bug 行为），改完逐条裁决 | 用户要求「确保改前的正确逻辑和改后一致」。语义翻转是静默的，编译器不报错，只有基线测试能证明「没有顺手改坏一个没人提到的行为」 |
| 2026-09-23 | 覆盖边界含间接依赖 | `OrderedSet` 去重、书签的合成 `Hashable`、`DocumentState` 历史与 tab、DifferenceKit diff 都会因 `==` 翻语义而静默改变行为 |
| 2026-09-23 | 从 `next` 切 feature 分支并回 `next`，不走 main | `next` 领先 `main` 272 个提交且依赖 MachOSwiftSection 的未发布分支（`main` 钉 `exact: 0.15.2`）。从 main 切虽能让这个修复独立进发布分支，但要在还带着 `secondaryKind` 的 `RuntimeObject` 上重做一遍，并在 `next` 合并时手工解冲突 |
| 2026-09-23 | 不动 `ComparableBuildable` | 用户明确：它只在 sidebar 排序用，是故意的 |
| 2026-09-23 | 状态置为 Accepted，开始实现 | 用户：「提案先提交到 next，然后改成 Accepted 开工」 |
| 2026-09-23 | 手写 `==` / `hash(into:)`，放弃 `@EquatableIgnored` | 实测：`@MemberwiseInit` 也读这个 peer macro，被标注的属性从生成的构造器里消失。提案原先猜的冲突方（`@Default` / `@Init`）猜错了 |
| 2026-09-23 | 16 条断言显式翻转，9 条 Contract 断言原样通过 | 翻转的理由逐条写在测试旁边而不是这里——两处记同一件事必然漂移。关键在于分布：改动落地后红的 8 条全部是标记为 Defect 的，Contract 一条未红，这就是「改动精确命中目标且没有误伤」的证据 |
| 2026-09-23 | `RelationshipsEquivalenceSnapshotTests` 的失败判定为与本提案无关 | 把 `RuntimeObject.swift` 退回改动前重跑，同样的 4 行 missing / 4 行 unexpected（`__C.Decimal.FormatStyle` ↔ `__C.NSDecimal.FormatStyle`）。是上游 demangling 的打印差异，基线快照录制时的上游版本与现在不同 |
| 2026-09-23 | 一处调用点没有测试覆盖：`ContentCoordinator.swift:129` | 它在 `RuntimeViewerUsingAppKit` 这个 app target 里，而该 target 下只有 `RuntimeViewerSourceEditorBridgeTests`，没有针对 app 代码的测试 target。语义翻转让它少一次无谓重绑，方向与另外八处一致，但只有整包构建验证了它能编译，没有测试证明行为 |
| 2026-09-23 | 记录一个挡路的项目状态问题：`RuntimeViewerPackages/Package.resolved` 的 MachOSwiftSection pin 比 `RuntimeViewerCore/Package.resolved` 旧 | 单独 `swift build` 这个包会因为缺 `ObjCImplementationClasses` 而失败，跑包测试前得临时对齐 pin。workspace 构建不受影响（它有自己的 resolved）。不属于本提案范围，未改动 |
| 2026-09-23 | 不写配套实现说明 | 「`==` 是身份、`hasSameContent(as:)` 是内容」这条契约写在 `RuntimeObject` 的 `==` extension 注释上，浅层比较的限制写在方法上，不用 `@EquatableIgnored` 的原因写在紧邻的注释里，完整推理在本提案。再单开一份会变成两处记同一件事，必然漂移 |
| 2026-09-23 | 不新增术语表条目 | 「身份 / 内容」是通用编程概念，不是本项目特有的说法 |
| 2026-09-23 | 验收通过，状态置为 Implemented | 整包 `./RunScript.sh --no-launch` 三个 Build Succeeded 零 error；`RuntimeViewerCore` 505 个测试仅剩那条与本提案无关的快照失败，`RuntimeViewerPackages` 299 个测试全绿 |
| 2026-09-23 | 复审：`/code-review xhigh` 报 12 条，逐条裁决 | 四问与裁决记在 [`KnownIssues/2026-09-23-runtime-object-identity-review-findings.md`](../KnownIssues/2026-09-23-runtime-object-identity-review-findings.md)，编号 `OBJID.<N>`；修复在 `feature/runtime-object-identity-review-fixes` |
| 2026-09-23 | 「一个字不改」的七处里有三处其实依赖内容，改回按内容比较 | Specialization 页的 `update(for:)` 守卫：它的行就是 `children`，生成特化后回到父类型时新特化不显示。历史栈的连续去重与活动标签页同步：保留了先到的形态，后退或切回标签页时恢复的是链接载荷。本提案把这三处归成了「身份比较」，而 characterization 测试的数据恰好没有长出子节点，也没有让两种形态先后到达，所以没拦住（OBJID.1、OBJID.2） |
| 2026-09-23 | 翻回 `specializationPaneDoesNotRebuildOnPropertiesDifference` | 改为「同一类型带不同 properties 进入时，重建出相同的行」。当初把「不重建」当作修好钉住，但这个面板不取数据、没有加载占位，重建相同的行看不出来；它改按内容守卫后属性不同就会重建，断言因此改成重建前后的行一致 |
| 2026-09-23 | 「已验证的事实」第一条（`displayName` 可以安全排除出相等判定）的前提不成立 | 协议嵌套在类型里时，sidebar 用它自己的短名（`currentName`），跳转路径用限定名，并非「只有链接载荷例外」。排除 `displayName` 的结论不变，但 Relationships 按 `displayName` 查遵循者，所以 resolver 改为从 mangled `name` 反查限定名（OBJID.3）。正文保持落地时的原样，更正只记在这里 |
| 2026-09-23 | 补上编号 0021 | 落到 `next` 时漏了编号：规则是在落到长期共享分支的那次提交里编号，0019、0020 都是这么做的。同一批把「不写配套实现说明」起的三行收尾记录挪回它们实际发生的位置，它们原先被插在了「不动 `ComparableBuildable`」之前 |
