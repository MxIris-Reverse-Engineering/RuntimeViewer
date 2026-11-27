import Foundation
import Testing
import RuntimeViewerCore

@Suite("C++ object kinds")
struct CPlusPlusObjectKindTests {
    @Test("C++ kinds sort after the C kinds and before the Objective-C ones, classes before namespaces")
    func cPlusPlusKindsSortBetweenCAndObjectiveCKinds() throws {
        let cKinds = RuntimeObjectKind.C.allCases.map(RuntimeObjectKind.c)
        let objectiveCKinds = RuntimeObjectKind.ObjectiveC.allCases.map(RuntimeObjectKind.objc)
        let lastCKind = try #require(cKinds.max())
        let firstObjectiveCKind = try #require(objectiveCKinds.min())
        #expect(lastCKind < .cPlusPlus(.class))
        #expect(RuntimeObjectKind.cPlusPlus(.namespace) < firstObjectiveCKind)
        #expect(RuntimeObjectKind.cPlusPlus(.class) < .cPlusPlus(.namespace))
        #expect(Array(RuntimeObjectKind.allCases[cKinds.count ..< cKinds.count + 3]) == [.cPlusPlus(.class), .cPlusPlus(.classTemplate), .cPlusPlus(.namespace)])
    }

    @Test("a class template node sorts after the classes and before the namespaces")
    func cPlusPlusClassTemplateSortsBetweenClassesAndNamespaces() {
        #expect(RuntimeObjectKind.cPlusPlus(.class) < .cPlusPlus(.classTemplate))
        #expect(RuntimeObjectKind.cPlusPlus(.classTemplate) < .cPlusPlus(.namespace))
        let imagePath = "/usr/lib/libc++.1.dylib"
        let namespace = RuntimeObject(name: "std::__1::__fs", displayName: "__fs", kind: .cPlusPlus(.namespace), imagePath: imagePath, children: [])
        let template = RuntimeObject(name: "std::__1::basic_string", displayName: "basic_string", kind: .cPlusPlus(.classTemplate), imagePath: imagePath, children: [])
        let lastClass = RuntimeObject(name: "std::__1::system_error", displayName: "system_error", kind: .cPlusPlus(.class), imagePath: imagePath, children: [])
        #expect([namespace, template, lastClass].sorted().map(\.displayName) == ["system_error", "basic_string", "__fs"])
    }

    @Test("a C++ kind, the class template node's included, comes back from JSON as itself")
    func cPlusPlusKindRoundTripsThroughJSON() throws {
        #expect(RuntimeObjectKind.CPlusPlus.allCases == [.class, .classTemplate, .namespace])
        for kind in RuntimeObjectKind.CPlusPlus.allCases.map(RuntimeObjectKind.cPlusPlus) {
            let data = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(RuntimeObjectKind.self, from: data) == kind)
        }
    }

    @Test("the descriptions name the language")
    func cPlusPlusKindDescriptionsNameTheLanguage() {
        #expect(RuntimeObjectKind.cPlusPlus(.class).description == "C++ Class")
        #expect(RuntimeObjectKind.cPlusPlus(.namespace).description == "C++ Namespace")
        #expect(RuntimeObjectKind.cPlusPlus(.classTemplate).description == "C++ Class Template")
        #expect(RuntimeObjectKind.cPlusPlus(.classTemplate).isCPlusPlus)
        #expect(RuntimeObjectKind.cPlusPlus(.class).isCPlusPlus)
        #expect(!RuntimeObjectKind.cPlusPlus(.class).isSwift)
        #expect(!RuntimeObjectKind.c(.struct).isCPlusPlus)
    }

    @Test("C++ interfaces are written in cpp")
    func cPlusPlusInterfaceLanguageIsCpp() {
        #expect(RuntimeInterfaceLanguage.cPlusPlus.rawValue == "cpp")
    }
}
