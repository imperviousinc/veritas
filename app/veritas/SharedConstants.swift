import Foundation

enum VeritasShared {
    static let appGroupID = "group.com.impervious.veritas"
    static let pendingQueryKey = "pendingShareQuery"
    static let urlScheme = "veritas"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}

/// Local preferences persisted in UserDefaults.
enum AppSettings {
    static let rpcPortKey = "veritasRpcPort"
    static let excludeRelaysKey = "veritasExcludeRelays"

    static let defaultRpcPort: UInt32 = 12888
    /// Matches `query_handle::DEFAULT_EXCLUDE`. Empty saved value excludes none.
    static let defaultExcludeRelays = "http://70.251.209.207:47778"

    static var rpcPort: UInt32 {
        get {
            guard UserDefaults.standard.object(forKey: rpcPortKey) != nil else {
                return defaultRpcPort
            }
            let value = UserDefaults.standard.integer(forKey: rpcPortKey)
            if value >= 1 && value <= 65535 {
                return UInt32(value)
            }
            return defaultRpcPort
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: rpcPortKey)
        }
    }

    /// Digits only — SwiftUI number interpolation inserts grouping commas.
    static func portText(_ port: UInt32) -> String {
        String(port)
    }

    static var excludeRelays: String {
        get {
            guard UserDefaults.standard.object(forKey: excludeRelaysKey) != nil else {
                return defaultExcludeRelays
            }
            return UserDefaults.standard.string(forKey: excludeRelaysKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: excludeRelaysKey)
        }
    }
}
