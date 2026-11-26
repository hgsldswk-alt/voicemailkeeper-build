import Foundation

enum Launch {
    static let freePeriod = false
    static let group = "group.com.hgsldswk.voicemailkeeper"
    static let arguments = ProcessInfo.processInfo.arguments

    static var testing: Bool {
        #if DEBUG
        arguments.contains("-ui-testing")
        #else
        false
        #endif
    }

    static var reset: Bool { testing && arguments.contains("-reset") }
    static var seed: Bool { testing && arguments.contains("-seed") }
    static var storeShots: Bool { testing && arguments.contains("-store-shot") }
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static func container() throws -> URL {
        if testing {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("UITestVault", isDirectory: true)
        }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw KeeperError.storage
        }
        return url.appendingPathComponent("VoiceVault", isDirectory: true)
    }

    static var defaults: UserDefaults {
        if testing { return UserDefaults(suiteName: group + ".uitest") ?? .standard }
        return .standard
    }
}
