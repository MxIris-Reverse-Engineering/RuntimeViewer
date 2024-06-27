import Foundation

//#if targetEnvironment(macCatalyst)

@objcMembers
@dynamicMemberLookup
class AppKitBridge: NSObject {
    static let shared = AppKitBridge()
    
    var plugin: AppKitPlugin?

    enum Error: Swift.Error {
        case failedCreateBundlePath
        case failedLoadBundleFile
        case failedLoadPrincipalClass
    }

    func loadPlugins() throws {
        guard let bundlePath = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RuntimeViewerCatalystHelperPlugin.bundle").path else {
            throw Error.failedCreateBundlePath
        }

        guard let bundle = Bundle(path: bundlePath) else {
            throw Error.failedLoadBundleFile
        }
        
        guard let principalClass = bundle.principalClass as? AppKitPlugin.Type else {
            throw Error.failedLoadPrincipalClass
        }

        AppKitBridge.shared.plugin = principalClass.init()
    }
    
    subscript<Property>(dynamicMember keyPath: KeyPath<AppKitPlugin, Property>) -> Property {
        get {
            if let plugins = plugin {
               return plugins[keyPath: keyPath]
            } else {
                fatalError("请在成功加载插件后再访问成员")
            }
        }
    }
    
    subscript<Property>(dynamicMember keyPath: WritableKeyPath<AppKitPlugin, Property>) -> Property {
        set {
            if var plugins = plugin {
                plugins[keyPath: keyPath] = newValue
            } else {
                fatalError("请在成功加载插件后再访问成员")
            }
            
        }
        get {
            if let plugins = plugin {
               return plugins[keyPath: keyPath]
            } else {
                fatalError("请在成功加载插件后再访问成员")
            }
        }
    }
}
//#endif
