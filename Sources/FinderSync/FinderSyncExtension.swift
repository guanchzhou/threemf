import Cocoa
import FinderSync
import os

private let log = Logger(subsystem: "com.andreymaltsev.3mf-quicklook", category: "FinderSync")

/// Right-click menu provider for `.3mf` / `.stl` files. Lists installed slicers
/// (Bambu Studio, OrcaSlicer, PrusaSlicer) and lets the user open the file in any of them.
final class FinderSyncExtension: FIFinderSync {
    private struct Slicer {
        let name: String
        let url: URL
    }

    /// Candidate slicer apps. Listed in user-preferred order; we filter to those installed.
    private static let candidates: [(name: String, paths: [String])] = [
        ("Bambu Studio", ["/Applications/BambuStudio.app", "/Applications/Bambu Studio.app"]),
        ("OrcaSlicer", ["/Applications/OrcaSlicer.app"]),
        ("PrusaSlicer", ["/Applications/PrusaSlicer.app"]),
    ]

    override init() {
        super.init()
        // FIFinderSyncController only fires callbacks for items inside watched directories.
        // We watch the user's home (Downloads/Documents/Desktop/iCloud Drive) and /Volumes
        // (USB drives, network mounts, external SSDs — common storage for 3D-print archives).
        // We don't badge anything — purely menu work.
        FIFinderSyncController.default().directoryURLs = [
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Volumes"),
        ]
        log.debug("FinderSync extension initialized")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        guard let selected = FIFinderSyncController.default().selectedItemURLs(),
              !selected.isEmpty,
              selected.allSatisfy({ url in
                  let ext = url.pathExtension.lowercased()
                  return ext == "3mf" || ext == "stl" || ext == "gcode"
              })
        else {
            return nil
        }

        let slicers = installedSlicers()
        guard !slicers.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        for slicer in slicers {
            let title = String(format: NSLocalizedString("Open in %@", comment: ""), slicer.name)
            let item = NSMenuItem(
                title: title,
                action: #selector(openInSlicer(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = slicer.url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openInSlicer(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL,
              let urls = FIFinderSyncController.default().selectedItemURLs(),
              !urls.isEmpty
        else { return }
        log.debug("Opening \(urls.count) item(s) in \(appURL.lastPathComponent, privacy: .public)")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config) { app, error in
            if let error {
                log.error("openInSlicer failed: \(error.localizedDescription, privacy: .public)")
            } else if let app {
                log.debug("Opened in \(app.bundleIdentifier ?? "unknown", privacy: .public)")
            }
        }
    }

    private func installedSlicers() -> [Slicer] {
        Self.candidates.compactMap { candidate in
            for path in candidate.paths where FileManager.default.fileExists(atPath: path) {
                return Slicer(name: candidate.name, url: URL(fileURLWithPath: path))
            }
            return nil
        }
    }
}
