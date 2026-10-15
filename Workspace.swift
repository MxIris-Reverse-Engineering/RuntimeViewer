import ProjectDescription
import ProjectDescriptionHelpers

// RuntimeViewer-Tuist.xcworkspace, the development-only workspace Tuist generates beside the native
// ones: Documentations/Guides/TuistDevelopment.md.
let workspace = Workspace(
    name: "RuntimeViewer-Tuist",
    projects: ["RuntimeViewerUsingAppKit"],
    schemes: [
        // The local packages' test targets live in the projects Tuist generates for the packages,
        // which a scheme of RuntimeViewerUsingAppKit/Project.swift cannot reference. The SourceEditor
        // bridge is built here because its tests load it at run time and cannot depend on it.
        .scheme(
            name: "RuntimeViewer Tests",
            buildAction: .buildAction(targets: [
                .project(path: "RuntimeViewerUsingAppKit", target: "RuntimeViewerSourceEditorBridge"),
            ]),
            testAction: .targets(
                LocalPackages.testTargetNames.flatMap { package, targets in
                    targets.map { .testableTarget(target: .project(path: .relativeToRoot(package), target: $0)) }
                } + [
                    .testableTarget(target: .project(path: "RuntimeViewerUsingAppKit", target: "RuntimeViewerSourceEditorBridgeTests")),
                ]
            )
        ),
    ]
)
