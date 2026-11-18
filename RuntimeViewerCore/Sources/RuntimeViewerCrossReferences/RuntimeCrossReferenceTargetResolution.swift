public import RuntimeViewerCore

/// The subject a callers or callees query asks about, as a command line or an
/// MCP client writes it — one spelling for both front ends:
///
/// - `-[NSWindow makeKeyAndOrderFront:]` or `+[NSColor redColor]`: a method;
/// - `SwiftUI.ViewGraph.updateOutputs(at:)`: a Swift member, as `members`
///   prints it;
/// - a symbol, with or without its leading underscore: `_objc_msgSend`,
///   `CFRelease`, `$s7SwiftUI9ViewGraphC…`;
/// - `0x184ae35c0`, which needs the image it is in;
/// - with `isSelector`, a selector, whose every send is a caller.
public enum RuntimeCrossReferenceTargetResolution {
    /// Resolves `target`.
    ///
    /// - Parameters:
    ///   - imagePath: The image the target is in, when one is named: an
    ///     address needs it, and it picks one of several definitions of a
    ///     symbol.
    ///   - findType: Looks a type up by name — each front end has its own
    ///     rules for which images it searches.
    public static func subject(
        forTarget target: String,
        isSelector: Bool,
        imagePath: String?,
        engine: RuntimeEngine,
        findType: (String) async throws -> RuntimeObject?
    ) async throws -> RuntimeCrossReferenceSubject {
        let target = target.trimmingCharacters(in: .whitespaces)
        if isSelector { return .selector(target) }
        if let address = Self.address(in: target) {
            guard let imagePath else { throw RuntimeCrossReferenceError.addressNeedsImage(address: address) }
            return .function(imagePath: imagePath, address: address)
        }
        if let method = ObjectiveCMethodName(symbol: target), let object = try await findType(method.className) {
            return .member(RuntimeMemberReference(object: object, name: method.selector, kind: .objcMethod, isStatic: method.isClassMethod))
        }
        if !Self.isMangledSwiftName(target), let (typeName, memberName) = Self.splitMember(target),
           let object = try await findType(typeName) {
            guard let member = try await Self.member(named: memberName, of: object, engine: engine) else {
                throw RuntimeCrossReferenceError.memberNotFound(objectName: object.displayName, memberName: memberName)
            }
            return .member(member)
        }
        return try await Self.function(ofSymbolNamed: target, imagePath: imagePath, engine: engine)
    }

    /// `0x` and hexadecimal digits.
    private static func address(in target: String) -> UInt64? {
        guard target.hasPrefix("0x") || target.hasPrefix("0X") else { return nil }
        return UInt64(target.dropFirst(2), radix: 16)
    }

    private static func isMangledSwiftName(_ target: String) -> Bool {
        ["$s", "_$s", "$S", "_$S", "_T0", "$e", "_$e"].contains { target.hasPrefix($0) }
    }

    /// `Module.Type.member(label:)` as the type's name and the member's: the
    /// last dot before any parenthesis divides them.
    private static func splitMember(_ target: String) -> (typeName: String, memberName: String)? {
        let beforeParameters = target.firstIndex(of: "(").map { target[..<$0] } ?? Substring(target)
        guard let dot = beforeParameters.lastIndex(of: "."), dot != target.startIndex else { return nil }
        let memberName = String(target[target.index(after: dot)...])
        guard !memberName.isEmpty else { return nil }
        return (String(target[..<dot]), memberName)
    }

    /// The member of `object` named `memberName`, from its member list: the
    /// row's kind says whether it is a method, a property, an accessor of a
    /// variable, a subscript or an initializer. A name without parameters
    /// matches a function's name with them when only one does.
    private static func member(named memberName: String, of object: RuntimeObject, engine: RuntimeEngine) async throws -> RuntimeMemberReference? {
        let baseName = memberName.firstIndex(of: "(").map { String(memberName[..<$0]) } ?? memberName
        let rows = try await engine.memberAddresses(for: object, memberName: baseName)
        var matches = rows.filter { $0.name == memberName }
        if matches.isEmpty, !memberName.contains("(") {
            let candidates = rows.filter { $0.name.hasPrefix(memberName + "(") }
            if Set(candidates.map(\.name)).count == 1 { matches = candidates }
        }
        if matches.isEmpty, baseName == "init" {
            matches = rows.filter { $0.kind == "init" || $0.kind == "allocator" }
        }
        guard let row = matches.first else { return nil }
        let (kind, isStatic) = Self.memberKind(ofRowKind: row.kind)
        return RuntimeMemberReference(object: object, name: row.name, kind: kind, isStatic: isStatic)
    }

    /// The member kind a member-list row's kind spells — the reverse of what
    /// the callers' matching reads.
    private static func memberKind(ofRowKind rowKind: String) -> (RuntimeMemberKind, isStatic: Bool) {
        switch rowKind {
        case "method": return (.objcMethod, false)
        case "class method": return (.objcMethod, true)
        case "init", "allocator": return (.swiftInitializer, false)
        default: break
        }
        if rowKind.hasPrefix("class property ") { return (.objcProperty, true) }
        if rowKind.hasPrefix("property ") { return (.objcProperty, false) }
        let isStatic = rowKind.hasPrefix("static ")
        let rest = isStatic ? String(rowKind.dropFirst("static ".count)) : rowKind
        if rest == "func" { return (.swiftFunction, isStatic) }
        if rest.hasPrefix("subscript.") { return (.swiftSubscript, isStatic) }
        return (.swiftVariable, isStatic)
    }

    /// The function a symbol names: the one definition, or the one in
    /// `imagePath`. A C name is also tried with the underscore the symbol
    /// table spells it with.
    private static func function(ofSymbolNamed name: String, imagePath: String?, engine: RuntimeEngine) async throws -> RuntimeCrossReferenceSubject {
        var locations = try await engine.locations(ofSymbolNamed: name)
        if locations.isEmpty, !name.hasPrefix("_") {
            locations = try await engine.locations(ofSymbolNamed: "_" + name)
        }
        if let imagePath {
            locations = locations.filter { $0.imagePath == imagePath }
        }
        guard let location = locations.first else { throw RuntimeCrossReferenceError.targetNotFound(name) }
        guard Set(locations).count == 1 else {
            throw RuntimeCrossReferenceError.ambiguousTarget(name, imagePaths: locations.map(\.imagePath))
        }
        return .function(imagePath: location.imagePath, address: location.address)
    }
}
