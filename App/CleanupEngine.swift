import Foundation

actor CleanupEngine {
    private let fileManager = FileManager.default

    func analyze(mode: CleanupMode, home: URL, runningBundleIDs: Set<String>) -> AnalysisReport {
        guard mode != .leftovers else {
            return analyzeLeftovers(home: home)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -mode.ageDays, to: Date()) ?? .distantPast
        var candidates: [CleanupCandidate] = []
        var warnings: [String] = []

        for target in CleanupPolicy.targets(for: mode) {
            if !target.ownerBundleIDs.isDisjoint(with: runningBundleIDs) {
                warnings.append("Skipped \(target.label): close the owning app first.")
                continue
            }

            let url = home.appendingPathComponent(target.relativePath)
            guard isSafe(url, inside: home), exists(url), !containsSymlink(from: home, to: url) else { continue }

            switch target.kind {
            case .agedFiles:
                let files = oldFiles(in: url, cutoff: cutoff)
                let size = files.reduce(Int64(0)) { $0 + allocatedSize(of: $1) }
                guard size > 0 else { continue }
                candidates.append(.init(
                    id: target.id,
                    label: target.label,
                    detail: "\(files.count) item(s) • \(target.detail)",
                    size: size,
                    itemCount: files.count,
                    risk: target.risk,
                    defaultSelected: true,
                    operation: .deleteFiles(files, cutoff: cutoff)
                ))
            case .entireTree:
                let size = directorySize(url)
                guard size > 0 else { continue }
                candidates.append(.init(
                    id: target.id,
                    label: target.label,
                    detail: target.detail,
                    size: size,
                    itemCount: 1,
                    risk: target.risk,
                    defaultSelected: true,
                    operation: .deleteTree(url)
                ))
            }
        }

        if mode == .high {
            candidates += manualRecommendations()
        }

        return AnalysisReport(mode: mode, candidates: candidates, warnings: warnings)
    }

    func apply(candidates: [CleanupCandidate], home: URL) -> CleanupResult {
        var removedBytes: Int64 = 0
        var removedItems = 0
        var skippedItems = 0
        var warnings: [String] = []

        for candidate in candidates {
            switch candidate.operation {
            case let .deleteFiles(urls, cutoff):
                for url in urls {
                    guard revalidate(url, inside: home), modificationDate(of: url) <= cutoff else {
                        skippedItems += 1
                        continue
                    }
                    let size = allocatedSize(of: url)
                    do {
                        try fileManager.removeItem(at: url)
                        removedBytes += size
                        removedItems += 1
                    } catch {
                        skippedItems += 1
                        warnings.append("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            case let .deleteTree(url):
                guard revalidate(url, inside: home) else {
                    skippedItems += 1
                    continue
                }
                let size = directorySize(url)
                do {
                    try fileManager.removeItem(at: url)
                    removedBytes += size
                    removedItems += 1
                } catch {
                    skippedItems += 1
                    warnings.append("Could not remove \(candidate.label): \(error.localizedDescription)")
                }
            case .recycle, .recommendation:
                continue
            }
        }

        return CleanupResult(
            removedBytes: removedBytes,
            removedItems: removedItems,
            skippedItems: skippedItems,
            warnings: warnings
        )
    }

    private func analyzeLeftovers(home: URL) -> AnalysisReport {
        let installed = installedBundleIDs(home: home)
        let now = Date()
        let roots: [(String, String, Int)] = [
            ("Library/Caches", "", 30),
            ("Library/Preferences", ".plist", 45),
            ("Library/Saved Application State", ".savedState", 45),
            ("Library/Containers", "", 45),
        ]
        var candidates: [CleanupCandidate] = []

        for (relativeRoot, suffix, minimumAge) in roots {
            let root = home.appendingPathComponent(relativeRoot)
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in children {
                let rawName = suffix.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(suffix.count))
                let bundleID = rawName.lowercased()
                guard isBundleIdentifier(bundleID),
                      !bundleID.hasPrefix("com.apple."),
                      !installed.contains(bundleID),
                      ageDays(of: url, now: now) >= minimumAge,
                      revalidate(url, inside: home) else { continue }

                let size = directorySize(url)
                guard size >= 1_000_000 else { continue }
                candidates.append(.init(
                    id: "leftover-\(stableID(url.path))",
                    label: rawName,
                    detail: "No matching installed app • \(ageDays(of: url, now: now))+ days old",
                    size: size,
                    itemCount: 1,
                    risk: .confirm,
                    defaultSelected: false,
                    operation: .recycle([url])
                ))
            }
        }

        return AnalysisReport(
            mode: .leftovers,
            candidates: candidates.sorted { $0.size > $1.size },
            warnings: ["Leftovers are never selected automatically and are moved to Trash, not permanently deleted."]
        )
    }

    private func manualRecommendations() -> [CleanupCandidate] {
        [
            .init(id: "manual-xcode", label: "Xcode application and archives", detail: "Review in Finder or Xcode Organizer.", size: 0, itemCount: 0, risk: .review, defaultSelected: false, operation: .recommendation),
            .init(id: "manual-trash", label: "Trash", detail: "Review and empty with Finder when you are ready.", size: 0, itemCount: 0, risk: .review, defaultSelected: false, operation: .recommendation),
            .init(id: "manual-snapshots", label: "Time Machine local snapshots", detail: "Manage with macOS and Time Machine settings.", size: 0, itemCount: 0, risk: .review, defaultSelected: false, operation: .recommendation),
        ]
    }

    private func oldFiles(in root: URL, cutoff: Date) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantFuture) <= cutoff else { continue }
            result.append(url)
        }
        return result
    }

    private func directorySize(_ url: URL) -> Int64 {
        if !isDirectory(url) { return allocatedSize(of: url) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func installedBundleIDs(home: URL) -> Set<String> {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        var identifiers: Set<String> = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                if let identifier = Bundle(url: url)?.bundleIdentifier?.lowercased() {
                    identifiers.insert(identifier)
                }
                enumerator.skipDescendants()
            }
        }
        return identifiers
    }

    private func stableID(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func isBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private func ageDays(of url: URL, now: Date) -> Int {
        let date = modificationDate(of: url)
        return max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
    }

    private func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isSafe(_ url: URL, inside root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(rootPath)
    }

    private func revalidate(_ url: URL, inside root: URL) -> Bool {
        isSafe(url, inside: root) && exists(url) && !containsSymlink(from: root, to: url)
    }

    private func containsSymlink(from root: URL, to target: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return true }

        var current = root.standardizedFileURL
        let relative = targetPath.dropFirst(rootPath.count).split(separator: "/")
        for component in relative {
            current.appendPathComponent(String(component))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }
}

