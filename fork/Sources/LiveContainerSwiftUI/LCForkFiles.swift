//
//  LCForkFiles.swift
//  LiveContainer (fork)
//
//  LiveContainer's locations in the Files app (fork/Extensions/AppsFileProvider): one per app with Files
//  turned on, served by the app's own File Provider when it has one and showing its Documents otherwise.
//  This keeps the list of those apps in the shared settings and registers exactly their locations,
//  removing any other.
//

import FileProvider
import Foundation

enum LCForkFiles {
    static let appsKey = "LCFilesApps"
    static func sync() {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer else { return }
        let model = DataManager.shared.model
        let apps = (model.apps + model.hiddenApps).map(\.appInfo).filter { $0.isExtensionEnabled(fileProviderPoint) }
        let list: [[String: Any]] = apps.compactMap { app in
            guard let folder = app.relativeBundlePath else { return nil }
            return ["folder": folder, "name": app.displayName() ?? folder, "isShared": app.isShared, "dataUUID": app.dataUUID ?? ""]
        }
        UserDefaults.lcShared().set(list, forKey: appsKey)
        // LiveContainer's File Provider (replicated) needs iOS 16.
        guard #available(iOS 16.0, *) else { return }
        let wanted = list.map { app in
            NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domainPrefix + (app["folder"] as! String)),
                                 displayName: app["name"] as! String)
        }
        let wantedIds = Set(wanted.map(\.identifier))
        // After a rebuild a location may be served differently (the app's own File Provider instead of
        // its Documents): start those afresh, so the Files app doesn't keep showing what it cached.
        let stamp = LCGuestExtensionBuilder.installedSignature()
        let reset = UserDefaults.lcShared().string(forKey: stampKey) != stamp
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if let error { NSLog("[LCForkFiles] list: \(error)") }
            let group = DispatchGroup()
            // Locations that are already there under the same name: nothing to register again.
            var kept: [NSFileProviderDomainIdentifier: String] = [:]
            // Locations added by apps on their own in earlier builds: only removeAllDomains reaches them,
            // because the hook that ignores apps' requests also covers removeDomain.
            if domains.contains(where: { !$0.identifier.rawValue.hasPrefix(domainPrefix) }) {
                group.enter()
                NSFileProviderManager.removeAllDomains { _ in group.leave() }
            } else {
                // Locations of deleted apps and of apps that turned Files off, and all of them after a rebuild.
                for domain in domains {
                    guard reset || !wantedIds.contains(domain.identifier) else {
                        kept[domain.identifier] = domain.displayName
                        continue
                    }
                    group.enter()
                    NSFileProviderManager.remove(domain) { error in
                        if let error { NSLog("[LCForkFiles] remove \(domain.identifier.rawValue): \(error)") }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                for domain in wanted {
                    // Have Files look again, so changes made inside the app show up.
                    let refresh = { NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { _ in } }
                    if kept[domain.identifier] == domain.displayName {
                        refresh()
                        continue
                    }
                    NSFileProviderManager.add(domain) { error in
                        if let error { NSLog("[LCForkFiles] add \(domain.identifier.rawValue): \(error)") }
                        refresh()
                    }
                }
                UserDefaults.lcShared().set(stamp, forKey: stampKey)
            }
        }
    }

    /// What the Files extension last reported for this app's location (fork/Extensions/AppsFileProvider).
    static func status(folder: String) -> String? {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LCSharedUtils.appGroupID()) else { return nil }
        return try? String(contentsOf: group.appendingPathComponent("LiveContainer/FilesStatus/\(folder).txt"), encoding: .utf8)
    }

    private static let stampKey = "LCFilesSyncedSignature"
    /// LiveContainer's own locations; apps' requests for other locations are ignored (LCGuestExtensionRuntime.m).
    static let domainPrefix = "lc.files."
    static let fileProviderPoint = "com.apple.fileprovider-nonui"
}
