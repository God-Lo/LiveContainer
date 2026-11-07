//
//  LCSelfUpdate.swift
//  LiveContainer (fork)
//
//  Adds apps' Shortcuts actions and extensions to LiveContainer: builds an updated copy of itself with
//  the actions merged in (LCGuestIntentsMerger) and the apps' extensions copied in
//  (LCGuestExtensionBuilder), and hands it to the built-in SideStore, which reinstalls LiveContainer
//  over itself (same App IDs, data kept). iOS only reads these when an app is installed, so a reinstall
//  is the only way to add them.
//

import Foundation
import UIKit

enum LCSelfUpdate {
    /// What the user chose "Later" for, so we ask once per change.
    private static let dismissedKey = "LCShortcutsSelfUpdateDismissedSignature"

    enum Reason {
        /// LiveContainer started: catches changes made elsewhere or before this version.
        case launch
        case installed(bundleId: String)
        case uninstalled(bundleId: String, folder: String, name: String)
    }

    private static var allApps: [LCAppInfo] {
        let model = DataManager.shared.model
        return (model.apps + model.hiddenApps).map { $0.appInfo }
    }

    /// Apps with extensions turned on, as LCGuestExtensionBuilder expects them.
    static func extensionApps(_ apps: [LCAppInfo]) -> [[String: Any]] {
        apps.compactMap { app in
            let points = app.enabledExtensionPoints.intersection(app.supportedExtensionPoints)
            guard !points.isEmpty, let folder = app.relativeBundlePath else { return nil }
            return ["bundlePath": app.bundlePath() ?? "", "folder": folder, "isShared": app.isShared,
                    "name": app.displayName() ?? folder, "bundleId": app.bundleIdentifier() ?? "",
                    "points": Array(points)]
        }
    }

    private struct Pending {
        let guests: [LCGuestIntentsMerger.Guest]
        let extensionApps: [[String: Any]]
        let signature: String
        let needed: Bool
    }

    private static func pending(_ apps: [LCAppInfo]) -> Pending {
        let guests = LCGuestIntentsMerger.loadGuests()
        let intents = guests.isEmpty ? "" : LCGuestIntentsMerger.signature(of: guests)
        let extApps = extensionApps(apps)
        let extensions = LCGuestExtensionBuilder.signature(forApps: extApps)
        let needed = intents != LCGuestIntentsMerger.installedSignature || extensions != LCGuestExtensionBuilder.installedSignature()
        return Pending(guests: guests, extensionApps: extApps, signature: intents + "|" + extensions, needed: needed)
    }

    /// Called once the Shortcuts index is up to date. Never asks for apps with nothing turned on.
    static func offerIfNeeded(_ reason: Reason) {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer else { return }
        let apps = allApps
        let p = pending(apps)
        guard p.needed else { return }
        var removedName: String? = nil
        switch reason {
        case .installed(let bundleId):
            guard apps.first(where: { $0.bundleIdentifier() == bundleId })?.hasFeaturesEnabled == true else { return }
        case .uninstalled(let bundleId, let folder, let name):
            guard mergedBundleIds.contains(bundleId) || LCGuestExtensionBuilder.installedFolders().contains(folder) else { return }
            removedName = name
        case .launch:
            if UserDefaults.standard.string(forKey: dismissedKey) == p.signature { return }
        }
        DispatchQueue.main.async {
            guard UserDefaults.sideStoreExist() else {
                present(title: "App Extensions",
                        message: "Adding apps' Shortcuts actions and extensions needs LiveContainer+SideStore, which reinstalls LiveContainer with them included.")
                return
            }
            let what = removedName.map { "Remove what \($0) added to LiveContainer?" }
                ?? "Update the Shortcuts actions and extensions LiveContainer includes for your apps?"
            let alert = UIAlertController(title: "Update LiveContainer", message: what + " " + how, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Later", style: .cancel) { _ in
                UserDefaults.standard.set(p.signature, forKey: dismissedKey)
            })
            alert.addAction(UIAlertAction(title: "Update", style: .default) { _ in run(p) })
            topViewController()?.present(alert, animated: true)
        }
    }

    private static let how = "LiveContainer rebuilds itself and the built-in SideStore reinstalls it. Your data is kept."

    /// Bundle IDs whose Shortcuts actions are merged into the running LiveContainer.
    static var mergedBundleIds: Set<String> {
        let url = Bundle.main.bundleURL.appendingPathComponent(LCGuestIntentsMerger.mapFile)
        let map = NSDictionary(contentsOf: url) as? [String: [String: String]] ?? [:]
        return Set(map.values.compactMap { $0["bundleId"] })
    }

    /// A switch under App Extensions changed: apply it right away, no extra prompt.
    static func applySettingChange() {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer else { return }
        let apps = allApps
        LCForkFiles.sync()
        LCGuestIntentsIndexer.reindex(apps: apps) {
            let p = pending(apps)
            // Switched back before anything was applied: nothing to do.
            guard p.needed else { return }
            DispatchQueue.main.async {
                guard UserDefaults.sideStoreExist() else {
                    present(title: "App Extensions",
                            message: "This needs LiveContainer+SideStore, which reinstalls LiveContainer with your apps' actions and extensions included.")
                    return
                }
                run(p)
            }
        }
    }

    private static func run(_ p: Pending) {
        let progress = UIAlertController(title: "Preparing LiveContainer…", message: nil, preferredStyle: .alert)
        topViewController()?.present(progress, animated: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<URL, Error> {
                let app = try LCSelfIPABuilder.copyBundle()
                try LCGuestIntentsMerger.merge(into: app, guests: p.guests)
                try LCGuestExtensionBuilder.addExtensions(ofApps: p.extensionApps, toApp: app)
                try LCSelfIPABuilder.signBundle(app)
                return try LCSelfIPABuilder.archivePreparedBundle()
            }
            DispatchQueue.main.async {
                progress.dismiss(animated: true) {
                    switch result {
                    case .success(let ipa):
                        LCUtils.openSideStore(urlStr: ipa.absoluteString)
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("LCSelfUpdate"))
                        present(title: "Couldn't prepare the update", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Removes what an on-phone update leaves behind: the IPA LiveContainer built, its work folder, and
    /// the copies SideStore makes while installing it (tmp/<UUID>/LiveContainer.ipa, and its signing
    /// working folders tmp/<UUID>/App.ipa + App.app, which SideStore doesn't delete). Called at launch,
    /// so an update that just finished is never in progress. Only folders older than 10 minutes that
    /// contain nothing but those files are touched; apps' own temporary files are left alone.
    static func cleanUpLeftovers() {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer else { return }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.removeItem(at: LCPath.docPath.appendingPathComponent("LCSelfUpdate"))
            let tmp = fm.temporaryDirectory
            try? fm.removeItem(at: tmp.appendingPathComponent("LCSelfUpdate"))
            let installFiles: Set<String> = ["LiveContainer.ipa", "App.ipa", "App.app"]
            let cutoff = Date().addingTimeInterval(-10 * 60)
            for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] {
                // SideStore names these folders <UUID>-<pid>-<hex>.
                guard name.range(of: #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}-"#,
                                 options: .regularExpression) != nil else { continue }
                let dir = tmp.appendingPathComponent(name)
                guard let contents = try? fm.contentsOfDirectory(atPath: dir.path), !contents.isEmpty,
                      Set(contents).isSubset(of: installFiles),
                      let modified = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date,
                      modified < cutoff else { continue }
                try? fm.removeItem(at: dir)
            }
        }
    }

    private static func present(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topViewController()?.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
