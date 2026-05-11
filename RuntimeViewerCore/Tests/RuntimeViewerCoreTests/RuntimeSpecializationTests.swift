import Testing
import Foundation
@testable import RuntimeViewerCore

// MARK: - RuntimeSpecializationRequest.Candidate

@Suite("RuntimeSpecializationRequest.Candidate")
struct RuntimeSpecializationCandidateTests {
    @Test("init sets all properties")
    func initSetsAllProperties() {
        let candidate = RuntimeSpecializationRequest.Candidate(
            id: "$s4Test3IntV",
            displayName: "Int",
            imagePath: "/path/to/Test.framework/Test",
            isGeneric: false
        )
        #expect(candidate.id == "$s4Test3IntV")
        #expect(candidate.displayName == "Int")
        #expect(candidate.imagePath == "/path/to/Test.framework/Test")
        #expect(candidate.isGeneric == false)
    }

    @Test("encodes and decodes through Codable")
    func codableRoundTrip() throws {
        let original = RuntimeSpecializationRequest.Candidate(
            id: "$s4Test5ArrayVySiG",
            displayName: "Array<Int>",
            imagePath: "/usr/lib/libswiftCore.dylib",
            isGeneric: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSpecializationRequest.Candidate.self, from: data)

        #expect(decoded == original)
        #expect(decoded.id == original.id)
        #expect(decoded.displayName == original.displayName)
        #expect(decoded.imagePath == original.imagePath)
        #expect(decoded.isGeneric == original.isGeneric)
    }

    @Test("equal candidates have equal hashes")
    func hashConsistency() {
        let a = RuntimeSpecializationRequest.Candidate(id: "id-1", displayName: "Int", imagePath: "/a", isGeneric: false)
        let b = RuntimeSpecializationRequest.Candidate(id: "id-1", displayName: "Int", imagePath: "/a", isGeneric: false)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("differing id makes candidates unequal")
    func differingIDInequality() {
        let a = RuntimeSpecializationRequest.Candidate(id: "id-1", displayName: "Int", imagePath: "/a", isGeneric: false)
        let b = RuntimeSpecializationRequest.Candidate(id: "id-2", displayName: "Int", imagePath: "/a", isGeneric: false)
        #expect(a != b)
    }

    @Test("isGeneric flag is independent of equality")
    func differingIsGenericInequality() {
        let a = RuntimeSpecializationRequest.Candidate(id: "id-1", displayName: "Box", imagePath: "/a", isGeneric: false)
        let b = RuntimeSpecializationRequest.Candidate(id: "id-1", displayName: "Box", imagePath: "/a", isGeneric: true)
        #expect(a != b)
    }
}

// MARK: - RuntimeSpecializationRequest.Parameter

@Suite("RuntimeSpecializationRequest.Parameter")
struct RuntimeSpecializationParameterTests {
    private func makeCandidate(_ name: String) -> RuntimeSpecializationRequest.Candidate {
        RuntimeSpecializationRequest.Candidate(
            id: "$s4Test\(name.count)\(name)V",
            displayName: name,
            imagePath: "/path",
            isGeneric: false
        )
    }

    @Test("init carries name, displayDescription, and candidates")
    func initFields() {
        let parameter = RuntimeSpecializationRequest.Parameter(
            name: "A",
            displayDescription: "A : Hashable & Equatable",
            candidates: [makeCandidate("Int"), makeCandidate("String")]
        )
        #expect(parameter.name == "A")
        #expect(parameter.displayDescription == "A : Hashable & Equatable")
        #expect(parameter.candidates.count == 2)
        #expect(parameter.candidates[0].displayName == "Int")
        #expect(parameter.candidates[1].displayName == "String")
    }

    @Test("encodes and decodes through Codable")
    func codableRoundTrip() throws {
        let original = RuntimeSpecializationRequest.Parameter(
            name: "A",
            displayDescription: "A : AnyObject",
            candidates: [makeCandidate("NSObject"), makeCandidate("NSView")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSpecializationRequest.Parameter.self, from: data)

        #expect(decoded == original)
        #expect(decoded.candidates.count == 2)
        #expect(decoded.candidates[1].displayName == "NSView")
    }

    @Test("differing displayDescription makes parameters unequal")
    func differingDescriptionInequality() {
        let a = RuntimeSpecializationRequest.Parameter(
            name: "A",
            displayDescription: "A : Hashable",
            candidates: []
        )
        let b = RuntimeSpecializationRequest.Parameter(
            name: "A",
            displayDescription: "A",
            candidates: []
        )
        #expect(a != b)
    }
}

// MARK: - RuntimeSpecializationRequest

@Suite("RuntimeSpecializationRequest")
struct RuntimeSpecializationRequestTests {
    @Test("init with empty parameters list")
    func initEmpty() {
        let request = RuntimeSpecializationRequest(parameters: [])
        #expect(request.parameters.isEmpty)
    }

    @Test("init carries parameter list in order")
    func initWithParameters() {
        let parameterA = RuntimeSpecializationRequest.Parameter(name: "A", displayDescription: "A", candidates: [])
        let parameterB = RuntimeSpecializationRequest.Parameter(name: "B", displayDescription: "B", candidates: [])
        let request = RuntimeSpecializationRequest(parameters: [parameterA, parameterB])
        #expect(request.parameters.count == 2)
        #expect(request.parameters[0].name == "A")
        #expect(request.parameters[1].name == "B")
    }

    @Test("encodes and decodes through Codable")
    func codableRoundTrip() throws {
        let candidate = RuntimeSpecializationRequest.Candidate(
            id: "$s4Test3IntV",
            displayName: "Int",
            imagePath: "/test",
            isGeneric: false
        )
        let original = RuntimeSpecializationRequest(parameters: [
            RuntimeSpecializationRequest.Parameter(
                name: "A",
                displayDescription: "A : Hashable",
                candidates: [candidate]
            ),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSpecializationRequest.self, from: data)

        #expect(decoded == original)
        #expect(decoded.parameters[0].candidates[0] == candidate)
    }
}

// MARK: - RuntimeSpecializationSelection

@Suite("RuntimeSpecializationSelection")
struct RuntimeSpecializationSelectionTests {
    private func makeCandidate(_ name: String) -> RuntimeSpecializationRequest.Candidate {
        RuntimeSpecializationRequest.Candidate(
            id: "id-\(name)",
            displayName: name,
            imagePath: "/path",
            isGeneric: false
        )
    }

    @Test("default init produces empty selection")
    func defaultInit() {
        let selection = RuntimeSpecializationSelection()
        #expect(selection.arguments.isEmpty)
        #expect(selection.hasArgument(for: "A") == false)
        #expect(selection["A"] == nil)
    }

    @Test("custom init carries arguments")
    func customInit() {
        let intCandidate = makeCandidate("Int")
        let selection = RuntimeSpecializationSelection(arguments: ["A": .candidate(intCandidate)])
        #expect(selection.arguments.count == 1)
        #expect(selection.hasArgument(for: "A") == true)
        #expect(selection.hasArgument(for: "B") == false)
        #expect(selection["A"] == .candidate(intCandidate))
    }

    @Test("setArgument adds an argument")
    func setArgumentAdd() {
        var selection = RuntimeSpecializationSelection()
        let intCandidate = makeCandidate("Int")
        selection.setArgument(.candidate(intCandidate), for: "A")
        #expect(selection.hasArgument(for: "A"))
        #expect(selection["A"] == .candidate(intCandidate))
    }

    @Test("setArgument replaces an existing argument")
    func setArgumentReplace() {
        let intCandidate = makeCandidate("Int")
        let stringCandidate = makeCandidate("String")
        var selection = RuntimeSpecializationSelection(arguments: ["A": .candidate(intCandidate)])
        selection.setArgument(.candidate(stringCandidate), for: "A")
        #expect(selection["A"] == .candidate(stringCandidate))
        #expect(selection.arguments.count == 1)
    }

    @Test("subscript returns nil for unknown parameter")
    func subscriptNil() {
        let selection = RuntimeSpecializationSelection(arguments: ["A": .candidate(makeCandidate("Int"))])
        #expect(selection["B"] == nil)
    }

    @Test("encodes and decodes through Codable")
    func codableRoundTrip() throws {
        let original = RuntimeSpecializationSelection(arguments: [
            "A": .candidate(makeCandidate("Int")),
            "B": .candidate(makeCandidate("String")),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSpecializationSelection.self, from: data)

        #expect(decoded == original)
        #expect(decoded.arguments.count == 2)
        if case .candidate(let candidate) = decoded["A"] {
            #expect(candidate.displayName == "Int")
        } else {
            Issue.record("Expected `.candidate` argument for A")
        }
        if case .candidate(let candidate) = decoded["B"] {
            #expect(candidate.displayName == "String")
        } else {
            Issue.record("Expected `.candidate` argument for B")
        }
    }

    @Test("nested boundGeneric arguments round-trip through Codable")
    func nestedBoundGenericRoundTrip() throws {
        let innerCandidate = makeCandidate("Int")
        let outerCandidate = RuntimeSpecializationRequest.Candidate(
            id: "id-Array",
            displayName: "Array",
            imagePath: "/usr/lib/libswiftCore.dylib",
            isGeneric: true
        )
        let original = RuntimeSpecializationSelection(arguments: [
            "A": .boundGeneric(
                baseCandidate: outerCandidate,
                innerArguments: ["A": .candidate(innerCandidate)]
            ),
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSpecializationSelection.self, from: data)

        #expect(decoded == original)
        guard case .boundGeneric(let baseCandidate, let innerArguments) = decoded["A"] else {
            Issue.record("Expected `.boundGeneric` argument for A")
            return
        }
        #expect(baseCandidate == outerCandidate)
        #expect(innerArguments.count == 1)
        if case .candidate(let candidate) = innerArguments["A"] {
            #expect(candidate == innerCandidate)
        } else {
            Issue.record("Expected nested `.candidate` argument for A")
        }
    }

    @Test("equal selections have equal hashes")
    func hashConsistency() {
        let a = RuntimeSpecializationSelection(arguments: ["A": .candidate(makeCandidate("Int"))])
        let b = RuntimeSpecializationSelection(arguments: ["A": .candidate(makeCandidate("Int"))])
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}

// MARK: - RuntimeEngine.SpecializeRequest

@Suite("RuntimeEngine.SpecializeRequest")
struct RuntimeEngineSpecializeRequestTests {
    @Test("encodes and decodes through Codable")
    func codableRoundTrip() throws {
        let object = RuntimeObject(
            name: "$s4Test3BoxV",
            displayName: "Box",
            kind: .swift(.type(.struct)),
            secondaryKind: nil,
            imagePath: "/test",
            children: []
        )
        let candidate = RuntimeSpecializationRequest.Candidate(
            id: "$s4Test3IntV",
            displayName: "Int",
            imagePath: "/test",
            isGeneric: false
        )
        let selection = RuntimeSpecializationSelection(arguments: ["A": .candidate(candidate)])
        let original = RuntimeEngine.SpecializeRequest(object: object, selection: selection)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeEngine.SpecializeRequest.self, from: data)

        #expect(decoded.object == original.object)
        #expect(decoded.selection == original.selection)
        #expect(decoded.selection["A"] == .candidate(candidate))
    }
}

// MARK: - RuntimeEngine.SpecializationRequestForCandidateRequest

@Suite("RuntimeEngine.SpecializationRequestForCandidateRequest")
struct RuntimeEngineSpecializationRequestForCandidateRequestTests {
    @Test("encodes and decodes through Codable")
    func codableRoundTrip() throws {
        let original = RuntimeEngine.SpecializationRequestForCandidateRequest(
            candidateID: "$s4Test5ArrayV",
            imagePath: "/usr/lib/libswiftCore.dylib"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeEngine.SpecializationRequestForCandidateRequest.self, from: data)
        #expect(decoded.candidateID == original.candidateID)
        #expect(decoded.imagePath == original.imagePath)
    }
}

// MARK: - RuntimeEngine.EngineError

@Suite("RuntimeEngine.EngineError")
struct RuntimeEngineEngineErrorTests {
    @Test("imageNotIndexed errorDescription includes path")
    func imageNotIndexed() {
        let error = RuntimeEngine.EngineError.imageNotIndexed(imagePath: "/path/to/lib")
        #expect(error.errorDescription?.contains("/path/to/lib") == true)
    }

    @Test("typeNotGeneric has a stable description")
    func typeNotGeneric() {
        let error = RuntimeEngine.EngineError.typeNotGeneric
        #expect(error.errorDescription == "This type is not generic.")
    }

    @Test("unsupportedGenericParameter forwards the description")
    func unsupportedGenericParameter() {
        let error = RuntimeEngine.EngineError.unsupportedGenericParameter(description: "TypePack not supported")
        #expect(error.errorDescription == "TypePack not supported")
    }

    @Test("specializationParameterNotFound includes parameter name")
    func specializationParameterNotFound() {
        let error = RuntimeEngine.EngineError.specializationParameterNotFound(name: "A")
        #expect(error.errorDescription?.contains("A") == true)
    }

    @Test("specializationCandidateNotFound includes parameter and candidate names")
    func specializationCandidateNotFound() {
        let error = RuntimeEngine.EngineError.specializationCandidateNotFound(
            parameterName: "A",
            candidateDisplayName: "Int"
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("A"))
        #expect(description.contains("Int"))
    }

    @Test("boundGenericInnerFailed includes outer parameter name and underlying message")
    func boundGenericInnerFailed() {
        let error = RuntimeEngine.EngineError.boundGenericInnerFailed(
            parameterName: "A",
            underlying: "missing metadata"
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("A"))
        #expect(description.contains("missing metadata"))
    }

    @Test("unindexedCandidate includes display name and image path")
    func unindexedCandidate() {
        let error = RuntimeEngine.EngineError.unindexedCandidate(
            displayName: "Array",
            imagePath: "/usr/lib/libswiftCore.dylib"
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("Array"))
        #expect(description.contains("/usr/lib/libswiftCore.dylib"))
    }
}
