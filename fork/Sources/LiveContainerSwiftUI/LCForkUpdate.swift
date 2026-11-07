//
//  LCForkUpdate.swift
//  LiveContainer (fork)
//
//  Checks this fork's source for a newer release, at launch and from Settings → Check for Updates.
//  "Update" downloads the IPA and hands it to the built-in SideStore, which reinstalls LiveContainer
//  over itself (same App ID, data kept). Doesn't depend on SideStore noticing the update.
//

import SwiftUI
import UIKit

enum LCForkUpdate {
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/God-Lo/LiveContainer/main/source.json")!
    private static let dismissedKey = "LCForkUpdateDismissedBuild"

    struct Release {
        let build: String
        let notes: String
        let downloadURL: URL
    }

    /// This install's build, e.g. "3.8.11.4".
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Numeric, part by part: 3.8.11.10 is newer than 3.8.11.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func fetchLatest() async throws -> Release? {
        // Skip local and CDN caches so a release shows up right away.
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let app = (json?["apps"] as? [[String: Any]])?.first
        guard let latest = (app?["versions"] as? [[String: Any]])?.first,
              let build = latest["buildVersion"] as? String ?? latest["version"] as? String,
              let url = (latest["downloadURL"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(build: build, notes: latest["localizedDescription"] as? String ?? "", downloadURL: url)
    }

    /// At launch: offer a newer release once per release.
    static func checkAtLaunch() {
        guard LCGuestIntentsIndexer.isPrimaryLiveContainer, UserDefaults.sideStoreExist() else { return }
        Task {
            guard let release = try? await fetchLatest(), isNewer(release.build, than: currentBuild),
                  UserDefaults.standard.string(forKey: dismissedKey) != release.build else { return }
            await MainActor.run { offer(release, rememberLater: true) }
        }
    }

    /// From Settings: always reports the result.
    @MainActor
    static func checkNow() async {
        do {
            guard let release = try await fetchLatest() else { return present("Couldn't read the update source.") }
            if isNewer(release.build, than: currentBuild) {
                offer(release, rememberLater: false)
            } else {
                present("LiveContainer is up to date (\(currentBuild)).")
            }
        } catch {
            present("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func offer(_ release: Release, rememberLater: Bool) {
        guard UserDefaults.sideStoreExist() else {
            return present("Version \(release.build) is available. Updating needs LiveContainer+SideStore; download it from the fork's Releases page.")
        }
        let alert = UIAlertController(title: "Update to \(release.build)?",
                                      message: release.notes + "\n\nThe built-in SideStore reinstalls LiveContainer. Your data is kept.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Later", style: .cancel) { _ in
            if rememberLater { UserDefaults.standard.set(release.build, forKey: dismissedKey) }
        })
        alert.addAction(UIAlertAction(title: "Update", style: .default) { _ in install(release) })
        topViewController()?.present(alert, animated: true)
    }

    @MainActor
    private static func install(_ release: Release) {
        let progress = UIAlertController(title: "Downloading \(release.build)…", message: nil, preferredStyle: .alert)
        topViewController()?.present(progress, animated: true)
        Task {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: release.downloadURL)
                // Same place as the Shortcuts self-update; cleaned up at the next launch.
                let dir = LCPath.docPath.appendingPathComponent("LCSelfUpdate")
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let ipa = dir.appendingPathComponent("LiveContainer.ipa")
                try FileManager.default.moveItem(at: tmp, to: ipa)
                await MainActor.run {
                    progress.dismiss(animated: true) { LCUtils.openSideStore(urlStr: ipa.absoluteString) }
                }
            } catch {
                await MainActor.run {
                    progress.dismiss(animated: true) { present("Download failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    @MainActor
    private static func present(_ message: String) {
        let alert = UIAlertController(title: "Updates", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topViewController()?.present(alert, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// The fork's section in LiveContainer's Settings.
struct LCForkSettingsSection: View {
    @State private var checking = false

    var body: some View {
        Section {
            Button {
                checking = true
                Task {
                    await LCForkUpdate.checkNow()
                    checking = false
                }
            } label: {
                HStack {
                    Text("Check for Updates")
                    Spacer()
                    if checking { ProgressView() }
                }
            }
            .disabled(checking)
        } header: {
            Text("LiveContainer Fork")
        } footer: {
            Text("Build \(LCForkUpdate.currentBuild). Updates come from github.com/God-Lo/LiveContainer.")
        }
    }
}
