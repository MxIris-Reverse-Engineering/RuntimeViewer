import ProjectDescription
import ProjectDescriptionHelpers

// EXPERIMENT: with the upstream libraries taken from local checkouts (TUIST_LOCAL_UPSTREAM_CHECKOUTS,
// Tuist/Package.swift) the local packages' test targets are not mapped, so there is no test scheme.
let usesLocalUpstreamCheckouts = !Environment.localUpstreamCheckouts.getString(default: "").isEmpty

// RuntimeViewer-Tuist.xcworkspace, the development-only workspace Tuist generates beside the native
// ones: Documentations/Guides/TuistDevelopment.md.
let workspace = Workspace(
    name: "RuntimeViewer-Tuist",
    projects: ["RuntimeViewerUsingAppKit"],
    schemes: usesLocalUpstreamCheckouts ? [] : [
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
