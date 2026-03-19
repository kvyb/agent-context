import Foundation

enum SystemAppDenylist {
    private static let deniedBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.UserNotificationCenter"
    ]

    private static let deniedBundleIDPrefixes: [String] = [
        "com.apple.ScreenSaver"
    ]

    private static let deniedAppNames: Set<String> = [
        "loginwindow",
        "coreautha",
        "universalaccessauthwarn",
        "usersnotificationcenter",
        "usernotificationcenter"
    ]

    static func isDenied(appName: String?, bundleID: String?) -> Bool {
        if let normalizedBundleID = normalize(bundleID) {
            if deniedBundleIDs.contains(normalizedBundleID) {
                return true
            }
            if deniedBundleIDPrefixes.contains(where: { normalizedBundleID.hasPrefix($0) }) {
                return true
            }
        }

        if let normalizedName = normalize(appName)?.lowercased(),
           deniedAppNames.contains(normalizedName) {
            return true
        }

        return false
    }

    private static func normalize(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return nil
    }
}
