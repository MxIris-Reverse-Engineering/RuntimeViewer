import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerSettings
import DependenciesMacros

@MainActor
final class AppearanceController {
    fileprivate static let shared = AppearanceController()

    @Dependency(\.settings) private var settings

    private var observeToken: ObserveToken?

    private init() {}

    func start() {
        guard observeToken == nil else { return }
        observeToken = SwiftNavigation.observe { [weak self] in
            guard let self else { return }
            switch settings.general.appearance {
            case .system:
                NSApp.appearance = nil
            case .dark:
                NSApp.appearance = NSAppearance(named: .darkAqua)
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
            }
        }
    }

    func stop() {
        observeToken?.cancel()
        observeToken = nil
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { AppearanceController.shared })
    var appearanceController: AppearanceController
}
