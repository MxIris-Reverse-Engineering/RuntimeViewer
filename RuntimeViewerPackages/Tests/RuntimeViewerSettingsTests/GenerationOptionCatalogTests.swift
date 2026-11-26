import Foundation
import Testing
import RuntimeViewerCore

@testable import RuntimeViewerSettings

/// `Settings.GenerationOption` is the only way an option reaches Settings › Generation Options, an
/// image's sheet and an image override. A field added to `ObjCGenerationOptions` or
/// `SwiftGenerationOptions` without a case would print with its default for ever, with nothing to
/// say so: these tests change every option on its own and compare the encoded options.
@Suite("Generation Option catalog")
struct GenerationOptionCatalogTests {
    /// Encoded fields that are deliberately no option the user sets, with the reason.
    private static let fieldsWithoutAnOption: Set<String> = [
        // The column a broken type wraps at; Break Long Types turns breaking on, and the width
        // stays at the printer's default.
        "swiftInterfaceOptions.maximumLineWidth",
    ]

    /// The fields an option can live in: the two printers' groups and the one top-level field the
    /// user sets, `marksSwiftNamesFromAPINotes`. The other top-level fields are decided per request.
    private static func userSetFields(of options: RuntimeObjectInterface.GenerationOptions) throws -> [String: String] {
        let flattened = try flattenedFields(of: options)
        return flattened.filter { field, _ in
            field.hasPrefix("objcHeaderOptions.") || field.hasPrefix("swiftInterfaceOptions.") || field == "marksSwiftNamesFromAPINotes"
        }
    }

    /// Every leaf of the encoded options, keyed by its dotted path, with its value as text.
    private static func flattenedFields(of options: RuntimeObjectInterface.GenerationOptions) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options))
        var fields: [String: String] = [:]
        func visit(_ value: Any, path: String) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    visit(child, path: path.isEmpty ? key : "\(path).\(key)")
                }
            } else {
                fields[path] = "\(value)"
            }
        }
        visit(object, path: "")
        return fields
    }

    /// `options` with `option` set to another value than it has.
    private static func changing(_ option: Settings.GenerationOption, in options: RuntimeObjectInterface.GenerationOptions) -> RuntimeObjectInterface.GenerationOptions {
        var changedOptions = options
        switch option.control {
        case .toggle(let keyPath):
            changedOptions[keyPath: keyPath].toggle()
        case .choice(let choice):
            choice.select((choice.selectedIndex(options) + 1) % choice.labels.count, &changedOptions)
        }
        return changedOptions
    }

    @Test("every option changes exactly one encoded field, and every field the user sets has an option")
    func catalogCoversEveryEncodedOptionExactlyOnce() throws {
        let defaults = RuntimeObjectInterface.GenerationOptions()
        let defaultFields = try Self.userSetFields(of: defaults)
        var fieldsByOption: [Settings.GenerationOption: String] = [:]

        for option in Settings.GenerationOption.allCases {
            let changedFields = try Self.userSetFields(of: Self.changing(option, in: defaults))
            let differingFields = defaultFields.keys.filter { defaultFields[$0] != changedFields[$0] }
            #expect(differingFields.count == 1, "\(option) changes \(differingFields.sorted())")
            fieldsByOption[option] = differingFields.first
        }

        let coveredFields = Set(fieldsByOption.values)
        #expect(coveredFields.count == fieldsByOption.count, "two options change the same field")
        let uncoveredFields = Set(defaultFields.keys).subtracting(coveredFields).subtracting(Self.fieldsWithoutAnOption)
        #expect(uncoveredFields.isEmpty, "fields with no Settings.GenerationOption case: \(uncoveredFields.sorted())")
    }

    @Test("every choice has one label per case, and setting an index reads back the same index")
    func choicesRoundTrip() {
        let defaults = RuntimeObjectInterface.GenerationOptions()
        for option in Settings.GenerationOption.allCases {
            guard case .choice(let choice) = option.control else { continue }
            for index in choice.labels.indices {
                var options = defaults
                choice.select(index, &options)
                #expect(choice.selectedIndex(options) == index, "\(option) at \(index)")
            }
        }
    }

    @Test("copying an option's value and comparing it touch that option alone")
    func copyValueAndHasSameValueAreScopedToTheOption() {
        let defaults = RuntimeObjectInterface.GenerationOptions()
        for option in Settings.GenerationOption.allCases {
            let changedOptions = Self.changing(option, in: defaults)
            #expect(!option.hasSameValue(in: defaults, as: changedOptions), "\(option)")

            var copiedOptions = defaults
            option.copyValue(from: changedOptions, to: &copiedOptions)
            #expect(copiedOptions == changedOptions, "\(option)")
        }
    }

    @Test("both sections list their options, and every option is in one")
    func sectionsPartitionTheOptions() {
        let listedOptions = Settings.GenerationOption.Section.allCases.flatMap(\.options)
        #expect(listedOptions.count == Settings.GenerationOption.allCases.count)
        #expect(Set(listedOptions) == Set(Settings.GenerationOption.allCases))
    }
}
