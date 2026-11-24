import ProjectDescription

/// swift-onboardingkit links Apple's private OnBoardingKit.framework, weakly, through unsafe linker flags on
/// its Objective-C target. Xcode's own SwiftPM integration, which the native workspaces use, passes a
/// package target's linker flags on to every binary that links it. Tuist leaves them on the package's own
/// static target, so a binary that links RuntimeViewerAppUI misses every OnBoardingKit class
/// (`_OBJC_CLASS_$_OBTemplateView`, …) at link time. Those binaries repeat the flags.
public enum OnBoardingKitLinking {
    /// The flags swift-onboardingkit 0.1.0 declares: the SDK's private frameworks on the search path, and
    /// OnBoardingKit linked weakly, so the app still launches on a system without it.
    public static let linkerFlags: [String] = [
        "-F/System/Library/PrivateFrameworks",
        "-Xlinker", "-weak_framework", "-Xlinker", "OnBoardingKit",
    ]

    /// The local packages' test targets that link RuntimeViewerAppUI.
    public static let testTargetNames: Set<String> = [
        "RuntimeViewerAppUITests",
    ]
}
