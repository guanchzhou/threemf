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

    /// Snapshotted at init so `menu(for:)` does not restat /Applications on every click.
    private let slicers: [Slicer]

    override init() {
        slicers = Self.discoverInstalledSlicers()
        super.init()
        // FIFinderSyncController only fires callbacks for items inside watched directories.
        // Watch the home directory plus local mounted volumes only — skip network shares.
        FIFinderSyncController.default().directoryURLs = Self.watchedDirectories()
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

    private static func discoverInstalledSlicers() -> [Slicer] {
        candidates.compactMap { candidate in
            for path in candidate.paths where FileManager.default.fileExists(atPath: path) {
                return Slicer(name: candidate.name, url: URL(fileURLWithPath: path))
            }
            return nil
        }
    }

    /// Home directory plus locally attached volumes (USB, external SSDs). Network
    /// mounts are excluded via `volumeIsLocalKey`.
    private static func watchedDirectories() -> Set<URL> {
        var urls: Set<URL> = [FileManager.default.homeDirectoryForCurrentUser]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes {
            let isLocal = (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
            guard isLocal else { continue }
            urls.insert(volume)
        }
        return urls
    }
}
