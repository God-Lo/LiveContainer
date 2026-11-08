//
//  LCForkBackground.swift
//  LiveContainer (fork)
//
//  Background Events (LCBackgroundEvents.h): keeps the shared setting LiveContainer reads at start in step
//  with the app picked under App Extensions.
//

import Foundation

enum LCForkBackground {
    static let point = "lc.background-events"
    private static let appKey = "LCBackgroundEventsApp"
    private static let lastStartKey = "LCBackgroundEventsLastStart"

    static func sync() {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer else { return }
        let model = DataManager.shared.model
        let app = (model.apps + model.hiddenApps).map(\.appInfo).first { $0.isExtensionEnabled(point) }
        let urlTypes = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        if let folder = app?.relativeBundlePath, let scheme = (urlTypes?.first?["CFBundleURLSchemes"] as? [String])?.first {
            UserDefaults.lcShared().set(["folder": folder, "scheme": scheme], forKey: appKey)
        } else {
            UserDefaults.lcShared().removeObject(forKey: appKey)
            UserDefaults.lcShared().removeObject(forKey: lastStartKey)
        }
    }

    /// When LiveContainer last started the app for a background event.
    static var lastStart: Date? { UserDefaults.lcShared().object(forKey: lastStartKey) as? Date }
}
