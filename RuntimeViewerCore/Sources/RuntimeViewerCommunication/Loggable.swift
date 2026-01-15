#if canImport(os)

public import os.log
import Foundation

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@usableFromInline
protocol Loggable {
    var logger: Logger { get }
    static var logger: Logger { get }
    static var subsystem: String { get }
    static var category: String { get }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
private var loggerByObjectIdentifier: [ObjectIdentifier: Logger] = [:]
private let lock = NSLock()

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension Loggable {
    static var logger: Logger {
        let objectIdentifier = ObjectIdentifier(self)
        if let logger = lock.withLock({ loggerByObjectIdentifier[objectIdentifier] }) {
            return logger
        }

        let logger = Logger(subsystem: subsystem, category: category)
        lock.withLock {
            loggerByObjectIdentifier[objectIdentifier] = logger
        }
        return logger
    }

    var logger: Logger { Self.logger }

    static var category: String {
        .init(describing: self)
    }
    
    static var subsystem: String {
        Bundle(for: BundleClass.self).bundleIdentifier ?? .init(describing: self)
    }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension Loggable where Self: AnyObject {
    static var subsystem: String {
        Bundle(for: self).bundleIdentifier ?? .init(describing: self)
    }
}

private final class BundleClass {}

#endif
