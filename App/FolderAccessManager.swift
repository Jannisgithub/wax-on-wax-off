import AppKit
import Darwin
import Foundation

@MainActor
protocol FolderAccessManaging {
    func authorizedHome() -> URL?
    func requestHomeFolder() -> URL?
    func resetAuthorization()
}

@MainActor
final class FolderAccessManager: FolderAccessManaging {
    private let bookmarkFileName = "authorized-home.bookmark"
    private let accountHomeDirectory: URL

    init(accountHomeDirectory: URL? = nil) {
        self.accountHomeDirectory = (
            accountHomeDirectory ?? Self.resolveAccountHomeDirectory()
        ).standardizedFileURL
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
        let home = accountHomeDirectory
        let panel = NSOpenPanel()
        panel.title = "Choose Your Home Folder"
        panel.message = "Choose your Home folder named \(home.lastPathComponent). WaxOnWaxOff will check cleanup areas inside this folder and ask before removing anything."
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
        let selectedURL = url.standardizedFileURL
        let selectedPath = Self.dataVolumeNormalizedPath(selectedURL.path)
        let currentHomePath = Self.dataVolumeNormalizedPath(accountHomeDirectory.path)
        return selectedPath == currentHomePath || sameFileSystemLocation(selectedURL, accountHomeDirectory)
    }

    private static func resolveAccountHomeDirectory() -> URL {
        let fallback = URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
        let paths: [String?] = [
            passwordDatabaseHomeDirectory(),
            ProcessInfo.processInfo.environment["HOME"],
            NSHomeDirectory(),
            FileManager.default.homeDirectoryForCurrentUser.path,
            fallback.path,
        ]

        for path in paths.compactMap({ $0 }) {
            let normalized = dataVolumeNormalizedPath(
                URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            )
            if isAccountHomePath(normalized) {
                return URL(fileURLWithPath: normalized, isDirectory: true)
            }
        }
        return fallback
    }

    private static func passwordDatabaseHomeDirectory() -> String? {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return nil
    }

    private static func isAccountHomePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "Users" else { return false }
        let reservedNames = ["", "shared", "deleted users"]
        return !reservedNames.contains(parts[1].lowercased())
    }

    private static func dataVolumeNormalizedPath(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        guard path.hasPrefix(prefix + "/") else { return path }
        return String(path.dropFirst(prefix.count))
    }

    private func sameFileSystemLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsAttributes = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let rhsAttributes = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let lhsVolume = lhsAttributes[.systemNumber] as? NSNumber,
              let rhsVolume = rhsAttributes[.systemNumber] as? NSNumber,
              let lhsFile = lhsAttributes[.systemFileNumber] as? NSNumber,
              let rhsFile = rhsAttributes[.systemFileNumber] as? NSNumber else {
            return false
        }
        return lhsVolume == rhsVolume && lhsFile == rhsFile
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
