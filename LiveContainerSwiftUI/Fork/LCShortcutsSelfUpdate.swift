//
//  LCShortcutsSelfUpdate.swift
//  LiveContainer (fork)
//
//  After an app with Shortcuts actions is installed, offers to register its actions: LiveContainer
//  builds an updated copy of itself with the actions merged in and hands it to the built-in
//  SideStore, which reinstalls LiveContainer over itself (same App IDs, data kept). iOS only reads
//  App Intents metadata when an app is installed, so a reinstall is the only way to add actions.
//

import Foundation
import UIKit

enum LCShortcutsSelfUpdate {
    /// Signature the user chose "Later" for, so we ask once per change.
    private static let dismissedKey = "LCShortcutsSelfUpdateDismissedSignature"

    enum Reason {
        /// LiveContainer started: catches apps installed before this fork, or changes made elsewhere.
        case launch
        case installed(bundleId: String)
        case uninstalled(bundleId: String, name: String)
    }

    /// Bundle IDs whose actions are merged into the running LiveContainer.
    static var mergedBundleIds: Set<String> {
        let url = Bundle.main.bundleURL.appendingPathComponent(LCGuestIntentsMerger.mapFile)
        let map = NSDictionary(contentsOf: url) as? [String: [String: String]] ?? [:]
        return Set(map.values.compactMap { $0["bundleId"] })
    }

    /// Called once the guest index is up to date. Never asks for apps without Shortcuts actions.
    static func offerIfNeeded(_ reason: Reason) {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer else { return }
        let guests = LCGuestIntentsMerger.loadGuests()
        let signature = guests.isEmpty ? "" : LCGuestIntentsMerger.signature(of: guests)
        guard signature != LCGuestIntentsMerger.installedSignature else { return }
        var removedName: String? = nil
        switch reason {
        case .installed(let bundleId):
            // Only apps with the Shortcuts switch on are indexed, so new apps (off by default) never ask.
            guard guests.contains(where: { $0.bundleId == bundleId }) else { return }
        case .uninstalled(let bundleId, let name):
            // Only apps whose actions are currently registered need a reinstall to remove them.
            guard mergedBundleIds.contains(bundleId) else { return }
            removedName = name
        case .launch:
            if UserDefaults.standard.string(forKey: dismissedKey) == signature { return }
        }
        let names = guests.map(\.name).joined(separator: ", ")
        DispatchQueue.main.async {
            guard UserDefaults.sideStoreExist() else {
                present(title: "Shortcuts actions",
                        message: "Adding apps' Shortcuts actions needs LiveContainer+SideStore, which reinstalls LiveContainer with the actions included.")
                return
            }
            let how = "LiveContainer will rebuild itself and the built-in SideStore will reinstall it. Your data is kept. In SideStore, keep app extensions using the main profile so no new App IDs are used."
            let message: String
            if let removedName {
                message = "Remove the Shortcuts actions of \(removedName), which you deleted? " + how
            } else {
                message = "Update the Shortcuts actions for \(names)? " + how
            }
            let alert = UIAlertController(title: "Update Shortcuts actions", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Later", style: .cancel) { _ in
                UserDefaults.standard.set(signature, forKey: dismissedKey)
            })
            alert.addAction(UIAlertAction(title: "Update", style: .default) { _ in run(guests: guests) })
            topViewController()?.present(alert, animated: true)
        }
    }

    /// Removes what an on-phone update leaves behind: the IPA LiveContainer built, its work folder, and
    /// the copies SideStore makes while installing it (tmp/<UUID>/LiveContainer.ipa, and its signing
    /// working folders tmp/<UUID>/App.ipa + App.app, which SideStore doesn't delete). Called at launch,
    /// so an update that just finished is never in progress. Only folders older than 10 minutes that
    /// contain nothing but those files are touched; guest apps' own temporary files are left alone.
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

    /// The Shortcuts switch in an app's settings changed: apply it right away, no extra prompt.
    static func applySettingChange() {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer else { return }
        let model = DataManager.shared.model
        let apps = (model.apps + model.hiddenApps).map { $0.appInfo }
        LCGuestIntentsIndexer.reindex(apps: apps) {
            let guests = LCGuestIntentsMerger.loadGuests()
            let signature = guests.isEmpty ? "" : LCGuestIntentsMerger.signature(of: guests)
            // Switched back before anything was applied: nothing to do.
            guard signature != LCGuestIntentsMerger.installedSignature else { return }
            DispatchQueue.main.async {
                guard UserDefaults.sideStoreExist() else {
                    present(title: "Shortcuts",
                            message: "Changing apps' Shortcuts actions needs LiveContainer+SideStore, which reinstalls LiveContainer with the actions included.")
                    return
                }
                run(guests: guests)
            }
        }
    }

    static func run(guests: [LCGuestIntentsMerger.Guest]) {
        let progress = UIAlertController(title: "Preparing LiveContainer…", message: nil, preferredStyle: .alert)
        topViewController()?.present(progress, animated: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<URL, Error> {
                let app = try LCSelfIPABuilder.prepareBundle()
                try LCGuestIntentsMerger.merge(into: app, guests: guests)
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
