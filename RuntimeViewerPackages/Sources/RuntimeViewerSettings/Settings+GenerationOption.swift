import Foundation
import RuntimeViewerCore

extension Settings {
    /// One Generation Option the user sets: a row of Settings › Generation Options and of an image's
    /// Generation Options sheet, and what an image override names (proposal
    /// `generation-options-image-overrides`).
    ///
    /// Both lists are built from ``allCases`` in this order, so an option added to
    /// `ObjCGenerationOptions` or `SwiftGenerationOptions` reaches the user through a case here;
    /// `GenerationOptionCatalogTests` fails while an encoded option has none. The fields a request
    /// decides for itself — `transformer`, the `marks…` flags other than
    /// `marksSwiftNamesFromAPINotes`, `waitsForTypeIndex`, `interfaceLanguage` — are not options the
    /// user sets and have no case.
    ///
    /// The raw values are stored in `settings.json` (`ImageGenerationOptionsOverride.overriddenOptions`):
    /// never rename one. A stored value no case has any more is dropped when it is read.
    public enum GenerationOption: String, CaseIterable, Codable, Sendable {
        case objcStripProtocolConformance = "objc.stripProtocolConformance"
        case objcStripOverrides = "objc.stripOverrides"
        case objcStripSynthesizedIvars = "objc.stripSynthesizedIvars"
        case objcStripSynthesizedMethods = "objc.stripSynthesizedMethods"
        case objcStripCtorMethod = "objc.stripCtorMethod"
        case objcStripDtorMethod = "objc.stripDtorMethod"
        case objcAddIvarOffsetComments = "objc.addIvarOffsetComments"
        case objcAddPropertyAttributesComments = "objc.addPropertyAttributesComments"
        case objcAddPropertyAccessorAddressComments = "objc.addPropertyAccessorAddressComments"
        case objcAddMethodIMPAddressComments = "objc.addMethodIMPAddressComments"
        case objcPrintExportedDeclarationsOnly = "objc.printExportedDeclarationsOnly"
        /// The SDK's `NS_SWIFT_NAME` / `NS_REFINED_FOR_SWIFT` (proposal swift-type-indexing-package).
        /// A top-level field of the options rather than one of `objcHeaderOptions`, listed with them.
        case marksSwiftNamesFromAPINotes
        case swiftPrintStrippedSymbolicItem = "swift.printStrippedSymbolicItem"
        case swiftPrintFieldOffset = "swift.printFieldOffset"
        case swiftPrintExpandedFieldOffset = "swift.printExpandedFieldOffset"
        case swiftPrintVTableOffset = "swift.printVTableOffset"
        case swiftPrintPWTOffset = "swift.printPWTOffset"
        case swiftPrintMemberAddress = "swift.printMemberAddress"
        case swiftPrintTypeLayout = "swift.printTypeLayout"
        case swiftPrintEnumLayout = "swift.printEnumLayout"
        case swiftSynthesizeOpaqueType = "swift.synthesizeOpaqueType"
        /// `AnyWeakAttribute` or `__C.AGWeakAttribute` (proposal c-imported-type-name-spelling in
        /// MachOSwiftSection); the content pane's tags after such types switch it too.
        case swiftCImportedTypeNameSpelling = "swift.cImportedTypeNameSpelling"
        /// `__C.X` under its module and Swift name, from the SDK (proposal swift-type-indexing-package).
        /// Does nothing while Imported Type Names is C.
        case swiftResolvesImportedTypeNames = "swift.resolvesImportedTypeNames"
        case swiftInfersObjCOverridesFromSelectorNames = "swift.infersObjCOverridesFromSelectorNames"
        case swiftPrintExportedDeclarationsOnly = "swift.printExportedDeclarationsOnly"
        case swiftExpandsMacros = "swift.expandsMacros"
        case swiftBreaksLongTypes = "swift.breaksLongTypes"
        case swiftMemberSortOrder = "swift.memberSortOrder"

        /// The group an option is listed under.
        public enum Section: CaseIterable, Sendable {
            case objectiveC
            case swift

            public var title: String {
                switch self {
                case .objectiveC: "ObjC"
                case .swift: "Swift"
                }
            }

            /// The options of this group, in the order they are listed.
            public var options: [GenerationOption] {
                GenerationOption.allCases.filter { $0.section == self }
            }
        }

        /// How an option is shown and set.
        public enum Control {
            /// A checkbox over a Boolean field.
            case toggle(WritableKeyPath<RuntimeObjectInterface.GenerationOptions, Bool>)
            /// A segmented control over an enumeration's cases.
            case choice(Choice)
        }

        /// One choice among the cases of an enumeration field, by index.
        public struct Choice {
            /// One label per case, in the order of the cases.
            public let labels: [String]

            /// The index of the case `options` holds.
            public let selectedIndex: (RuntimeObjectInterface.GenerationOptions) -> Int

            /// Sets the case at an index; an index out of range changes nothing.
            public let select: (Int, inout RuntimeObjectInterface.GenerationOptions) -> Void

            fileprivate init<Value: CaseIterable & Equatable>(
                _ keyPath: WritableKeyPath<RuntimeObjectInterface.GenerationOptions, Value>,
                labels: [String]
            ) {
                self.labels = labels
                selectedIndex = { options in
                    Array(Value.allCases).firstIndex(of: options[keyPath: keyPath]) ?? 0
                }
                select = { index, options in
                    let allCases = Array(Value.allCases)
                    guard allCases.indices.contains(index) else { return }
                    options[keyPath: keyPath] = allCases[index]
                }
            }
        }

        public var section: Section {
            switch self {
            case .objcStripProtocolConformance, .objcStripOverrides, .objcStripSynthesizedIvars,
                 .objcStripSynthesizedMethods, .objcStripCtorMethod, .objcStripDtorMethod,
                 .objcAddIvarOffsetComments, .objcAddPropertyAttributesComments,
                 .objcAddPropertyAccessorAddressComments, .objcAddMethodIMPAddressComments,
                 .objcPrintExportedDeclarationsOnly, .marksSwiftNamesFromAPINotes:
                .objectiveC
            case .swiftPrintStrippedSymbolicItem, .swiftPrintFieldOffset, .swiftPrintExpandedFieldOffset,
                 .swiftPrintVTableOffset, .swiftPrintPWTOffset, .swiftPrintMemberAddress,
                 .swiftPrintTypeLayout, .swiftPrintEnumLayout, .swiftSynthesizeOpaqueType,
                 .swiftCImportedTypeNameSpelling, .swiftResolvesImportedTypeNames,
                 .swiftInfersObjCOverridesFromSelectorNames, .swiftPrintExportedDeclarationsOnly,
                 .swiftExpandsMacros, .swiftBreaksLongTypes, .swiftMemberSortOrder:
                .swift
            }
        }

        public var title: String {
            switch self {
            case .objcStripProtocolConformance: "Strip Protocol Conformance"
            case .objcStripOverrides: "Strip Overrides"
            case .objcStripSynthesizedIvars: "Strip Synthesized Ivars"
            case .objcStripSynthesizedMethods: "Strip Synthesized Methods"
            case .objcStripCtorMethod: "Strip Ctor Method"
            case .objcStripDtorMethod: "Strip Dtor Method"
            case .objcAddIvarOffsetComments: "Add Ivar Offset Comments"
            case .objcAddPropertyAttributesComments: "Add Property Attributes Comments"
            case .objcAddPropertyAccessorAddressComments: "Add Property Accessor Address Comments"
            case .objcAddMethodIMPAddressComments: "Add Method IMP Address Comments"
            case .objcPrintExportedDeclarationsOnly: "Print Exported Declarations Only"
            case .marksSwiftNamesFromAPINotes: "Mark Swift Names From SDK"
            case .swiftPrintStrippedSymbolicItem: "Print Stripped Symbol Description"
            case .swiftPrintFieldOffset: "Print Field Offset"
            case .swiftPrintExpandedFieldOffset: "Print Expanded Field Offset"
            case .swiftPrintVTableOffset: "Print VTable Offset"
            case .swiftPrintPWTOffset: "Print PWT Offset"
            case .swiftPrintMemberAddress: "Print Member Address"
            case .swiftPrintTypeLayout: "Print Type Layout"
            case .swiftPrintEnumLayout: "Print Enum Layout"
            case .swiftSynthesizeOpaqueType: "Synthesize Opaque Type"
            case .swiftCImportedTypeNameSpelling: "Imported Type Names"
            case .swiftResolvesImportedTypeNames: "Resolve Imported Type Names"
            case .swiftInfersObjCOverridesFromSelectorNames: "Infers ObjC Overrides From Selector Names"
            case .swiftPrintExportedDeclarationsOnly: "Print Exported Declarations Only"
            case .swiftExpandsMacros: "Expand Macros"
            case .swiftBreaksLongTypes: "Break Long Types"
            case .swiftMemberSortOrder: "Member Sort Order"
            }
        }

        public var control: Control {
            switch self {
            case .objcStripProtocolConformance: .toggle(\.objcHeaderOptions.stripProtocolConformance)
            case .objcStripOverrides: .toggle(\.objcHeaderOptions.stripOverrides)
            case .objcStripSynthesizedIvars: .toggle(\.objcHeaderOptions.stripSynthesizedIvars)
            case .objcStripSynthesizedMethods: .toggle(\.objcHeaderOptions.stripSynthesizedMethods)
            case .objcStripCtorMethod: .toggle(\.objcHeaderOptions.stripCtorMethod)
            case .objcStripDtorMethod: .toggle(\.objcHeaderOptions.stripDtorMethod)
            case .objcAddIvarOffsetComments: .toggle(\.objcHeaderOptions.addIvarOffsetComments)
            case .objcAddPropertyAttributesComments: .toggle(\.objcHeaderOptions.addPropertyAttributesComments)
            case .objcAddPropertyAccessorAddressComments: .toggle(\.objcHeaderOptions.addPropertyAccessorAddressComments)
            case .objcAddMethodIMPAddressComments: .toggle(\.objcHeaderOptions.addMethodIMPAddressComments)
            case .objcPrintExportedDeclarationsOnly: .toggle(\.objcHeaderOptions.printExportedDeclarationsOnly)
            case .marksSwiftNamesFromAPINotes: .toggle(\.marksSwiftNamesFromAPINotes)
            case .swiftPrintStrippedSymbolicItem: .toggle(\.swiftInterfaceOptions.printStrippedSymbolicItem)
            case .swiftPrintFieldOffset: .toggle(\.swiftInterfaceOptions.printFieldOffset)
            case .swiftPrintExpandedFieldOffset: .toggle(\.swiftInterfaceOptions.printExpandedFieldOffset)
            case .swiftPrintVTableOffset: .toggle(\.swiftInterfaceOptions.printVTableOffset)
            case .swiftPrintPWTOffset: .toggle(\.swiftInterfaceOptions.printPWTOffset)
            case .swiftPrintMemberAddress: .toggle(\.swiftInterfaceOptions.printMemberAddress)
            case .swiftPrintTypeLayout: .toggle(\.swiftInterfaceOptions.printTypeLayout)
            case .swiftPrintEnumLayout: .toggle(\.swiftInterfaceOptions.printEnumLayout)
            case .swiftSynthesizeOpaqueType: .toggle(\.swiftInterfaceOptions.synthesizeOpaqueType)
            case .swiftCImportedTypeNameSpelling: .choice(Choice(\.swiftInterfaceOptions.cImportedTypeNameSpelling, labels: ["Swift", "C"]))
            case .swiftResolvesImportedTypeNames: .toggle(\.swiftInterfaceOptions.resolvesImportedTypeNames)
            case .swiftInfersObjCOverridesFromSelectorNames: .toggle(\.swiftInterfaceOptions.infersObjCOverridesFromSelectorNames)
            case .swiftPrintExportedDeclarationsOnly: .toggle(\.swiftInterfaceOptions.printExportedDeclarationsOnly)
            case .swiftExpandsMacros: .toggle(\.swiftInterfaceOptions.expandsMacros)
            case .swiftBreaksLongTypes: .toggle(\.swiftInterfaceOptions.breaksLongTypes)
            case .swiftMemberSortOrder: .choice(Choice(\.swiftInterfaceOptions.memberSortOrder, labels: ["By Category", "By Offset"]))
            }
        }

        /// Copies this option's value from `source` into `destination`, leaving every other field of
        /// `destination` as it is.
        public func copyValue(
            from source: RuntimeObjectInterface.GenerationOptions,
            to destination: inout RuntimeObjectInterface.GenerationOptions
        ) {
            switch control {
            case .toggle(let keyPath):
                destination[keyPath: keyPath] = source[keyPath: keyPath]
            case .choice(let choice):
                choice.select(choice.selectedIndex(source), &destination)
            }
        }

        /// Whether this option has the same value in both.
        public func hasSameValue(
            in options: RuntimeObjectInterface.GenerationOptions,
            as otherOptions: RuntimeObjectInterface.GenerationOptions
        ) -> Bool {
            switch control {
            case .toggle(let keyPath):
                options[keyPath: keyPath] == otherOptions[keyPath: keyPath]
            case .choice(let choice):
                choice.selectedIndex(options) == choice.selectedIndex(otherOptions)
            }
        }

        /// The value as a list shows it: On or Off, or the label of the chosen case.
        public func displayValue(in options: RuntimeObjectInterface.GenerationOptions) -> String {
            switch control {
            case .toggle(let keyPath):
                options[keyPath: keyPath] ? "On" : "Off"
            case .choice(let choice):
                choice.labels[choice.selectedIndex(options)]
            }
        }
    }
}
