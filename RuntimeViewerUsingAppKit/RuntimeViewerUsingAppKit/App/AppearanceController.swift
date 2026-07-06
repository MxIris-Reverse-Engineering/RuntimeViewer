import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerSettings

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

private enum AppearanceControllerKey: @preconcurrency DependencyKey {
    @MainActor static let liveValue = AppearanceController.shared
}

extension DependencyValues {
    var appearanceController: AppearanceController {
        get { self[AppearanceControllerKey.self] }
        set { self[AppearanceControllerKey.self] = newValue }
    }
}
