# Draft - C++ 类模板的特化收进一个节点

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-27
- **最后更新**: 2026-11-27
- **所属愿景**: 无
- **关联提案**: [0103 C++ 对象](0103-cplusplus-objects.md)（对象树的来历）、[0107 导出 C++ 对象](0107-cplusplus-export.md)（导出展开对象树的规则）
- **实现分支 / PR**: `feature/cplusplus-class-template-groups`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

C++ 对象树里，同一个作用域中同一个类模板的所有特化收进一个以模板名命名的节点：`std::__1` 下不再平铺
`vector<int, std::__1::allocator<int>>`、`vector<char, …>`……，而是一个 `vector` 节点，展开后是它的各个特化，
特化行照旧显示全名。只有一个特化的模板也收进节点。节点是新的对象类型 `.cPlusPlus(.classTemplate)`，
绿色 `T` 图标；选中它，内容区列出全部特化的声明，每行可点击跳到那个特化。归组做在 Core 的对象树里，
侧栏、路径栏（jump bar，编辑区顶部的路径控件）、镜像页与 iOS 侧栏看到的是同一棵树。名字里的模板名取自上游
MachOKitExtensions 现成的 `baseName`，不解析文本。`objectsInImage` 请求多一个可选字段，只有声明认识这种
新类型的请求方才拿到分组后的树，旧版请求方照旧收到平铺的特化。命名空间的界面文字与导出结果都不变。

## 动机

0103 把 C++ 对象树按作用域逐段建起来，每个作用域成分是一个节点，`displayName` 就是这一段的原文
（0103 方案第 3 条：`displayName` 是最后一段，`vector<int, std::__1::allocator<int>>`）。模板的每个特化
都是独立的一段，于是：

- **列表被长名字淹没。** libc++ 这类镜像的 `std::__1` 下，`basic_string<…>`、`__hash_table<…>`、
  `__tree<…>`、`__function::__func<…>` 的特化成排出现，每行都是几十到上百字符的模板参数。用户要找的是
  「`vector` 有哪些特化」，现在只能在一长串里逐行辨认前缀。
- **同一模板的特化没有聚在一起的入口。** 现在只能靠过滤框输入 `vector` 再逐行看，没有一处能一眼看到
  一个模板在这个镜像里被实例化了几次、各是什么参数。

代码路径：`RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/CPlusPlus/CPlusPlusObjectTreeBuilder.swift`
的 `Node.object(parentPath:imagePath:)` 给每个子节点各做一个对象，`children` 按 `RuntimeObject` 的比较规则排序。

## 前期调研

- **对象树怎么建的**：`RuntimeCPlusPlusSection.init`
  （`RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/CPlusPlus/RuntimeCPlusPlusSection.swift:52-96`）
  读 `CPlusPlusSymbolIndexStore` 的作用域树（`treeScope(of:in:)`，`:103-121`）和
  `CPlusPlusClassIndexStore` 的类（RTTI，运行时类型信息），交给 `CPlusPlusObjectTreeBuilder.objects(globalScope:classPaths:)`。
  builder 的 `Node.insert(_:)` 按作用域树插节点，`insertClass(at:)` 按 RTTI 的类路径补节点，缺的中间段现编
  （上一层是类就编成类，否则编成命名空间），这些现编的节点没有作用域树里的任何信息。
  `object(parentPath:imagePath:)`（`CPlusPlusObjectTreeBuilder.swift:157-173`）给节点做 `RuntimeObject`：
  `name` 是 `::` 连起来的限定名，`displayName` 是这一段，`kind` 只有 `.cPlusPlus(.class)` 与
  `.cPlusPlus(.namespace)`。section 把整棵树按 `name` 登记进 `objectsByName`，界面、层级、派生类都按名字查。
- **上游已有模板名**：MachOKitExtensions 的 `CPlusPlusScope.baseName`
  （`Sources/Symbols/CPlusPlusSymbols/CPlusPlusScope.swift:20-25`）文档写明「去掉模板参数的最后一段——
  `vector<int, std::__1::allocator<int>>` 的是 `vector`——让同一类模板的每个特化共享它；函数则是不带参数的
  函数名」；`CPlusPlusClass.baseName`（`CPlusPlusClass.swift:24-25`）是类名最后一段去掉模板参数。两者都由
  demangler 的语法树给出（`CPlusPlusDemangler.ParsedName.scopeComponentBaseName(at:)`），自 3.0.0
  （2026-11-19 的 `ddeb48f`）就有；RuntimeViewerCore 的下限是 `from: "3.3.0"`，**不用改上游、不用抬版本**。
  `CPlusPlusClass` 只给最后一段的 `baseName`，RTTI 路径中间的各段没有。
- **带模板参数的作用域不一定是 type**：上游给作用域成分打类型提示时（`Sources/Symbols/CPlusPlusDemangling/CPlusPlusDemangling.cpp:458-478`），
  只有 `std`、匿名命名空间、闭包与无名类型有明确提示，带模板参数的普通名字没有；最终 kind 看符号证据，
  可能是 `undetermined`，builder 把它做成 `.cPlusPlus(.namespace)`。所以归组不能只看 `.class`：
  **名字带模板参数（`baseName` 与这一段不同）就是类模板的特化**，C++ 的命名空间不能是模板。
- **对象类型的编码与排序**：`RuntimeObjectKind`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Objects/RuntimeObjectKind.swift`）
  的 `Codable` 由编译器按 case 名合成，旧版解码器遇到不认识的 case 会让整个回复解码失败。`level` 是私有的、
  只给 `<` 用、从不编码（`:66-70` 的注释），改编号不影响任何对端。`RuntimeObject` 按 `imagePath`、`kind`、
  `displayName` 依次比较（`RuntimeObject.swift:222-228`），`ComparableBuildable` 的每一步只在 `<` 两个方向都不成立时
  才看下一步（FrameworkToolbox `SwiftStdlibToolbox/ComparableBuildable.swift` 的 `KeyPathComparisonStep`）。
- **线上兼容的先例**：`ObjectsInImageCommand.includesCPlusPlusObjects`
  （`RuntimeViewerCore/Sources/RuntimeViewerCore/Engine/RuntimeEngine+Commands.swift:160-190`）是可选字段，只有为真时
  才编码，保证「旧版请求方的回复里不会有它解不开的 kind」；`ObjectsInImageCPlusPlusWireTests` 用冻结的旧请求
  结构固定这一点，`Documentations/CommunicationAndEngineArchitecture.md` 第 408 行把它记为第五例。**0103 之后、
  本提案之前的 App 会设这个字段**，如果新版对端直接在回复里放新 kind，这些 App 连到新版的远端设备（Bonjour 共享的
  Mac、iOS 设备上的 App）时，这个镜像的对象列表整个解不开。
- **各处消费方**（全部读过）：
  - 侧栏顶层按对象类型分区（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Sidebar/RuntimeObject/SidebarRuntimeObjectSection.swift`），
    子节点挂在 cell 下，顺序就是 `children` 的顺序；iOS 侧栏用同一个 AppCore ViewModel。
  - 路径栏把子节点再排一次（`RuntimeViewerPackages/Sources/RuntimeViewerAppUI/EditorArea/JumpBar/EditorJumpBarItemStore.swift:383`
    的 `object.children.sorted()`），顶层按类型分组、组间加分隔线（`:413`）。
  - 过滤范围（Filter Scope）按勾选的类型集合过滤（`RuntimeObjectScope.includedKinds`，空集表示不限），
    `passes(_:)` 看对象自己，`matchesRecursively(_:)` 让有子孙通过的父节点留下
    （`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Sidebar/RuntimeObject/RuntimeObjectScope.swift:179-203`）；
    画哪些勾选框由 `allRepresentableKinds`（`:143-147`）决定，`RuntimeObjectScopeMemory` 记住的就是这个集合。
    勾选框的标题在 `SidebarRuntimeObjectScopeViewController.swift:628-629`，是穷举 switch。
  - 命名空间的界面在「Declared here」一段把子对象逐个印成 `class X;` / `namespace X {}`
    （`CPlusPlusInterfacePrinter.swift:222` 与 `declaredSection(title:declared:isIndented:)`，`:360-381`），
    子对象表来自 `RuntimeCPlusPlusSection.namespaceDeclaration(of:)` 的 `object.children`（`:262`），
    类的「Types」一段同理（`:237`）。每个名字是 `.type(.class, .name)` 或 `.type(.other, .name)` 记号，
    内容区按全名把它链接到对象（`ContentInterface.linkTargetKind`，`ContentInterface.swift:228-235`）。
  - 导出把 C++ 对象整棵展开、每个类与命名空间各写一份（`RuntimeObject+Export.swift:17-20` 的 `exportedObjects`）。
  - 镜像页只数顶层对象、按类型列计数（`ContentImageViewModel.swift:38-44`）。
  - 引擎的 `_hierarchy`（`RuntimeEngine.swift:1572-1584`）对 kind 穷举；`_relationships` 对 C++ 问 section 的
    `derivedClasses(of:)`，按名字查 `classesByName`，查不到就是空。
  - Inspector 只给 `.cPlusPlus(.class)` 显示层级与派生类（`InspectorRuntimeObjectCoordinator.swift:318-332`、
    `InspectorRelationshipsViewModel.swift:159-182`），其余 kind 走 `default`。
  - 图标在 `RuntimeObjectIcon.glyphContent(for:)`（`RuntimeObjectIcon.swift:86-89`）：类是绿色 `C`，命名空间是
    绿色 `N`；Swift 的 typealias 是蓝色 `T`。
  - 词云的 `NamingWordCounter.kindName(of:)`（`NamingWordCounter.swift:150-158`）对 kind 穷举；词云、Find、MCP、
    CLI 与后台索引从不要 C++ 对象（根 `AGENTS.md` 的 Architecture 一节）。
- **真实镜像**：`CPlusPlusSectionTests` 用本机 libc++abi、libc++ 测 section；libc++ 实例化了
  `std::__1::basic_string<char, …>` 与 `<wchar_t, …>`，可拿来测归组（推测：命名空间在本机是 `__1`，测试按
  `std` 下的 `baseName` 找，不写死 `__1`）。

## 提议方案

1. **新对象类型**：`RuntimeObjectKind.CPlusPlus` 加 `classTemplate`，说明是「C++ Class Template」，排在类之后、
   命名空间之前（`level` 重新编号，Objective-C 与 Swift 各后移一位）。它不是镜像里的实体，是对象树里把同一模板的
   特化聚在一起的节点。
2. **对象树归组**：builder 的作用域与类都带上 `baseName`。给一个节点做子对象时，把子节点里「`baseName` 非空且
   与这一段不同」的按 `baseName` 分组，每组做一个模板节点：`name` 是父路径加 `baseName` 的限定名
   （`std::__1::vector`），`displayName` 是 `baseName`，`kind` 是 `.cPlusPlus(.classTemplate)`，`children` 是这一组的
   特化（照旧排序、照旧带各自的子树与全名）。**一个特化也成组。** 顶层（全局作用域）同样归组。两种情况不归组：
   RTTI 现编的中间节点没有 `baseName`，留在原处；同一作用域里已经有一个名字正好是 `baseName` 的兄弟节点时
   （合法 C++ 里不会出现，留作防御），这一组不建节点、特化留在原处，免得两个对象同名。
3. **模板节点的界面**：section 按 kind 打印，模板节点印成：
   ```cpp
   // libc++.1
   // Specializations of std::__1::basic_string
   class std::__1::basic_string<char, std::__1::char_traits<char>, std::__1::allocator<char>>;
   class std::__1::basic_string<wchar_t, std::__1::char_traits<wchar_t>, std::__1::allocator<wchar_t>>;
   ```
   每行与「Declared here」同一写法、同一种记号，所以照旧能点击跳到那个特化；作用域树判不出种类的特化
   （`undetermined`，对象是命名空间）照它的对象种类印成 `namespace X {}`，与现在一致。
4. **命名空间与类的界面文字不变**：它们列出内部声明时把模板节点换成它的特化，所以「Declared here」与「Types」
   仍然逐个列出每个特化，文字与现在逐字相同。
5. **线上兼容**：`ObjectsInImageCommand` 加可选字段 `includesCPlusPlusClassTemplates`，只在为真时编码；本版的
   `objects(in:includesCPlusPlusObjects:)` / `objectsWithProgress(in:includesCPlusPlusObjects:)` 要 C++ 对象时
   一并设它，公开 API 不变。服务端（`_objects`）在请求方没设它时，把 C++ 对象里的每个模板节点换成它的特化
   （递归、重新排序），回复与现在逐字节相同；旧版服务端跳过这个键，回平铺的树，本版 App 照常显示，只是没有
   模板节点。中转（proxy、借用 shared cache 镜像的转发）原样转发命令结构，字段随之过去。
6. **导出不变**：`exportedObjects` 遇到模板节点时只写它的特化、不写节点本身，单个与批量导出的文件与计数都和现在一样。
7. **界面各处**：
   - 图标：绿色 `T`（C 家族的绿色；与 Swift typealias 的蓝色 `T` 靠颜色区分）。
   - 过滤范围：模板节点不设勾选框（从 `allRepresentableKinds` 去掉），只要它的特化里有一个通过就留下——这正是
     `matchesRecursively` 已有的行为；记住的过滤范围因此不受影响。勾选框标题的穷举 switch 补一个永远用不到的
     `"Class Template"`。
   - 侧栏：全局作用域的模板节点在顶层自成「C++ Class Template」一区，位于「C++ Class」与「C++ Namespace」之间；
     命名空间里，模板节点在类之后、命名空间之前成一块。路径栏同理。
   - Inspector：模板节点没有层级与派生类页（走 `default`）。引擎 `_hierarchy` 对它回空。
   - 镜像页：全局作用域有模板时多一行「C++ Class Template」计数（只数顶层，与现有规则一致）。
   - 词云的 `kindName`：`"template"`（词云不读 C++ 对象，只为穷举）。

### 非目标

- **函数模板**：命名空间界面里的函数特化（成员，不是对象树的节点）不归组。
- **主模板本身的声明**：Itanium mangling 不记录模板形参列表，不打印 `template <typename T, …> class vector`。
- **RTTI 现编的中间节点**：`CPlusPlusClass` 只有最后一段的 `baseName`，`Outer<int>::Inner` 里只靠 RTTI 才知道的
  `Outer<int>` 不归组。要补就得上游给 `CPlusPlusClass` 加每一段的 `baseName`，另立后续项。
- **把带模板参数的 `undetermined` 作用域改判成类**：kind 的判定不动，只归组。
- **与类按名字混排**：见替代方案第 4 条。
- **Find、MCP、CLI、词云、后台索引**：它们从不读 C++ 对象，不受影响。
- **设置开关**：不提供关掉归组的选项。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Objects/RuntimeObjectKind.swift` · `RuntimeObjectKind.CPlusPlus` | 修改 | 加 `classTemplate`（文档注释说明它是树节点、不是实体）；`level` 重新编号；`description` 加 `"C++ Class Template"` | 方案第 1 条 | 1 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Engine/RuntimeEngine.swift` · `_hierarchy(for:)` | 修改 | `.cPlusPlus(.classTemplate)` 与命名空间一起回 `[]` | 穷举 switch；模板节点没有层级 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/RuntimeObject/RuntimeObjectIcon.swift` · `glyphContent(for:)` | 修改 | `.cPlusPlus(.classTemplate)` → `("T", .green)` | 方案第 7 条 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Sidebar/RuntimeObject/RuntimeObjectScope.swift` · `allRepresentableKinds` | 修改 | 去掉 `.cPlusPlus(.classTemplate)`，注释改为「运行时不产生的、以及没有勾选框的类型」 | 不设勾选框、记住的范围不受影响 | 1 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Sidebar/RuntimeObject/SidebarRuntimeObjectScopeViewController.swift` · 类型标题 switch | 修改 | 补 `.cPlusPlus(.classTemplate): "Class Template"` | 穷举 switch | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/NamingWordCloud/NamingWordCounter.swift` · `kindName(of:)` | 修改 | 补 `"template"`，文档注释的列举同步 | 穷举 switch | 1 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/CPlusPlus/CPlusPlusObjectTreeBuilder.swift` · `CPlusPlusObjectTreeBuilder` | 修改 | `Scope` 加 `baseName`；`objects(globalScope:classPaths:)` 改为 `objects(globalScope:classes:)`，`classes` 是新的 `ClassName`（`path`、`baseName`）；`Node` 加 `baseName: String?`；新增私有的 `childObjects(path:imagePath:)` 做归组，`object(parentPath:imagePath:)` 与顶层都用它；类型文档注释补归组规则 | 方案第 2 条 | 2 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/CPlusPlus/RuntimeCPlusPlusSection.swift` · `init`、`treeScope(of:in:)` | 修改 | 把 `CPlusPlusScope.baseName` 与 `CPlusPlusClass.baseName` 交给 builder | 方案第 2 条 | 2 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/CPlusPlus/RuntimeObject+CPlusPlusClassTemplates.swift` · `RuntimeObject` | 新增 | `var replacingCPlusPlusClassTemplatesWithSpecializations: [RuntimeObject]`：模板节点换成它的特化（递归、重新排序），其余对象返回自身（子树同样处理） | 引擎给没声明的请求方换回平铺的树（方案第 5 条） | 2 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Engine/RuntimeEngine+Commands.swift` · `ObjectsInImageCommand` | 修改 | 加 `includesCPlusPlusClassTemplates: Bool?`（只在为真时编码，`includesCPlusPlusObjects` 为真时一并设），`perform` 传给 `_objects` | 方案第 5 条 | 2 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Engine/RuntimeEngine.swift` · `_objects(in:includesCPlusPlusObjects:)`、`_objects(in:includesCPlusPlusObjects:reportProgress:)`、`_localObjectsWithProgress` | 修改 | 加参数 `includesCPlusPlusClassTemplates`；为假时把 C++ 对象换成平铺的特化 | 方案第 5 条 | 2 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/CPlusPlus/CPlusPlusInterfacePrinter.swift` · `CPlusPlusInterfacePrinter` | 修改 | 新增 `ClassTemplateDeclaration`（`qualifiedName`、`imageName`、`specializations: [Declared]`）与 `interface(of: ClassTemplateDeclaration)`，复用 `declaredSection` | 方案第 3 条 | 3 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/CPlusPlus/Array+CPlusPlusClassTemplates.swift` · `[RuntimeObject]` | 新增 | `var openingCPlusPlusClassTemplateNodes: [RuntimeObject]`：只展开这一层的模板节点，C++ 对象按有模板节点之前的顺序重排，其他语言的对象原位留在前面 | 声明表与导出要的是一层展开加原顺序，不必深拷贝整棵子树（方案第 4、6 条） | 3 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/CPlusPlus/RuntimeCPlusPlusSection.swift` · `interface(for:options:)`、`classDeclaration(of:)`、`namespaceDeclaration(of:)` | 修改 | `interface` 加 `.cPlusPlus(.classTemplate)` 分支与 `classTemplateDeclaration(of:)`；两处内部声明表经 `declared(in:)` 用 `openingCPlusPlusClassTemplateNodes` 展开 | 方案第 3、4 条 | 3 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeObject+Export.swift` · `exportedObjects` | 修改 | 模板节点只展开它的特化，不写节点本身；子节点经 `[RuntimeObject].exportedObjects` 保持原顺序；注释同步 | 方案第 6 条 | 4 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/Array+RuntimeObjectExport.swift` · `[RuntimeObject]` | 新增 | `public var exportedObjects: [RuntimeObject]`：先 `openingCPlusPlusClassTemplateNodes`，再逐个 `exportedObjects` | 顶层的模板节点也按原顺序写（单文件格式按顺序拼接） | 4 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeEngine+Export.swift` · `exportInterfaces(with:reporter:)` | 修改 | 改用数组的 `exportedObjects` | 同上 | 4 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Exporting/ExportingConfigurationViewModel.swift` · C++ 计数 | 修改 | 改用数组的 `exportedObjects` | 计数与实际写出的一致 | 4 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusObjectKindTests.swift` | 修改 | 顺序（类 < 模板 < 命名空间、`allCases` 里三个连续）、JSON 往返、说明文字 | 第 1 步的行为 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/CPlusPlusPresentationTests.swift` | 修改 | 绿色 `T`；过滤范围的 C++ 组仍只有类与命名空间两个勾选框；模板节点在有特化通过时留下 | 第 1 步的行为 | 1 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeObjectTests.swift`、`RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/RuntimeObjectScopeTests.swift` | 修改 | `allCases` 由 23 种变 24 种；没有勾选框的类型多了模板节点 | 既有测试枚举了全部类型 | 1 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusObjectTreeBuilderTests.swift` | 修改 | 归组规则的全部情形（见第 2 步行为清单） | 第 2 步的行为 | 2 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/ObjectsInImageCPlusPlusWireTests.swift` | 修改 | 新字段的编码、旧服务端读法、旧请求方拿到平铺的树、经中转 | 第 2 步的行为 | 2 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusSectionTests.swift` | 修改 | libc++ 的 `basic_string` 成组；模板节点的界面；命名空间界面仍列出特化 | 第 2、3 步的行为 | 2、3 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusInterfacePrinterTests.swift` | 修改 | 模板声明的打印 | 第 3 步的行为 | 3 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusExportTests.swift` | 修改 | 导出跳过模板节点、写出特化 | 第 4 步的行为 | 4 |
| `Documentations/CommunicationAndEngineArchitecture.md` · 第 408 行之后 | 修改 | 加「第六例」：`includesCPlusPlusClassTemplates` 的含义、两种对端组合、测试名 | 线上格式的约定要有文档 | 4 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案；落地时改编号 | 文档索引 | 4 |

## 架构图

对象树改了什么：

```text
CPlusPlusObjectTreeBuilder.objects(globalScope:classes:)
├─ Node.insert(_:)              ~ Scope carries baseName
├─ Node.insertClass(at:)        ~ last component carries CPlusPlusClass.baseName
└─ Node.object(parentPath:imagePath:)
   -  children.values.compactMap(object)            one object per scope component
   +  childObjects(path:imagePath:)
   +    specializations sharing a baseName (baseName != component)
   +      → RuntimeObject(name: path + baseName, displayName: baseName,
   +                      kind: .cPlusPlus(.classTemplate), children: specializations)

before                                     after
std                     (namespace)        std                       (namespace)
└─ __1                  (namespace)        └─ __1                    (namespace)
   ├─ basic_string<char, …>    (class)        ├─ exception           (class)
   ├─ basic_string<wchar_t, …> (class)        ├─ basic_string        (class template)  +
   ├─ exception                (class)        │  ├─ basic_string<char, …>     (class)
   └─ vector<int, …>           (class)        │  └─ basic_string<wchar_t, …>  (class)
                                              └─ vector              (class template)  +
                                                 └─ vector<int, …>            (class)
```

谁拿到哪棵树（`objectsInImage`）：

```text
requester (this build)                       engine (this build)
  includesCPlusPlusObjects: true
+ includesCPlusPlusClassTemplates: true  ──▶ _objects(…, includesCPlusPlusClassTemplates: true)
                                               → section's tree, template nodes included

requester (0103 … before this change)        engine (this build)
  includesCPlusPlusObjects: true         ──▶ _objects(…, includesCPlusPlusClassTemplates: false)
                                               → replacingCPlusPlusClassTemplatesWithSpecializations
                                               → byte for byte the reply of today

requester (this build)                       engine (before this change)
  both keys                              ──▶ unknown key skipped → flat tree, no template node

interface(for: template node)
  RuntimeEngine._interface ─▶ RuntimeCPlusPlusSection.interface(for:options:)
+   case .cPlusPlus(.classTemplate) ─▶ CPlusPlusInterfacePrinter.interface(of: ClassTemplateDeclaration)
```

## 详细设计

### 对象类型

```swift
public enum CPlusPlus: Codable, Hashable, Identifiable, CaseIterable, Sendable {
    case `class`
    /// The specializations of one class template in one scope, gathered
    /// under the template's name: a node of the object tree rather than an
    /// entity of the image. Only a requester that says it knows this kind
    /// (`ObjectsInImageCommand.includesCPlusPlusClassTemplates`) is sent one.
    case classTemplate
    case namespace

    public var id: Self { self }
}
```

`level`：`.cPlusPlus(.class)` 2、`.cPlusPlus(.classTemplate)` 3、`.cPlusPlus(.namespace)` 4，Objective-C 从 5 起、
Swift 从 9 起依次后移。`description`：`"C++ Class Template"`。`allCases` 由各子枚举的 `allCases` 拼成，自动带上。

### 对象树

```swift
struct CPlusPlusObjectTreeBuilder {
    struct Scope: Sendable {
        var path: [String]
        /// The last component without template arguments, as
        /// `CPlusPlusScope.baseName` gives it.
        var baseName: String
        var kind: Kind
        var hasMembers: @Sendable () -> Bool
        var children: [Scope]
    }

    /// A class run-time type information shows.
    struct ClassName: Sendable {
        /// The components, outermost first.
        var path: [String]
        /// The last component without template arguments, as
        /// `CPlusPlusClass.baseName` gives it.
        var baseName: String
    }

    func objects(globalScope: Scope, classes: [ClassName]) -> [RuntimeObject]
}
```

`Node` 加 `var baseName: String?`：`insert(_:)` 取 `scope.baseName`；`insertClass(at:baseName:)` 只在最后一段、
节点是新建时填 `baseName`（已有节点保留作用域树给的），中间现编的节点留 `nil`。

归组（私有，`object(parentPath:imagePath:)` 与顶层共用）：

```swift
/// The objects of `children`, below `path`, with the specializations of each
/// class template gathered under one `.cPlusPlus(.classTemplate)` object.
private static func childObjects(of children: [String: Node], path: [String], imagePath: String) -> [RuntimeObject]
```

1. 每个子节点先做成对象（函数作用域、空命名空间照旧为 `nil`）。
2. 一个子节点是特化，当且仅当它的对象不为 `nil`、`baseName` 非 `nil` 非空、且 `baseName != component`。
3. 特化按 `baseName` 分组；如果某个 `baseName` 等于任一兄弟节点的 `component`，这一组不建节点，特化原样留下。
4. 每组做 `RuntimeObject(name: (path + [baseName]).joined(separator: "::"), displayName: baseName, kind: .cPlusPlus(.classTemplate), imagePath: imagePath, children: specializations.sorted())`。
5. 非特化的对象加上各模板节点，整体 `sorted()`。

模板节点的 `name` 会登记进 `objectsByName`，与特化、作用域的限定名不会撞（特化的名字带 `<…>`，第 3 条排除了同名兄弟）。

### 换回平铺的特化

```swift
extension RuntimeObject {
    /// The object as a requester that does not know
    /// `RuntimeObjectKind.CPlusPlus.classTemplate` reads it: a class template
    /// node is replaced by its specializations, and every object below has
    /// its class template nodes replaced likewise.
    var replacingCPlusPlusClassTemplatesWithSpecializations: [RuntimeObject] { get }
}
```

模板节点返回 `children.flatMap(\.replacingCPlusPlusClassTemplatesWithSpecializations)`；其他对象返回一个元素：
自身，`children` 换成子对象各自处理后拼起来再 `sorted()`（经 `RuntimeObject` 的成员初始化器重建，其余字段原样）。
内部用（`internal`）：引擎、section、导出都在 RuntimeViewerCore 里。

### 线上字段

```swift
struct ObjectsInImageCommand: RuntimeEngineProgressCommand {
    let image: String
    let includesCPlusPlusObjects: Bool?
    /// Whether the requester knows `RuntimeObjectKind.CPlusPlus.classTemplate`.
    /// Set with `includesCPlusPlusObjects`, and left out of the encoding
    /// otherwise, so that a request without it — every request of a build
    /// before class templates — is byte for byte what it was. Without it the
    /// reply carries each template's specializations where the template node
    /// would be, as builds before class templates listed them; a peer of such
    /// a build skips the key and answers that way anyway.
    let includesCPlusPlusClassTemplates: Bool?

    init(image: String, includesCPlusPlusObjects: Bool = false) {
        self.image = image
        self.includesCPlusPlusObjects = includesCPlusPlusObjects ? true : nil
        self.includesCPlusPlusClassTemplates = includesCPlusPlusObjects ? true : nil
    }
}
```

`_objects(in:includesCPlusPlusObjects:includesCPlusPlusClassTemplates:)` 两个重载与 `_localObjectsWithProgress`
多一个参数，默认 `false`；C++ 对象取到后，参数为假就 `flatMap(\.replacingCPlusPlusClassTemplatesWithSpecializations)`。
测试照 `ShippedObjectsInImageRequest` 再冻结一份「0103 版的请求」（带 `includesCPlusPlusObjects`、不带新字段）。

### 界面

```swift
struct ClassTemplateDeclaration: Sendable {
    var qualifiedName: String
    var imageName: String
    var specializations: [Declared]
}

func interface(of declaration: ClassTemplateDeclaration) -> SemanticString {
    var string = SemanticString()
    appendCommentLine(declaration.imageName, to: &string)
    string.append(declaredSection(title: "Specializations of \(declaration.qualifiedName)", declared: declaration.specializations, isIndented: false))
    return string
}
```

section 里 `classTemplateDeclaration(of:)` 把节点的每个特化做成 `Declared`（`declaration(of:)`）；
`classDeclaration(of:)` 与 `namespaceDeclaration(of:)` 的内部声明表经 `declared(in:)` 改用
`object.children.openingCPlusPlusClassTemplateNodes`，顺序与以前相同（类、命名空间各自按名字）：

```swift
extension Array where Element == RuntimeObject {
    /// These objects with each C++ class template node among them replaced by
    /// the specializations it gathers — this level only — and the C++ objects
    /// in the order they took before there were template nodes; objects of
    /// other languages keep their places ahead of them.
    var openingCPlusPlusClassTemplateNodes: [RuntimeObject] { get }
}
```

模板节点的子节点只会是特化，所以一层就够；深层的 `replacingCPlusPlusClassTemplatesWithSpecializations` 会重建整棵子树，
只留给引擎换回平铺的树。

### 导出

`RuntimeObject.exportedObjects` 遇到模板节点返回它的特化各自的 `exportedObjects`，其他 C++ 对象返回自身加
`children.exportedObjects`；新增的 `public var [RuntimeObject].exportedObjects` 先 `openingCPlusPlusClassTemplateNodes`
再逐个展开，导出引擎和导出配置页的 C++ 计数都改用它。所以顶层与各层的特化都落在以前的位置，单文件格式拼出的
`.hpp` 与以前逐字相同。

## 替代方案考量

1. **只在 AppCore 的侧栏里归组，不改 Core。** 否：路径栏、镜像页、iOS 侧栏各要做一遍，模板节点也没有界面可打印；
   一棵树在 Core 里做一次，所有消费方自然一致。
2. **模板节点用 `.cPlusPlus(.class)`，靠属性位区分。** 否：一个不是类的「类」会让层级、派生类、Inspector、导出都把它
   当成类处理；新属性位按根 `AGENTS.md` 第 9 条还得在过滤范围加一行，对用户没有意义；图标也和类分不开。
3. **自己解析名字里的模板参数。** 否：上游已有 demangler 语法树给出的 `baseName`；文本解析会碰上 `operator<`、
   嵌套的尖括号与 ABI 标签。
4. **模板节点与类按名字混排。** 否：要混排就得让 `RuntimeObjectKind.<` 把类与类模板当成相等，侧栏顶层两个分区的先后
   就不确定了；现在类与命名空间本来就各成一块，模板节点再成一块与之一致。
5. **两个以上特化才归组。** 用户选了一律归组：模板在列表里总是短名，规则不用记例外。
6. **子项只显示模板参数。** 用户选了全名：过滤与路径栏里一眼认得，离开节点（跳转、最近对象）也认得。
7. **不加线上字段，直接在回复里放新类型。** 否：0103 之后、本提案之前的 App 会要 C++ 对象，连到新版对端时整个镜像的
   对象列表解码失败；这正是 `ObjectsInImageCPlusPlusWireTests` 守着的约定。
8. **选中模板节点时只展开、不显示内容。** 用户选了列出全部特化：一眼看到这个模板被实例化了几次、各是什么参数，
   并能从内容区直接跳过去。

## 影响

### 用户可见变化

- 侧栏、路径栏与 iOS 侧栏：C++ 类模板的特化收进一个以模板名命名、绿色 `T` 图标的节点，展开后是特化，行上仍是全名。
  命名空间里，模板节点在类之后、命名空间之前；全局作用域的模板在侧栏顶层自成「C++ Class Template」一区。
- 选中模板节点，内容区列出「Specializations of <限定名>」与每个特化的声明，点击即跳到那个特化。
- 镜像页在全局作用域有模板时多一行「C++ Class Template」计数。
- 过滤范围没有新勾选框；过滤框输入 `vector` 时，`vector` 节点与它的特化都匹配（特化是全名）。
- 不变的：命名空间与类的界面文字、单个与批量导出的结果、Find、MCP、CLI。
- 原有习惯的替代路径：以前在 `std::__1` 下直接点 `vector<int, …>`，现在先展开 `vector`；用过滤框搜全名照旧直接命中。

### 可发现性

默认开启，没有开关：这是对象树的显示方式，平铺没有值得保留的场景；节点本身就在列表里，展开即见。

### 数据与配置兼容

- 书签、导航历史、最近对象按 `(imagePath, name, kind)` 认对象，特化的这三项都没变，原有条目照常打开。
- 记住的过滤范围不受影响：模板节点没有勾选框，不进 `allRepresentableKinds`。
- 不同版本的对端：见「谁拿到哪棵树」的图，三种组合都能读；旧版 App 永远收不到它解不开的类型。

### 平台与最低版本

最低版本不变。Core 的改动在所有平台都编；界面上 macOS 与 iOS 家族（共用 AppCore 的侧栏 ViewModel）都显示模板节点。

### 发布

不需要新的权限、entitlement 或隐私清单条目；不影响公证与 Sparkle。

## 落地步骤

1. **新对象类型与各处穷举**（已完成） —— 改动地图第 1–6 行、`CPlusPlusObjectKindTests`、`CPlusPlusPresentationTests`
   - 行为：`cPlusPlusClassTemplateSortsBetweenClassesAndNamespaces`
   - 行为：`cPlusPlusClassTemplateRoundTripsThroughJSON`
   - 行为：`cPlusPlusClassTemplateDescriptionIsCPlusPlusClassTemplate`
   - 行为：`cPlusPlusClassTemplateGlyphIsAGreenT`
   - 行为：`filterScopeOffersNoCheckboxForClassTemplates`
   - 行为：`classTemplateNodeStaysWhileOneOfItsSpecializationsPasses`
   - 行为：`classTemplateNodeHasNoHierarchy`
2. **对象树归组与线上字段**（已完成） —— 第 7–11 行、`CPlusPlusObjectTreeBuilderTests`、`ObjectsInImageCPlusPlusWireTests`、`CPlusPlusSectionTests`
   - 行为：`specializationsOfOneTemplateSitUnderOneNodeNamedAfterIt`
   - 行为：`aSingleSpecializationIsGroupedToo`
   - 行为：`templateNodeIsNamedByItsScopeAndShowsTheTemplateName`
   - 行为：`specializationsKeepTheirFullNamesAndTheirSubtrees`
   - 行为：`sameTemplateNameInTwoScopesMakesTwoNodes`
   - 行为：`undeterminedTemplatedScopeIsGroupedLikeAClass`
   - 行为：`classOnlyTypeInformationShowsIsGroupedByItsBaseName`
   - 行为：`madeUpScopeWithoutBaseNameStaysWhereItIs`
   - 行为：`noTemplateNodeWhenASiblingAlreadyHasItsName`
   - 行为：`globalScopeSpecializationsAreGroupedAtTheTopLevel`
   - 行为：`templateNodesSortAfterClassesAndBeforeNamespaces`
   - 行为：`requestWithCPlusPlusObjectsCarriesTheClassTemplateFlag`
   - 行为：`serverOfAnEarlierBuildReadsTheFlaggedRequestWithout`
   - 行为：`requesterWithoutTheClassTemplateFlagGetsSpecializationsWhereTheyWere`
   - 行为：`relayOfThisBuildForwardsTheClassTemplateFlag`
   - 行为：`libcxxListsBasicStringAsAClassTemplateOfItsSpecializations`
3. **模板节点的界面**（已完成） —— 第 12–13 行、`CPlusPlusInterfacePrinterTests`、`CPlusPlusSectionTests`
   - 行为：`classTemplatePrintsItsSpecializationsSpelledInFull`
   - 行为：`classTemplateSpecializationTokensLinkToTheSpecializations`
   - 行为：`namespaceStillListsEverySpecializationDeclaredInIt`
   - 行为：`libcxxClassTemplateInterfaceListsItsSpecializations`
4. **导出与文档**（已完成） —— 第 14 行、`CPlusPlusExportTests`、文档两行
   - 行为：`exportWritesTheSpecializationsOfATemplateButNotTheNode`
   - 行为：`exportOfAnImageWithTemplatesWritesTheSameFilesAsBefore`

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要：调用方契约只有线上字段一条，写进 `CommunicationAndEngineArchitecture.md`
  的第六例；归组规则在 builder 的类型文档注释里。
- **有没有引入新术语** —— 「类模板节点」只在本提案与代码注释里用，预计不进术语表，落地时再判断。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-27 | Created as Draft | C++ 对象树里同一模板的特化逐个平铺、名字很长，用户希望把它们收进以模板名命名的一个节点（例如 `vector`）。 |
| 2026-11-27 | 澄清提问（默认档一轮） | 用户定了三件事：只有一个特化的模板也归组；选中模板节点时内容区列出全部特化、可点击跳转；特化行显示全名。 |
| 2026-11-27 | 排序改为单独成块 | 调研前对用户说过「与类按名字混排」，写提案时改为类之后、命名空间之前单独成块：混排要让两种类型比较相等，侧栏顶层分区的先后会不确定（替代方案第 4 条）。 |
| 2026-11-27 | 加线上字段 | 0103 之后的 App 会要 C++ 对象，新类型直接进回复会让它们连新版对端时解码失败；照 `includesCPlusPlusObjects` 的先例加可选字段，旧请求方拿到平铺的树。 |
| 2026-11-27 | Accepted | 用户批准，开始实现。 |
| 2026-11-27 | 声明表与导出改用一层展开 | 详细设计原写用深层的 `replacingCPlusPlusClassTemplatesWithSpecializations`。实现时改为新增的 `[RuntimeObject].openingCPlusPlusClassTemplateNodes`：模板节点下只有特化，展开一层就够，不必每打印一次命名空间就重建整棵子树；导出另加 `[RuntimeObject].exportedObjects`，顶层的模板节点也按原顺序写，导出配置页的计数随之改用它。 |
| 2026-11-27 | 第 2–4 步合成一个提交 | 三步的改动交织在 `RuntimeCPlusPlusSection.swift` 与 `CPlusPlusSectionTests.swift` 等几个文件里，按步拆提交要逐块拆分；测试按步写全，一次验证。 |
| 2026-11-27 | 验证改用本地依赖 | 基线上用远端解析依赖的包构建就编不过：锁文件钉的 MachOSwiftSection 需要 MachOKitExtensions 3.3.0 之后还没发版的改动（`recordsFunctionAddressReferences`）。验证在 Ultra 上 `USING_LOCAL_DEPENDENCIES=1` 原地构建，与这次改动无关。 |
| 2026-11-27 | 不改根 `AGENTS.md` | 根 `AGENTS.md` 已有 74 KB，超过 Codex 读取的 64 KiB；模板节点的约定写进通信架构文档的第六例与类型的文档注释。 |
| 2026-11-27 | 实现完成，待用户看过后收尾 | 在 Ultra 上以本地依赖模式验证：Core 全量 940 个、`RuntimeViewerAppCoreTests` 全量 1121 个跑完，红的都是既有红灯——`FindCrossReferenceTests` 与 `BackgroundWorkProcessActivityTests` 基线同样红，其余（`CrossReferencePreparationTests` 两条、`RuntimeLocalSocketConnectionTests`、`RuntimeBackgroundIndexingManagerTests`、`OwnerReportingTaskTests`、`SidebarImageListLoadWaitTests`）单独重跑全过。App target 只多一个 switch 分支，没有整编 App；`RuntimeViewerAppUITests` 没跑（这次没改 AppUI）。配套专题文章不需要：调用方契约只有线上字段一条，已写进通信架构文档的第六例，归组规则在 builder 的类型注释里；「类模板节点」只在提案与代码注释里用，不进术语表。 |
