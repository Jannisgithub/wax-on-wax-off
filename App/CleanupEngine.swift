import Darwin
import AppKit
import Foundation

typealias CleanupProgressUpdate = @Sendable (String) async -> Void

private enum LeftoverRootKind {
    case bundleDirectory
    case plistFile
    case savedStateDirectory
    case groupContainerDirectory
}

private struct LeftoverScanRoot {
    let relativePath: String
    let label: String
    let kind: LeftoverRootKind
}

private struct LeftoverPathEvidence {
    let bundleID: String
    let url: URL
    let relativePath: String
    let rootLabel: String
    let ageDays: Int
    let size: Int64
}

private struct AgedFileEvidence {
    let url: URL
    let size: Int64
    let ageDays: Int
}

private struct OwnedTreeMeasurement {
    let files: [AgedFileEvidence]
    let hasSkippedFiles: Bool

    var size: Int64 {
        files.reduce(Int64(0)) { $0 + $1.size }
    }
}

actor CleanupEngine {
    private let fileManager = FileManager.default
    private let currentUserID = getuid()

    func analyze(
        mode: CleanupMode,
        home: URL,
        runningBundleIDs: Set<String>,
        progress: CleanupProgressUpdate? = nil
    ) async -> AnalysisReport {
        let analyzedAt = Date()
        guard mode != .leftovers else {
            return await analyzeLeftovers(
                home: home,
                runningBundleIDs: runningBundleIDs,
                analyzedAt: analyzedAt,
                progress: progress
            )
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -mode.ageDays, to: analyzedAt) ?? .distantPast
        let volumeCapacity = totalCapacity(at: home)
        let volumeFreeSpace = availableCapacity(at: home)
        var candidates: [CleanupCandidate] = []
        var warnings: [String] = []

        for target in CleanupPolicy.targets(for: mode) {
            await progress?("Checking \(target.label) · \(displayPath(target.relativePath))")
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
                let files = await oldFileEvidence(
                    in: url,
                    cutoff: cutoff,
                    excluding: excludedRoots,
                    home: home,
                    now: analyzedAt,
                    progress: progress
                )
                let size = files.reduce(Int64(0)) { $0 + $1.size }
                guard size > 0 else { continue }
                let urls = files.map(\.url)
                candidates.append(CleanupCandidate(
                    id: target.id,
                    label: target.label,
                    detail: "\(files.count) item(s) • \(target.detail)",
                    size: size,
                    itemCount: files.count,
                    badge: target.badge,
                    defaultSelected: target.defaultSelected,
                    operation: .deleteFiles(DeleteFilesPlan(
                        urls: urls,
                        cutoff: cutoff,
                        scopeRoot: home,
                        measurementRoot: url,
                        ownerBundleIDs: target.ownerBundleIDs
                    )),
                    currentFootprint: size,
                    daysSinceLastAccess: files.map(\.ageDays).max()
                ))
            case .entireTree:
                await progress?("Measuring \(target.label) · \(displayPath(url, relativeTo: home))")
                if let size = measureTreeIfOwnedByCurrentUser(url), size > 0 {
                    candidates.append(CleanupCandidate(
                        id: target.id,
                        label: target.label,
                        detail: target.detail,
                        size: size,
                        itemCount: 1,
                        badge: target.badge,
                        defaultSelected: target.defaultSelected,
                        operation: .deleteTree(treePlan(
                            url: url,
                            scopeRoot: home,
                            analyzedSize: size,
                            ownerBundleIDs: target.ownerBundleIDs
                        )),
                        currentFootprint: size,
                        daysSinceLastAccess: ageDays(of: url, now: analyzedAt)
                    ))
                } else if let owned = measureOwnedPortionOfTree(url, now: analyzedAt),
                          owned.size > 0 {
                    candidates.append(CleanupCandidate(
                        id: target.id,
                        label: target.label,
                        detail: "\(owned.files.count) owned file(s) • \(target.detail) • Contains files owned by another user; only your files will be removed",
                        size: owned.size,
                        itemCount: owned.files.count,
                        badge: .review,
                        defaultSelected: false,
                        operation: .deleteFiles(DeleteFilesPlan(
                            urls: owned.files.map(\.url),
                            cutoff: .distantFuture,
                            scopeRoot: home,
                            measurementRoot: url,
                            ownerBundleIDs: target.ownerBundleIDs
                        )),
                        currentFootprint: owned.size,
                        daysSinceLastAccess: owned.files.map(\.ageDays).max(),
                        hasPartialOwnership: owned.hasSkippedFiles
                    ))
                }
            }
        }

        if mode == .high {
            candidates += await analyzeMavenRemoteCache(home: home, cutoff: cutoff, analyzedAt: analyzedAt, progress: progress)
            let appCacheReport = await analyzeAppSupportCaches(
                home: home,
                runningBundleIDs: runningBundleIDs,
                analyzedAt: analyzedAt,
                progress: progress
            )
            candidates += appCacheReport.candidates
            warnings += appCacheReport.warnings
            let sandboxCacheReport = await analyzeSandboxContainerCaches(
                home: home,
                cutoff: cutoff,
                runningBundleIDs: runningBundleIDs,
                analyzedAt: analyzedAt,
                progress: progress
            )
            candidates += sandboxCacheReport.candidates
            warnings += sandboxCacheReport.warnings

            let midCandidateIDs = Set(CleanupPolicy.targets(for: .mid).map(\.id))
            let additionalBytes = candidates
                .filter { !midCandidateIDs.contains($0.id) && isImmediateCleanup($0.operation) }
                .reduce(Int64(0)) { $0 + $1.size }
            let threshold = highAdditionalCleanupThreshold(freeSpace: volumeFreeSpace)
            if additionalBytes < threshold {
                warnings.append("HIGH adds only \(additionalBytes.fileSizeText) beyond safer cleanup. MID is recommended unless you specifically need that space.")
            } else {
                warnings.append("HIGH found \(additionalBytes.fileSizeText) beyond safer cleanup. High-value extra items are selected for review and still require confirmation.")
            }
        }

        return AnalysisReport(
            mode: mode,
            candidates: candidates.sorted(by: candidateOrder),
            warnings: warnings,
            analyzedAt: analyzedAt,
            volumeCapacity: volumeCapacity,
            volumeFreeSpace: volumeFreeSpace
        )
    }

    func apply(
        candidates: [CleanupCandidate],
        home: URL,
        runningBundleIDs: Set<String> = [],
        progress: CleanupProgressUpdate? = nil
    ) async -> CleanupResult {
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
                await progress?("Revalidating \(candidate.label)")
                guard ownersAreClosed(plan.ownerBundleIDs, runningBundleIDs: runningBundleIDs) else {
                    candidateSkippedItems += plan.urls.count
                    warnings.append("Skipped \(candidate.label): its owning app started after analysis.")
                    break
                }
                for url in plan.urls {
                    await progress?("Removing \(displayPath(url, relativeTo: home))")
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
                remainingFootprint = remainingPlannedFileFootprint(for: plan)

            case let .deleteTree(plan):
                await progress?("Removing \(displayPath(plan.url, relativeTo: home))")
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
                    await progress?("Removing \(displayPath(plan.url, relativeTo: home))")
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
        runningBundleIDs: Set<String>,
        analyzedAt: Date,
        progress: CleanupProgressUpdate?
    ) async -> (candidates: [CleanupCandidate], warnings: [String]) {
        let cacheNames: Set<String> = [
            "Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "ShaderCache",
        ]
        var candidates: [CleanupCandidate] = []
        var warnings: [String] = []

        let fixedPaths = Set(CleanupPolicy.targets(for: .high).map {
            home.appendingPathComponent($0.relativePath).standardizedFileURL
        })

        for rule in CleanupPolicy.appSupportCaches {
            await progress?("Checking \(rule.label) · \(displayPath(rule.relativePath))")
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
            var checkedCount = 0
            while let url = enumerator.nextObject() as? URL {
                if enumerator.level > 4 {
                    enumerator.skipDescendants()
                    continue
                }
                checkedCount += 1
                if checkedCount == 1 || checkedCount.isMultiple(of: 128) {
                    await progress?("Checking \(displayPath(url, relativeTo: home))")
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
                badge: .confirm,
                defaultSelected: false,
                operation: .deleteTrees(plans, measurementRoot: root),
                currentFootprint: size,
                daysSinceLastAccess: plans
                    .map { ageDays(from: $0.analyzedModificationDate, now: analyzedAt) }
                    .max()
            ))
        }
        return (candidates, warnings)
    }

    private func analyzeSandboxContainerCaches(
        home: URL,
        cutoff: Date,
        runningBundleIDs: Set<String>,
        analyzedAt: Date,
        progress: CleanupProgressUpdate?
    ) async -> (candidates: [CleanupCandidate], warnings: [String]) {
        let containersRoot = home.appendingPathComponent("Library/Containers", isDirectory: true)
        await progress?("Checking sandboxed app caches · \(displayPath(containersRoot, relativeTo: home))")
        guard revalidate(containersRoot, inside: home),
              isDirectory(containersRoot),
              isOwnedByCurrentUser(containersRoot),
              let containers = try? fileManager.contentsOfDirectory(
                at: containersRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return ([], [])
        }

        let cacheRoots = [
            ("cache", "Data/Library/Caches"),
            ("log", "Data/Library/Logs"),
            ("temp", "Data/tmp"),
        ]
        var candidates: [CleanupCandidate] = []
        var warnings: [String] = []

        for container in containers {
            let bundleID = container.lastPathComponent.lowercased()
            guard isBundleIdentifier(bundleID),
                  !isProtectedBundleID(bundleID),
                  revalidate(container, inside: home),
                  isDirectory(container),
                  isOwnedByCurrentUser(container) else {
                continue
            }
            await progress?("Checking \(displayPath(container, relativeTo: home))")
            guard ownersAreClosed([bundleID], runningBundleIDs: runningBundleIDs) else {
                warnings.append("Skipped sandbox caches for \(bundleID): close the owning app first.")
                continue
            }

            var files: [AgedFileEvidence] = []
            var usedRootLabels: [String] = []
            for (rootLabel, relativeRoot) in cacheRoots {
                let root = container.appendingPathComponent(relativeRoot, isDirectory: true)
                guard revalidate(root, inside: home), isDirectory(root), isOwnedByCurrentUser(root) else {
                    continue
                }
                let rootFiles = await oldFileEvidence(
                    in: root,
                    cutoff: cutoff,
                    home: home,
                    now: analyzedAt,
                    progress: progress
                )
                guard !rootFiles.isEmpty else { continue }
                files += rootFiles
                usedRootLabels.append(rootLabel)
            }

            let size = files.reduce(Int64(0)) { $0 + $1.size }
            guard size > 0 else { continue }
            let urls = files.map(\.url)
            let rootSummary = usedRootLabels.sorted().joined(separator: "/")
            candidates.append(CleanupCandidate(
                id: "sandbox-cache-\(stableID(bundleID))",
                label: "Sandbox caches: \(bundleID)",
                detail: "\(files.count) old \(rootSummary) file(s) • Application Support, preferences, documents, and containers for Apple apps are excluded",
                size: size,
                itemCount: files.count,
                badge: .confirm,
                defaultSelected: false,
                operation: .deleteFiles(DeleteFilesPlan(
                    urls: urls,
                    cutoff: cutoff,
                    scopeRoot: home,
                    measurementRoot: container,
                    ownerBundleIDs: [bundleID]
                )),
                currentFootprint: size,
                daysSinceLastAccess: files.map(\.ageDays).max()
            ))
        }

        return (candidates, warnings)
    }

    private func analyzeMavenRemoteCache(
        home: URL,
        cutoff: Date,
        analyzedAt: Date,
        progress: CleanupProgressUpdate?
    ) async -> [CleanupCandidate] {
        let root = home.appendingPathComponent(".m2/repository", isDirectory: true)
        await progress?("Checking Maven remote artifacts · \(displayPath(root, relativeTo: home))")
        guard revalidate(root, inside: home), isDirectory(root), isOwnedByCurrentUser(root) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var remoteFiles: Set<URL> = []
        while let marker = enumerator.nextObject() as? URL {
            guard marker.lastPathComponent == "_remote.repositories" else { continue }
            await progress?("Checking \(displayPath(marker, relativeTo: home))")
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
            badge: .confirm,
            defaultSelected: false,
            operation: .deleteFiles(DeleteFilesPlan(
                urls: urls,
                cutoff: cutoff,
                scopeRoot: home,
                measurementRoot: root,
                ownerBundleIDs: []
            )),
            currentFootprint: size,
            daysSinceLastAccess: oldestAgeDays(of: urls, now: analyzedAt)
        )]
    }

    private func analyzeLeftovers(
        home: URL,
        runningBundleIDs: Set<String>,
        analyzedAt: Date,
        progress: CleanupProgressUpdate?
    ) async -> AnalysisReport {
        let installed = installedBundleIDs(home: home)
        let now = analyzedAt
        let minimumAge = CleanupMode.leftovers.ageDays
        let primaryRoots = [
            LeftoverScanRoot(relativePath: "Library/Caches", label: "Caches", kind: .bundleDirectory),
            LeftoverScanRoot(relativePath: "Library/Preferences", label: "Preferences", kind: .plistFile),
            LeftoverScanRoot(relativePath: "Library/Saved Application State", label: "Saved State", kind: .savedStateDirectory),
            LeftoverScanRoot(relativePath: "Library/Containers", label: "Containers", kind: .bundleDirectory),
            LeftoverScanRoot(relativePath: "Library/Application Support", label: "Application Support", kind: .bundleDirectory),
            LeftoverScanRoot(relativePath: "Library/HTTPStorages", label: "HTTP Storage", kind: .bundleDirectory),
            LeftoverScanRoot(relativePath: "Library/WebKit", label: "WebKit Data", kind: .bundleDirectory),
            LeftoverScanRoot(relativePath: "Library/Logs", label: "Logs", kind: .bundleDirectory),
            LeftoverScanRoot(relativePath: "Library/Application Scripts", label: "App Scripts", kind: .bundleDirectory),
            LeftoverScanRoot(relativePath: "Library/SyncedPreferences", label: "Synced Preferences", kind: .plistFile),
        ]
        var evidenceByBundleID: [String: [LeftoverPathEvidence]] = [:]

        for root in primaryRoots {
            let evidence = await leftoverEvidence(
                in: root,
                home: home,
                now: now,
                minimumAge: minimumAge,
                allowedBundleIDs: nil,
                progress: progress
            )
            for item in evidence {
                evidenceByBundleID[canonicalBundleID(item.bundleID), default: []].append(item)
            }
        }

        let groupEvidence = await leftoverEvidence(
            in: LeftoverScanRoot(
                relativePath: "Library/Group Containers",
                label: "Group Containers",
                kind: .groupContainerDirectory
            ),
            home: home,
            now: now,
            minimumAge: minimumAge,
            allowedBundleIDs: Set(evidenceByBundleID.keys),
            progress: progress
        )
        for item in groupEvidence {
            evidenceByBundleID[canonicalBundleID(item.bundleID), default: []].append(item)
        }

        var candidates: [CleanupCandidate] = []
        for (canonicalID, evidence) in evidenceByBundleID {
            let bundleID = evidence.first?.bundleID ?? canonicalID
            guard !isProtectedBundleID(canonicalID),
                  !installed.contains(canonicalID),
                  ownersAreClosed([canonicalID], runningBundleIDs: runningBundleIDs) else {
                continue
            }
            let workspaceMatches = await installedApplicationURLs(for: bundleID)
            let canonicalWorkspaceMatches = canonicalID == canonicalBundleID(bundleID)
                ? []
                : await installedApplicationURLs(for: canonicalID)
            guard workspaceMatches.isEmpty, canonicalWorkspaceMatches.isEmpty else {
                continue
            }
            let orderedEvidence = evidence.sorted {
                if $0.rootLabel != $1.rootLabel { return $0.rootLabel < $1.rootLabel }
                return $0.relativePath < $1.relativePath
            }
            let size = orderedEvidence.reduce(Int64(0)) { $0 + $1.size }
            guard size >= 1_000_000 else { continue }
            let urls = orderedEvidence.map(\.url)
            let oldestAge = orderedEvidence.map(\.ageDays).max() ?? minimumAge
            candidates.append(CleanupCandidate(
                id: "leftover-\(stableID(canonicalID))",
                label: displayName(for: bundleID),
                detail: leftoverDetail(
                    bundleID: bundleID,
                    evidence: orderedEvidence,
                    oldestAge: oldestAge
                ),
                size: size,
                itemCount: orderedEvidence.count,
                badge: .confirm,
                defaultSelected: false,
                operation: .recycle(urls),
                currentFootprint: size,
                daysSinceLastAccess: oldestAge,
                bundleID: bundleID
            ))
        }

        return AnalysisReport(
            mode: .leftovers,
            candidates: candidates.sorted { $0.size > $1.size },
            warnings: ["Application Leftovers are never selected automatically and are moved to Trash, not permanently deleted."],
            analyzedAt: analyzedAt,
            volumeCapacity: totalCapacity(at: home),
            volumeFreeSpace: availableCapacity(at: home)
        )
    }

    private func leftoverEvidence(
        in root: LeftoverScanRoot,
        home: URL,
        now: Date,
        minimumAge: Int,
        allowedBundleIDs: Set<String>?,
        progress: CleanupProgressUpdate?
    ) async -> [LeftoverPathEvidence] {
        await progress?("Checking Application Leftovers · \(displayPath(root.relativePath))")
        let rootURL = home.appendingPathComponent(root.relativePath, isDirectory: true)
        guard revalidate(rootURL, inside: home) else { return [] }
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var evidence: [LeftoverPathEvidence] = []
        for url in children {
            await progress?("Checking \(displayPath(url, relativeTo: home))")
            guard revalidate(url, inside: home),
                  let bundleID = leftoverBundleID(for: url, kind: root.kind),
                  isBundleIdentifier(bundleID) else {
                continue
            }
            let canonicalID = canonicalBundleID(bundleID)
            guard allowedBundleIDs?.contains(canonicalID) ?? true,
                  !isProtectedBundleID(canonicalID) else {
                continue
            }
            let age = ageDays(of: url, now: now)
            guard age >= minimumAge,
                  let size = measureTreeIfOwnedByCurrentUser(url),
                  size > 0 else {
                continue
            }
            evidence.append(LeftoverPathEvidence(
                bundleID: bundleID,
                url: url,
                relativePath: displayPath(url, relativeTo: home),
                rootLabel: root.label,
                ageDays: age,
                size: size
            ))
        }
        return evidence
    }

    private func leftoverBundleID(for url: URL, kind: LeftoverRootKind) -> String? {
        let rawName = url.lastPathComponent
        switch kind {
        case .bundleDirectory:
            return rawName
        case .plistFile:
            let suffix = ".plist"
            guard rawName.lowercased().hasSuffix(suffix) else { return nil }
            return String(rawName.dropLast(suffix.count))
        case .savedStateDirectory:
            let suffix = ".savedState"
            guard rawName.hasSuffix(suffix) else { return nil }
            return String(rawName.dropLast(suffix.count))
        case .groupContainerDirectory:
            let prefix = "group."
            let lowercased = rawName.lowercased()
            guard lowercased.hasPrefix(prefix) else { return nil }
            return String(rawName.dropFirst(prefix.count))
        }
    }

    private func leftoverDetail(
        bundleID: String,
        evidence: [LeftoverPathEvidence],
        oldestAge: Int
    ) -> String {
        let pathLimit = 3
        let visiblePaths = evidence.prefix(pathLimit).map(\.relativePath).joined(separator: ", ")
        let hiddenCount = max(0, evidence.count - pathLimit)
        let pathSummary = hiddenCount > 0 ? "\(visiblePaths), +\(hiddenCount) more" : visiblePaths
        return "Missing installed app for \(bundleID) • \(evidence.count) item(s) • oldest \(oldestAge)d • \(pathSummary) • moves to Trash if selected"
    }

    private func installedApplicationURLs(for bundleID: String) async -> [URL] {
        await MainActor.run {
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        }
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
        guard ownersAreClosed(plan.ownerBundleIDs, runningBundleIDs: runningBundleIDs),
              revalidate(plan.url, inside: plan.scopeRoot),
              let currentSize = measureTreeIfOwnedByCurrentUser(plan.url) else {
            return false
        }
        let growthTolerance = max(1_000_000, Int64(Double(plan.analyzedSize) * 0.05))
        return currentSize <= plan.analyzedSize + growthTolerance
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

    private func remainingPlannedFileFootprint(for plan: DeleteFilesPlan) -> Int64 {
        plan.urls.reduce(Int64(0)) { partial, url in
            guard exists(url) else { return partial }
            return partial + allocatedSize(of: url)
        }
    }

    private func oldFileEvidence(
        in root: URL,
        cutoff: Date,
        excluding excludedRoots: [URL] = [],
        home: URL,
        now: Date,
        progress: CleanupProgressUpdate?
    ) async -> [AgedFileEvidence] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return [] }

        let excludedPaths = Set(excludedRoots.map { $0.standardizedFileURL.path })
        var result: [AgedFileEvidence] = []
        var checkedCount = 0
        while let url = enumerator.nextObject() as? URL {
            checkedCount += 1
            if checkedCount == 1 || checkedCount.isMultiple(of: 128) {
                await progress?("Checking \(displayPath(url, relativeTo: home))")
            }
            let standardizedPath = url.standardizedFileURL.path
            if excludedPaths.contains(standardizedPath)
                || excludedPaths.contains(where: { standardizedPath.hasPrefix($0 + "/") }) {
                if isDirectory(url) { enumerator.skipDescendants() }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  isOwnedByCurrentUser(url),
                  let modificationDate = values.contentModificationDate,
                  modificationDate <= cutoff else { continue }
            result.append(AgedFileEvidence(
                url: url,
                size: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                ageDays: ageDays(from: modificationDate, now: now)
            ))
        }
        return result
    }

    private func displayPath(_ relativePath: String) -> String {
        let cleaned = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return shortenDisplayPath(cleaned.isEmpty ? "~" : "~/" + cleaned)
    }

    private func displayPath(_ url: URL, relativeTo home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == homePath || path.hasPrefix(homePath + "/") else {
            return shortenDisplayPath(url.lastPathComponent)
        }
        let relative = String(path.dropFirst(homePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return displayPath(relative)
    }

    private func shortenDisplayPath(_ path: String) -> String {
        guard path.count > 92 else { return path }
        let suffix = path.suffix(76)
        return "…/" + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
        if badgeRank(lhs.badge) != badgeRank(rhs.badge) { return badgeRank(lhs.badge) < badgeRank(rhs.badge) }
        return lhs.size > rhs.size
    }

    private func badgeRank(_ badge: CandidateBadge) -> Int {
        switch badge {
        case .safe: 0
        case .confirm: 1
        case .review: 2
        }
    }

    private func highAdditionalCleanupThreshold(freeSpace: Int64?) -> Int64 {
        guard let freeSpace else { return 1_000_000_000 }
        if freeSpace < 10_000_000_000 { return 100_000_000 }
        if freeSpace < 30_000_000_000 { return 500_000_000 }
        return 1_000_000_000
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

    private func canonicalBundleID(_ value: String) -> String {
        value.lowercased()
    }

    private func isProtectedBundleID(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.hasPrefix("com.apple.") || normalized.hasPrefix("org.webkit.")
    }

    private func displayName(for bundleID: String) -> String {
        let lastPart = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        let separators = CharacterSet(charactersIn: "-_")
        let words = lastPart.components(separatedBy: separators).filter { !$0.isEmpty }
        let compact = words.isEmpty ? lastPart : words.joined(separator: " ")
        var result = ""
        var previous: Character?
        for character in compact {
            if let previous,
               character.isUppercase,
               previous.isLowercase {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        let readable = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readable.isEmpty else { return bundleID }
        return "\(readable.prefix(1).uppercased())\(readable.dropFirst()) (\(bundleID))"
    }

    private func ageDays(of url: URL, now: Date) -> Int {
        ageDays(from: modificationDate(of: url), now: now)
    }

    private func ageDays(from date: Date, now: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
    }

    private func oldestAgeDays(of urls: [URL], now: Date) -> Int? {
        urls.map { ageDays(of: $0, now: now) }.max()
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
    }

    private func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    private func totalCapacity(at url: URL) -> Int64? {
        guard let capacity = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity else { return nil }
        return Int64(capacity)
    }

    private func availableCapacity(at url: URL) -> Int64? {
        guard let capacity = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return capacity
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

    private func measureOwnedPortionOfTree(_ url: URL, now: Date) -> OwnedTreeMeasurement? {
        guard isOwnedByCurrentUser(url), !isSymbolicLink(url) else { return nil }
        if !isDirectory(url) {
            return OwnedTreeMeasurement(
                files: [AgedFileEvidence(url: url, size: allocatedSize(of: url), ageDays: ageDays(of: url, now: now))],
                hasSkippedFiles: false
            )
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return nil }

        var files: [AgedFileEvidence] = []
        var hasSkippedFiles = false
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                hasSkippedFiles = true
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard isOwnedByCurrentUser(item) else {
                hasSkippedFiles = true
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let modificationDate = values.contentModificationDate ?? modificationDate(of: item)
            files.append(AgedFileEvidence(
                url: item,
                size: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                ageDays: ageDays(from: modificationDate, now: now)
            ))
        }
        return OwnedTreeMeasurement(files: files, hasSkippedFiles: hasSkippedFiles)
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
