import AppKit
import Foundation

@MainActor
final class FolderAccessManager {
    private let bookmarkFileName = "authorized-home.bookmark"

    init() {
        UserDefaults.standard.removeObject(forKey: "authorized-project-root-relative-paths")
    }

    func authorizedHome() -> URL? {
        guard let data = try? Data(contentsOf: bookmarkFileURL()) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), isExpectedHomeSelection(url) else { return nil }

        if stale {
            try? saveBookmark(for: url)
        }
        return url
    }

    func requestHomeFolder() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let panel = NSOpenPanel()
        panel.title = "Allow cleanup access"
        panel.message = "Choose the signed-in user's Home folder named \(home.lastPathComponent). The app rejects /Users, system folders, and other user folders, and never asks for administrator privileges."
        panel.prompt = "Use Home Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = home.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard isExpectedHomeSelection(url) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Choose your Home folder"
            alert.informativeText = "Choose the current signed-in user's Home folder. System roots, /Users, lookalike folders, and other user folders are not accepted."
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

    func isExpectedHomeSelection(_ url: URL) -> Bool {
        let selectedPath = dataVolumeNormalizedPath(url.standardizedFileURL.path)
        let currentHomePath = dataVolumeNormalizedPath(
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        )
        return selectedPath == currentHomePath
    }

    private func dataVolumeNormalizedPath(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        guard path.hasPrefix(prefix + "/") else { return path }
        return String(path.dropFirst(prefix.count))
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
