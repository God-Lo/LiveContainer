//
//  LCForkFiles.swift
//  LiveContainer (fork)
//
//  LiveContainer's location in the Files app (fork/Extensions/AppsFileProvider): one folder per app with
//  Files turned on, showing its Documents. This keeps the list of those apps in the shared settings and
//  the location registered while any app uses it.
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
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("LiveContainer"), displayName: "LiveContainer")
        // Locations apps added on their own in earlier builds aren't used any more: remove them all (the
        // hook that ignores apps' requests doesn't apply to removeAllDomains), then add LiveContainer's.
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            let stale = domains.contains { $0.identifier != domain.identifier }
            let finish = {
                if list.isEmpty {
                    NSFileProviderManager.remove(domain) { _ in }
                } else {
                    NSFileProviderManager.add(domain) { error in
                        if let error { NSLog("[LCForkFiles] add domain: \(error)") }
                        NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { _ in }
                    }
                }
            }
            if stale {
                NSFileProviderManager.removeAllDomains { _ in finish() }
            } else {
                finish()
            }
        }
    }

    static let fileProviderPoint = "com.apple.fileprovider-nonui"
}
