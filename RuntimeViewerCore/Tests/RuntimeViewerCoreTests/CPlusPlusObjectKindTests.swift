import Foundation
import Testing
import RuntimeViewerCore

@Suite("C++ object kinds")
struct CPlusPlusObjectKindTests {
    @Test("C++ kinds sort after every Swift kind, classes before namespaces")
    func cPlusPlusKindsSortAfterSwiftKinds() {
        let lastSwiftKind = RuntimeObjectKind.allCases.filter(\.isSwift).max()
        #expect(lastSwiftKind.map { $0 < .cPlusPlus(.class) } == true)
        #expect(RuntimeObjectKind.cPlusPlus(.class) < .cPlusPlus(.namespace))
        #expect(RuntimeObjectKind.allCases.suffix(2) == [.cPlusPlus(.class), .cPlusPlus(.namespace)])
    }

    @Test("a C++ kind comes back from JSON as itself")
    func cPlusPlusKindRoundTripsThroughJSON() throws {
        for kind in RuntimeObjectKind.CPlusPlus.allCases.map(RuntimeObjectKind.cPlusPlus) {
            let data = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(RuntimeObjectKind.self, from: data) == kind)
        }
    }

    @Test("the descriptions name the language")
    func cPlusPlusKindDescriptionsNameTheLanguage() {
        #expect(RuntimeObjectKind.cPlusPlus(.class).description == "C++ Class")
        #expect(RuntimeObjectKind.cPlusPlus(.namespace).description == "C++ Namespace")
        #expect(RuntimeObjectKind.cPlusPlus(.class).isCPlusPlus)
        #expect(!RuntimeObjectKind.cPlusPlus(.class).isSwift)
        #expect(!RuntimeObjectKind.c(.struct).isCPlusPlus)
    }

    @Test("C++ interfaces are written in cpp")
    func cPlusPlusInterfaceLanguageIsCpp() {
        #expect(RuntimeInterfaceLanguage.cPlusPlus.rawValue == "cpp")
    }
}
