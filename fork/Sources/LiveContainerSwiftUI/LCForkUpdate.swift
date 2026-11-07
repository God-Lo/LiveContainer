//
//  LCForkUpdate.swift
//  LiveContainer (fork)
//
//  Checks this fork's source for a newer release, at launch and from Settings → Check for Updates, and
//  offers to open the built-in SideStore on My Apps, where the user taps Update. SideStore fetches the
//  source fresh too (SideStoreHooks.m), so it shows the same release.
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

    /// The same file through GitHub's API, which serves the latest commit (raw.githubusercontent.com can
    /// keep serving an older copy for several minutes, query string or not).
    static let apiSourceURL = URL(string: "https://api.github.com/repos/God-Lo/LiveContainer/contents/source.json")!

    static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: apiSourceURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        var (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            // API limit reached (60 an hour): fall back to the plain link.
            (data, _) = try await URLSession.shared.data(for: URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        }
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
        let alert = UIAlertController(title: "Version \(release.build) is available",
                                      message: release.notes + "\n\nOpen SideStore's My Apps and tap Update. Your data is kept.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Later", style: .cancel) { _ in
            if rememberLater { UserDefaults.standard.set(release.build, forKey: dismissedKey) }
        })
        alert.addAction(UIAlertAction(title: "Open SideStore", style: .default) { _ in
            // SideStoreHooks.m switches to My Apps when it sees this.
            UserDefaults.lcShared().set(true, forKey: "LCSideStoreOpenMyApps")
            LCUtils.openSideStore()
        })
        topViewController()?.present(alert, animated: true)
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

/// The fork's sections in LiveContainer's Settings.
struct LCForkSettingsSection: View {
    @State private var checking = false

    var body: some View {
        LCSingleAppExtensionsSection()
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
