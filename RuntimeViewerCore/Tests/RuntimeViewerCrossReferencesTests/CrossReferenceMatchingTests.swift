import Testing
import Foundation
import RuntimeViewerCore
import CrossReferenceAnalysis
@testable import RuntimeViewerCrossReferences

/// The rules that decide which sends reach a method, which rows of the member
/// list belong to a member, and how a function is named — pure functions, so
/// every case is spelled out here rather than hoped for in a real image.
@Suite("Cross-reference matching rules")
struct CrossReferenceMatchingTests {
    private let instanceMethod = ObjectiveCMethodName(className: "NSWindow", selector: "makeKeyAndOrderFront:", isClassMethod: false)
    private let classMethod = ObjectiveCMethodName(className: "NSWindow", selector: "windowNumbersWithOptions:", isClassMethod: true)
    private let rootInstanceMethod = ObjectiveCMethodName(className: "NSObject", selector: "description", isClassMethod: false)

    private func sender(_ symbol: String) -> [ObjectiveCMethodName] {
        [ObjectiveCMethodName(symbol: symbol)].compactMap { $0 }
    }

    // MARK: - Method names

    @Test("Method names split into class, selector and kind")
    func methodNamesSplit() throws {
        let instance = try #require(ObjectiveCMethodName(symbol: "-[NSWindow makeKeyAndOrderFront:]"))
        #expect(instance == instanceMethod)
        let categoryMethod = try #require(ObjectiveCMethodName(symbol: "+[NSWindow(NSWindowTabbing) allowsAutomaticWindowTabbing]"))
        #expect(categoryMethod.className == "NSWindow")
        #expect(categoryMethod.selector == "allowsAutomaticWindowTabbing")
        #expect(categoryMethod.isClassMethod)
        #expect(ObjectiveCMethodName(symbol: "_CFRelease") == nil)
        #expect(ObjectiveCMethodName(symbol: "-[NSWindow]") == nil)
    }

    // MARK: - Sends

    @Test("A send from the class's own instance method to self is exact")
    func sendToSelfFromTheSameClass() {
        let precision = ObjectiveCSendMatching.precision(ofSendWith: .methodReceiver, isSuperSend: false, from: sender("-[NSWindow orderFront:]"), to: instanceMethod)
        #expect(precision == .exact)
    }

    @Test("A send to self from another class matches by selector — it may be a subclass")
    func sendToSelfFromAnotherClass() {
        let precision = ObjectiveCSendMatching.precision(ofSendWith: .methodReceiver, isSuperSend: false, from: sender("-[NSPanel becomeKeyWindow]"), to: instanceMethod)
        #expect(precision == .matchedBySelector)
    }

    @Test("A class method's self is a class object and cannot reach an instance method")
    func classObjectCannotReachInstanceMethod() {
        let precision = ObjectiveCSendMatching.precision(ofSendWith: .methodReceiver, isSuperSend: false, from: sender("+[NSWindow load]"), to: instanceMethod)
        #expect(precision == nil)
    }

    @Test("A class object still reaches its root class's instance methods")
    func classObjectReachesRootInstanceMethods() {
        let precision = ObjectiveCSendMatching.precision(ofSendWith: .methodReceiver, isSuperSend: false, from: sender("+[NSObject debugDescription]"), to: rootInstanceMethod)
        #expect(precision == .matchedBySelector)
    }

    @Test("An instance never reaches a class method")
    func instanceCannotReachClassMethod() {
        let precision = ObjectiveCSendMatching.precision(ofSendWith: .methodReceiver, isSuperSend: false, from: sender("-[NSWindow orderFront:]"), to: classMethod)
        #expect(precision == nil)
    }

    @Test("Folded methods match as any of them")
    func foldedMethodsMatchAsAnyOfThem() {
        // Identical code folding gave one body to a class method and an
        // instance method: the instance one can reach the instance method.
        let folded = sender("+[NSWindow load]") + sender("-[NSWindow orderFront:]")
        let precision = ObjectiveCSendMatching.precision(ofSendWith: .methodReceiver, isSuperSend: false, from: folded, to: instanceMethod)
        #expect(precision == .exact)
    }

    @Test("A class literal names the class object")
    func classLiteralReceivers() {
        #expect(ObjectiveCSendMatching.precision(ofSendWith: .classLiteral("NSWindow"), isSuperSend: false, from: [], to: classMethod) == .exact)
        #expect(ObjectiveCSendMatching.precision(ofSendWith: .classLiteral("NSPanel"), isSuperSend: false, from: [], to: classMethod) == .matchedBySelector)
        #expect(ObjectiveCSendMatching.precision(ofSendWith: .classLiteral("NSWindow"), isSuperSend: false, from: [], to: instanceMethod) == nil)
    }

    @Test("An unknown receiver matches by selector")
    func unknownReceiver() {
        #expect(ObjectiveCSendMatching.precision(ofSendWith: .unknown, isSuperSend: false, from: [], to: instanceMethod) == .matchedBySelector)
        #expect(ObjectiveCSendMatching.receiverClassName(of: .unknown, isSuperSend: false, from: sender("-[NSWindow orderFront:]")) == nil)
    }

    @Test("A super send keeps the receiver's kind but not its class")
    func superSends() {
        #expect(ObjectiveCSendMatching.precision(ofSendWith: .unknown, isSuperSend: true, from: sender("-[NSPanel makeKeyAndOrderFront:]"), to: instanceMethod) == .matchedBySelector)
        #expect(ObjectiveCSendMatching.precision(ofSendWith: .unknown, isSuperSend: true, from: sender("+[NSPanel initialize]"), to: instanceMethod) == nil)
    }

    @Test("The receiver's class is the literal's, or the sending method's for self")
    func receiverClassNames() {
        #expect(ObjectiveCSendMatching.receiverClassName(of: .classLiteral("NSWindow"), isSuperSend: false, from: []) == "NSWindow")
        #expect(ObjectiveCSendMatching.receiverClassName(of: .methodReceiver, isSuperSend: false, from: sender("-[NSPanel becomeKeyWindow]")) == "NSPanel")
        #expect(ObjectiveCSendMatching.receiverClassName(of: .methodReceiver, isSuperSend: true, from: sender("-[NSPanel becomeKeyWindow]")) == nil)
    }

    // MARK: - Member rows

    private func row(_ name: String, _ kind: String) -> RuntimeMemberAddress {
        RuntimeMemberAddress(name: name, kind: kind, symbolName: "", address: "0x1000")
    }

    private func member(_ name: String, _ kind: RuntimeMemberKind, isStatic: Bool) -> RuntimeMemberReference {
        let object = RuntimeObject(name: "NSWindow", displayName: "NSWindow", kind: .objc(.type(.class)), imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", children: [])
        return RuntimeMemberReference(object: object, name: name, kind: kind, isStatic: isStatic)
    }

    @Test("Member rows match by name, kind and staticness — not the way the search box does")
    func memberRows() {
        let method = member("title", .objcMethod, isStatic: false)
        #expect(MemberAddressMatching.matches(row("title", "method"), method))
        #expect(!MemberAddressMatching.matches(row("title", "class method"), method))
        #expect(!MemberAddressMatching.matches(row("setTitle:", "method"), method))

        let property = member("title", .objcProperty, isStatic: false)
        #expect(MemberAddressMatching.matches(row("title", "property getter"), property))
        #expect(MemberAddressMatching.matches(row("title", "property setter"), property))
        #expect(!MemberAddressMatching.matches(row("title", "class property getter"), property))

        let function = member("updateOutputs", .swiftFunction, isStatic: false)
        #expect(MemberAddressMatching.matches(row("updateOutputs", "func"), function))
        #expect(!MemberAddressMatching.matches(row("updateOutputs", "static func"), function))

        let variable = member("body", .swiftVariable, isStatic: false)
        #expect(MemberAddressMatching.matches(row("body", "getter"), variable))
        #expect(!MemberAddressMatching.matches(row("body", "static getter"), variable))
        #expect(!MemberAddressMatching.matches(row("body", "func"), variable))

        let staticSubscript = member("subscript", .swiftSubscript, isStatic: true)
        #expect(MemberAddressMatching.matches(row("subscript", "static subscript.getter"), staticSubscript))
        #expect(!MemberAddressMatching.matches(row("subscript", "subscript.getter"), staticSubscript))

        let initializer = member("init", .swiftInitializer, isStatic: true)
        #expect(MemberAddressMatching.matches(row("init(frame:)", "allocator"), initializer))
        #expect(MemberAddressMatching.matches(row("init(frame:)", "init"), initializer))

        #expect(!MemberAddressMatching.matches(row("_title", "ivar"), member("_title", .objcIvar, isStatic: false)))
    }

    @Test("Member rows print unslid hexadecimal addresses")
    func memberRowAddresses() {
        #expect(MemberAddressMatching.address(of: RuntimeMemberAddress(name: "", kind: "", symbolName: "", address: "0x18AE335C0")) == 0x1_8AE3_35C0)
        #expect(MemberAddressMatching.address(of: RuntimeMemberAddress(name: "", kind: "", symbolName: "", address: "<invalid 0x0>")) == nil)
    }

    // MARK: - Names

    @Test("Display names: Objective-C as it is, Swift demangled, C without its underscore")
    func displayNames() {
        #expect(CrossReferenceNaming.displayName(forSymbol: "-[NSWindow makeKeyAndOrderFront:]") == "-[NSWindow makeKeyAndOrderFront:]")
        #expect(CrossReferenceNaming.displayName(forSymbol: "_CFRelease") == "CFRelease")
        #expect(CrossReferenceNaming.displayName(forSymbol: "_$s7SwiftUI9ViewGraphC13updateOutputs2atyAA4TimeV_tF") == "SwiftUI.ViewGraph.updateOutputs(at:)")
        #expect(CrossReferenceNaming.displayName(forSymbol: "_$sNotAMangledName") == "$sNotAMangledName")
    }
}
