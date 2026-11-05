import CrossReferenceAnalysis
import Demangling
import ObjectiveC
import RuntimeViewerCore

/// Turns the analysis's functions into the wire's, demangling each name once
/// per query.
struct FunctionReferenceBuilder {
    let imagePaths: [String]
    private let analyzer: CrossReferenceAnalyzer
    private var displayNamesBySymbol: [String: String] = [:]
    /// Where each class an Objective-C method named was found defined, by the
    /// image the method is in and the class's name.
    private var classImagePaths: [ClassInImage: String] = [:]

    private struct ClassInImage: Hashable {
        let className: String
        let imageIndex: Int
    }

    init(analyzer: CrossReferenceAnalyzer) {
        self.imagePaths = analyzer.imagePaths
        self.analyzer = analyzer
    }

    /// `member` is the subject's own, when the function is one of the
    /// subject's; any other Objective-C method gets the member its name says
    /// it implements.
    mutating func reference(for function: CodeFunction, member: RuntimeMemberReference? = nil) -> RuntimeFunctionReference {
        let symbolName: String?
        let displayName: String?
        var methodName: ObjectiveCMethodName?
        switch function.name {
        case .symbol(let symbol)?:
            symbolName = symbol
            displayName = cachedDisplayName(forSymbol: symbol)
            methodName = ObjectiveCMethodName(symbol: symbol)
        case .objectiveCMethod(let className, let selector, let isClassMethod)?:
            symbolName = nil
            displayName = "\(isClassMethod ? "+" : "-")[\(className) \(selector)]"
            methodName = ObjectiveCMethodName(className: className, selector: selector, isClassMethod: isClassMethod)
        case .swiftMetadata(let mangledName)?:
            // Rebuilt from the metadata, not read from the symbol table: a
            // complete mangled name that demangles like a symbol.
            symbolName = nil
            displayName = cachedDisplayName(forSymbol: mangledName)
        case nil:
            symbolName = nil
            displayName = nil
        }
        return RuntimeFunctionReference(
            imagePath: imagePaths[function.location.imageIndex],
            address: function.location.address,
            displayName: displayName,
            symbolName: symbolName,
            member: member ?? methodName.map { objectiveCMember(named: $0, implementedInImageAt: function.location.imageIndex) },
            foldedSymbolCount: function.foldedSymbolNames.count
        )
    }

    /// The member an Objective-C method implements: the selector of its class,
    /// as the class's own page lists it. A method of a category on a class
    /// from another image belongs to that image's class.
    private mutating func objectiveCMember(named methodName: ObjectiveCMethodName, implementedInImageAt imageIndex: Int) -> RuntimeMemberReference {
        let classObject = RuntimeObject(
            name: methodName.className,
            displayName: CrossReferenceNaming.displayName(forClassName: methodName.className),
            kind: .objc(.type(.class)),
            imagePath: classImagePath(ofClassNamed: methodName.className, methodImageIndex: imageIndex),
            children: []
        )
        return RuntimeMemberReference(object: classObject, name: methodName.selector, kind: .objcMethod, isStatic: methodName.isClassMethod)
    }

    /// The image defining the class: the method's own when it defines the
    /// class; otherwise the one the Objective-C runtime loaded the class from;
    /// otherwise — the class's image not loaded — the method's again.
    private mutating func classImagePath(ofClassNamed className: String, methodImageIndex imageIndex: Int) -> String {
        let key = ClassInImage(className: className, imageIndex: imageIndex)
        if let known = classImagePaths[key] { return known }
        var imagePath = imagePaths[imageIndex]
        if analyzer.objectiveCClassLocations(named: className, inImageAt: imageIndex).isEmpty,
           let classObject = objc_lookUpClass(className),
           let classImageName = class_getImageName(classObject) {
            imagePath = String(cString: classImageName)
        }
        classImagePaths[key] = imagePath
        return imagePath
    }

    /// Code at `location` that starts no function the analysis knows.
    func unnamedReference(at location: CodeLocation) -> RuntimeFunctionReference {
        RuntimeFunctionReference(
            imagePath: imagePaths[location.imageIndex],
            address: location.address,
            displayName: nil,
            symbolName: nil,
            member: nil,
            foldedSymbolCount: 0
        )
    }

    private mutating func cachedDisplayName(forSymbol symbol: String) -> String {
        if let known = displayNamesBySymbol[symbol] { return known }
        let displayName = CrossReferenceNaming.displayName(forSymbol: symbol)
        displayNamesBySymbol[symbol] = displayName
        return displayName
    }
}
