//
//  LCFork.swift
//  LiveContainer (fork)
//
//  The fork's entry points. Upstream files call these with one line each, so merging upstream
//  updates stays easy:
//  - LiveContainerSwiftUIApp: LCFork.appsLoaded(...) after the app list is read at launch
//  - LCAppListView: LCFork.appInstalled(...) after an install or update, LCFork.appRemoved(...) on delete
//  - LCAppSettingsView: LCForkAppSettingsSections(appInfo:) in each app's settings
//  - LCSettingsView: LCForkSettingsSection() (Check for Updates)
//

import SwiftUI

enum LCFork {
    private static func extensionInfo(_ app: LCAppInfo) -> [String: Any] {
        ["bundlePath": app.bundlePath() ?? "", "folder": app.relativeBundlePath ?? "", "isShared": app.isShared]
    }

    /// LiveContainer read its app list at launch.
    static func appsLoaded(_ apps: [LCAppInfo]) {
        LCGuestIntentsIndexer.reindex(apps: apps) {
            LCShortcutsSelfUpdate.cleanUpLeftovers()
            LCShortcutsSelfUpdate.offerIfNeeded(.launch)
        }
        if LCGuestIntentsIndexer.isPrimaryLiveContainer {
            LCGuestExtensionPreparer.syncApps(apps.map(extensionInfo))
        }
        LCForkUpdate.checkAtLaunch()
    }

    /// An app was installed, or updated (replacing the old copy).
    static func appInstalled(_ app: LCAppInfo, replacing old: LCAppInfo?, allApps: [LCAppInfo]) {
        if let old { app.shortcutsEnabled = old.shortcutsEnabled }
        if LCGuestIntentsIndexer.isPrimaryLiveContainer {
            let info = extensionInfo(app)
            LCGuestExtensionPreparer.prepareBundle(info["bundlePath"] as! String, folder: info["folder"] as! String,
                                                   isShared: app.isShared, completion: nil)
        }
        let others = allApps.filter { $0.bundleIdentifier() != app.bundleIdentifier() }
        LCGuestIntentsIndexer.reindex(apps: others + [app]) {
            if let id = app.bundleIdentifier() { LCShortcutsSelfUpdate.offerIfNeeded(.installed(bundleId: id)) }
        }
    }

    /// An app was deleted: drop its Shortcuts actions (picker now, merged actions at the next
    /// reinstall) and its extensions.
    static func appRemoved(_ app: LCAppInfo, remaining: [LCAppInfo]) {
        guard let removedId = app.bundleIdentifier() else { return }
        if let folder = app.relativeBundlePath { LCGuestExtensionPreparer.removeFolder(folder) }
        LCGuestIntentsIndexer.reindex(apps: remaining) {
            LCShortcutsSelfUpdate.offerIfNeeded(.uninstalled(bundleId: removedId, name: app.displayName() ?? removedId))
        }
    }
}

/// The fork's sections in an app's settings.
struct LCForkAppSettingsSections: View {
    let appInfo: LCAppInfo

    var body: some View {
        LCAppExtensionsSettingSection(appInfo: appInfo)
    }
}
