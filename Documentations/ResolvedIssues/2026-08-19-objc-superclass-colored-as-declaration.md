# 2026-08-19 ObjC 父类名被染成"声明"色，而不是类型色

**调查日期：** 2026-08-19
**修复落地：** 本日，见 `RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/SourceModelDeclarationShortCircuitOverride.swift`
**所属分支：** `feature/source-editor-integration`
**Severity：** Minor —— 只影响着色，不影响跳转、折叠或任何交互
**触发场景：** 打开任意 ObjC 类，例如 AppKit 的 `NSView`

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | `@interface NSView : NSResponder <…>` 里，父类 `NSResponder` 与被声明的 `NSView` 同色（Xcode 主题的"类型声明"蓝），而不是类型引用的紫色。同一份接口里协议列表和 ivar 的类型（`NSPSMatrix *_frameMatrix`）都是正确的紫色 |
| **影响范围** | 只有 ObjC 类接口的父类名。同一行的协议列表正常 |
| **根因** | `SourceModelSyntaxTokenProvider` 在征询我们安装的 `nodeTypeAdjuster` **之前**先自行判定，命中即提前 return；ObjC 语法规范让被声明的类名和父类名是同一种节点，于是两者一起被判成声明 |
| **Status** | **Fixed** —— 替换掉那条判定所依赖的 `-[SMSourceModel isDeclarationOrDefinitionAtLocation:]`，让类型引用落到 adjuster |

---

## 现象

同一行里两种类型名，颜色却分成两派：

```objc
@interface NSView : NSResponder <NSAppearanceCustomizationInternal, …> {
    NSPSMatrix *_frameMatrix;    // ← 紫色，正确
}
```

`NSView`（蓝，正确——它确实是声明）、`NSResponder`（蓝，**错**）、协议名（紫，正确）、`NSPSMatrix`（紫，正确）。

这种"同一类 token 分成两派"的形态说明问题不在主题映射上——`SourceEditorThemeConversion` 对每个 `SemanticType` 只有一条映射，不可能给同一个类型两种颜色。生成侧也没问题：`ObjCClassInfo.semanticString` 里父类用的就是 `TypeName(kind: .class, superClassName)`，与协议名、ivar 类型同为 `.type(_, .name)`。

**同一行里协议名是对的、父类名是错的**，这一条把范围收得很窄：出问题的不是"类型引用"这一类 token，而是父类名所处的那个语法位置。

---

## 根因

三环连起来才解释得了这个现象。

### 一、ObjC 语法规范让"被声明的类"和"父类"是同一种节点

`SourceModel.framework/Resources/LanguageSpecifications/ObjectiveC.xclangspec`：

```
Identifier = "xcode.lang.objc.interface.declarator";
Rules = ("@interface",
         "xcode.lang.objc.classnameclause",   // ← 被声明的类，里面是 classname
         ":?",
         "xcode.lang.objc.classname?",        // ← 父类，同一条规则
         "xcode.lang.objc.protocolclause?");
```

而 `xcode.lang.objc.classname` 的 `Type = "xcode.syntax.name.type"`。也就是说在语法树上 `NSView` 和 `NSResponder` 完全是同一种东西，规范本身不打算区分声明与引用。

### 二、框架在问我们之前先自己下了结论

反编译 `SourceModelSupport` 的 `SourceModelSyntaxTokenProvider.adjustNodeType(for:sourceModel:)`（Xcode 26.6，`0x61124`）：

```
if item.parent.nodeType == "xcode.syntax.name.type",
   sourceModel.isDeclarationOrDefinitionAtLocation(item.range.location) {
    item.setNodeType("xcode.syntax.declaration.type")
    item.setNeedsAdjustNodeType(false)
    return                                   // ← 到此为止，nodeTypeAdjuster 不会被调用
}
// 只有没命中，才轮到我们安装的 nodeTypeAdjuster
```

`@interface … @end` 整块是一个 declaration 节点，所以 `-isDeclarationOrDefinitionAtLocation:` 对父类名那个位置也返回 YES（判定链是 `enclosingItemAtLocation:` → `isItemDeclarationOrDefinition:` → 沿祖先查 declaration 类型表）。父类因此被设成 `xcode.syntax.declaration.type` 并原地封存，`SemanticNodeTypeAdjuster` 全程没被叫到。

协议名和 ivar 的类型名之所以正常，是因为它们的父节点不是 `xcode.syntax.name.type`——协议名在 `xcode.lang.objc.protocolclause` 这个 Scope 规则底下，ivar 类型在声明规则底下——都走不到这条捷径，能顺利到达 adjuster。换句话说，被这条捷径截住的只有 `xcode.lang.objc.classname` 规则产出的那两个名字，而其中一个（父类）本不该算声明。

### 三、`xcode.syntax.declaration.type` 在我们的主题里就是蓝

`SourceEditorThemeConversion.styleRepresentativeByThemeKey` 把它映射到 `.variable`，最终落到 `preset.declaration`。这一步没有问题，是前两步把节点送错了类别。

---

## 修复

`SourceModelDeclarationShortCircuitOverride` 替换 `-[SMSourceModel isDeclarationOrDefinitionAtLocation:]` 的实现：**当该位置落在生成侧标记为「引用」的语义区间内时返回 `false`，其余一律交回原实现。**

于是父类名不再命中捷径，落到 `SemanticNodeTypeAdjuster`，被改成 `xcode.syntax.identifier.class`（紫）；被声明的类名仍是 `.type(_, .declaration)`，映射到 `xcode.syntax.declaration.other`，颜色不变。

判定"是不是引用"用的是节点类型名的层级：`xcode.syntax.identifier.*` 表示对某个东西的**使用**，`xcode.syntax.declaration.*` 表示它被**引入**的地方。app 侧本来就按这个层级分配名字，所以 bundle 侧只看前缀即可，不必为此从 app 链接任何东西（bundle 不能链接 app 的代码，理由见 `SourceEditorBridging` 的文件注释）。

### 为什么敢改这个方法

`-isDeclarationOrDefinitionAtLocation:` 在 `SourceModel`、`SourceModelSupport`、`SourceEditor`、`SourceEditorSwiftSupport`、`DVTSourceEditor`、`IDESourceEditor` 六个框架里**只有一个调用点**，就是上面那段节点类型调整；它转发到的 `-isItemDeclarationOrDefinition:` 也没有第二个调用者。跳转、折叠、结构大纲都不读它。

若将来的 Xcode 改名或删掉这个方法，`install()` 找不到目标就什么都不做，编辑器退回今天的样子，不会崩。

### 多文档并存不会互相污染

替换实现只拿得到一个位置和一个 `SMSourceModel`，无法反查该 model 上装的是哪个 adjuster，所以注册表按位置查询**所有**在世 adjuster 的引用区间，任一命中即返回 `false`。这不会串色：假设文档 A 认为位置 100 是引用、文档 B 认为它是声明，B 解析到该位置时只是多走一步——落到 B 自己的 adjuster，由 B 的语义区间给出"声明"，最终仍是声明色。这个 override 只决定**要不要问 adjuster**，从不决定 adjuster 答什么。

---

## 验证

- **编译**：`RuntimeViewerSourceEditorBridge`（唯一改动的 target）以 arm64 构建通过，无新增警告。app target 不含这两个文件，未受影响。
- **运行**：打开 AppKit 的 `NSView`，`NSResponder` 应显示为类型紫色，`NSView` 保持声明蓝色，ivar 类型颜色不变。

---

## 相关代码

- `RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/SourceModelDeclarationShortCircuitOverride.swift` —— 替换实现，含框架侧短路逻辑的反编译摘录
- `RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/SemanticNodeTypeAdjuster.swift` —— 引用区间注册表与 `isTypeReferenceLocation(_:)`
- `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/SourceEditorThemeConversion.swift` —— `SemanticType` 与主题 key / 节点类型名的对照表
