//
//  LCForkFiles.swift
//  LiveContainer (fork)
//
//  LiveContainer's locations in the Files app (fork/Extensions/AppsFileProvider): one per app with Files
//  turned on ("LiveContainer – <App>"), showing its Documents. This keeps the list of those apps in the
//  shared settings and registers exactly their locations, removing any other.
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
        let addWanted = {
            for domain in wanted {
                NSFileProviderManager.add(domain) { error in
                    if let error { NSLog("[LCForkFiles] add \(domain.identifier.rawValue): \(error)") }
                    NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { _ in }
                }
            }
        }
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            // Locations of apps that turned Files off, and ones apps added on their own in earlier builds.
            // removeAllDomains, because the hook that ignores apps' requests also covers removeDomain.
            if domains.contains(where: { !wantedIds.contains($0.identifier) }) {
                NSFileProviderManager.removeAllDomains { _ in addWanted() }
            } else {
                addWanted()
            }
        }
    }

    /// LiveContainer's own locations; apps' requests for other locations are ignored (LCGuestExtensionRuntime.m).
    static let domainPrefix = "lc.files."
    static let fileProviderPoint = "com.apple.fileprovider-nonui"
}
