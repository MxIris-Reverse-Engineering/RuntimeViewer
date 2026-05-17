# Nested Generic Specialization 实施计划

> **For agentic workers:** 按 task 顺序串行实施，每个 task 末尾的 Commit step 完成后再进入下一个 task。所有 step 用 `- [ ]` checkbox 追踪。

**Goal:** 把 specialization sheet 从 `NSGridView` 平铺表单升级为 `NSOutlineView` 树形表单，让用户能选择泛型 candidate 并递归填充内层参数（`Box<Array<Int>>` / `Container<Dictionary<String, [User]>>` 等），适配上游 `MachOSwiftSection` 已落地的 `SpecializationSelection.Argument.boundGeneric(...)` 能力。

**Architecture:** 先改 wire/engine 层让 `RuntimeSpecializationSelection.arguments` 改为递归 `Argument` enum + 新增 `specializationRequest(forCandidate:in:)` 引擎方法；再新建 `SpecializationRowViewModel`（per-row VM）并改造 `SpecializationViewModel` 派生 selection 自 row 树；最后把 VC 换成 outline view，picker 解禁 generic candidate。每个 commit 都保持代码可构建（破坏性 wire 变更与对应的引擎适配捆绑在同一个 commit 里）。

**Tech Stack:** Swift 6.2 (mode v5)、RxSwift、SnapKit、`NSOutlineView` + RxAppKit `rx.nodes`、`tableView.box.makeView(ofClass:)`、`@Observed` / `BehaviorRelay` 派生 Driver、`swift-dependencies`。

**参考文档:** `Documentations/Plans/2026-05-11-nested-generic-specialization-design.md`

**前置依赖:** workspace `../MxIris-Reverse-Engineering.xcworkspace` 已就绪，其本地 `MachOSwiftSection` checkout 包含 `Argument.boundGeneric` / `Candidate.isGeneric` / `excludeGenerics` 等 API。

---

## File Structure

| 类型 | 路径 | 责任 |
|------|------|------|
| 修改 | `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeSpecialization.swift` | `arguments` → `[String: Argument]`；新增 `Argument` enum |
| 修改 | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift` | 新命令名 + 公共方法 `specializationRequest(forCandidate:in:)`；新增 `EngineError` case |
| 修改 | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+GenericSpecialization.swift` | 内层 request 方法路由 |
| 修改 | `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift` | 新 `specializationRequest(forCandidateID:)`；递归 `resolveUpstreamSelection`；树遍历 `typeArgumentNodes`；翻译上游 `boundGenericInnerFailed` |
| 修改 | `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift` | 注册新命令 handler |
| 修改 | `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeSpecializationTests.swift` | 适配 `Argument` enum；新增 nested 选择 round-trip case |
| **创建** | `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Specialization/SpecializationRowViewModel.swift` | per-row VM，`OutlineNodeType` + `Differentiable` |
| 修改 | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationViewModel.swift` | row 树替换 flat selection；lazy 内层 request；`expandRow` 信号 |
| 修改 | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationTypePickerViewModel.swift` | path-keyed parameter；去掉 `isGeneric` 拦截 |
| 修改 | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationViewController.swift` | `NSGridView` → `NSOutlineView`；新建 cell 类型；按 path 锚定 picker；自动展开 |
| 修改 | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationTypePickerViewController.swift` | 去掉 `shouldSelectRow` 拦截；徽标 "GENERIC" → "Nested" |
| 修改 | `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationCoordinator.swift` | route enum 字段 `parameterName` → `parameterPath: [String]` |

`SpecializationViewModel` / `SpecializationTypePickerViewModel` 当前文件位置是 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/`（不是 Application package），改 wire 类型时一并更新。

---

## Task 1: 改造 `RuntimeSpecializationSelection` 为递归 `Argument` enum

把 wire 层 selection 模型 + 引擎侧 selection 解析 / typeName 重写 / 错误码翻译 一次性切到新形态。破坏性变更，但都在同一个 commit 里完成以保持构建可行。

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeSpecialization.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift`
- Modify: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeSpecializationTests.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationViewModel.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationCoordinator.swift`

- [ ] **Step 1: 重写 `RuntimeSpecializationSelection`**

  在 `RuntimeSpecialization.swift` 中：

  - 把 `arguments` 的类型从 `[String: RuntimeSpecializationRequest.Candidate]` 改成 `[String: Argument]`。
  - 新增 `public enum Argument: Codable, Hashable, Sendable { case candidate(RuntimeSpecializationRequest.Candidate); case boundGeneric(baseCandidate: RuntimeSpecializationRequest.Candidate, innerArguments: [String: Argument]) }`。
  - 把 `subscript(_:)` 返回类型改成 `Argument?`。
  - 把 `setCandidate(_:for:)` 改名 `setArgument(_:for:)`，签名 `(_ argument: Argument, for parameterName: String)`。
  - 保留 `hasArgument(for:)` 不变。

- [ ] **Step 2: 引擎侧 `resolveUpstreamSelection` 递归化**

  在 `RuntimeSwiftSection.swift` 中：

  - 引入私有递归方法 `resolveUpstreamArguments(_ runtime: [String: Argument], against request: SpecializationRequest) throws -> [String: SpecializationSelection.Argument]`，按参数名匹配；对 `.candidate(c)` 走原 `(id, imagePath)` 匹配逻辑；对 `.boundGeneric(base, inner)`：
    1. 在 outer parameter 的 candidates 里按 `(id, imagePath)` 匹配 `base` 得到 upstream `Candidate`。
    2. 由 `base.typeName` 反查 `factory.indexer.allTypeDefinitions[typeName]`；查不到则抛 `EngineError.unindexedCandidate(displayName:imagePath:)`。
    3. `let innerRequest = try specializer.makeRequest(for: innerTypeDef.type.typeContextDescriptorWrapper)`。
    4. 递归 `resolveUpstreamArguments(inner, against: innerRequest)`。
    5. 返回 `.boundGeneric(baseCandidate: matchedUpstream, innerArguments: resolvedInner)`。
  - `resolveUpstreamSelection(_:against:)` 改为：`SpecializationSelection(arguments: try resolveUpstreamArguments(selection.arguments, against: request))`。

- [ ] **Step 3: `typeArgumentNodes` 树遍历**

  在 `RuntimeSwiftSection.specialize(for:with:)` 中，把现有平铺的 `typeArgumentNodes: [Node]` 收集替换为递归 helper。当前代码片段（在文件中搜索 `typeArgumentNodes`）：

  - 原来对每个 `upstreamRequest.parameter` 取 selection.arguments[name]，仅在 `.candidate` 情况下取 `candidate.typeName.node`；其它情况返回 nil 跳过。
  - 新版本：对每个 outer parameter，调 `buildTypeNode(for: upstreamArgument)`：
    - `.candidate(c)` → `c.typeName.node`
    - `.boundGeneric(base, inner)` → 用 `Demangling` 构造 `Node(kind: .boundGenericStructure / .boundGenericEnum / .boundGenericClass)` 节点链（依据 `base.typeName.kind` 决定 kind）；child[0] = `base.typeName.node`，child[1] = `Node(kind: .typeList, children: inner 参数按 upstream `innerRequest.parameters` 顺序的 buildTypeNode 结果)`。
  - 注意 inner request 重新构造一次（同 Step 2 的逻辑），保证 inner 参数的顺序与上游一致；可以把递归 helper 同时返回 `(SpecializationSelection.Argument, Node?)` 二元组以避免重复 `makeRequest` 调用。

- [ ] **Step 4: `EngineError` 新增 case 与翻译**

  在 `RuntimeEngine.swift` 的 `EngineError` 加：

  ```swift
  case boundGenericInnerFailed(parameterName: String, underlying: String)
  case unindexedCandidate(displayName: String, imagePath: String)
  ```

  以及对应 `errorDescription`。在 `RuntimeSwiftSection.specializationRequest(for:)` / `specialize(for:with:)` / 新 helper 的 `catch let error as GenericSpecializer<MachOImage>.SpecializerError` 分支中追加：

  ```swift
  case .boundGenericInnerFailed(let parameterName, let underlying):
      throw RuntimeEngine.EngineError.boundGenericInnerFailed(
          parameterName: parameterName,
          underlying: underlying.localizedDescription)
  ```

  （上游 case 名以 `MachOSwiftSection` 当前公开 API 为准；如名字不同则改成实际名字。）

- [ ] **Step 5: 更新调用方编译错误**

  在 `SpecializationViewModel.swift` 的 `applyArgumentChange(parameterName:candidate:)` 内：

  ```swift
  newSelection.setArgument(.candidate(candidate), for: parameterName)
  ```

  保持现有行为（只支持平铺选择），后续 Task 4 才会扩展。

  `SpecializationCoordinator.swift` 里现 `applyArgumentChange(parameterName:candidate:)` 调用不变，但参数语义在 Task 6 才改。

- [ ] **Step 6: 更新测试**

  `RuntimeSpecializationTests.swift`：

  - 所有现有断言里的 `.arguments["A"] == candidate` 改为 `.arguments["A"] == .candidate(candidate)`。
  - 新增一个 nested round-trip 用例：构造 `RuntimeSpecializationSelection(arguments: ["A": .boundGeneric(baseCandidate: ..., innerArguments: ["A": .candidate(...)])])`，`JSONEncoder().encode()` + decode，断言 round-trip 相等。

- [ ] **Step 7: 验证构建 + 测试**

  ```bash
  cd RuntimeViewerCore && swift package update 2>&1 | xcsift && swift build 2>&1 | xcsift
  cd RuntimeViewerCore && swift test 2>&1 | xcsift
  ```

  预期：build 成功、测试通过（包含新增的 nested round-trip）。

- [ ] **Step 8: Commit**

  ```bash
  git add RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeSpecialization.swift \
          RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift \
          RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift \
          RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeSpecializationTests.swift \
          RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationViewModel.swift
  git commit -m "$(cat <<'EOF'
  refactor(core): recursive selection.Argument for nested specialization

  Replaces the flat `[String: Candidate]` shape with a tagged
  `Argument` enum (`.candidate` / `.boundGeneric`). `resolveUpstreamSelection`
  walks the inner upstream request recursively; `typeArgumentNodes` emits
  nested `BoundGenericStructure(...)` nodes so specialized type names
  print as `Box<Array<Int>>` rather than `Box<Array>`. Adds
  `boundGenericInnerFailed` and `unindexedCandidate` to `EngineError`
  to surface the new upstream diagnostics across the wire.

  Wire shape changes — the v1 sheet has not shipped externally, so
  cross-version compatibility is not maintained.
  EOF
  )"
  ```

---

## Task 2: 新增 `specializationRequest(forCandidate:in:)` 引擎方法

让 UI 能在用户选了 generic candidate 后异步拉取它的内层 `RuntimeSpecializationRequest`。

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+GenericSpecialization.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift`
- Modify: `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeSpecializationTests.swift`

- [ ] **Step 1: 命令名 + Codable 请求结构**

  `RuntimeEngine.swift`：

  - `CommandNames` 添加 `case specializationRequestForCandidate`。
  - 新增 `struct SpecializationRequestForCandidateRequest: Codable, Sendable { let candidateID: String; let imagePath: String }`。

- [ ] **Step 2: `RuntimeSwiftSection.specializationRequest(forCandidateID:in:)`**

  在 `RuntimeSwiftSection` actor 中实现：

  ```swift
  func specializationRequest(forCandidateID candidateID: String, in imagePath: String) async throws -> RuntimeSpecializationRequest {
      // candidateID 是 mangleAsString(typeName.node) 产生的字符串；用 factory.indexer.allTypeDefinitions 反查 TypeName 匹配
      guard let typeDef = factory.indexer.allTypeDefinitions.first(where: { (typeName, _) in
          (try? mangleAsString(typeName.node)) == candidateID
      })?.value else {
          throw RuntimeEngine.EngineError.unindexedCandidate(displayName: candidateID, imagePath: imagePath)
      }
      do {
          let upstreamRequest = try specializer.makeRequest(for: typeDef.type.typeContextDescriptorWrapper)
          return try makeRuntimeSpecializationRequest(from: upstreamRequest)
      } catch let error as GenericSpecializer<MachOImage>.SpecializerError {
          // 复用 specializationRequest(for:) 中的错误翻译路径
          ...
      }
  }
  ```

  注：mangle 反查是 O(n) 全表扫描，n 大时若敏感再加 reverse map；首版先简单实现。

- [ ] **Step 3: 引擎入口**

  `RuntimeEngine+GenericSpecialization.swift` 加：

  ```swift
  public func specializationRequest(forCandidate candidateID: String, in imagePath: String) async throws -> RuntimeSpecializationRequest {
      try await specializationRequest(for: .init(candidateID: candidateID, imagePath: imagePath))
  }

  func specializationRequest(for request: SpecializationRequestForCandidateRequest) async throws -> RuntimeSpecializationRequest {
      try await self.request {
          guard let swiftSection = await swiftSectionFactory.existingSection(for: request.imagePath) else {
              throw EngineError.imageNotIndexed(imagePath: request.imagePath)
          }
          return try await swiftSection.specializationRequest(forCandidateID: request.candidateID, in: request.imagePath)
      } remote: { senderConnection in
          try await senderConnection.sendMessage(name: .specializationRequestForCandidate, request: request)
      }
  }
  ```

- [ ] **Step 4: server / proxy handler 注册**

  `RuntimeEngine.setupMessageHandlerForServer` 中加：

  ```swift
  setMessageHandlerBinding(forName: .specializationRequestForCandidate, of: self) { $0.specializationRequest(for:) }
  ```

  `RuntimeEngineProxyServer.setupRequestHandlers` 中加：

  ```swift
  connection.setMessageHandler(name: RuntimeEngine.CommandNames.specializationRequestForCandidate.commandName) {
      [engine] (request: RuntimeEngine.SpecializationRequestForCandidateRequest) -> RuntimeSpecializationRequest in
      try await engine.specializationRequest(forCandidate: request.candidateID, in: request.imagePath)
  }
  ```

- [ ] **Step 5: 测试**

  `RuntimeSpecializationTests.swift` 加一个 case：本地引擎对一个已知泛型 candidate（如 `Array`，从 stdlib image）调 `specializationRequest(forCandidate:in:)`，断言返回的 `RuntimeSpecializationRequest.parameters.count == 1` 且 `parameters[0].name == "A"`。如 stdlib image 在测试环境不可得，跳过 `#expect(false, "needs stdlib image, skipped")` 或用 fixture image。

- [ ] **Step 6: 验证构建 + 测试**

  ```bash
  cd RuntimeViewerCore && swift build 2>&1 | xcsift && swift test 2>&1 | xcsift
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift \
          RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+GenericSpecialization.swift \
          RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift \
          RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift \
          RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeSpecializationTests.swift
  git commit -m "$(cat <<'EOF'
  feat(core): expose specializationRequest(forCandidate:in:)

  Lets the UI fetch an inner SpecializationRequest for a generic
  candidate after the user selects it, without preloading the entire
  type-descriptor universe. Server-side resolves the candidateID
  (mangled name) via `factory.indexer.allTypeDefinitions` and reuses
  the existing `makeRuntimeSpecializationRequest` translation so the
  Codable shape stays identical to the outer-level request.

  Plumbed through both `RuntimeEngine.setupMessageHandlerForServer`
  and `RuntimeEngineProxyServer.setupRequestHandlers` for remote
  parity.
  EOF
  )"
  ```

---

## Task 3: 新建 `SpecializationRowViewModel`

把 per-row 的状态（当前 candidate / children / loadState）封装成一个公共 cell VM，给 outline 绑定。

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Specialization/SpecializationRowViewModel.swift`

> Application package 当前没有 `Specialization/` 子目录；新建即可。`SpecializationViewModel` 因为是 macOS-only sheet，留在 AppKit 目标里没动。这个 cell VM 公共类型必须落在 Application package，让两个目标都可见。

- [ ] **Step 1: 文件骨架与导入**

  ```swift
  #if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import RxAppKit
  #endif

  import Foundation
  import RuntimeViewerUI
  import RuntimeViewerCore
  import RuntimeViewerArchitectures
  import DifferenceKit
  ```

- [ ] **Step 2: 主类型 + observed 字段**

  ```swift
  public final class SpecializationRowViewModel: NSObject, OutlineNodeType, @unchecked Sendable {
      public let parameterPath: [String]
      public let parameter: RuntimeSpecializationRequest.Parameter

      @Observed public private(set) var selectedCandidate: RuntimeSpecializationRequest.Candidate?
      @Observed public private(set) var children: [SpecializationRowViewModel]
      @Observed public private(set) var loadState: InnerLoadState
      @Observed public private(set) var buttonTitle: String
      @Observed public private(set) var descriptionText: NSAttributedString

      public var isLeaf: Bool { children.isEmpty && loadState == .idle }

      public enum InnerLoadState: Equatable, Sendable {
          case idle, loading
          case failed(String)
      }

      public init(parameterPath: [String], parameter: RuntimeSpecializationRequest.Parameter) {
          self.parameterPath = parameterPath
          self.parameter = parameter
          self.selectedCandidate = nil
          self.children = []
          self.loadState = .idle
          self.buttonTitle = "Choose Type…"
          self.descriptionText = Self.makeDescriptionText(for: parameter)
          super.init()
      }
  }
  ```

  `Self.makeDescriptionText(for:)` 把 `parameter.displayDescription` 包装成 `NSAttributedString`（labelColor / systemFont13 / lineBreakMode=byTruncatingTail）。

- [ ] **Step 3: `argument` 派生 + mutators**

  ```swift
  public var argument: RuntimeSpecializationSelection.Argument? {
      guard let candidate = selectedCandidate else { return nil }
      if !candidate.isGeneric { return .candidate(candidate) }
      var innerArgs: [String: RuntimeSpecializationSelection.Argument] = [:]
      for child in children {
          guard let childArg = child.argument else { return nil }
          innerArgs[child.parameter.name] = childArg
      }
      return .boundGeneric(baseCandidate: candidate, innerArguments: innerArgs)
  }

  public func applyCandidate(_ candidate: RuntimeSpecializationRequest.Candidate) {
      selectedCandidate = candidate
      children = []           // 切换基础 candidate 时丢弃旧子树
      loadState = .idle
      buttonTitle = Self.shortDisplayName(for: candidate)
  }

  public func setLoading() { loadState = .loading }
  public func setLoadFailed(_ message: String) { loadState = .failed(message) }

  public func installInnerParameters(_ parameters: [RuntimeSpecializationRequest.Parameter]) {
      children = parameters.map { SpecializationRowViewModel(parameterPath: parameterPath + [$0.name], parameter: $0) }
      loadState = .idle
  }
  ```

  `Self.shortDisplayName(for:)` 对非 generic 返回 `displayName`；对 generic 返回如 `Array<…>` / `Dictionary<…>`（用 `parameter.candidates.first.typeName` 或者 candidate 自带 `displayName`，截断尖括号内部）—— 首版可以简单地返回 `candidate.displayName`。

- [ ] **Step 4: `OutlineNodeType` 适配**

  `OutlineNodeType` 协议要求 `children` 返回 `[Self]` —— 已通过 `@Observed children: [SpecializationRowViewModel]` 满足。如协议还要求 `isLeaf` 已经有了。

- [ ] **Step 5: `Differentiable` 适配**

  ```swift
  #if canImport(AppKit) && !targetEnvironment(macCatalyst)
  extension SpecializationRowViewModel: Differentiable {
      public var differenceIdentifier: [String] { parameterPath }
      public func isContentEqual(to source: SpecializationRowViewModel) -> Bool {
          parameterPath == source.parameterPath
              && selectedCandidate == source.selectedCandidate
              && loadState == source.loadState
      }
  }
  #endif
  ```

- [ ] **Step 6: 验证构建**

  ```bash
  cd RuntimeViewerPackages && swift package update 2>&1 | xcsift && swift build 2>&1 | xcsift
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/Specialization/SpecializationRowViewModel.swift
  git commit -m "$(cat <<'EOF'
  feat(application): add SpecializationRowViewModel for nested form

  Per-row VM backing the upcoming NSOutlineView form. Wraps a single
  generic parameter with its currently selected candidate, lazily
  populated child rows for `.boundGeneric` selections, and a load
  state surfaced for the inner-request fetch. The wire-level
  `Argument` is derived (not stored) so the form's selection tree
  is always the source of truth.
  EOF
  )"
  ```

---

## Task 4: 改造 `SpecializationViewModel` 用 row 树

把现有 `selection: RuntimeSpecializationSelection` 状态改成 `topLevelRows: [SpecializationRowViewModel]`，添加 lazy 拉内层 request 的路径，新增 `expandRow` 信号。

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationViewModel.swift`

- [ ] **Step 1: 状态改造**

  - 删除 `@Observed private(set) var selection: RuntimeSpecializationSelection`。
  - 新增 `@Observed private(set) var topLevelRows: [SpecializationRowViewModel] = []`。
  - 新增 `private let expandRowRelay = PublishRelay<SpecializationRowViewModel>()`。
  - `canSpecialize` 派生：`topLevelRows.allSatisfy { $0.argument != nil }`，在每次 row 树变更后用 `refreshCanSpecialize()` 重算。

- [ ] **Step 2: `Input` / `Output` 重构**

  ```swift
  public struct Input {
      public let specializeClicked: Signal<Void>
      public let cancelClicked: Signal<Void>
      public let requestTypePickerClicked: Signal<[String]>     // parameterPath
  }

  public struct Output {
      public let request: Driver<RuntimeSpecializationRequest?>
      public let rows: Driver<[SpecializationRowViewModel]>
      public let loadState: Driver<LoadState>
      public let canSpecialize: Driver<Bool>
      public let runtimeObjectDisplayName: Driver<String>
      public let expandRow: Signal<SpecializationRowViewModel>
  }
  ```

  `selection` 字段从 Output 删除（VC 不再需要订阅）。

- [ ] **Step 3: `loadRequest()` 末尾构造 topLevelRows**

  ```swift
  request = req
  topLevelRows = req.parameters.map { SpecializationRowViewModel(parameterPath: [$0.name], parameter: $0) }
  loadState = .loaded
  refreshCanSpecialize()
  ```

- [ ] **Step 4: `applyArgumentChange(path:candidate:)`**

  替换原 `applyArgumentChange(parameterName:candidate:)`：

  ```swift
  public func applyArgumentChange(
      path: [String],
      candidate: RuntimeSpecializationRequest.Candidate
  ) {
      guard let row = locateRow(path: path, in: topLevelRows) else { return }
      row.applyCandidate(candidate)
      refreshCanSpecialize()

      if candidate.isGeneric {
          row.setLoading()
          Task { [weak self] in
              guard let self else { return }
              do {
                  let innerRequest = try await documentState.runtimeEngine
                      .specializationRequest(forCandidate: candidate.id, in: candidate.imagePath)
                  await MainActor.run {
                      row.installInnerParameters(innerRequest.parameters)
                      self.refreshCanSpecialize()
                      self.expandRowRelay.accept(row)
                  }
              } catch {
                  await MainActor.run { row.setLoadFailed(error.localizedDescription) }
              }
          }
      }
  }

  private func locateRow(path: [String], in rows: [SpecializationRowViewModel]) -> SpecializationRowViewModel? {
      guard let head = path.first else { return nil }
      guard let match = rows.first(where: { $0.parameter.name == head }) else { return nil }
      if path.count == 1 { return match }
      return locateRow(path: Array(path.dropFirst()), in: match.children)
  }
  ```

- [ ] **Step 5: `performSpecialize` 用 row 树派生 selection**

  ```swift
  private func performSpecialize() async {
      var args: [String: RuntimeSpecializationSelection.Argument] = [:]
      for row in topLevelRows {
          guard let arg = row.argument else { return }
          args[row.parameter.name] = arg
      }
      let selection = RuntimeSpecializationSelection(arguments: args)
      do {
          let validation = try await documentState.runtimeEngine.runtimePreflight(
              for: runtimeObject, with: selection)
          guard validation.isValid else {
              errorRelay.accept(PreflightFailedError(errors: validation.errors))
              return
          }
          let specialized = try await documentState.runtimeEngine.specialize(
              runtimeObject, with: selection)
          router.trigger(.specializeCompleted(specialized))
      } catch {
          #log(.error, "specialize failed: \(error, privacy: .public)")
          errorRelay.accept(error)
      }
  }
  ```

- [ ] **Step 6: `transform(_:)` 接线**

  - 将原 `selection.driveOnNext { ... refresh chooseButtons ... }` 整段删除（VC 改造在 Task 7 里完成）。
  - `requestTypePickerClicked` 改成 `[String]` payload，转发 `.requestTypePicker(parameterPath:)`（route 改名见 Task 6）。
  - 把 `rows: $topLevelRows.asDriver()` 与 `expandRow: expandRowRelay.asSignal()` 放进 Output。

- [ ] **Step 7: 验证构建（VC 还未改造，整体 build 会暂时挂在 SpecializationViewController；先只确认 VM 文件自身语法干净）**

  ```bash
  cd RuntimeViewerCore && swift build 2>&1 | xcsift
  # 然后 xcodebuild 仍会失败，预期；下一个 task 起依次修复
  ```

- [ ] **Step 8: 暂不 commit（依赖 Task 6 / 7 才能整体编译）**

  > Task 4 的改动单独 commit 后 xcode build 会红，因此 Task 4 不独立 commit；推迟到 Task 7 末尾与 Coordinator / VC 改动一起 commit。把这一步标 `- [x] (skipped, bundled into Task 7 commit)` 即可。

---

## Task 5: TypePicker VM 接受 path，解禁 isGeneric

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationTypePickerViewModel.swift`

- [ ] **Step 1: 重命名 init 参数**

  ```swift
  public init(
      parameterPath: [String],
      candidates: [RuntimeSpecializationRequest.Candidate],
      documentState: DocumentState,
      router: any Router<SpecializationRoute>
  ) {
      self.parameterPath = parameterPath
      ...
  }
  ```

  存为 `private let parameterPath: [String]`，删除 `private let parameterName: String`。

- [ ] **Step 2: 解禁 generic candidate**

  在 `transform(_:)` 的 `candidateClicked.emitOnNext` 内：

  - 删除 `guard !candidate.isGeneric else { return }` 短路。
  - `router.trigger(.didSelectCandidate(parameterPath: parameterPath, candidate: candidate))`（route 字段在 Task 6 改）。

- [ ] **Step 3: 与 Task 7 同 commit**

  这一步不独立 commit，等 Task 7 完成。

---

## Task 6: `SpecializationCoordinator` route 字段改名

`SpecializationRoute.requestTypePicker(parameterName:)` / `.didSelectCandidate(parameterName:candidate:)` 改成 `parameterPath: [String]`。

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationCoordinator.swift`

- [ ] **Step 1: 改 route 枚举**

  ```swift
  @AssociatedValue(.public)
  @CaseCheckable(.public)
  public enum SpecializationRoute: Routable {
      case cancel
      case dismiss
      case requestTypePicker(parameterPath: [String])
      case didSelectCandidate(parameterPath: [String], candidate: RuntimeSpecializationRequest.Candidate)
      case specializeCompleted(RuntimeObject)
  }
  ```

- [ ] **Step 2: `prepareTransition(for:)` 适配**

  - `case .requestTypePicker(let parameterPath): return showTypePicker(for: parameterPath)`
  - `case .didSelectCandidate(let parameterPath, let candidate): specializationViewModel?.applyArgumentChange(path: parameterPath, candidate: candidate); return .dismiss()`

- [ ] **Step 3: `showTypePicker(for:)` 改成按 path 查 parameter + anchor**

  ```swift
  private func showTypePicker(for parameterPath: [String]) -> SpecializationTransition {
      guard let parameter = parameter(forPath: parameterPath),
            let anchor = specializationViewController?.anchorView(forPath: parameterPath)
      else {
          #log(.error, "Cannot resolve type picker anchor for path \(parameterPath, privacy: .public)")
          return .none()
      }
      let pickerViewController = makeTypePicker(parameterPath: parameterPath, parameter: parameter)
      return .present(pickerViewController, mode: .asPopover(...))
  }

  private func parameter(forPath path: [String]) -> RuntimeSpecializationRequest.Parameter? {
      // 用 topLevelRows 而不是 request.parameters；行树才包含内层 parameter 信息。
      guard let viewModel = specializationViewModel else { return nil }
      var rows = viewModel.topLevelRows
      var match: SpecializationRowViewModel?
      for name in path {
          match = rows.first { $0.parameter.name == name }
          guard let next = match else { return nil }
          rows = next.children
      }
      return match?.parameter
  }
  ```

  `makeTypePicker` 改签名：`(parameterPath:, parameter:)`，把 candidates 传 `parameter.candidates`，VM init 用 `parameterPath:`。

- [ ] **Step 4: 与 Task 7 同 commit**

---

## Task 7: `SpecializationViewController` 改用 `NSOutlineView`

把 sheet 主体从 `NSGridView` 平铺改成 outline tree，新建私有 cell 类型，绑 `output.rows` / `output.expandRow`。同 commit 包含 Task 4 / 5 / 6 的累积改动，让 AppKit 目标恢复构建。

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationViewController.swift`

- [ ] **Step 1: 替换 subviews**

  - 删除 `gridView`、`chooseButtonsByParameterName`、`requestTypePickerClickedRelay`（行级 relay 改由 cell 自带）。
  - 新增：
    ```swift
    private let (scrollView, outlineView): (ScrollView, NSOutlineView) = NSOutlineView.scrollableOutlineView()
    private let chooseClickRelay = PublishRelay<[String]>()
    ```
    （`NSOutlineView.scrollableOutlineView()` 工厂如不存在，则参照 `SingleColumnTableView.scrollableTableView()` 风格手工组装 ScrollView + OutlineView + 单列。)

- [ ] **Step 2: `viewDidLoad` 重写 hierarchy + 约束**

  - `headerLabel` 在顶上不变；`scrollView` 在中间；`statusLabel` 在 scrollView 底部 / specialize cancel 之间；`cancelButton` / `specializeButton` 在底右。
  - `outlineView` 单列、`headerView = nil`、`indentationPerLevel = 16`、`autoresizesOutlineColumn = false`、`style = .inset`、`backgroundColor = .clear`、`rowHeight = 28` 起步（cell 内 HStack 自适应也行）。
  - 删除 `rebuildForm(for:)` 整个方法。
  - 删除 `anchorView(forParameter:)`；新增 `anchorView(forPath:)`：

    ```swift
    func anchorView(forPath parameterPath: [String]) -> NSView? {
        guard let row = locateRow(forPath: parameterPath) else { return nil }
        let rowIndex = outlineView.row(forItem: row)
        guard rowIndex >= 0,
              let cellView = outlineView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? ParameterRowCellView
        else { return nil }
        return cellView.chooseButton
    }

    private func locateRow(forPath path: [String]) -> SpecializationRowViewModel? {
        // 同 Coordinator.parameter(forPath:)，但走 viewModel.topLevelRows
        ...
    }
    ```

- [ ] **Step 3: 私有 cell 类型 `ParameterRowCellView`**

  ```swift
  extension SpecializationViewController {
      fileprivate final class ParameterRowCellView: TableCellView {
          private let descriptionLabel = Label()
          let chooseButton = PushButton(title: "Choose Type…", titleFont: .systemFont(ofSize: 13))
          let clickRelay = PublishRelay<[String]>()
          private var currentPath: [String] = []

          override func setup() {
              super.setup()
              let stack = HStackView(spacing: 8) { descriptionLabel; chooseButton }
              hierarchy { stack }
              stack.snp.makeConstraints { make in
                  make.leading.trailing.equalToSuperview().inset(4)
                  make.centerY.equalToSuperview()
              }
              descriptionLabel.do { $0.maximumNumberOfLines = 1 }
              chooseButton.setContentHuggingPriority(.required, for: .horizontal)
              chooseButton.snp.makeConstraints { make in make.width.greaterThanOrEqualTo(160) }
          }

          func bind(to row: SpecializationRowViewModel) {
              rx.disposeBag = DisposeBag()
              currentPath = row.parameterPath
              row.$descriptionText.asDriver().drive(descriptionLabel.rx.attributedStringValue).disposed(by: rx.disposeBag)
              row.$buttonTitle.asDriver().drive(chooseButton.rx.title).disposed(by: rx.disposeBag)
              chooseButton.rx.click
                  .asSignal()
                  .emit(with: self) { $0.clickRelay.accept($0.currentPath) }
                  .disposed(by: rx.disposeBag)
          }
      }
  }
  ```

- [ ] **Step 4: 绑定 `output.rows` / `expandRow`**

  ```swift
  output.rows
      .drive(outlineView.rx.nodes) { [weak self] (outlineView, _, row: SpecializationRowViewModel) -> NSView? in
          guard let self else { return nil }
          let cellView = outlineView.box.makeView(ofClass: ParameterRowCellView.self)
          cellView.bind(to: row)
          // 桥接 cell 内 relay 到 VC 统一 relay
          cellView.clickRelay
              .asSignal()
              .emit(to: self.chooseClickRelay)
              .disposed(by: cellView.rx.disposeBag)
          return cellView
      }
      .disposed(by: rx.disposeBag)

  output.expandRow.emitOnNext { [weak self] row in
      guard let self else { return }
      outlineView.expandItem(row, expandChildren: false)
  }
  .disposed(by: rx.disposeBag)
  ```

- [ ] **Step 5: `Input` 接线**

  ```swift
  let input = SpecializationViewModel.Input(
      specializeClicked: specializeButton.rx.click.asSignal(),
      cancelClicked: cancelButton.rx.click.asSignal(),
      requestTypePickerClicked: chooseClickRelay.asSignal()
  )
  ```

  原 `output.selection.driveOnNext { ... }` 段整段删除（cell 已经按 row VM 自更新 buttonTitle）。

- [ ] **Step 6: 验证构建**

  通过 workspace 构建主 scheme：

  ```bash
  xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
      -scheme RuntimeViewerUsingAppKit -configuration Debug \
      -destination 'generic/platform=macOS' 2>&1 | xcsift
  ```

- [ ] **Step 7: Commit（含 Task 4 / 5 / 6 / 7 累积改动）**

  ```bash
  git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationViewModel.swift \
          RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationTypePickerViewModel.swift \
          RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationCoordinator.swift \
          RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationViewController.swift
  git commit -m "$(cat <<'EOF'
  feat(specialization): nested form via NSOutlineView

  Replaces the NSGridView-based sheet with an NSOutlineView tree.
  Each parameter row keeps its own SpecializationRowViewModel
  (state + lazy inner-request fetch) and the wire-level selection
  is rebuilt by walking the row tree at specialize time. Picking
  a generic candidate auto-expands the row and exposes the
  candidate's own parameters as child rows. The type picker now
  accepts a `parameterPath: [String]` route payload so the
  coordinator can anchor the popover relative to the clicked row,
  not the sheet itself.
  EOF
  )"
  ```

---

## Task 8: TypePicker VC — 去掉 generic 拦截，徽标改文案

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationTypePickerViewController.swift`

- [ ] **Step 1: 删除 `shouldSelectRow` 拦截**

  整个 `extension SpecializationTypePickerViewController: NSTableViewDelegate { ... }` 块可删（或保留方法但恒返回 `true`，看是否还有其它委托方法计划加入；首版直接删）。

  同步删除 `tableView.rx.setDelegate(self).disposed(by: rx.disposeBag)` 这一行（不再需要 forward optional delegate methods）。

- [ ] **Step 2: 徽标重命名**

  `CandidateCellView` 内：

  ```swift
  genericBadge.do {
      $0.font = .systemFont(ofSize: 10, weight: .medium)
      $0.textColor = .systemBlue          // 从 .systemRed 改为 .systemBlue
      $0.stringValue = "NESTED"           // 从 "GENERIC" 改为 "NESTED"
  }
  ```

  `configure(with:)`：

  ```swift
  genericBadge.isHidden = !candidate.isGeneric
  nameLabel.alphaValue = 1.0              // 不再灰显
  imageLabel.alphaValue = 1.0
  toolTip = candidate.isGeneric
      ? "Selecting this opens a nested specialization for the type's own generic parameters."
      : nil
  ```

- [ ] **Step 3: 验证构建**

  ```bash
  xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
      -scheme RuntimeViewerUsingAppKit -configuration Debug \
      -destination 'generic/platform=macOS' 2>&1 | xcsift
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationTypePickerViewController.swift
  git commit -m "$(cat <<'EOF'
  feat(specialization): allow selecting generic candidates in picker

  Removes the `shouldSelectRow` gate that rejected generic candidates
  and recolors the candidate-cell badge from red "GENERIC" to blue
  "NESTED" so it now reads as an informational hint instead of a
  disabled marker. Picking a generic candidate is the entry point
  for the new nested specialization flow added in the previous
  commit.
  EOF
  )"
  ```

---

## Task 9: 端到端冒烟（manual，不产生 commit）

- [ ] **Step 1: 启动 Debug 主 app**

  ```bash
  xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
      -scheme RuntimeViewerUsingAppKit -configuration Debug \
      -destination 'generic/platform=macOS' 2>&1 | xcsift
  open Products/Debug/RuntimeViewer.app    # 或通过 Xcode Run，路径以实际产物为准
  ```

- [ ] **Step 2: 选一个已知 generic 类型**

  - 用 sidebar 打开任意已索引的 image（最简：当前进程主可执行；若 stdlib 类型不出现在 sidebar，加载一个含泛型类型的 framework）。
  - 在 sidebar 找到一个 `isGeneric` 类型（图标右下角有 G 标），右键 / 工具栏选 "Specialize"。
  - sheet 弹出，外层参数显示约束。

- [ ] **Step 3: 选 generic candidate（非叶）**

  - 在外层参数行点 "Choose Type…"，picker 弹出。
  - 选一个标 "NESTED" 的 candidate（比如 `Array`、`Optional`）。
  - 期望：popover 关闭后外层 row 自动展开，下方出现 inner parameter 行；row 按钮显示 candidate displayName，short hint 文案保留。

- [ ] **Step 4: 在内层 row 选叶 candidate 完成 specialize**

  - 内层 row 选 `Int` / `String` 等非泛型 candidate。
  - 点 "Specialize"。
  - 期望：preflight 通过，sheet 关闭，sidebar 在原泛型节点下插入新的 specialized 子节点（如 `Box<Array<Int>>`）。点该子节点 Content view 应显示已替换泛型参数的 Swift interface。

- [ ] **Step 5: 错误路径冒烟**

  - 选一个**违反约束**的 candidate（如外层 `A : Hashable`，内层选了一个非 `Hashable` 类型生成的嵌套结构）。点 "Specialize"。
  - 期望：底部 statusLabel 弹错误 alert，描述包含 `protocolRequirementNotSatisfied` 与外层参数名。

- [ ] **Step 6: 多层嵌套（可选）**

  - 选 `Dictionary` 作为外层，内层 `B` 再选 `Array`，最里层 `Int`。
  - 期望：三层 disclosure 全部展开，specialize 后 sidebar 出现 `Container<Dictionary<String, [Int]>>` 类的节点（或对应的实际类型链）。

- [ ] **Step 7: 不产生 commit；如发现 bug，记入 follow-up task**

---

## Self-Review

- [ ] **Wire compatibility 没人留意**：跨版本的 client / server 不再能解码 `RuntimeSpecializationSelection`；确认这点已在 design 文档里写明白，且当前只有本地 app 在用。
- [ ] **Lazy inner-request 没有缓存**：远程 source 下用户在多个 generic 行间切换 candidate 时，每次都跨网拉一次内层 request。如 QA 反映卡，按 design 文档 "Open Questions #2" 加 actor-side `(candidateID, imagePath)` cache。
- [ ] **Outline view expansion state 在节点重建后是否保留**：`@Observed children` 重新赋值时 `rx.nodes` 走 DifferenceKit diff；`differenceIdentifier = parameterPath` 保证已展开节点 identity 稳定，理论上展开态保留。如出现折叠回弹，加 `outlineView.expandItem(row)` 在 `expandRow` 回调中保险。
- [ ] **Recursion 安全**：上游 `maxBindingDepth = 16`，UI 这边没单独限。深度 > 16 时 `specialize` 会抛 `boundGenericInnerFailed`，statusLabel 会展示，没问题。
- [ ] **`mangleAsString` 反查 O(n)**：`specializationRequest(forCandidateID:)` 每次扫全表。如热路径上感知，加一个 `[String: TypeName]` reverse map 在 `RuntimeSwiftSection` 内 lazy 构建。
- [ ] **Cell view button width 拥挤**：嵌套深时 row 缩进吃宽度，`chooseButton.width >= 160` 可能超出 popover 宽度；冒烟时确认 sheet `preferredContentSize` 在三层嵌套下仍能完整放下，否则把 sheet 宽度提到 600。
