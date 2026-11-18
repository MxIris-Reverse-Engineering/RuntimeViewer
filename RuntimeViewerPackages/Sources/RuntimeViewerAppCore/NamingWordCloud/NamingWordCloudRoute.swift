#if os(macOS)

import Foundation
import RuntimeViewerArchitectures

/// What a naming word cloud window asks its coordinator for.
public enum NamingWordCloudRoute: Routable {
    /// Ask where to save, then write the format: the image from the window's
    /// canvas, the counts from the view model (`exportedData(as:)`).
    case export(NamingWordCloudExportFormat)
    /// The Compound Words sheet.
    case editCompoundWords
    /// Close the Compound Words sheet.
    case closeCompoundWords
}

#endif
