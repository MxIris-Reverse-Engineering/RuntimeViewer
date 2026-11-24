import Foundation

/// The system symbols the application layer shows. A case's raw value is the symbol's name; RuntimeViewerAppUI
/// draws it (`SystemSymbol.image`), and `SystemSymbolTests` there loads every case, which is what SFSymbols'
/// typed names used to check at compile time.
public enum SystemSymbol: String, CaseIterable, Sendable {
    // Image lists (`RuntimeImageKind`; the bundles' symbols are `CustomSymbol`s)
    case doc
    case buildingColumnsFill = "building.columns.fill"
    case folderFill = "folder.fill"
    case eCircleFill = "e.circle.fill"
    case wrenchAndScrewdriverFill = "wrench.and.screwdriver.fill"
    case switch2 = "switch.2"
    case sparkles

    // Find results
    case textAlignleft = "text.alignleft"
    case questionmarkSquare = "questionmark.square"
    case chevronRight = "chevron.right"
    case chevronDown = "chevron.down"
    case arrowTriangle2Circlepath = "arrow.triangle.2.circlepath"
    case hourglass
    case exclamationmarkTriangle = "exclamationmark.triangle"

    // Report
    case squareStack3dDownRight = "square.stack.3d.down.right"
    case magnifyingglass
    case arrowTriangleBranch = "arrow.triangle.branch"
    case trayAndArrowDown = "tray.and.arrow.down"
    case powerCircle = "power.circle"
    case exclamationmarkCircle = "exclamationmark.circle"
    case archivebox
    case shippingbox

    // Onboarding pages (`OnboardingCatalog`; also `magnifyingglass`, `arrowTriangleBranch`)
    case squareStack3dUp = "square.stack.3d.up"
    case arrowRightCircle = "arrow.right.circle"
    case appConnectedToAppBelowFill = "app.connected.to.app.below.fill"
    case terminal
    case folder
    case curlybraces
    case rectangleSplit2x1 = "rectangle.split.2x1"
}
