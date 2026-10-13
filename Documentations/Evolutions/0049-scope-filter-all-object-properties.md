# 0049 - Filter Scope 补齐 RuntimeObject 的全部属性

- **状态**: Implemented
- **创建日期**: 2026-10-13
- **最后更新**: 2026-10-13

## 摘要

侧栏对象列表的 Filter Scope（过滤栏上 scope 按钮弹出的 popover）在 Properties 一节只能按 `isGeneric`、
`isSpecialized` 两个 `RuntimeObject.Properties` 位过滤。此后 Core 加的五位都没有过滤项：ObjC 类与 Swift 类互标的
`isObjCImplementation`、`isSwiftClass`、`isObjCClass`（[0038](0038-objc-implementation-class-badge.md)、
[0026](0026-objc-swift-class-counterparts.md)），以及局部类型的 `isLocalType`、`isPositionNamedLocalType`
（[0031](0031-private-discriminator-tag.md)）。本提案让 Properties 一节覆盖全部七位（`isSwiftClass` 与 `isObjCClass`
是同一个桥接类的两面，合成一行，共六行），并让以后新加的位在没有过滤项之前编译不过。

## 方案

- **Core**：`RuntimeObject.Properties` 新增 `Flag` 枚举，一位一个 case，raw value 就是位序号；七个静态成员改由
  `Properties(_ flag:)` 构造，值不变（`properties` 按 raw value 编码，位序号是线上格式，Core 测试把七个值钉死）。
  新的一位从此是「`Flag` 加一个 case，再由它构造静态成员」。
- **`RuntimeObjectScope`**（RuntimeViewerApplication）：新增 `RuntimeObjectScope.Property` 枚举，case 顺序即 popover
  的行序：`generic`、`specialized`、`objcImplementation`、`bridgedSwiftClass`、`localType`、`positionNamedLocalType`。
  `init(filtering:)` 对 `Flag` 做穷尽的 switch，决定每一位归哪一行——**这就是「以后加位必须改这里」的保证**：漏了就编译
  不过。各行的 `flags` 由它反推，所以两者不会不一致；一行匹配「带其中任意一位」，`bridgedSwiftClass` 因此同时选中 ObjC 那面
  （`isSwiftClass`）和 Swift 那面（`isObjCClass`）。各行的约束存进 `[Property: PropertyState]`，`.any` 从不存入，所以约束
  相同的两个 scope 必然相等（popover 提交前的 `next != draft` 判断和 scope 按钮的高亮都依赖这一点）；读写走
  下标 `scope[property]`。原来的 `generic` / `specialized` 两个属性与同名 init 参数去掉，init 改收 `propertyStates:`，
  用到它们的测试照改。
- **popover 的 ViewModel**：`setGeneric` / `setSpecialized` 两路输入合成一路
  `setPropertyState: Signal<(RuntimeObjectScope.Property, RuntimeObjectScope.PropertyState)>`。
- **popover 的 ViewController**：`PropertyRow` 像 `KindGroupRow` 持有自己的 group 那样持有自己的 `Property`，行按
  `Property.allCases` 生成。行标题：`Generic`、`Specialized`、`@objc @implementation`、`Bridged Swift Class`、`Local`、
  `Position-Named Local`；每行一个 tooltip，说明这一行选的是哪些对象。标题与 tooltip 也是对 `Property` 的穷尽 switch，
  新加一行同样编译不过直到补上。
- **行的显隐**沿用现有规则：当前镜像里没有对象带这一行的任何一位，就不显示这一行。顺带修一个旧问题：一行都不显示时（比如
  纯 C / 纯 ObjC 镜像），把「Properties」标题和它上面的分隔线一起隐藏，而不是留一个空标题。
- **`AGENTS.md`**：Development Guidelines 加一条——新的 `Properties` 位要声明成 `Flag` 的 case，并在 Filter Scope 有一行。
- **测试**：Core 的 `RuntimeObjectTests` 钉住七位的值。`RuntimeObjectScopeTests`：一条遍历 `Property.allCases` 的参数化
  用例，断言每一行设成 Only / Exclude 都让 `isActive` 为真并真正约束 `passes`，设回 Any 后与默认 scope 相等；每一位都归到
  一行、每一行至少有一位；`bridgedSwiftClass` 两面都选中；局部类型两位的组合（Local Only + Position-Named Exclude 只剩有
  函数名的局部类型）；外层类型因局部子类型匹配而保留。popover 的 ViewModel 与 ViewController 在 App target 里，没有对应的
  测试 target，只做编译验证。

没有询问就采用的假设：

1. 行与行之间是「且」，一行之内是「或」（只有 `bridgedSwiftClass` 一行有两位）。
2. 沿用现有的「自己或任一后代通过就保留」规则。于是 Local Only 时，外层类型作为通往局部类型的路径保留，而局部类型
   里再嵌套的类型不显示；Local Exclude 时，里面还嵌着类型的局部类型会作为它们的父节点留下。原因是按 Core 的定义，
   嵌在局部类型里的类型不算局部类型、也不带 `Local` tag，过滤与 tag 保持一致。
3. 不做行间联动（如 Position-Named 缩进在 Local 之下）。自相矛盾的组合（Local Exclude + Position-Named Only）就是
   什么都不剩，与 Generic / Specialized 现有的组合行为一致。
4. 改动落在 `next`：局部类型那两位只在 `next` 上（d6d37947），`main` 还没有。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-13 | Created as Draft | 用户原话：「RuntimeObject那里的Scope过滤加上最新的两个Properties，目前只处理了泛型和特化类型」 |
| 2026-10-13 | Properties 一节改为 `Property` 枚举驱动，而不是照现有写法再抄 | 照抄意味着 ViewModel 里每一位一段几乎相同的处理、ViewController 里每一位一个手写行与一处显隐 / 回显；枚举驱动与同一 popover 里 Kind 一节的写法一致 |
| 2026-10-13 | 范围从局部类型两位扩大到全部五位（另加 `isObjCImplementation`、`isSwiftClass`、`isObjCClass`） | 用户贴出这三位的定义：「这几个也没有加」 |
| 2026-10-13 | 约束改存 `[Property: PropertyState]`，不再一行一个存储属性 | 一行一个属性意味着六个存储属性、六参数的 init、读写各一个六分支的 switch；字典里不存 `.any`，相等性仍然成立 |
| 2026-10-13 | `isSwiftClass` 与 `isObjCClass` 合成一行 `Bridged Swift Class` | 用户决定。这两位分别在同一个桥接类的 ObjC 条目与 Swift 条目上，分成两行时行间是「且」，没法一次列出两面；合成一行后要单看一面，配合 Kind 一节即可 |
| 2026-10-13 | 「以后加位必须改这里」用编译期保证：Core 加 `Properties.Flag`，`RuntimeObjectScope.Property.init(filtering:)` 对它做穷尽 switch | 用户要求：「以后Properties加内容这里也要改」。只在注释或 `AGENTS.md` 里写一句，忘了也没有任何东西会变红；OptionSet 的静态成员又无法枚举，只有在 Core 把位列成枚举，App 侧才能穷尽地 switch。代价是 Core 多一个公开枚举，七个静态成员的值不变 |
| 2026-10-13 | 状态 Draft → In Progress | 用户在两轮修改后给出最终决定（合并两位、加位必须改这里），按此实现 |
| 2026-10-13 | 状态 In Progress → Implemented，编号 0049，直接提交到 `next` | 代码与本提案同一个提交。验证：Packages 的 `RuntimeObjectScopeTests` 等三个套件 39 例、Core 的 `RuntimeObjectTests` 41 例全过，App 用 `RuntimeViewer-Debug.xcworkspace` 按 Debug-arm64e 编译通过。**留给人工检查**：popover 没有在 App 里打开看过——六行标题在 300 点宽里是否放得下、tooltip、纯 ObjC 镜像里 Properties 一节是否整节隐藏。不需要配套的使用指南或实现说明：行为由本提案与 `AGENTS.md` 第 10 条交代。术语表不加新词：「局部类型」「按位置命名」已有条目，Filter Scope 与桥接类不是本次引入的 |
