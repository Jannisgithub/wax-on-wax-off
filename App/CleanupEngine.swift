import Darwin
import Foundation

actor CleanupEngine {
    private let fileManager = FileManager.default
    private let currentUserID = getuid()

    func analyze(
        mode: CleanupMode,
        home: URL,
        runningBundleIDs: Set<String>
    ) -> AnalysisReport {
        guard mode != .leftovers else {
            return analyzeLeftovers(home: home)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -mode.ageDays, to: Date()) ?? .distantPast
        var candidates: [CleanupCandidate] = []
        var warnings: [String] = []

        for target in CleanupPolicy.targets(for: mode) {
            if !ownersAreClosed(target.ownerBundleIDs, runningBundleIDs: runningBundleIDs) {
                warnings.append("Skipped \(target.label): close the owning app first.")
                continue
            }

            let url = home.appendingPathComponent(target.relativePath)
            guard isSafe(url, inside: home),
                  exists(url),
                  !containsSymlink(from: home, to: url),
                  isOwnedByCurrentUser(url) else {
                continue
            }

            switch target.kind {
            case .agedFiles:
                let excludedRoots: [URL]
                if target.id == "user-caches" {
                    excludedRoots = CleanupPolicy.targets(for: mode)
                        .filter { $0.id != target.id && $0.relativePath.hasPrefix("Library/Caches/") }
                        .map { home.appendingPathComponent($0.relativePath).standardizedFileURL }
                } else {
                    excludedRoots = []
                }
                let files = oldFiles(in: url, cutoff: cutoff, excluding: excludedRoots)
                let size = files.reduce(Int64(0)) { $0 + allocatedSize(of: $1) }
                guard size > 0 else { continue }
                candidates.append(CleanupCandidate(
                    id: target.id,
                    label: target.label,
                    detail: "\(files.count) item(s) • \(target.detail)",
                    size: size,
                    itemCount: files.count,
                    risk: target.risk,
                    defaultSelected: target.defaultSelected,
                    operation: .deleteFiles(DeleteFilesPlan(
                        urls: files,
                        cutoff: cutoff,
                        scopeRoot: home,
                        measurementRoot: url,
                        ownerBundleIDs: target.ownerBundleIDs
                    )),
                    currentFootprint: directorySize(url)
                ))
            case .entireTree:
                guard let size = measureTreeIfOwnedByCurrentUser(url), size > 0 else { continue }
                candidates.append(CleanupCandidate(
                    id: target.id,
                    label: target.label,
                    detail: target.detail,
                    size: size,
                    itemCount: 1,
                    risk: target.risk,
                    defaultSelected: target.defaultSelected,
                    operation: .deleteTree(treePlan(
                        url: url,
                        scopeRoot: home,
                        analyzedSize: size,
                        ownerBundleIDs: target.ownerBundleIDs
                    )),
                    currentFootprint: size
                ))
            }
        }

        if mode == .high {
            candidates += analyzeMavenRemoteCache(home: home, cutoff: cutoff)
            let appCacheReport = analyzeAppSupportCaches(home: home, runningBundleIDs: runningBundleIDs)
            candidates += appCacheReport.candidates
            warnings += appCacheReport.warnings

            candidates += manualRecommendations(home: home)
            let midCandidateIDs = Set(CleanupPolicy.targets(for: .mid).map(\.id))
            let additionalBytes = candidates
                .filter { !midCandidateIDs.contains($0.id) && isImmediateCleanup($0.operation) }
                .reduce(Int64(0)) { $0 + $1.size }
            if additionalBytes < 1_000_000_000 {
                warnings.append("HIGH adds only \(additionalBytes.fileSizeText) beyond safer cleanup. MID is recommended unless you specifically need that space.")
            } else {
                warnings.append("HIGH found \(additionalBytes.fileSizeText) beyond safer cleanup. Extra items remain unchecked for review.")
            }
        }

        return AnalysisReport(
            mode: mode,
            candidates: candidates.sorted(by: candidateOrder),
            warnings: warnings
        )
    }

    func apply(
        candidates: [CleanupCandidate],
        home: URL,
        runningBundleIDs: Set<String> = []
    ) -> CleanupResult {
        var removedBytes: Int64 = 0
        var removedItems = 0
        var skippedItems = 0
        var warnings: [String] = []
        var outcomes: [CandidateCleanupOutcome] = []

        for candidate in candidates {
            var candidateBytes: Int64 = 0
            var candidateRemovedItems = 0
            var candidateSkippedItems = 0
            var remainingFootprint: Int64 = candidate.currentFootprint

            switch candidate.operation {
            case let .deleteFiles(plan):
                guard ownersAreClosed(plan.ownerBundleIDs, runningBundleIDs: runningBundleIDs) else {
                    candidateSkippedItems += plan.urls.count
                    warnings.append("Skipped \(candidate.label): its owning app started after analysis.")
                    break
                }
                for url in plan.urls {
                    guard revalidate(url, inside: plan.scopeRoot), modificationDate(of: url) <= plan.cutoff else {
                        candidateSkippedItems += 1
                        continue
                    }
                    guard isOwnedByCurrentUser(url) else {
                        candidateSkippedItems += 1
                        continue
                    }
                    let size = allocatedSize(of: url)
                    do {
                        try fileManager.removeItem(at: url)
                        candidateBytes += size
                        candidateRemovedItems += 1
                    } catch {
                        candidateSkippedItems += 1
                        warnings.append("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                remainingFootprint = directorySize(plan.measurementRoot)

            case let .deleteTree(plan):
                if validate(plan, runningBundleIDs: runningBundleIDs) {
                    do {
                        try fileManager.removeItem(at: plan.url)
                        candidateBytes = plan.analyzedSize
                        candidateRemovedItems = 1
                        remainingFootprint = 0
                    } catch {
                        candidateSkippedItems = 1
                        warnings.append("Could not remove \(candidate.label): \(error.localizedDescription)")
                    }
                } else {
                    candidateSkippedItems = 1
                    warnings.append("Skipped \(candidate.label): it changed or is no longer safe to remove.")
                }

            case let .deleteTrees(plans, measurementRoot: _):
                for plan in plans {
                    guard validate(plan, runningBundleIDs: runningBundleIDs) else {
                        candidateSkippedItems += 1
                        continue
                    }
                    do {
                        try fileManager.removeItem(at: plan.url)
                        candidateBytes += plan.analyzedSize
                        candidateRemovedItems += 1
                    } catch {
                        candidateSkippedItems += 1
                        warnings.append("Could not remove \(plan.url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                remainingFootprint = plans.reduce(Int64(0)) { partial, plan in
                    partial + (exists(plan.url) ? directorySize(plan.url) : 0)
                }

            case .recycle, .recommendation:
                continue
            }

            removedBytes += candidateBytes
            removedItems += candidateRemovedItems
            skippedItems += candidateSkippedItems
            if candidateBytes > 0 {
                outcomes.append(CandidateCleanupOutcome(
                    candidateID: candidate.id,
                    removedBytes: candidateBytes,
                    remainingFootprint: remainingFootprint,
                    disposition: .deleted
                ))
            } else if candidateSkippedItems > 0 {
                outcomes.append(CandidateCleanupOutcome(
                    candidateID: candidate.id,
                    removedBytes: 0,
                    remainingFootprint: remainingFootprint,
                    disposition: .skipped
                ))
            }
        }

        return CleanupResult(
            removedBytes: removedBytes,
            removedItems: removedItems,
            skippedItems: skippedItems,
            warnings: warnings,
            outcomes: outcomes
        )
    }

    private func analyzeAppSupportCaches(
        home: URL,
        runningBundleIDs: Set<String>
    ) -> (candidates: [CleanupCandidate], warnings: [String]) {
        let cacheNames: Set<String> = [
            "Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "ShaderCache",
        ]
        var candidates: [CleanupCandidate] = []
        var warnings: [String] = []

        for rule in CleanupPolicy.appSupportCaches {
            if !ownersAreClosed(rule.ownerBundleIDs, runningBundleIDs: runningBundleIDs) {
                warnings.append("Skipped \(rule.label): close the owning app first.")
                continue
            }
            let root = home.appendingPathComponent(rule.relativePath)
            guard revalidate(root, inside: home), isDirectory(root), isOwnedByCurrentUser(root) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            var plans: [DeleteTreePlan] = []
            let fixedPaths = Set(CleanupPolicy.targets(for: .high).map {
                home.appendingPathComponent($0.relativePath).standardizedFileURL
            })
            while let url = enumerator.nextObject() as? URL {
                if enumerator.level > 4 {
                    enumerator.skipDescendants()
                    continue
                }
                guard isDirectory(url), !isSymbolicLink(url) else { continue }
                guard cacheNames.contains(url.lastPathComponent) else { continue }
                if fixedPaths.contains(url.standardizedFileURL) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let size = measureTreeIfOwnedByCurrentUser(url) else {
                    enumerator.skipDescendants()
                    continue
                }
                if size > 0 {
                    plans.append(treePlan(
                        url: url,
                        scopeRoot: home,
                        analyzedSize: size,
                        ownerBundleIDs: rule.ownerBundleIDs
                    ))
                }
                enumerator.skipDescendants()
            }

            let size = plans.reduce(Int64(0)) { $0 + $1.analyzedSize }
            guard size > 0 else { continue }
            candidates.append(CleanupCandidate(
                id: rule.id,
                label: rule.label,
                detail: "\(plans.count) HTTP, code, or GPU cache folder(s) • site data is excluded",
                size: size,
                itemCount: plans.count,
                risk: .confirm,
                defaultSelected: false,
                operation: .deleteTrees(plans, measurementRoot: root),
                currentFootprint: size
            ))
        }
        return (candidates, warnings)
    }

    private func analyzeMavenRemoteCache(home: URL, cutoff: Date) -> [CleanupCandidate] {
        let root = home.appendingPathComponent(".m2/repository", isDirectory: true)
        guard revalidate(root, inside: home), isDirectory(root), isOwnedByCurrentUser(root) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var remoteFiles: Set<URL> = []
        for case let marker as URL in enumerator where marker.lastPathComponent == "_remote.repositories" {
            guard modificationDate(of: marker) <= cutoff,
                  let contents = try? String(contentsOf: marker, encoding: .utf8) else { continue }
            let parent = marker.deletingLastPathComponent()
            var foundRemoteArtifact = false
            for line in contents.split(whereSeparator: \Character.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !text.hasPrefix("#"), let separator = text.firstIndex(of: ">") else { continue }
                let provenance = text[text.index(after: separator)...]
                guard let assignment = provenance.firstIndex(of: "="),
                      !provenance[..<assignment].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let name = String(text[..<separator])
                let artifact = parent.appendingPathComponent(name)
                guard revalidate(artifact, inside: root),
                      isOwnedByCurrentUser(artifact),
                      modificationDate(of: artifact) <= cutoff else {
                    continue
                }
                remoteFiles.insert(artifact)
                for suffix in [".sha1", ".md5", ".lastUpdated"] {
                    let sidecar = parent.appendingPathComponent(name + suffix)
                    if revalidate(sidecar, inside: root),
                       isOwnedByCurrentUser(sidecar),
                       modificationDate(of: sidecar) <= cutoff {
                        remoteFiles.insert(sidecar)
                    }
                }
                foundRemoteArtifact = true
            }
            if foundRemoteArtifact, isOwnedByCurrentUser(marker) { remoteFiles.insert(marker) }
        }

        let urls = remoteFiles.sorted { $0.path < $1.path }
        let size = urls.reduce(Int64(0)) { $0 + allocatedSize(of: $1) }
        guard size > 0 else { return [] }
        return [CleanupCandidate(
            id: "maven-remote-cache",
            label: "Maven remote artifacts",
            detail: "\(urls.count) remotely sourced file(s) • local installs are preserved",
            size: size,
            itemCount: urls.count,
            risk: .confirm,
            defaultSelected: false,
            operation: .deleteFiles(DeleteFilesPlan(
                urls: urls,
                cutoff: cutoff,
                scopeRoot: home,
                measurementRoot: root,
                ownerBundleIDs: []
            )),
            currentFootprint: directorySize(root)
        )]
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

                guard let size = measureTreeIfOwnedByCurrentUser(url), size >= 1_000_000 else { continue }
                candidates.append(CleanupCandidate(
                    id: "leftover-\(stableID(url.path))",
                    label: rawName,
                    detail: "No matching installed app • \(ageDays(of: url, now: now))+ days old",
                    size: size,
                    itemCount: 1,
                    risk: .confirm,
                    defaultSelected: false,
                    operation: .recycle([url]),
                    currentFootprint: size
                ))
            }
        }

        return AnalysisReport(
            mode: .leftovers,
            candidates: candidates.sorted { $0.size > $1.size },
            warnings: ["Leftovers are never selected automatically and are moved to Trash, not permanently deleted."]
        )
    }

    private func manualRecommendations(home: URL) -> [CleanupCandidate] {
        let locations: [(String, String, String, URL)] = [
            ("manual-xcode", "Xcode archives", "Retain archives needed for crash symbolication; manage in Xcode Organizer.", home.appendingPathComponent("Library/Developer/Xcode/Archives")),
            ("manual-backups", "iPhone and iPad backups", "Personal recovery data; manage with Finder's Manage Backups.", home.appendingPathComponent("Library/Application Support/MobileSync/Backup")),
            ("manual-models", "Downloaded AI models", "Models may be private or needed offline; manage with the owning tool.", home.appendingPathComponent(".cache/huggingface/hub")),
            ("manual-docker", "Docker data", "Use Docker's prune tools so referenced images and volumes remain protected.", home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")),
        ]
        var result = locations.compactMap { id, label, detail, url -> CleanupCandidate? in
            guard exists(url) else { return nil }
            let size = directorySize(url)
            guard size > 0 else { return nil }
            return CleanupCandidate(
                id: id,
                label: label,
                detail: detail,
                size: size,
                itemCount: 0,
                risk: .review,
                defaultSelected: false,
                operation: .recommendation,
                currentFootprint: size
            )
        }
        result += [
            CleanupCandidate(id: "manual-components", label: "Xcode platforms and runtimes", detail: "Remove unused components in Xcode Settings, where compatibility is known.", size: 0, itemCount: 0, risk: .review, defaultSelected: false, operation: .recommendation),
            CleanupCandidate(id: "manual-trash", label: "Trash", detail: "Review and empty with Finder when you are ready.", size: 0, itemCount: 0, risk: .review, defaultSelected: false, operation: .recommendation),
            CleanupCandidate(id: "manual-snapshots", label: "Time Machine local snapshots", detail: "Manage with macOS and Time Machine settings.", size: 0, itemCount: 0, risk: .review, defaultSelected: false, operation: .recommendation),
        ]
        return result
    }

    private func treePlan(
        url: URL,
        scopeRoot: URL,
        analyzedSize: Int64,
        ownerBundleIDs: Set<String> = []
    ) -> DeleteTreePlan {
        DeleteTreePlan(
            url: url,
            scopeRoot: scopeRoot,
            analyzedSize: analyzedSize,
            analyzedModificationDate: modificationDate(of: url),
            ownerBundleIDs: ownerBundleIDs
        )
    }

    private func validate(_ plan: DeleteTreePlan, runningBundleIDs: Set<String>) -> Bool {
        ownersAreClosed(plan.ownerBundleIDs, runningBundleIDs: runningBundleIDs)
            && revalidate(plan.url, inside: plan.scopeRoot)
            && measureTreeIfOwnedByCurrentUser(plan.url) == plan.analyzedSize
            && modificationDate(of: plan.url) == plan.analyzedModificationDate
    }

    private func ownersAreClosed(
        _ bundleIDs: Set<String>,
        runningBundleIDs: Set<String>
    ) -> Bool {
        !runningBundleIDs.contains { id in
            let runningID = id.lowercased()
            let owned = bundleIDs.contains { owner in
                let normalizedOwner = owner.lowercased()
                return runningID == normalizedOwner || runningID.hasPrefix(normalizedOwner + ".")
            }
            return owned
        }
    }

    private func oldFiles(in root: URL, cutoff: Date, excluding excludedRoots: [URL] = []) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            if excludedRoots.contains(where: { excluded in
                url.standardizedFileURL == excluded || url.standardizedFileURL.path.hasPrefix(excluded.path + "/")
            }) {
                if isDirectory(url) { enumerator.skipDescendants() }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  isOwnedByCurrentUser(url),
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
            options: []
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

    private func candidateOrder(_ lhs: CleanupCandidate, _ rhs: CleanupCandidate) -> Bool {
        if lhs.isSelectable != rhs.isSelectable { return lhs.isSelectable }
        if lhs.defaultSelected != rhs.defaultSelected { return lhs.defaultSelected }
        return lhs.size > rhs.size
    }

    private func isImmediateCleanup(_ operation: CleanupOperation) -> Bool {
        switch operation {
        case .deleteFiles, .deleteTree, .deleteTrees: true
        case .recycle, .recommendation: false
        }
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

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isOwnedByCurrentUser(_ url: URL) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let ownerID = attributes?[.ownerAccountID] as? NSNumber
        return ownerID?.uint32Value == currentUserID
    }

    private func isOwnedByCurrentUserTree(_ url: URL) -> Bool {
        guard isOwnedByCurrentUser(url), !isSymbolicLink(url) else { return false }
        guard isDirectory(url) else { return true }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return false }
        for case let item as URL in enumerator {
            guard isOwnedByCurrentUser(item), !isSymbolicLink(item) else {
                return false
            }
        }
        return true
    }

    private func measureTreeIfOwnedByCurrentUser(_ url: URL) -> Int64? {
        guard isOwnedByCurrentUser(url), !isSymbolicLink(url) else { return nil }
        if !isDirectory(url) { return allocatedSize(of: url) }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return nil }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys) else { return nil }
            guard isOwnedByCurrentUser(item), values.isSymbolicLink != true else {
                return nil
            }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return total
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
            if isSymbolicLink(current) { return true }
        }
        return false
    }
}
