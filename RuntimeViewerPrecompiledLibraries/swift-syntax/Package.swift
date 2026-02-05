// swift-tools-version: 5.9

import PackageDescription

let tag = "601.0.1"

let package = Package(
    name: "swift-syntax",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "SwiftBasicFormat", targets: ["SwiftBasicFormat_Aggregation"]),
        .library(name: "SwiftCompilerPlugin", targets: ["SwiftCompilerPlugin_Aggregation"]),
        .library(name: "SwiftDiagnostics", targets: ["SwiftDiagnostics_Aggregation"]),
        .library(name: "SwiftIDEUtils", targets: ["SwiftIDEUtils_Aggregation"]),
        .library(name: "SwiftIfConfig", targets: ["SwiftIfConfig_Aggregation"]),
        .library(name: "SwiftLexicalLookup", targets: ["SwiftLexicalLookup_Aggregation"]),
        .library(name: "SwiftOperators", targets: ["SwiftOperators_Aggregation"]),
        .library(name: "SwiftParser", targets: ["SwiftParser_Aggregation"]),
        .library(name: "SwiftParserDiagnostics", targets: ["SwiftParserDiagnostics_Aggregation"]),
        .library(name: "SwiftRefactor", targets: ["SwiftRefactor_Aggregation"]),
        .library(name: "SwiftSyntax", targets: ["SwiftSyntax_Aggregation"]),
        .library(name: "SwiftSyntaxBuilder", targets: ["SwiftSyntaxBuilder_Aggregation"]),
        .library(name: "SwiftSyntaxMacros", targets: ["SwiftSyntaxMacros_Aggregation"]),
        .library(name: "SwiftSyntaxMacroExpansion", targets: ["SwiftSyntaxMacroExpansion_Aggregation"]),
        .library(name: "SwiftSyntaxMacrosTestSupport", targets: ["SwiftSyntaxMacrosTestSupport_Aggregation"]),
        .library(name: "SwiftSyntaxMacrosGenericTestSupport", targets: ["SwiftSyntaxMacrosGenericTestSupport_Aggregation"]),
        .library(name: "_SwiftCompilerPluginMessageHandling", targets: ["SwiftCompilerPluginMessageHandling_Aggregation"]),
        .library(name: "_SwiftLibraryPluginProvider", targets: ["SwiftLibraryPluginProvider_Aggregation"]),
    ],
    targets: [
        // MARK: - SwiftBasicFormat
        .target(
            name: "SwiftBasicFormat_Aggregation",
            dependencies: [
                .target(name: "SwiftBasicFormat"),
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftBasicFormat",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftBasicFormat.xcframework.zip",
            checksum: "94365ab0f550e63d788c2379193bcaef059d4c155d587eacc0648deb4dcdf418"
        ),

        // MARK: - SwiftCompilerPlugin
        .target(
            name: "SwiftCompilerPlugin_Aggregation",
            dependencies: [
                .target(name: "SwiftCompilerPlugin"),
                "SwiftCompilerPluginMessageHandling_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftCompilerPlugin",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftCompilerPlugin.xcframework.zip",
            checksum: "e3cad3e5b8c29b70c85fe05dd85622ad3a82f9ad48789ed7998bee35b34475da"
        ),

        // MARK: - SwiftDiagnostics
        .target(
            name: "SwiftDiagnostics_Aggregation",
            dependencies: [
                .target(name: "SwiftDiagnostics"),
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftDiagnostics",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftDiagnostics.xcframework.zip",
            checksum: "50bf401279fc1f35f177bd40e4a1a107950dbb442fcde7a3fdce47836eb2016b"
        ),

        // MARK: - SwiftIDEUtils
        .target(
            name: "SwiftIDEUtils_Aggregation",
            dependencies: [
                .target(name: "SwiftIDEUtils"),
                "SwiftSyntax_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftParser_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftIDEUtils",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftIDEUtils.xcframework.zip",
            checksum: "82a31659ddf3a24a89a17863aabaeea15024dd92267898c27b3d03a5298e3827"
        ),

        // MARK: - SwiftIfConfig
        .target(
            name: "SwiftIfConfig_Aggregation",
            dependencies: [
                .target(name: "SwiftIfConfig"),
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxBuilder_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftOperators_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftIfConfig",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftIfConfig.xcframework.zip",
            checksum: "86d9fb1a73a5c1f7f71d384abdd7f631a0b6a10de7660fe3fd577f1f1650c0a7"
        ),

        // MARK: - SwiftLexicalLookup
        .target(
            name: "SwiftLexicalLookup_Aggregation",
            dependencies: [
                .target(name: "SwiftLexicalLookup"),
                "SwiftSyntax_Aggregation",
                "SwiftIfConfig_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftLexicalLookup",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftLexicalLookup.xcframework.zip",
            checksum: "7f2f318e7caf5e6bc8707b3ddd812f77913852cbd699be6fafdc7e9e4638b0f8"
        ),

        // MARK: - SwiftOperators
        .target(
            name: "SwiftOperators_Aggregation",
            dependencies: [
                .target(name: "SwiftOperators"),
                "SwiftDiagnostics_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftOperators",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftOperators.xcframework.zip",
            checksum: "d6da125f107d2e0109b8f5056ab5f62a57ecc7a6f8760d7068628f0d660084ef"
        ),

        // MARK: - SwiftParser
        .target(
            name: "SwiftParser_Aggregation",
            dependencies: [
                .target(name: "SwiftParser"),
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftParser",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftParser.xcframework.zip",
            checksum: "873e3a52f51db1f46531877d81d747c0b9c8125e801b0f40472c5b94359d57c1"
        ),

        // MARK: - SwiftParserDiagnostics
        .target(
            name: "SwiftParserDiagnostics_Aggregation",
            dependencies: [
                .target(name: "SwiftParserDiagnostics"),
                "SwiftBasicFormat_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftParserDiagnostics",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftParserDiagnostics.xcframework.zip",
            checksum: "7b6776f6941e1b32250694927c59e72abe952582eaad269da6183118349746ca"
        ),

        // MARK: - SwiftRefactor
        .target(
            name: "SwiftRefactor_Aggregation",
            dependencies: [
                .target(name: "SwiftRefactor"),
                "SwiftBasicFormat_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxBuilder_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftRefactor",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftRefactor.xcframework.zip",
            checksum: "b402430b131e6a9133dbb6cbc8760096454b97d3e6d9d97e3f0cfb4ea7bd0b42"
        ),

        // MARK: - SwiftSyntax
        .target(
            name: "SwiftSyntax_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntax"),
                "_SwiftSyntaxCShims_Aggregation",
                "SwiftSyntax509_Aggregation",
                "SwiftSyntax510_Aggregation",
                "SwiftSyntax600_Aggregation",
                "SwiftSyntax601_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntax",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntax.xcframework.zip",
            checksum: "d06ed8d94024fa44041a4ee0bf84610353cbaf1576bb7bfa91e952ef779c870a"
        ),

        // MARK: - SwiftSyntaxBuilder
        .target(
            name: "SwiftSyntaxBuilder_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxBuilder"),
                "SwiftBasicFormat_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftParserDiagnostics_Aggregation",
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxBuilder",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntaxBuilder.xcframework.zip",
            checksum: "4d9554178485ee66242b68662e92710461a0a1f641e0703c74e24c313a55251d"
        ),

        // MARK: - SwiftSyntaxMacros
        .target(
            name: "SwiftSyntaxMacros_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxMacros"),
                "SwiftDiagnostics_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxBuilder_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxMacros",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntaxMacros.xcframework.zip",
            checksum: "428f898a1e7852dec98d4c09185fb1a87e7fc77e0203ba83a0db90b360c6e035"
        ),

        // MARK: - SwiftSyntaxMacroExpansion
        .target(
            name: "SwiftSyntaxMacroExpansion_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxMacroExpansion"),
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxBuilder_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftOperators_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxMacroExpansion",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntaxMacroExpansion.xcframework.zip",
            checksum: "2ddcd299bd7523b53f02a005ec066831cbac20677292ee198801a3eafb8cf696"
        ),

        // MARK: - SwiftSyntaxMacrosTestSupport
        .target(
            name: "SwiftSyntaxMacrosTestSupport_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxMacrosTestSupport"),
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxMacroExpansion_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
                "SwiftSyntaxMacrosGenericTestSupport_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxMacrosTestSupport",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntaxMacrosTestSupport.xcframework.zip",
            checksum: "8ae3781cd5ad9e63b653a99a3c7ba1efd1eeaa2d831122d05868ea80b9998529"
        ),

        // MARK: - SwiftSyntaxMacrosGenericTestSupport
        .target(
            name: "SwiftSyntaxMacrosGenericTestSupport_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxMacrosGenericTestSupport"),
                "_SwiftSyntaxGenericTestSupport_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftIDEUtils_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
                "SwiftSyntaxMacroExpansion_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxMacrosGenericTestSupport",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntaxMacrosGenericTestSupport.xcframework.zip",
            checksum: "5601a9d686cc84f5b32e1c6c04a01f3fe16c8f5216f1edec648b6d2ce0aa1d04"
        ),

        // MARK: - _SwiftCompilerPluginMessageHandling
        .target(
            name: "_SwiftCompilerPluginMessageHandling_Aggregation",
            dependencies: [.target(name: "_SwiftCompilerPluginMessageHandling")]
        ),
        .binaryTarget(
            name: "_SwiftCompilerPluginMessageHandling",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/_SwiftCompilerPluginMessageHandling.xcframework.zip",
            checksum: "df02239aac44cb97402c49d04ebdb8d63880d1cf6d2730bdafb0c71d594b31b9"
        ),

        // MARK: - _SwiftLibraryPluginProvider
        .target(
            name: "_SwiftLibraryPluginProvider_Aggregation",
            dependencies: [.target(name: "_SwiftLibraryPluginProvider")]
        ),
        .binaryTarget(
            name: "_SwiftLibraryPluginProvider",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/_SwiftLibraryPluginProvider.xcframework.zip",
            checksum: "d5aeedeefa4aa7f424054147f4d55809f65f30174a3235bfd7cde957b4e8631f"
        ),

        // MARK: - _SwiftLibraryPluginProviderCShims
        .target(
            name: "_SwiftLibraryPluginProviderCShims_Aggregation",
            dependencies: [.target(name: "_SwiftLibraryPluginProviderCShims")]
        ),
        .binaryTarget(
            name: "_SwiftLibraryPluginProviderCShims",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/_SwiftLibraryPluginProviderCShims.xcframework.zip",
            checksum: "889ee8bf53509090f75fe39e5a74784af8eacdd896f7a314f1dff4fa60a5a8ca"
        ),

        // MARK: - _SwiftSyntaxCShims
        .target(
            name: "_SwiftSyntaxCShims_Aggregation",
            dependencies: [.target(name: "_SwiftSyntaxCShims")]
        ),
        .binaryTarget(
            name: "_SwiftSyntaxCShims",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/_SwiftSyntaxCShims.xcframework.zip",
            checksum: "f4d14eabe1bec36dfe7ebc13f4a159dbb046e966579af5d8d807e151c2aa6c9b"
        ),

        // MARK: - _SwiftSyntaxGenericTestSupport
        .target(
            name: "_SwiftSyntaxGenericTestSupport_Aggregation",
            dependencies: [.target(name: "_SwiftSyntaxGenericTestSupport")]
        ),
        .binaryTarget(
            name: "_SwiftSyntaxGenericTestSupport",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/_SwiftSyntaxGenericTestSupport.xcframework.zip",
            checksum: "884d1c5983a63e1863d38049174933f5c734a2537c91c26a1d241c08c4aeeeac"
        ),

        // MARK: - SwiftCompilerPluginMessageHandling
        .target(
            name: "SwiftCompilerPluginMessageHandling_Aggregation",
            dependencies: [
                .target(name: "SwiftCompilerPluginMessageHandling"),
                "_SwiftSyntaxCShims_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftOperators_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
                "SwiftSyntaxMacroExpansion_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftCompilerPluginMessageHandling",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftCompilerPluginMessageHandling.xcframework.zip",
            checksum: "d405da850c46662e7995110bfa1b21d2c900d61d24864bd4f4a47f3d94097014"
        ),

        // MARK: - SwiftLibraryPluginProvider
        .target(
            name: "SwiftLibraryPluginProvider_Aggregation",
            dependencies: [
                .target(name: "SwiftLibraryPluginProvider"),
                "SwiftSyntaxMacros_Aggregation",
                "SwiftCompilerPluginMessageHandling_Aggregation",
                "_SwiftLibraryPluginProviderCShims_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftLibraryPluginProvider",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftLibraryPluginProvider.xcframework.zip",
            checksum: "8cdccb3839eb1f94eb601f347ada3839848add1b6c92cf415fab57c11727f396"
        ),

        // MARK: - SwiftSyntax509
        .target(
            name: "SwiftSyntax509_Aggregation",
            dependencies: [.target(name: "SwiftSyntax509")]
        ),
        .binaryTarget(
            name: "SwiftSyntax509",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntax509.xcframework.zip",
            checksum: "9c362169c3e677e0670c3630d1215d26b31191250db76516ea399f350d9b45ad"
        ),

        // MARK: - SwiftSyntax510
        .target(
            name: "SwiftSyntax510_Aggregation",
            dependencies: [.target(name: "SwiftSyntax510")]
        ),
        .binaryTarget(
            name: "SwiftSyntax510",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntax510.xcframework.zip",
            checksum: "d3a578ad0c7d352b6940397480d8f040b5095065af3836de66b6961eea28501c"
        ),

        // MARK: - SwiftSyntax600
        .target(
            name: "SwiftSyntax600_Aggregation",
            dependencies: [.target(name: "SwiftSyntax600")]
        ),
        .binaryTarget(
            name: "SwiftSyntax600",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntax600.xcframework.zip",
            checksum: "83c09d90b60f67c001d6f598a657c6cf0b457acad466f823074112b40ff678cf"
        ),

        // MARK: - SwiftSyntax601
        .target(
            name: "SwiftSyntax601_Aggregation",
            dependencies: [.target(name: "SwiftSyntax601")]
        ),
        .binaryTarget(
            name: "SwiftSyntax601",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/601.0.1/SwiftSyntax601.xcframework.zip",
            checksum: "eed0abae3c33170a43441bd4c35f95e7591e05b7482cb10833803551dab5ebbd"
        ),

    ]
)
