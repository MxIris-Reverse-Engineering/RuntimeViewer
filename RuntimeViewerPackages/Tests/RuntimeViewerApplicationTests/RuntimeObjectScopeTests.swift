import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("RuntimeObjectScope")
struct RuntimeObjectScopeTests {
    // MARK: - Defaults

    @Test("default scope is inactive and admits every object")
    func defaultScopeAdmitsEverything() {
        let scope = RuntimeObjectScope()
        #expect(scope.isActive == false)

        let plainClass = object(kind: .swift(.type(.class)))
        let genericClass = object(kind: .swift(.type(.class)), properties: [.isGeneric])
        let specialized = object(kind: .swift(.type(.class)), properties: [.isSpecialized])
        let objcCategory = object(kind: .objc(.category(.class)))

        for candidate in [plainClass, genericClass, specialized, objcCategory] {
            #expect(scope.passes(candidate))
            #expect(scope.matchesRecursively(candidate))
        }
    }

    // MARK: - Kind constraints

    @Test("non-empty includedKinds rejects everything outside the whitelist")
    func includedKindsWhitelistsStrictly() {
        var scope = RuntimeObjectScope()
        scope.includedKinds = [.swift(.type(.class))]
        #expect(scope.isActive)

        #expect(scope.passes(object(kind: .swift(.type(.class)))))
        #expect(!scope.passes(object(kind: .swift(.type(.struct)))))
        #expect(!scope.passes(object(kind: .objc(.type(.class)))))
    }

    @Test("multiple included kinds form a union")
    func multipleIncludedKindsUnion() {
        var scope = RuntimeObjectScope()
        scope.includedKinds = [.swift(.type(.class)), .objc(.type(.protocol))]

        #expect(scope.passes(object(kind: .swift(.type(.class)))))
        #expect(scope.passes(object(kind: .objc(.type(.protocol)))))
        #expect(!scope.passes(object(kind: .swift(.type(.protocol)))))
    }

    // MARK: - Property tristate

    @Test("PropertyState.only requires the bit set")
    func propertyOnlyRequiresBit() {
        var scope = RuntimeObjectScope()
        scope[.generic] = .only

        #expect(scope.passes(object(properties: [.isGeneric])))
        #expect(!scope.passes(object(properties: [])))
        #expect(!scope.passes(object(properties: [.isSpecialized])))
    }

    @Test("PropertyState.exclude rejects objects carrying the bit")
    func propertyExcludeRejectsBit() {
        var scope = RuntimeObjectScope()
        scope[.specialized] = .exclude

        #expect(scope.passes(object(properties: [])))
        #expect(scope.passes(object(properties: [.isGeneric])))
        #expect(!scope.passes(object(properties: [.isSpecialized])))
        #expect(!scope.passes(object(properties: [.isGeneric, .isSpecialized])))
    }

    @Test("generic and specialized tristates compose independently")
    func tristatesComposeIndependently() {
        var scope = RuntimeObjectScope()
        scope[.generic] = .exclude
        scope[.specialized] = .only

        // Generic-only: rejected (generic excluded, no specialized bit).
        #expect(!scope.passes(object(properties: [.isGeneric])))
        // Specialized-only: passes.
        #expect(scope.passes(object(properties: [.isSpecialized])))
        // Plain: rejected (no specialized bit).
        #expect(!scope.passes(object(properties: [])))
    }

    // MARK: - Property rows

    @Test("each row filters by the flags it is named after", arguments: [
        (RuntimeObjectScope.Property.generic, RuntimeObject.Properties.isGeneric),
        (.specialized, .isSpecialized),
        (.objcImplementation, .isObjCImplementation),
        (.bridgedSwiftClass, [.isSwiftClass, .isObjCClass]),
        (.localType, .isLocalType),
        (.positionNamedLocalType, .isPositionNamedLocalType),
    ] as [(RuntimeObjectScope.Property, RuntimeObject.Properties)])
    func rowFiltersByItsFlags(property: RuntimeObjectScope.Property, expectedFlags: RuntimeObject.Properties) {
        #expect(property.flags == expectedFlags)
    }

    @Test("every row filters by at least one flag", arguments: RuntimeObjectScope.Property.allCases)
    func everyRowFiltersBySomeFlag(property: RuntimeObjectScope.Property) {
        #expect(!property.flags.isEmpty)
    }

    @Test("every flag belongs to at least one row", arguments: RuntimeObject.Properties.Flag.allCases)
    func everyFlagBelongsToSomeRow(flag: RuntimeObject.Properties.Flag) {
        #expect(!RuntimeObjectScope.Property.rows(filtering: flag).isEmpty)
    }

    /// Every row of every flag, one case each.
    private static let rowsOfEveryFlag: [(RuntimeObject.Properties.Flag, RuntimeObjectScope.Property)] =
        RuntimeObject.Properties.Flag.allCases.flatMap { flag in
            RuntimeObjectScope.Property.rows(filtering: flag).map { (flag, $0) }
        }

    @Test("Only on a row of a flag admits objects carrying the flag and nothing else", arguments: RuntimeObjectScopeTests.rowsOfEveryFlag)
    func onlyAdmitsObjectsCarryingTheFlag(flag: RuntimeObject.Properties.Flag, property: RuntimeObjectScope.Property) {
        var scope = RuntimeObjectScope()
        scope[property] = .only

        #expect(scope.isActive)
        #expect(scope.passes(object(properties: RuntimeObject.Properties(flag))))
        #expect(!scope.passes(object(properties: [])))
    }

    @Test("Exclude on a row of a flag rejects objects carrying the flag", arguments: RuntimeObjectScopeTests.rowsOfEveryFlag)
    func excludeRejectsObjectsCarryingTheFlag(flag: RuntimeObject.Properties.Flag, property: RuntimeObjectScope.Property) {
        var scope = RuntimeObjectScope()
        scope[property] = .exclude

        #expect(scope.isActive)
        #expect(!scope.passes(object(properties: RuntimeObject.Properties(flag))))
        #expect(scope.passes(object(properties: [])))
    }

    @Test("setting a row back to Any leaves the default scope", arguments: RuntimeObjectScope.Property.allCases)
    func anyRestoresTheDefaultScope(property: RuntimeObjectScope.Property) {
        var scope = RuntimeObjectScope()
        scope[property] = .only
        scope[property] = .any

        #expect(scope == RuntimeObjectScope())
        #expect(!scope.isActive)
    }

    @Test("Any passed to the initializer constrains nothing")
    func initializerIgnoresAny() {
        let scope = RuntimeObjectScope(propertyStates: [.generic: .any, .localType: .any])

        #expect(scope == RuntimeObjectScope())
        #expect(!scope.isActive)
    }

    @Test("the bridged row selects both entries of a bridged class, and no @objc @implementation class")
    func bridgedRowSelectsBothEntries() {
        var scope = RuntimeObjectScope()
        scope[.bridgedSwiftClass] = .only

        #expect(scope.passes(object(kind: .objc(.type(.class)), properties: [.isSwiftClass])))
        #expect(scope.passes(object(kind: .swift(.type(.class)), properties: [.isObjCClass])))
        #expect(!scope.passes(object(kind: .objc(.type(.class)), properties: [.isObjCImplementation])))
        #expect(!scope.passes(object(kind: .objc(.type(.class)))))
    }

    @Test("Local Only with Position-Named Exclude keeps the local types whose function is named")
    func localTypesWhoseFunctionIsNamed() {
        var scope = RuntimeObjectScope()
        scope[.localType] = .only
        scope[.positionNamedLocalType] = .exclude

        #expect(scope.passes(object(properties: [.isLocalType])))
        #expect(!scope.passes(object(properties: [.isLocalType, .isPositionNamedLocalType])))
        #expect(!scope.passes(object(properties: [])))
    }

    // MARK: - Recursive matching

    @Test("recursive matching pulls in a generic parent when a specialized child matches")
    func recursivePullsInGenericParentForSpecializedScope() {
        var scope = RuntimeObjectScope()
        scope[.specialized] = .only

        let specializedChild = object(
            kind: .swift(.type(.class)),
            properties: [.isSpecialized]
        )
        let genericParent = object(
            kind: .swift(.type(.class)),
            children: [specializedChild],
            properties: [.isGeneric]
        )

        // Parent fails the direct check (no specialized bit).
        #expect(!scope.passes(genericParent))
        // But recursive check accepts it because the child matches.
        #expect(scope.matchesRecursively(genericParent))
    }

    @Test("recursive matching keeps the type a local type is declared in")
    func recursiveKeepsTheTypeEnclosingALocalType() {
        var scope = RuntimeObjectScope()
        scope[.localType] = .only

        // The sidebar lists a local type under the type whose function
        // declares it.
        let localType = object(kind: .swift(.type(.struct)), properties: [.isLocalType])
        let enclosingType = object(kind: .swift(.type(.class)), children: [localType])

        #expect(!scope.passes(enclosingType))
        #expect(scope.matchesRecursively(enclosingType))
    }

    @Test("recursive matching rejects when no descendant matches")
    func recursiveRejectsWhenNoDescendantMatches() {
        var scope = RuntimeObjectScope()
        scope.includedKinds = [.swift(.type(.protocol))]

        let leaf = object(kind: .swift(.type(.class)))
        let inner = object(kind: .swift(.type(.struct)), children: [leaf])
        let outer = object(kind: .swift(.type(.class)), children: [inner])

        #expect(!scope.matchesRecursively(outer))
    }

    // MARK: - KindGroup

    @Test("KindGroup.of dispatches each kind into the right bucket")
    func kindGroupBuckets() {
        #expect(RuntimeObjectScope.KindGroup.of(.c(.struct)) == .c)
        #expect(RuntimeObjectScope.KindGroup.of(.objc(.type(.class))) == .objectiveC)
        #expect(RuntimeObjectScope.KindGroup.of(.objc(.category(.protocol))) == .objectiveC)
        #expect(RuntimeObjectScope.KindGroup.of(.swift(.type(.class))) == .swift)
        #expect(RuntimeObjectScope.KindGroup.of(.swift(.conformance(.protocol))) == .swift)
    }

    @Test("KindGroup.kinds enumerates a non-empty, kind-consistent set")
    func kindGroupEnumerates() {
        for group in RuntimeObjectScope.KindGroup.allCases {
            let kinds = group.kinds
            #expect(!kinds.isEmpty)
            for kind in kinds {
                #expect(RuntimeObjectScope.KindGroup.of(kind) == group)
            }
        }
    }

    // MARK: - toggleKind

    @Test("toggleKind from the empty default removes only that kind, keeping every other representable kind included")
    func toggleKindFromEmptyRemovesSingleKind() {
        var scope = RuntimeObjectScope()
        scope.toggleKind(.c(.struct))

        // Active because the selection is no longer the "everything" sentinel.
        #expect(scope.isActive)
        // Every representable kind except the toggled one is still allowed.
        #expect(!scope.includedKinds.contains(.c(.struct)))
        for kind in RuntimeObjectScope.allRepresentableKinds where kind != .c(.struct) {
            #expect(scope.includedKinds.contains(kind), "missing kind \(kind)")
        }
    }

    @Test("toggleKind round-trips: removing then re-adding every kind collapses back to the empty default")
    func toggleKindRoundTripCollapsesToEmpty() {
        var scope = RuntimeObjectScope()
        scope.toggleKind(.swift(.type(.class)))
        #expect(scope.isActive)

        scope.toggleKind(.swift(.type(.class)))
        #expect(scope.includedKinds.isEmpty)
        #expect(!scope.isActive)
    }

    @Test("toggleKind a second kind from explicit selection toggles only that kind")
    func toggleKindFromExplicitSelectionFlipsOne() {
        var scope = RuntimeObjectScope()
        scope.includedKinds = [.swift(.type(.class))]
        scope.toggleKind(.objc(.type(.protocol)))

        #expect(scope.includedKinds == [.swift(.type(.class)), .objc(.type(.protocol))])
    }

    // MARK: - toggleGroup

    @Test("toggleGroup from the empty default strips only that group, leaving the other groups included")
    func toggleGroupFromEmptyStripsGroup() {
        var scope = RuntimeObjectScope()
        scope.toggleGroup(.objectiveC)

        let objcKinds = Set(RuntimeObjectScope.KindGroup.objectiveC.kinds)
        #expect(scope.includedKinds.intersection(objcKinds).isEmpty)
        let nonObjcKinds = RuntimeObjectScope.allRepresentableKinds.subtracting(objcKinds)
        #expect(scope.includedKinds == nonObjcKinds)
    }

    @Test("toggleGroup on a mixed group strips the whole group")
    func toggleGroupOnMixedStripsGroup() {
        var scope = RuntimeObjectScope()
        // Mix: half of Objective-C selected, no other kinds.
        scope.includedKinds = [.objc(.type(.class))]
        scope.toggleGroup(.objectiveC)

        let objcKinds = Set(RuntimeObjectScope.KindGroup.objectiveC.kinds)
        #expect(scope.includedKinds.intersection(objcKinds).isEmpty)
    }

    @Test("toggleGroup on an absent group re-adds every kind in that group")
    func toggleGroupOnAbsentReaddsGroup() {
        var scope = RuntimeObjectScope()
        scope.toggleGroup(.swift)
        // Swift now absent; everything else present.
        scope.toggleGroup(.swift)
        // Re-added; should collapse back to the empty default.
        #expect(scope.includedKinds.isEmpty)
        #expect(!scope.isActive)
    }

    // MARK: - Representable kinds

    @Test("allRepresentableKinds excludes Objective-C protocol categories")
    func allRepresentableKindsExcludesProtocolCategory() {
        #expect(!RuntimeObjectScope.allRepresentableKinds.contains(.objc(.category(.protocol))))
    }

    @Test("allRepresentableKinds keeps every other RuntimeObjectKind case")
    func allRepresentableKindsKeepsOthers() {
        let everything = Set(RuntimeObjectKind.allCases)
        let dropped = everything.subtracting(RuntimeObjectScope.allRepresentableKinds)
        #expect(dropped == [.objc(.category(.protocol))])
    }

    @Test("KindGroup.objectiveC.kinds omits the impossible protocol category")
    func objectiveCGroupOmitsProtocolCategory() {
        let objcKinds = RuntimeObjectScope.KindGroup.objectiveC.kinds
        #expect(!objcKinds.contains(.objc(.category(.protocol))))
        // Sanity: the other three Objective-C variants are still listed.
        #expect(objcKinds.contains(.objc(.type(.class))))
        #expect(objcKinds.contains(.objc(.type(.protocol))))
        #expect(objcKinds.contains(.objc(.category(.class))))
    }

    @Test("toggleKind round-trips even when starting from allRepresentableKinds equivalence")
    func toggleKindRoundTripCollapsesAcrossAllRepresentable() {
        var scope = RuntimeObjectScope()
        // Reach the "all representable" canonical form via explicit toggle.
        scope.toggleKind(.swift(.type(.class)))
        scope.toggleKind(.swift(.type(.class)))
        #expect(scope.includedKinds.isEmpty)
    }

    // MARK: - Helpers

    private func object(
        kind: RuntimeObjectKind = .swift(.type(.class)),
        children: [RuntimeObject] = [],
        properties: RuntimeObject.Properties = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: "Sample",
            displayName: "Sample",
            kind: kind,
            imagePath: "/System/Library/Frameworks/Sample.framework/Sample",
            children: children,
            properties: properties
        )
    }
}
