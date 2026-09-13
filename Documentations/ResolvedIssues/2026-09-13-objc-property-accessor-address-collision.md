# 2026-09-13 属性 getter 的地址取成了同名类方法的地址

**调查日期：** 2026-09-13
**修复落地：** 本日，见 `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift`
**引入提交：** `9b5e1625`（2026-03-01）`improve: refine MCP bridge async design, consolidate image state, and enhance tool metadata`
**Severity：** Major —— 地址是这条命令存在的唯一理由，错得没有任何提示，而且同一份数据的另一条路径（interface 文本）是对的，两者互相矛盾
**触发场景：** 对 `runtime-viewer-cli` 做完整验收测试时，`members NSObject` 的输出里同一个符号出现了两个地址

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 实例属性的 getter 地址，报的是同名**类方法**的地址；符号列却照常印 `-[…]` |
| **影响范围** | `RuntimeEngine.memberAddresses(for:memberName:)` 的全部消费者 —— `runtime-viewer-cli members`、MCP 的成员地址工具、App 内读该接口处；类、协议、分类三个分支都中 |
| **根因** | 访问器查表用的是一张按 selector 索引的表，实例方法与类方法混在一起，同名时后插入的类方法覆盖了实例方法 |
| **上游对照** | MachOObjCSection **没有**这个问题：它的渲染上下文把 `methodIMPs` 与 `classMethodIMPs` 分成两张表，按 `isClassProperty` 择一 |
| **Status** | **Fixed** —— 按 `isClassMethod` 分成两张表，配两条回归测试 |

---

## 现象

`NSObject` 就是最小复现，四个属性全中（`description`、`debugDescription`、`hash`、`superclass`
各自既有 `-` 也有 `+` 的同名方法）。`runtime-viewer-cli members NSObject --image libobjc.A`：

```
ADDRESS      KIND             NAME         SYMBOL
0x1800CB4E8  method           description  -[NSObject description]
0x1800CA584  class method     description  +[NSObject description]
0x1800CA584  property getter  description  -[NSObject description]   ← 符号是 -，地址是 + 的
```

最后一行**自相矛盾**：它声称自己是 `-[NSObject description]`，却给出 `+[NSObject description]`
的地址。这不是显示问题——把同一个二进制交给 `nm` 核对，两个地址确实分属两个方法。

用一个 8 行的 dylib 可以把它从系统库里剥离出来单独看：

```objc
@interface RVAddressProbe : NSObject
@property (nonatomic, readonly) NSString *label;
+ (NSString *)label;          // 与属性 getter 同名的类方法
@end
@implementation RVAddressProbe
- (NSString *)label { return @"instance"; }
+ (NSString *)label { return @"class"; }
@end
```

```
nm 真值：   -[RVAddressProbe label] = 0x890     +[RVAddressProbe label] = 0x8AC

interface 命令（走 MachOObjCSection 渲染）：
  @property (nonatomic, readonly) NSString *label;  // getter IMP: 0x890    ← 对
members 命令（走本仓库的副本）：
  0x8AC  property getter  label  -[RVAddressProbe label]                    ← 错
```

**同一个进程、同一个二进制、同一个属性，两条路径给出两个不同的地址。** 这个对照是判定的关键：
它排除了"元数据本身就这样"的可能，把问题钉死在本仓库这一侧。

---

## 根因

`RuntimeObjCSection.memberAddresses(for:memberName:)` 里的局部函数 `collectPropertyAccessors`
先建一张 selector → IMP 的表，再按 getter / setter 的 selector 去查：

```swift
var methodIMPs: [String: UInt64] = [:]
for method in methods where method.imp != 0 {
    methodIMPs[method.name] = method.imp          // ← 一张表
}
```

三个调用点传进来的 `methods` 都是**实例方法与类方法拼接后的数组**：

```swift
methods: classInfo.methods + classInfo.classMethods
```

Objective-C 允许实例方法和类方法用同一个 selector，这在系统框架里非常普遍。两者同名时，后写入
的那个（拼接顺序决定了是类方法）把先写入的覆盖掉，于是实例属性的 getter 查到了类方法的 IMP。
`symbolName` 那一半却是另外拼出来的，用的是 `property.isClassProperty` 决定 `+` / `-`，所以它
仍然正确——**一行输出里一半对一半错**，正是这个不一致让问题浮出来。

## 上游为什么没错

MachOObjCSection 的渲染上下文从一开始就是两张表，取用时按属性自己的归属择一：

```swift
// ObjCDump+SemanticString.swift
let imps = isClassProperty ? context.classMethodIMPs : context.methodIMPs
```

填表侧（`ObjCInterfaceBuilder`）也分开填。所以 interface 文本里的 `getter IMP:` 注释一直是对的。
本仓库的这份是**第二份实现**，而且是写错的那份。

---

## 修复

按元数据自带的 `isClassMethod` 标志分表，而不是依赖调用方的拼接顺序：

```swift
var instanceMethodImplementations: [String: UInt64] = [:]
var classMethodImplementations: [String: UInt64] = [:]
for method in methods where method.imp != 0 {
    if method.isClassMethod {
        classMethodImplementations[method.name] = method.imp
    } else {
        instanceMethodImplementations[method.name] = method.imp
    }
}
…
let methodIMPs = property.isClassProperty ? classMethodImplementations : instanceMethodImplementations
```

选 `isClassMethod` 而不是"把两组分别当参数传进来"，是因为该标志在上游是构造时按来源显式写入的
（`info(isClassMethod: true/false)`，每一组方法列表都单独标注），比调用点的数组拼接顺序更可信；
同一函数里的 `collectMethods` 也已经在用它决定 `+` / `-` 前缀。三个调用点因此一行都不用改。

---

## 回归测试

`RuntimeViewerCore/Tests/RuntimeViewerCoreTests/ObjCPropertyAccessorAddressTests.swift`，两条，
都从镜像自身推导预期，不写死任何地址，所以系统更新不会让它们过期：

| 测试 | 断言 | 修复前 |
|---|---|---|
| `One symbol never has two addresses` | 扫 libobjc 全部类，同一个 `symbolName` 不得对应两个地址 | 失败，4 处（NSObject 的四个属性） |
| `An instance property's getter is the instance method, not the same-named class method` | NSObject 上每个"getter 与类方法同名且两者地址不同"的属性，getter 必须等于实例方法的地址 | 失败，4 处 |

第二条在找不到可判别的属性时会主动失败（而不是静默通过），以免前提消失后测试变成摆设。

---

## 四问

1. **能复现吗**：能。`nm` 核对过，且同进程内 interface 与 members 互相矛盾。不是误报。
2. **`main` 上有吗**：**有**，`main` 与 `next` 的这段代码逐字节相同。旧缺陷，不是新引入。
3. **值不值得修**：值得。成员地址是逆向下断点的依据，错了没有任何提示；`NSObject` 这种根类命中，
   波及面覆盖所有 ObjC 类型。
4. **以前修过吗**：**同一类问题修过一次** ——
   [2026-08-15 「剥离合成方法」从来没剥掉过 setter](2026-08-15-synthesized-setter-selector-strip.md)。
   那次也是"MachOObjCSection 修了自己那份，本仓库另存的副本没跟上"。本次是同一模式的第二次发作，
   区别在于上游那份**从来就是对的**，副本从写下的第一天（`9b5e1625`）就是错的。

**模式本身值得记住**：`RuntimeObjCSection` 里凡是与上游 `ObjCInterfaceBuilder` /
`ObjCDump+SemanticString` 做同一件事的代码，都要按"上游是权威实现"去对照，而不是各写各的。

## 横向排查

- 按方法名建查找表的写法，`RuntimeViewerCore` 全仓库只有 `collectPropertyAccessors` 一处；类、
  协议、分类三个分支共用它，所以一处修复覆盖三条路径。
- 同一函数里的 `collectMethods` 也接收拼接数组，但它直接遍历、不建表，按 `isClassMethod` 决定
  前缀与 kind，没有覆盖问题。
- Swift 侧 `RuntimeSwiftSection.memberAddresses` 用的是访问器自带的符号，不做按名查表，不受影响。
