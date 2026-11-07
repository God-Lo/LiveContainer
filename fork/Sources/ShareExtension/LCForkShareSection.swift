//
//  LCForkShareSection.swift
//  LiveContainer (fork)
//
//  "Share With" in LiveContainer's share menu: apps' own share extensions (turned on with Share under
//  App Extensions in each app's settings). Tapping one runs that app's share screen.
//

import SwiftUI
import UIKit

struct LCForkShareSection: View {
    let extensionContext: NSExtensionContext?
    @State private var entries: [[String: Any]] = LCForkShare.entries() as? [[String: Any]] ?? []
    @State private var host = HostHolder()
    @State private var errorText: String?

    final class HostHolder { weak var controller: UIViewController? }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Share With").font(.headline)
                ForEach(entries.indices, id: \.self) { i in
                    Button {
                        guard let controller = host.controller else { return }
                        var error: NSString?
                        if !LCForkShare.openEntry(entries[i], context: extensionContext, from: controller, error: &error) {
                            errorText = error as String? ?? "Couldn't open it."
                        }
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text(entries[i]["name"] as? String ?? "App")
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }
            .background(HostFinder(holder: host))
        }
    }

    /// Finds the view controller presenting this menu, to show the app's share screen over it.
    private struct HostFinder: UIViewControllerRepresentable {
        let holder: HostHolder
        func makeUIViewController(context: Context) -> UIViewController {
            let vc = Finder()
            vc.holder = holder
            return vc
        }
        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

        final class Finder: UIViewController {
            var holder: HostHolder?
            override func didMove(toParent parent: UIViewController?) {
                super.didMove(toParent: parent)
                holder?.controller = parent
            }
            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                holder?.controller = parent ?? self
            }
        }
    }
}
