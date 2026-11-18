#if os(macOS)

import Foundation

/// A row of the naming word cloud's usage list: a name holding the selected
/// word, with its kind or the type declaring it. Fully determined by the row,
/// so the list builds it in its cell provider (`DifferentiableBox`).
public final class NamingWordCloudUsageCellViewModel: CellViewModel, @unchecked Sendable {
    public let row: NamingWordCloudUsageRow

    public init(row: NamingWordCloudUsageRow) {
        self.row = row
        super.init()
    }
}

#endif
