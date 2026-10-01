# 2026-10-01 协议的默认实现被打印两遍

**调查日期：** 2026-10-01
**修复落地：** 本日，见 `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift` 的 `interface(for:)`
**引入时间：** 上游 MachOSwiftSection `4e82f105`（2026-01-25）把「协议后面接着打默认实现」挪进逐定义的打印器之后；本仓库对应的追加写于 `9b48c942`（2026-01-05），当时并不重复
**Severity：** Minor —— 内容区多出一整块重复的扩展，不崩溃、不丢内容
**触发场景：** 在 `feature/find-navigator` 上写 Find 语料的「同一扩展不该出现两次」测试时发现；2026-09-17 的 Foundation 导出里 `LocalizedError` 也能看到

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 打开 `LocalizedError`、`DataProtocol`、`AttributedStringKey` 这类协议，默认实现的 `extension` 块连着出现两次，逐字相同 |
| **影响范围** | 没有父类型定义的 Swift 协议，只要它有默认实现；Foundation 里有 15 个 |
| **根因** | MachOSwiftSection 的 `printProtocolDefinition` 对 `parent == nil` 的协议会自己在后面接着打 `defaultImplementationExtensions`，`RuntimeSwiftSection.interface(for:)` 又追加了一遍 |
| **Status** | **Fixed** —— 只在协议有父类型定义时由本仓库追加，配回归测试 |

---

## 根因

`RuntimeSwiftSection.interface(for:)` 打印一个协议对象时，先调 `printer.printProtocolDefinition(definition)`，再把
`definition.defaultImplementationExtensions` 逐个 `printExtensionDefinition` 接在后面。2026-01-05 写下这段时，
「协议后面接着打默认实现」只存在于 MachOSwiftSection 的整镜像生成器 `SwiftInterfaceBuilder` 里，逐定义的打印器不管，
所以本仓库自己补上是对的。

2026-01-25 上游 `4e82f105`（Refactor Node for memory efficiency and extract SwiftInterfacePrinter）把这段逻辑搬进了
`SwiftDeclarationPrinter.printProtocolDefinition`：`protocolDefinition.parent == nil` 时，打印器在协议声明之后用
`BlockList` 把默认实现扩展打出来。从那以后，没有父类型定义的协议在本仓库里就被打印两遍。嵌套在类型里的协议
（`parent != nil`）打印器不管，本仓库那一遍仍是唯一的一遍。

## 修复

`.rootProtocol` 与 `.childProtocol` 两处都改成「只在 `definition.parent != nil` 时追加」，与打印器的分工对齐：
打印器管没有父类型定义的协议，本仓库管嵌套的协议。

`next` 依赖的 MachOSwiftSection 还多了一层：上游的容器统一会把扩展表里的同一批扩展挂到协议上
（`isAttachedToProtocolDefinition`），同时保留在扩展表里，所以 `next` 上还要把已挂到协议上的那几份从
`protocolExtensionDefinitions` 的追加里滤掉，否则仍会重复。`main` 钉的 `0.15.2` 没有这个属性，也没有这层重复。

## 验证

`SwiftProtocolInterfaceTests.extensionsPrintedOnce`：加载 Foundation，逐个打印全部 Swift 协议的内容区接口，
断言没有任何一个以 `extension` 开头的块出现两次。修复前红（15 个协议各重复一块），修复后绿；Core 全量 436 个测试通过
（Xcode 26.6，`main` 的锁定版本）。
