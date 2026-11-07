//
//  LCGuestIntentsIndexer.swift
//  LiveContainer (fork)
//
//  Records each guest app's App Intents metadata so LCShortcutsSelfUpdate can merge it into
//  LiveContainer's own bundle and reinstall LiveContainer through SideStore, and publishes the guest
//  list used by the "Open App" / "Open URL in App" Shortcuts actions in LaunchAppExtension.
//
//  Layout written to Documents/LCGuestIntents:
//    <bundleId>/info.plist                        {bundleId, name}
//    <bundleId>/Metadata/<n>/extract.actionsdata  copy of each Metadata.appintents in the guest
//    <bundleId>/Strings/<table>.strings           the guest's English strings, to resolve action titles
//

import Foundation

enum LCGuestIntentsIndexer {
    /// Shortcuts are managed only by the primary LiveContainer. LiveContainer2 and later copies share
    /// its app group (so they must not overwrite the guest list) and have no SideStore to reinstall with.
    static var isPrimaryLiveContainer: Bool {
        LCUtils.appUrlScheme()?.lowercased() == "livecontainer"
    }

    static let rootURL = LCPath.docPath.appendingPathComponent("LCGuestIntents")
    /// lcShared defaults key read by LaunchAppExtension's guest app picker.
    static let guestListKey = "LCShortcutGuestApps"

    /// Every Metadata.appintents folder in a guest bundle: the app's own and each framework's.
    static func metadataFolders(in bundleURL: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        let own = bundleURL.appendingPathComponent("Metadata.appintents")
        if fm.fileExists(atPath: own.appendingPathComponent("extract.actionsdata").path) {
            found.append(own)
        }
        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        for name in (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? [] where name.hasSuffix(".framework") {
            let meta = frameworks.appendingPathComponent(name).appendingPathComponent("Metadata.appintents")
            if fm.fileExists(atPath: meta.appendingPathComponent("extract.actionsdata").path) {
                found.append(meta)
            }
        }
        return found
    }

    /// Copies one guest's metadata into the index. Hidden apps are left out on purpose.
    static func index(_ app: LCAppInfo) {
        guard let bundleId = app.bundleIdentifier() else { return }
        let fm = FileManager.default
        let dest = rootURL.appendingPathComponent(bundleId)
        try? fm.removeItem(at: dest)
        // Only apps whose Shortcuts switch is on (app settings) get their actions registered.
        if app.isHidden || !app.shortcutsEnabled { return }
        let folders = metadataFolders(in: URL(fileURLWithPath: app.bundlePath()))
        guard !folders.isEmpty else { return }
        do {
            try fm.createDirectory(at: dest.appendingPathComponent("Metadata"), withIntermediateDirectories: true)
            for (i, folder) in folders.enumerated() {
                try fm.copyItem(at: folder, to: dest.appendingPathComponent("Metadata/\(i)"))
            }
            copyEnglishStrings(from: URL(fileURLWithPath: app.bundlePath()), to: dest.appendingPathComponent("Strings"))
            let info: [String: Any] = ["bundleId": bundleId, "name": app.displayName() ?? bundleId]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: dest.appendingPathComponent("info.plist"))
        } catch {
            NSLog("[LC] failed to index App Intents for \(bundleId): \(error)")
        }
    }

    /// Action titles are often localization keys; keep the English tables so the merge can show real text.
    static func copyEnglishStrings(from bundleURL: URL, to dest: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        // Base first, then en overrides it.
        for lproj in ["Base.lproj", "en.lproj"] {
            let dir = bundleURL.appendingPathComponent(lproj)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".strings") {
                let target = dest.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try? fm.copyItem(at: dir.appendingPathComponent(name), to: target)
            }
        }
    }

    /// Rebuilds the whole index and the Shortcuts guest list from the current app list.
    static func reindex(apps: [LCAppInfo], completion: (() -> Void)? = nil) {
        guard isPrimaryLiveContainer else { return }
        DispatchQueue.global(qos: .utility).async {
            defer { completion?() }
            let fm = FileManager.default
            try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let visible = apps.filter { !$0.isHidden }
            let keep = Set(visible.filter(\.shortcutsEnabled).compactMap { $0.bundleIdentifier() })
            for name in (try? fm.contentsOfDirectory(atPath: rootURL.path)) ?? [] where !keep.contains(name) {
                try? fm.removeItem(at: rootURL.appendingPathComponent(name))
            }
            visible.forEach(index)
            publishGuestList(visible)
        }
    }

    static func publishGuestList(_ apps: [LCAppInfo]) {
        let list: [[String: String]] = apps.compactMap { app in
            guard let id = app.bundleIdentifier(), !app.isHidden else { return nil }
            // "folder" is what LiveContainer launch URLs use (bundle-name), not the bundle ID.
            return ["bundleId": id, "name": app.displayName() ?? id, "folder": app.relativeBundlePath ?? "\(id).app"]
        }
        UserDefaults.lcShared().set(list, forKey: guestListKey)
    }
}
