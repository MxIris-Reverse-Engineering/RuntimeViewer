import Testing
import Foundation
import RuntimeViewerCore

// MARK: - Phase Tests

@Suite("RuntimeObjectsLoadingProgress.Phase")
struct RuntimeObjectsLoadingProgressPhaseTests {
    // MARK: - Display Description

    @Test("All phases have non-empty display descriptions", arguments: [
        RuntimeObjectsLoadingProgress.Phase.preparingObjCSection,
        .loadingObjCClasses,
        .loadingObjCProtocols,
        .loadingObjCCategories,
        .extractingSwiftTypes,
        .extractingSwiftProtocols,
        .extractingSwiftConformances,
        .extractingSwiftAssociatedTypes,
        .preparingSymbolIndex,
        .indexingSwiftTypes,
        .indexingSwiftProtocols,
        .indexingSwiftConformances,
        .indexingSwiftExtensions,
        .buildingObjects,
    ])
    func displayDescriptionNonEmpty(phase: RuntimeObjectsLoadingProgress.Phase) {
        #expect(!phase.displayDescription.isEmpty)
    }

    @Test("Display descriptions contain expected keywords", arguments: [
        (RuntimeObjectsLoadingProgress.Phase.preparingObjCSection, "Objective-C"),
        (.loadingObjCClasses, "classes"),
        (.loadingObjCProtocols, "protocols"),
        (.loadingObjCCategories, "categories"),
        (.extractingSwiftTypes, "Swift types"),
        (.extractingSwiftProtocols, "Swift protocols"),
        (.extractingSwiftConformances, "Swift conformances"),
        (.extractingSwiftAssociatedTypes, "Swift associated types"),
        (.preparingSymbolIndex, "symbol index"),
        (.indexingSwiftTypes, "Swift types"),
        (.indexingSwiftProtocols, "Swift protocols"),
        (.indexingSwiftConformances, "Swift conformances"),
        (.indexingSwiftExtensions, "Swift extensions"),
        (.buildingObjects, "objects"),
    ] as [(RuntimeObjectsLoadingProgress.Phase, String)])
    func displayDescriptionKeywords(phase: RuntimeObjectsLoadingProgress.Phase, keyword: String) {
        #expect(phase.displayDescription.contains(keyword))
    }

    @Test("Display descriptions end with ellipsis")
    func displayDescriptionEndsWithEllipsis() {
        let allPhases: [RuntimeObjectsLoadingProgress.Phase] = [
            .preparingObjCSection, .loadingObjCClasses, .loadingObjCProtocols,
            .loadingObjCCategories, .extractingSwiftTypes, .extractingSwiftProtocols,
            .extractingSwiftConformances, .extractingSwiftAssociatedTypes,
            .preparingSymbolIndex, .indexingSwiftTypes, .indexingSwiftProtocols,
            .indexingSwiftConformances, .indexingSwiftExtensions, .buildingObjects,
        ]
        for phase in allPhases {
            #expect(phase.displayDescription.hasSuffix("..."))
        }
    }

    // MARK: - Progress Range

    @Test("Progress ranges start at 0.0 and end at 1.0")
    func progressRangesCoverFullSpectrum() {
        let firstRange = RuntimeObjectsLoadingProgress.Phase.preparingObjCSection.progressRange
        let lastRange = RuntimeObjectsLoadingProgress.Phase.buildingObjects.progressRange
        #expect(firstRange.start == 0.0)
        #expect(lastRange.end == 1.0)
    }

    @Test("Progress ranges are non-overlapping and contiguous")
    func progressRangesContiguous() {
        let phases: [RuntimeObjectsLoadingProgress.Phase] = [
            .preparingObjCSection, .loadingObjCClasses, .loadingObjCProtocols,
            .loadingObjCCategories, .extractingSwiftTypes, .extractingSwiftProtocols,
            .extractingSwiftConformances, .extractingSwiftAssociatedTypes,
            .preparingSymbolIndex, .indexingSwiftTypes, .indexingSwiftProtocols,
            .indexingSwiftConformances, .indexingSwiftExtensions, .buildingObjects,
        ]
        for phaseIndex in 0 ..< phases.count {
            let range = phases[phaseIndex].progressRange
            #expect(range.start < range.end, "Phase \(phases[phaseIndex]) has invalid range: start >= end")

            if phaseIndex > 0 {
                let previousRange = phases[phaseIndex - 1].progressRange
                #expect(
                    abs(previousRange.end - range.start) < 0.0001,
                    "Phase \(phases[phaseIndex]) is not contiguous with \(phases[phaseIndex - 1])"
                )
            }
        }
    }

    @Test("Progress range start is less than end for each phase")
    func progressRangeValid() {
        let phases: [RuntimeObjectsLoadingProgress.Phase] = [
            .preparingObjCSection, .loadingObjCClasses, .loadingObjCProtocols,
            .loadingObjCCategories, .extractingSwiftTypes, .extractingSwiftProtocols,
            .extractingSwiftConformances, .extractingSwiftAssociatedTypes,
            .preparingSymbolIndex, .indexingSwiftTypes, .indexingSwiftProtocols,
            .indexingSwiftConformances, .indexingSwiftExtensions, .buildingObjects,
        ]
        for phase in phases {
            let range = phase.progressRange
            #expect(range.start >= 0.0)
            #expect(range.end <= 1.0)
            #expect(range.start < range.end)
        }
    }

    // MARK: - Codable

    @Test("Phase Codable round-trip", arguments: [
        RuntimeObjectsLoadingProgress.Phase.preparingObjCSection,
        .loadingObjCClasses,
        .loadingObjCProtocols,
        .loadingObjCCategories,
        .extractingSwiftTypes,
        .extractingSwiftProtocols,
        .extractingSwiftConformances,
        .extractingSwiftAssociatedTypes,
        .preparingSymbolIndex,
        .indexingSwiftTypes,
        .indexingSwiftProtocols,
        .indexingSwiftConformances,
        .indexingSwiftExtensions,
        .buildingObjects,
    ])
    func phaseCodable(phase: RuntimeObjectsLoadingProgress.Phase) throws {
        let data = try JSONEncoder().encode(phase)
        let decoded = try JSONDecoder().decode(RuntimeObjectsLoadingProgress.Phase.self, from: data)
        #expect(decoded == phase)
    }
}

// MARK: - Progress Tests

@Suite("RuntimeObjectsLoadingProgress")
struct RuntimeObjectsLoadingProgressTests {
    // MARK: - Initialization

    @Test("Initialization with all properties")
    func initialization() {
        let progress = RuntimeObjectsLoadingProgress(
            phase: .loadingObjCClasses,
            itemDescription: "NSObject",
            currentCount: 50,
            totalCount: 100
        )
        #expect(progress.phase == .loadingObjCClasses)
        #expect(progress.itemDescription == "NSObject")
        #expect(progress.currentCount == 50)
        #expect(progress.totalCount == 100)
    }

    // MARK: - Overall Fraction

    @Test("Overall fraction at start of phase (zero progress)")
    func overallFractionAtStart() {
        let progress = RuntimeObjectsLoadingProgress(
            phase: .loadingObjCClasses,
            itemDescription: "",
            currentCount: 0,
            totalCount: 100
        )
        let range = RuntimeObjectsLoadingProgress.Phase.loadingObjCClasses.progressRange
        #expect(abs(progress.overallFraction - range.start) < 0.0001)
    }

    @Test("Overall fraction at end of phase (full progress)")
    func overallFractionAtEnd() {
        let progress = RuntimeObjectsLoadingProgress(
            phase: .loadingObjCClasses,
            itemDescription: "",
            currentCount: 100,
            totalCount: 100
        )
        let range = RuntimeObjectsLoadingProgress.Phase.loadingObjCClasses.progressRange
        #expect(abs(progress.overallFraction - range.end) < 0.0001)
    }

    @Test("Overall fraction at midpoint")
    func overallFractionAtMidpoint() {
        let progress = RuntimeObjectsLoadingProgress(
            phase: .loadingObjCClasses,
            itemDescription: "",
            currentCount: 50,
            totalCount: 100
        )
        let range = RuntimeObjectsLoadingProgress.Phase.loadingObjCClasses.progressRange
        let expectedFraction = range.start + (range.end - range.start) * 0.5
        #expect(abs(progress.overallFraction - expectedFraction) < 0.0001)
    }

    @Test("Overall fraction with zero totalCount returns range start")
    func overallFractionZeroTotal() {
        let progress = RuntimeObjectsLoadingProgress(
            phase: .preparingObjCSection,
            itemDescription: "",
            currentCount: 0,
            totalCount: 0
        )
        let range = RuntimeObjectsLoadingProgress.Phase.preparingObjCSection.progressRange
        #expect(abs(progress.overallFraction - range.start) < 0.0001)
    }

    @Test("Overall fraction for first phase at start is 0.0")
    func overallFractionFirstPhaseStart() {
        let progress = RuntimeObjectsLoadingProgress(
            phase: .preparingObjCSection,
            itemDescription: "",
            currentCount: 0,
            totalCount: 100
        )
        #expect(abs(progress.overallFraction - 0.0) < 0.0001)
    }

    @Test("Overall fraction for last phase at end is 1.0")
    func overallFractionLastPhaseEnd() {
        let progress = RuntimeObjectsLoadingProgress(
            phase: .buildingObjects,
            itemDescription: "",
            currentCount: 100,
            totalCount: 100
        )
        #expect(abs(progress.overallFraction - 1.0) < 0.0001)
    }

    @Test("Overall fraction is monotonically increasing across phases")
    func overallFractionMonotonic() {
        let phases: [RuntimeObjectsLoadingProgress.Phase] = [
            .preparingObjCSection, .loadingObjCClasses, .loadingObjCProtocols,
            .loadingObjCCategories, .extractingSwiftTypes, .extractingSwiftProtocols,
            .extractingSwiftConformances, .extractingSwiftAssociatedTypes,
            .preparingSymbolIndex, .indexingSwiftTypes, .indexingSwiftProtocols,
            .indexingSwiftConformances, .indexingSwiftExtensions, .buildingObjects,
        ]
        var previousFraction = -1.0
        for phase in phases {
            let progress = RuntimeObjectsLoadingProgress(
                phase: phase,
                itemDescription: "",
                currentCount: 50,
                totalCount: 100
            )
            #expect(progress.overallFraction > previousFraction)
            previousFraction = progress.overallFraction
        }
    }

    // MARK: - Codable

    @Test("Codable round-trip")
    func codable() throws {
        let original = RuntimeObjectsLoadingProgress(
            phase: .extractingSwiftTypes,
            itemDescription: "MyStruct",
            currentCount: 42,
            totalCount: 200
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeObjectsLoadingProgress.self, from: data)
        #expect(decoded.phase == original.phase)
        #expect(decoded.itemDescription == original.itemDescription)
        #expect(decoded.currentCount == original.currentCount)
        #expect(decoded.totalCount == original.totalCount)
    }
}

// MARK: - Loading Event Tests

@Suite("RuntimeObjectsLoadingEvent")
struct RuntimeObjectsLoadingEventTests {
    @Test("Progress event creation")
    func progressEvent() {
        let progress = RuntimeObjectsLoadingProgress(
            phase: .loadingObjCClasses,
            itemDescription: "NSObject",
            currentCount: 1,
            totalCount: 10
        )
        let event = RuntimeObjectsLoadingEvent.progress(progress)
        if case .progress(let eventProgress) = event {
            #expect(eventProgress.phase == .loadingObjCClasses)
        } else {
            Issue.record("Expected .progress event")
        }
    }

    @Test("Completed event creation")
    func completedEvent() {
        let objects = [
            RuntimeObject(
                name: "NSObject",
                displayName: "NSObject",
                kind: .objc(.type(.class)),
                secondaryKind: nil,
                imagePath: "/usr/lib/libobjc.dylib",
                children: []
            ),
        ]
        let event = RuntimeObjectsLoadingEvent.completed(objects)
        if case .completed(let eventObjects) = event {
            #expect(eventObjects.count == 1)
            #expect(eventObjects[0].name == "NSObject")
        } else {
            Issue.record("Expected .completed event")
        }
    }
}
