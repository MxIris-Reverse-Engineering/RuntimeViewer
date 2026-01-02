import Foundation

public enum RuntimeImageLoadState {
    case notLoaded
    case loading
    case loaded
    case loadError(Error)
    case unknown
}
