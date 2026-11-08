//
//  LCForkBackground.swift
//  LiveContainer (fork)
//
//  Background Events (LCBackgroundEvents.h): the list of apps with it on, which LiveContainer and the
//  apps read from the app group, and starting LiveContainer's listener at launch.
//

import UIKit

enum LCForkBackground {
    static let point = "lc.background-events"

    /// From application(_:didFinishLaunchingWithOptions:): background task handlers must be registered there.
    static func start(_ launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer else { return }
        let options = Dictionary(uniqueKeysWithValues: (launchOptions ?? [:]).map { ($0.key.rawValue, $0.value) })
        LCBackgroundEventsHostStart(options)
    }

    static func sync() {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer, let folder = LCBackgroundEventsFolder() else { return }
        let model = DataManager.shared.model
        let apps = (model.apps + model.hiddenApps).map(\.appInfo).filter { $0.isExtensionEnabled(point) }.compactMap(\.relativeBundlePath)
        (apps as NSArray).write(toFile: folder + "/apps.plist", atomically: true)
        // Settings of the one-app version (3.8.11.18).
        UserDefaults.lcShared().removeObject(forKey: "LCBackgroundEventsApp")
        UserDefaults.lcShared().removeObject(forKey: "LCBackgroundEventsLastStart")
        // What deleted apps and apps with it off registered.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name != "apps.plist" {
            if !apps.contains((name as NSString).deletingPathExtension) {
                try? FileManager.default.removeItem(atPath: folder + "/" + name)
            }
        }
    }

    /// When LiveContainer last passed an event to this app.
    static func lastEvent(folder: String) -> Date? {
        (UserDefaults.lcShared().dictionary(forKey: "LCBackgroundEventsLast") as? [String: Date])?[folder]
    }
}
