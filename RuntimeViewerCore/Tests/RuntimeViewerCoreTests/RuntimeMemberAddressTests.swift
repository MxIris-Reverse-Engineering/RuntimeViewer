import Testing
import Foundation
import RuntimeViewerCore

@Suite("RuntimeMemberAddress")
struct RuntimeMemberAddressTests {
    @Test("init sets all properties")
    func initSetsAllProperties() {
        let member = RuntimeMemberAddress(
            name: "viewDidLoad()",
            kind: "func",
            symbolName: "$s6UIKit14UIViewControllerC11viewDidLoadyyF",
            address: "0x100123ABC"
        )
        #expect(member.name == "viewDidLoad()")
        #expect(member.kind == "func")
        #expect(member.symbolName == "$s6UIKit14UIViewControllerC11viewDidLoadyyF")
        #expect(member.address == "0x100123ABC")
    }

    @Test("encodes and decodes correctly")
    func codable() throws {
        let original = RuntimeMemberAddress(
            name: "init(frame:)",
            kind: "init",
            symbolName: "$s4Main6MyViewC5frameACSo6CGRectV_tcfc",
            address: "0x00007FF8123ABC"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeMemberAddress.self, from: data)

        #expect(decoded.name == original.name)
        #expect(decoded.kind == original.kind)
        #expect(decoded.symbolName == original.symbolName)
        #expect(decoded.address == original.address)
    }

    @Test("various member kinds")
    func variousKinds() {
        let testCases: [(String, String)] = [
            ("func", "myMethod()"),
            ("static func", "classMethod()"),
            ("init", "init(coder:)"),
            ("getter", "myProperty"),
            ("setter", "myProperty"),
            ("subscript.getter", "subscript(_:)"),
        ]

        for (kind, name) in testCases {
            let member = RuntimeMemberAddress(name: name, kind: kind, symbolName: "_sym", address: "0x0")
            #expect(member.kind == kind)
            #expect(member.name == name)
        }
    }
}

@Suite("RuntimeImageLoadState")
struct RuntimeImageLoadStateTests {
    @Test("all cases can be created")
    func allCases() {
        let states: [RuntimeImageLoadState] = [
            .notLoaded,
            .loading,
            .loaded,
            .loadError(NSError(domain: "test", code: 1)),
            .unknown,
        ]
        #expect(states.count == 5)
    }
}
