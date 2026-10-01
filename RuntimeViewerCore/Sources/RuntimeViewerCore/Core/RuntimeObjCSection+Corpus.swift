import Foundation
import ObjCDump
import Semantic

extension RuntimeObjCSection {
    /// The object's corpus print: its interface marked for every combination
    /// of the Generation Options (`markedInterface(for:transformer:)`) with the
    /// user's transformer, separated into the text and its visibility regions,
    /// plus its members from the parsed metadata. An Objective-C interface
    /// nests nothing, so no part of it belongs to another entry.
    ///
    /// The Objective-C side keeps no interface cache, so there is nothing to
    /// bypass here: the builder is created per call and prints straight from
    /// the indexer. `nonisolated` because everything it reads is a `let` the
    /// section never changes, so a corpus build never holds the section while
    /// the content pane asks it for an interface, and prints of one image can
    /// overlap.
    nonisolated func corpusPrint(for object: RuntimeObject, transformer: Transformer.Configuration) async throws -> RuntimeInterfaceCorpusPrint? {
        guard let markedInterface = markedInterface(for: object, transformer: transformer.objc) else {
            throw Error.invalidRuntimeObject
        }
        let separated = markedInterface.frozen().separatingVisibilityRegions()
        return RuntimeInterfaceCorpusPrint(
            object: object,
            interface: separated.text,
            visibilityRegions: separated.regions,
            members: memberDeclarations(for: object),
            nestedDefinitionRanges: []
        )
    }

    /// The object's members as `ObjCClassInfo` / `ObjCProtocolInfo` /
    /// `ObjCCategoryInfo` list them, not yet located in any text. C structs
    /// and unions have no members in this sense.
    nonisolated func memberDeclarations(for object: RuntimeObject) -> [RuntimeMemberDeclaration] {
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
