import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Routes for the document-window sheet that walks the user through
/// specializing a generic Swift type. Lives in the Application layer so the
/// `SpecializationSheetViewModel` can hold a typed `Router` reference.
///
/// `requestTypePicker` carries an opaque anchor identifier (the
/// `parameterName`) rather than a platform `NSView`, so the route stays
/// platform-neutral. The view layer is responsible for resolving the
/// anchor by looking up the row's choose-button when it receives this
/// route.
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SpecializationRoute: Routable {
    case cancel
    case requestTypePicker(parameterName: String)
    case specializeCompleted(RuntimeObject)
}
