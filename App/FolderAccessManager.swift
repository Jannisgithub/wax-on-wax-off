import AppKit
import Foundation

@MainActor
final class FolderAccessManager {
    private let bookmarkFileName = "authorized-home.bookmark"

    func authorizedHome() -> URL? {
        guard let data = try? Data(contentsOf: bookmarkFileURL()) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }

        if stale {
            try? saveBookmark(for: url)
        }
        return url
    }

    func requestHomeFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Allow cleanup access"
        panel.message = "Choose your Home folder. The app only scans documented cache, log, developer, and leftover locations inside the folder you approve."
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Users", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Library").path) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Choose your Home folder"
            alert.informativeText = "The selected folder must contain your Library folder."
            alert.runModal()
            return nil
        }

        do {
            try saveBookmark(for: url)
            return url
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return nil
        }
    }

    func resetAuthorization() {
        try? FileManager.default.removeItem(at: bookmarkFileURL())
    }

    private func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let destination = bookmarkFileURL()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    private func bookmarkFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("WaxOnWaxOff", isDirectory: true)
            .appendingPathComponent(bookmarkFileName)
    }
}

