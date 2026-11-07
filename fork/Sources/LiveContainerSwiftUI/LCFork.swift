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
    /// LiveContainer read its app list at launch.
    static func appsLoaded(_ apps: [LCAppInfo]) {
        LCSelfUpdate.cleanUpLeftovers()
        LCForkFiles.sync()
        LCGuestIntentsIndexer.reindex(apps: apps) {
            LCSelfUpdate.offerIfNeeded(.launch)
        }
        LCForkUpdate.checkAtLaunch()
    }

    /// An app was installed, or updated (replacing the old copy): keep its switches.
    static func appInstalled(_ app: LCAppInfo, replacing old: LCAppInfo?, allApps: [LCAppInfo]) {
        if let old {
            app.shortcutsEnabled = old.shortcutsEnabled
            app.enabledExtensionPoints = old.enabledExtensionPoints
        }
        let others = allApps.filter { $0.bundleIdentifier() != app.bundleIdentifier() }
        LCGuestIntentsIndexer.reindex(apps: others + [app]) {
            if let id = app.bundleIdentifier() { LCSelfUpdate.offerIfNeeded(.installed(bundleId: id)) }
        }
    }

    /// An app was deleted: offer to remove what it added to LiveContainer, and delete the data its
    /// extensions kept in the app group.
    static func appRemoved(_ app: LCAppInfo, remaining: [LCAppInfo]) {
        guard let removedId = app.bundleIdentifier() else { return }
        let folder = app.relativeBundlePath ?? ""
        if !folder.isEmpty, let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LCSharedUtils.appGroupID()) {
            try? FileManager.default.removeItem(at: group.appendingPathComponent("LiveContainer/Data/ExtensionHome/\(folder)"))
        }
        LCForkFiles.sync()
        LCGuestIntentsIndexer.reindex(apps: remaining) {
            LCSelfUpdate.offerIfNeeded(.uninstalled(bundleId: removedId, folder: folder, name: app.displayName() ?? removedId))
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
