import SwiftUI
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

protocol DismissibleRoute: Routable {
    static var dismiss: Self { get }
}

enum EmptyRoute: Routable {}

struct RuntimeObjectKindFilter: Hashable, Identifiable {
    let kind: RuntimeObjectKind
    var isEnabled: Bool
    var id: Self { self }
    
    init(kind: RuntimeObjectKind, isEnabled: Bool = true) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

class RuntimeObjectKindFilterViewModel: ViewModel<EmptyRoute>, ObservableObject {
    @Published
    var filters: [RuntimeObjectKindFilter] = RuntimeObjectKind.allCases.map { RuntimeObjectKindFilter(kind: $0) }
}


struct RuntimeObjectKindFilterView: SwiftUI.View {
    @EnvironmentObject
    var viewModel: RuntimeObjectKindFilterViewModel
    
    var body: some SwiftUI.View {

        VStack(alignment: .leading) {
            ForEach($viewModel.filters) { filter in
                Toggle(isOn: filter.isEnabled) {
                    Text(filter.wrappedValue.kind.description)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding()
    }
}

class RuntimeObjectKindFilterViewController: NSHostingController<RuntimeObjectKindFilterView> {

    
}

@available(macOS 14, *)
#Preview {
    RuntimeObjectKindFilterView()
        .environmentObject(RuntimeObjectKindFilterViewModel(appServices: .init(), router: TestCoordinator<EmptyRoute>(initialRoute: nil)))
}
class TestCoordinator<Route: Routable>: Coordinator<Route, AppTransition> {
    
    override func prepareTransition(for route: Route) -> AppTransition {
        return .none()
    }
}
