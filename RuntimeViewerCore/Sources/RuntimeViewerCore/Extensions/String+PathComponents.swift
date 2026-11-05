import Foundation

extension String {
    func removeFirstPathComponent() -> String {
        let isAbsolute = hasPrefix("/")
        var components = split(separator: "/", omittingEmptySubsequences: true)

        guard !components.isEmpty else {
            return isAbsolute ? "/" : ""
        }

        components.removeFirst()

        if components.isEmpty {
            return isAbsolute ? "/" : ""
        }

        return isAbsolute ? "/" + components.joined(separator: "/") : components.joined(separator: "/")
    }
}
