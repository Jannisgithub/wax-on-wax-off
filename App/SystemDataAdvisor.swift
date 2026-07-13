import Foundation

enum SystemDataAdvisor {
    struct Advisory: Identifiable, Sendable {
        enum ActionType: Sendable {
            case cleanableByApp
            case manualAction
            case informational
        }

        enum Destination: Sendable {
            case reveal(URL)
            case storageSettings
        }

        let id: String
        let title: String
        let detail: String
        let estimatedSize: Int64
        let actionType: ActionType
        let path: String?
        let destination: Destination?
    }

    struct Thresholds: Sendable {
        let iOSBackups: Int64
        let dockerData: Int64
        let purgeableSpace: Int64
        let xcodeArchives: Int64
        let simulatorDevices: Int64
        let toolManagedData: Int64

        init(
            iOSBackups: Int64,
            dockerData: Int64,
            purgeableSpace: Int64,
            xcodeArchives: Int64 = 2_000_000_000,
            simulatorDevices: Int64 = 3_000_000_000,
            toolManagedData: Int64 = 2_000_000_000
        ) {
            self.iOSBackups = iOSBackups
            self.dockerData = dockerData
            self.purgeableSpace = purgeableSpace
            self.xcodeArchives = xcodeArchives
            self.simulatorDevices = simulatorDevices
            self.toolManagedData = toolManagedData
        }

        static let production = Thresholds(
            iOSBackups: 1_000_000_000,
            dockerData: 5_000_000_000,
            purgeableSpace: 5_000_000_000,
            xcodeArchives: 2_000_000_000,
            simulatorDevices: 3_000_000_000,
            toolManagedData: 2_000_000_000
        )
    }

    static func scan(
        home: URL,
        thresholds: Thresholds = .production
    ) -> [Advisory] {
        var advisories: [Advisory] = []

        let backupDirectory = home.appendingPathComponent(
            "Library/Application Support/MobileSync/Backup",
            isDirectory: true
        )
        if let size = directorySize(backupDirectory), size > thresholds.iOSBackups {
            advisories.append(Advisory(
                id: "ios-backups",
                title: "iOS Device Backups",
                detail: "Old device backups contribute to System Data. Manage them in Finder from the device backup list.",
                estimatedSize: size,
                actionType: .manualAction,
                path: "~/Library/Application Support/MobileSync/Backup",
                destination: .reveal(backupDirectory)
            ))
        }

        let dockerDirectory = home.appendingPathComponent(
            "Library/Containers/com.docker.docker/Data",
            isDirectory: true
        )
        if let size = directorySize(dockerDirectory), size > thresholds.dockerData {
            advisories.append(Advisory(
                id: "docker-data",
                title: "Docker Desktop Data",
                detail: "Manage images and containers in Docker Desktop. Do not delete the VM data folder directly.",
                estimatedSize: size,
                actionType: .manualAction,
                path: "~/Library/Containers/com.docker.docker/Data",
                destination: .reveal(dockerDirectory)
            ))
        }

        let archivesDirectory = home.appendingPathComponent(
            "Library/Developer/Xcode/Archives",
            isDirectory: true
        )
        if let size = directorySize(archivesDirectory), size > thresholds.xcodeArchives {
            advisories.append(Advisory(
                id: "xcode-archives",
                title: "Xcode Archives",
                detail: "Review old archives yourself. They can be needed to re-export builds or retrieve matching debug symbols.",
                estimatedSize: size,
                actionType: .manualAction,
                path: "~/Library/Developer/Xcode/Archives",
                destination: .reveal(archivesDirectory)
            ))
        }

        let simulatorDirectory = home.appendingPathComponent(
            "Library/Developer/CoreSimulator/Devices",
            isDirectory: true
        )
        if let size = directorySize(simulatorDirectory), size > thresholds.simulatorDevices {
            advisories.append(Advisory(
                id: "simulator-devices",
                title: "Simulator Devices",
                detail: "Remove unused runtimes and devices from Xcode settings. Wax On/Wax Off does not delete simulator devices automatically.",
                estimatedSize: size,
                actionType: .manualAction,
                path: "~/Library/Developer/CoreSimulator/Devices",
                destination: .reveal(simulatorDirectory)
            ))
        }

        let toolManagedRules: [(id: String, title: String, relativePath: String, detail: String)] = [
            (
                "pipenv-environments",
                "Pipenv Environments",
                ".local/share/virtualenvs",
                "Remove unused environments with Pipenv so active project environments are not deleted as a group."
            ),
            (
                "miniconda-packages",
                "Miniconda Package Data",
                "miniconda3/pkgs",
                "Use conda clean to remove unused packages and caches safely. Deleting the whole package directory can break symlinked environments."
            ),
            (
                "anaconda-packages",
                "Anaconda Package Data",
                "anaconda3/pkgs",
                "Use conda clean to remove unused packages and caches safely. Deleting the whole package directory can break symlinked environments."
            ),
            (
                "stack-root",
                "Haskell Stack Data",
                ".stack",
                "The Stack root can include compilers, snapshots, configuration, and global projects. Manage it with Stack instead of deleting the folder."
            ),
        ]
        for rule in toolManagedRules {
            let directory = home.appendingPathComponent(rule.relativePath, isDirectory: true)
            guard let size = directorySize(directory), size > thresholds.toolManagedData else { continue }
            advisories.append(Advisory(
                id: rule.id,
                title: rule.title,
                detail: rule.detail,
                estimatedSize: size,
                actionType: .manualAction,
                path: "~/\(rule.relativePath)",
                destination: .reveal(directory)
            ))
        }

        if let purgeable = purgeableSpace(at: home), purgeable > thresholds.purgeableSpace {
            advisories.append(Advisory(
                id: "purgeable-space",
                title: "macOS Purgeable Space",
                detail: "\(purgeable.fileSizeText) is marked purgeable by macOS and is reclaimed automatically under storage pressure.",
                estimatedSize: purgeable,
                actionType: .informational,
                path: nil,
                destination: .storageSettings
            ))
        }

        return advisories.sorted { $0.estimatedSize > $1.estimatedSize }
    }

    private static func directorySize(_ url: URL) -> Int64? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return allocatedSize(of: url) }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return nil }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    private static func purgeableSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
            let free = values.volumeAvailableCapacity,
            let important = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return max(0, important - Int64(free))
    }
}
