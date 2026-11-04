import ProjectDescription
import ProjectDescriptionHelpers

// RuntimeViewer-Tuist.xcworkspace, the development-only workspace Tuist generates beside the native
// ones: Documentations/Guides/TuistDevelopment.md.
let workspace = Workspace(
    name: "RuntimeViewer-Tuist",
    projects: ["RuntimeViewerUsingAppKit"],
    schemes: [
        // The local packages' test targets live in the projects Tuist generates for the packages,
        // which a scheme of RuntimeViewerUsingAppKit/Project.swift cannot reference.
        .scheme(
            name: "RuntimeViewer Tests",
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
