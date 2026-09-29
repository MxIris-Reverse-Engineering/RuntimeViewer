import Foundation
import ObjCDump

extension RuntimeObjCSection {
    /// The object's corpus entry: its interface printed with the canonical
    /// generation options (every strip switch off, every annotation on) and
    /// the user's transformer, plus its members from the parsed metadata,
    /// aligned with that text.
    ///
    /// The Objective-C side keeps no interface cache, so there is nothing to
    /// bypass here: the builder is created per call and prints straight from
    /// the indexer.
    func corpusEntry(for object: RuntimeObject, transformer: Transformer.Configuration) async throws -> RuntimeInterfaceCorpusEntry? {
        let interface = try await interface(
            for: object,
            using: RuntimeObjectInterface.GenerationOptions.mcp.objcHeaderOptions,
            transformer: transformer.objc
        )
        let members = RuntimeMemberDeclarationLocator.locate(memberDeclarations(for: object), in: interface.interfaceString)
        return RuntimeInterfaceCorpusEntry(object: object, interface: interface.interfaceString, members: members)
    }

    /// The object's members as `ObjCClassInfo` / `ObjCProtocolInfo` /
    /// `ObjCCategoryInfo` list them, not yet located in any text. C structs
    /// and unions have no members in this sense.
    func memberDeclarations(for object: RuntimeObject) -> [RuntimeMemberDeclaration] {
        let name = object.withImagePath(imagePath)
        switch name.kind {
        case .objc(.type(.class)):
            guard let classInfo = objcIndexer.classGroup(forName: name.name)?.info.first else { return [] }
            return Self.memberDeclarations(
                properties: classInfo.properties,
                classProperties: classInfo.classProperties,
                methods: classInfo.methods,
                classMethods: classInfo.classMethods,
                ivars: classInfo.ivars
            )
        case .objc(.type(.protocol)):
            guard let protocolInfo = objcIndexer.protocolGroup(forName: name.name)?.info else { return [] }
            return Self.memberDeclarations(
                properties: protocolInfo.properties + protocolInfo.optionalProperties,
                classProperties: protocolInfo.classProperties + protocolInfo.optionalClassProperties,
                methods: protocolInfo.methods + protocolInfo.optionalMethods,
                classMethods: protocolInfo.classMethods + protocolInfo.optionalClassMethods,
                ivars: []
            )
        case .objc(.category(.class)):
            guard let categoryInfo = objcIndexer.categoryGroup(forName: name.name)?.info else { return [] }
            return Self.memberDeclarations(
                properties: categoryInfo.properties,
                classProperties: categoryInfo.classProperties,
                methods: categoryInfo.methods,
                classMethods: categoryInfo.classMethods,
                ivars: []
            )
        default:
            return []
        }
    }

    private static func memberDeclarations(
        properties: [ObjCPropertyInfo],
        classProperties: [ObjCPropertyInfo],
        methods: [ObjCMethodInfo],
        classMethods: [ObjCMethodInfo],
        ivars: [ObjCIvarInfo]
    ) -> [RuntimeMemberDeclaration] {
        var members: [RuntimeMemberDeclaration] = []
        for property in properties {
            members.append(RuntimeMemberDeclaration(name: property.name, kind: .objcProperty, isStatic: false, declarationText: property.name, lineNumber: nil))
        }
        for property in classProperties {
            members.append(RuntimeMemberDeclaration(name: property.name, kind: .objcProperty, isStatic: true, declarationText: property.name, lineNumber: nil))
        }
        for ivar in ivars {
            members.append(RuntimeMemberDeclaration(name: ivar.name, kind: .objcIvar, isStatic: false, declarationText: ivar.name, lineNumber: nil))
        }
        for method in classMethods {
            members.append(RuntimeMemberDeclaration(name: method.name, kind: .objcMethod, isStatic: true, declarationText: method.name, lineNumber: nil))
        }
        for method in methods {
            members.append(RuntimeMemberDeclaration(name: method.name, kind: .objcMethod, isStatic: false, declarationText: method.name, lineNumber: nil))
        }
        return members
    }
}
