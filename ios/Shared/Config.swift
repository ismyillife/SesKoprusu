import Foundation

enum Config {
    /// Android tarafındaki NsdManager kaydıyla aynı olmalı.
    static let serviceType = "_seskoprusu._tcp"
    static let port: UInt16 = 50505
    static let manualHostKey = "manualHost"

    /// Ana uygulamanın paket kimliği (uzantının içinden çağrılsa bile).
    static var appBundleID: String {
        var id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".broadcast") { id.removeLast(".broadcast".count) }
        return id
    }

    static var extensionBundleID: String { appBundleID + ".broadcast" }

    static var appGroup: String { "group." + appBundleID }

    /// App Group yetkisi etkinse paylaşılan ayarlar; değilse nil (elle IP özelliği gizlenir).
    static var sharedDefaults: UserDefaults? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil else {
            return nil
        }
        return UserDefaults(suiteName: appGroup)
    }
}
