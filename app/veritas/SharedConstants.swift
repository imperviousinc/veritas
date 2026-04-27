import Foundation

enum VeritasShared {
    static let appGroupID = "group.com.impervious.veritas"
    static let pendingQueryKey = "pendingShareQuery"
    static let urlScheme = "veritas"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}
