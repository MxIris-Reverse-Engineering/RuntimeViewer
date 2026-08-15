# 2026-08-15 「剥离合成方法」从来没剥掉过 setter

**调查日期：** 2026-08-15
**修复落地：** 本日，见 `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift`
**引入提交：** `285fa49b`（2026-01-04），随 `9b48c94 Improve performance and bug fixes for RuntimeObjCSection` 进入仓库
**Severity：** Minor —— 输出多出一批本该被剥掉的方法，不崩溃、不报错，但选项没有兑现它的名字
**触发场景：** 升级 MachOObjCSection 到 `0.8.104` 时发现上游刚修了同一段代码的副本，回头排查本仓库

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 打开 **Strip synthesized methods**，合成 getter 消失了，合成 setter 一个没少 |
| **影响范围** | 所有 ObjC class 与 protocol 的 interface 生成，只要开了该选项 |
| **根因** | 收集的是 `setFoo`，而匹配用的是完整 selector `setFoo:`，两者永不相等 |
| **Status** | **Fixed** —— 两处补上冒号，配回归测试 |

---

## 现象

`NSAffineTransform` 是最小复现。开启 **Strip synthesized methods** 后：

```objc
@property struct { double x0; … } transformStruct;

// getter 没了 —— 正确
- (void)setTransformStruct:(struct { double x0; … })transformStruct;   // ← 还在
```

getter（`transformStruct`）被剥掉了，setter（`setTransformStruct:`）原封不动。这个"一半生效"的形态是关键线索：如果是收集逻辑整体没跑，getter 也该留着。

---

## 根因

剥离分两步：先把要删的 selector 收进一个 `Set<String>`，再按 `ObjCMethodInfo.name` 把方法过滤掉。

```swift
methods: currentClassInfo.methods.removingAll { needsStripMethods.contains($0.name) }
```

`ObjCMethodInfo.name` 是**完整 selector**。getter 零参数，selector 就是属性名本身，不带冒号，所以收集端写 `needsStripMethods.insert(propertyName)` 恰好对得上。setter 带一个参数，selector 是 `setFoo:`，而收集端写的是：

```swift
let setterMethodName = "set" + propertyName.uppercasedFirst   // "setFoo"，少了冒号
```

`"setFoo"` 与 `"setFoo:"` 永远不相等，所以从 `285fa49b` 起，这个选项一个 setter 都没剥过。

**错误是双向的。** 假如某个类恰好声明了一个与属性无关的零参数方法 `setFoo`，它会被当成 `foo` 的 setter 剥掉——真正的访问器 `setFoo:` 留下，无辜的 `setFoo` 消失。补上冒号同时关掉两个方向。

同一段逻辑在文件里出现两次：class 分支（第 196 行）和 protocol 分支（第 302 行），两处都有这个 bug。

---

## 横向排查

全仓库扫了所有"拼一个 selector 去匹配方法名"的地方：

| 位置 | 拼法 | 判定 |
|---|---|---|
| `RuntimeObjCSection.swift:196`（class 分支） | `"set" + name.uppercasedFirst` | **错**，已修 |
| `RuntimeObjCSection.swift:302`（protocol 分支） | `"set" + name.uppercasedFirst` | **错**，已修 |
| `RuntimeObjCSection.swift:397`（member address） | `"set\(name.uppercasedFirst):"` | 正确，一直带冒号 |
| `ObjCDump+SemanticString.swift:327`（渲染） | `"set\(name.uppercasedFirst):"` | 正确，一直带冒号 |
| getter 各处 | 属性名本身 | 正确，零参数 selector 本就无冒号 |
| `.cxx_construct` / `.cxx_destruct` | 字面量 | 正确 |

只有那两处。

---

## 与上游的关系

MachOObjCSection 的 evolution 0001 把 RuntimeViewer 的这段 ObjC 渲染逻辑搬到了上游，**原样搬过去、连 bug 一起**——提案里写明这是刻意的，不在迁移里夹带行为变化，并点名要留一个 follow-up 专门修它。上游在 `edac0da`（2026-08-11，其 evolution 0004）修了自己那份，用 Foundation 的 `_NSPersonNameComponentsFormatterData` 复现。

RuntimeViewer 的 ObjC dump 路径**不走**上游的 `ObjCInterfaceBuilder`，所以升级到 `0.8.104` 不会顺带修好本仓库这份。这篇记的就是本仓库那次 follow-up。

上游同时报告了一个更值得记的教训：原有测试只断言"剥离后的输出比不剥离短"，而单靠 getter 就能满足这个条件——**这条弱断言正是 bug 活到今天的原因**。

---

## 验证

新增 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/ObjCSynthesizedMethodStrippingTests.swift`，两个测试都跑真实的 Foundation：

1. **setter 被剥离** —— 修复前失败（`NSAffineTransform` 留着 `setTransformStruct:`），修复后通过。
2. **getter 仍被剥离** —— 对照组，修复前后都通过，证明补冒号没有伤到本来就正确的那一半。

两处细节让测试不易失效：

- 测试**搜索** Foundation 里第一个真正声明了合成 setter 的类，而不是写死类名，这样系统框架内容随 OS 版本变化时不会失效；`objects(in:)` 不保证顺序，所以按名字排序后再扫，否则两个测试会落在不同的类上。
- 断言按 **selector 位置**匹配（返回类型右括号之后），不是 `contains`。ObjC dump 会把参数名写在类型之后，`+ (id)transformWithTransformStruct:(…)transformStruct;` 这一行用 `contains(")transformStruct;")` 会被误判成"声明了 getter"——写这个测试时先踩了一次。
