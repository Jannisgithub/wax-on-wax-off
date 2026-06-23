import AppKit
import Darwin
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedMode: CleanupMode = .mid
    @Published var phase: AppPhase = .idle
    @Published var candidates: [CleanupCandidate] = []
    @Published var selectedCandidateIDs: Set<String> = []
    @Published var warnings: [String] = []
    @Published var result: CleanupResult?

    private let accessManager = FolderAccessManager()
    private let engine = CleanupEngine()
    private let historyStore = ReclaimHistoryStore()
    private let minimumActivityDuration: TimeInterval = 6.4
    private let currentUserID = getuid()
    private var authorizedHome: URL?
    private var analysisGeneration = 0

    init() {
#if DEBUG
        configureScreenshotStateIfRequested()
#endif
    }

    var runTitle: String {
        switch phase {
        case .idle, .failed, .finished: "RUN"
        case .review:
            selectedActionTitle
        case .confirming: "CONFIRM"
        case .analyzing: "ANALYZING…"
        case .cleaning: "CLEANING…"
        }
    }

    var selectedBytes: Int64 {
        candidates
            .filter { selectedCandidateIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var canRun: Bool {
        switch phase {
        case .idle, .failed, .finished: true
        case .review: !selectedCandidateIDs.isEmpty
        default: false
        }
    }

    func runPrimaryAction() {
        switch phase {
        case .idle, .failed, .finished:
            startAnalysis()
        case .review:
            confirmAndApply()
        default:
            break
        }
    }

    func selectMode(_ mode: CleanupMode) {
        guard phase != .analyzing && phase != .cleaning else { return }
        analysisGeneration += 1
        selectedMode = mode
        candidates = []
        selectedCandidateIDs = []
        warnings = []
        result = nil
        phase = .idle
    }

    func toggleCandidate(_ id: String) {
        guard candidates.first(where: { $0.id == id })?.isSelectable == true else { return }
        if selectedCandidateIDs.contains(id) {
            selectedCandidateIDs.remove(id)
        } else {
            selectedCandidateIDs.insert(id)
        }
    }

    func resetFolderAccess() {
        analysisGeneration += 1
        accessManager.resetAuthorization()
        authorizedHome = nil
        candidates = []
        selectedCandidateIDs = []
        warnings = []
        result = nil
        phase = .idle
    }

    func resetCleanupMemory() {
        historyStore.reset()
        candidates = candidates.map { candidate in
            var updated = candidate
            updated.reclaimEvidence = nil
            return updated
        }
    }

    private func startAnalysis() {
        let home = accessManager.authorizedHome() ?? accessManager.requestHomeFolder()
        guard let home else { return }
        authorizedHome = home
        guard home.startAccessingSecurityScopedResource() else {
            phase = .failed("macOS did not grant access to the selected folder.")
            return
        }

        phase = .analyzing
        candidates = []
        selectedCandidateIDs = []
        warnings = []
        result = nil
        analysisGeneration += 1
        let generation = analysisGeneration
        let mode = selectedMode
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let earliestReviewDate = Date().addingTimeInterval(minimumActivityDuration)

        Task {
            let report = await engine.analyze(
                mode: mode,
                home: home,
                runningBundleIDs: runningIDs
            )
            home.stopAccessingSecurityScopedResource()
            await wait(until: earliestReviewDate)
            guard analysisGeneration == generation, selectedMode == mode else { return }
            let enriched = report.candidates.map(historyStore.enrich)
            candidates = enriched
            selectedCandidateIDs = Set(enriched.filter { $0.defaultSelected && $0.isSelectable }.map(\.id))
            warnings = report.warnings
            phase = .review
        }
    }

    private func confirmAndApply() {
        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        guard !selected.isEmpty, let home = authorizedHome else { return }

        let alert = NSAlert()
        alert.alertStyle = selectedMode == .high ? .critical : .warning
        alert.messageText = confirmationTitle(for: selected)
        alert.informativeText = confirmationText(for: selected)
        var highConfirmationField: NSTextField?
        if selectedMode == .high {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "Type DELETE HIGH"
            alert.accessoryView = field
            highConfirmationField = field
        }
        alert.addButton(withTitle: selected.contains(where: isDirectDelete) ? "Apply Cleanup" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let highConfirmationField,
           highConfirmationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != "DELETE HIGH" {
            let mismatch = NSAlert()
            mismatch.alertStyle = .warning
            mismatch.messageText = "Confirmation did not match"
            mismatch.informativeText = "HIGH cleanup was not applied. Type DELETE HIGH exactly to confirm developer-cache removal."
            mismatch.runModal()
            return
        }

        guard home.startAccessingSecurityScopedResource() else {
            phase = .failed("macOS did not grant access to the selected folder.")
            return
        }

        phase = .cleaning
        let capacityBefore = availableCapacity(at: home)
        let mode = selectedMode
        let earliestResultDate = Date().addingTimeInterval(minimumActivityDuration)
        Task {
            let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let deleteCandidates = selected.filter(isDirectDelete)
            let recycleCandidates = selected.filter(isRecycle)
            let deleteResult = await engine.apply(
                candidates: deleteCandidates,
                home: home,
                runningBundleIDs: runningIDs
            )
            let recycleResult = await recycle(recycleCandidates, inside: home)
            let capacityAfter = availableCapacity(at: home)
            let cleanupResult = CleanupResult(
                removedBytes: deleteResult.removedBytes,
                recycledBytes: recycleResult.recycledBytes,
                removedItems: deleteResult.removedItems,
                recycledItems: recycleResult.recycledItems,
                skippedItems: deleteResult.skippedItems + recycleResult.skippedItems,
                warnings: deleteResult.warnings + recycleResult.warnings,
                outcomes: deleteResult.outcomes + recycleResult.outcomes,
                availableCapacityBefore: capacityBefore,
                availableCapacityAfter: capacityAfter
            )
            home.stopAccessingSecurityScopedResource()
            await wait(until: earliestResultDate)
            historyStore.record(cleanupResult, mode: mode)
            result = cleanupResult
            warnings += cleanupResult.warnings
            phase = .finished
        }
    }

    private func wait(until date: Date) async {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }

    private func confirmationText(for selected: [CleanupCandidate]) -> String {
        let amount = selected.reduce(Int64(0)) { $0 + $1.size }
        let directCount = selected.filter(isDirectDelete).count
        let trashCount = selected.filter(isRecycle).count
        let base = "\(selected.count) selected action(s), totaling \(amount.fileSizeText): \(directCount) permanent and \(trashCount) moved to Trash. Every path and safety condition is checked again."
        if selectedMode == .high {
            return base + "\n\nStop active builds, package managers, and development servers first. HIGH may remove developer caches and build artifacts. Projects and source files are excluded, but rebuilding may take longer afterward."
        }
        if selectedMode == .leftovers {
            return base + "\n\nItems remain recoverable in Trash."
        }
        return base + "\n\nPersonal documents and protected system files are excluded."
    }

    private func recycle(_ candidates: [CleanupCandidate], inside home: URL) async -> CleanupResult {
        guard !candidates.isEmpty else {
            return CleanupResult(removedBytes: 0, removedItems: 0, skippedItems: 0, warnings: [])
        }
        var validCandidates: [CleanupCandidate] = []
        var urls: [URL] = []
        var skipped = 0
        for candidate in candidates {
            guard case let .recycle(candidateURLs) = candidate.operation,
                  !candidateURLs.isEmpty,
                  candidateURLs.allSatisfy({ isSafeForRecycle($0, inside: home) }),
                  candidateURLs.reduce(Int64(0), { $0 + sizeOfItem($1) }) == candidate.currentFootprint else {
                skipped += 1
                continue
            }
            validCandidates.append(candidate)
            urls += candidateURLs
        }
        guard !urls.isEmpty else {
            return CleanupResult(
                removedBytes: 0,
                removedItems: 0,
                skippedItems: skipped,
                warnings: skipped > 0 ? ["Skipped Trash items that changed after analysis."] : []
            )
        }
        let finalURLs = urls
        let finalCandidates = validCandidates
        let skippedCount = skipped
        let sizes = Dictionary(uniqueKeysWithValues: finalURLs.map {
            ($0.standardizedFileURL, sizeOfItem($0))
        })
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(finalURLs) { newURLs, error in
                let successfulURLs = Set(newURLs.keys.map(\.standardizedFileURL))
                let recycledBytes = successfulURLs.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
                let failedCount = finalURLs.count - successfulURLs.count
                let outcomes = finalCandidates.compactMap { candidate -> CandidateCleanupOutcome? in
                    guard case let .recycle(candidateURLs) = candidate.operation else { return nil }
                    let candidateBytes = candidateURLs.reduce(Int64(0)) {
                        $0 + (successfulURLs.contains($1.standardizedFileURL) ? (sizes[$1.standardizedFileURL] ?? 0) : 0)
                    }
                    guard candidateBytes > 0 else { return nil }
                    return CandidateCleanupOutcome(
                        candidateID: candidate.id,
                        removedBytes: candidateBytes,
                        remainingFootprint: max(0, candidate.currentFootprint - candidateBytes),
                        disposition: .recycled
                    )
                }
                var warnings = skippedCount > 0 ? ["Skipped Trash items that changed after analysis."] : []
                if let error {
                    warnings.append("Could not move every selected item to Trash: \(error.localizedDescription)")
                }
                continuation.resume(returning: CleanupResult(
                    removedBytes: 0,
                    recycledBytes: recycledBytes,
                    removedItems: 0,
                    recycledItems: successfulURLs.count,
                    skippedItems: skippedCount + failedCount,
                    warnings: warnings,
                    outcomes: outcomes
                ))
            }
        }
    }

    private func sizeOfItem(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private var selectedActionTitle: String {
        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        if selected.contains(where: isDirectDelete) && selected.contains(where: isRecycle) {
            return "CONFIRM CLEANUP"
        }
        return selected.contains(where: isDirectDelete) ? "CONFIRM & DELETE" : "CONFIRM & MOVE TO TRASH"
    }

    private func confirmationTitle(for selected: [CleanupCandidate]) -> String {
        if selected.contains(where: isDirectDelete) && selected.contains(where: isRecycle) {
            return "Apply permanent cleanup and move review items to Trash?"
        }
        return selected.contains(where: isDirectDelete) ? "Delete selected cleanup data?" : "Move selected items to Trash?"
    }

    private func isDirectDelete(_ candidate: CleanupCandidate) -> Bool {
        switch candidate.operation {
        case .deleteFiles, .deleteTree, .deleteTrees: true
        case .recycle, .recommendation: false
        }
    }

    private func isRecycle(_ candidate: CleanupCandidate) -> Bool {
        if case .recycle = candidate.operation { return true }
        return false
    }

    private func availableCapacity(at url: URL) -> Int64? {
        guard let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }

    private func isSafeForRecycle(_ url: URL, inside home: URL) -> Bool {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/"),
              FileManager.default.fileExists(atPath: path),
              isOwnedByCurrentUserTree(url) else {
            return false
        }
        var current = home.standardizedFileURL
        for component in path.dropFirst(homePath.count).split(separator: "/") {
            current.appendPathComponent(String(component))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return false
            }
        }
        return true
    }

    private func isOwnedByCurrentUserTree(_ url: URL) -> Bool {
        guard isOwnedByCurrentUser(url) else { return false }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return true }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return false }
        for case let item as URL in enumerator {
            guard isOwnedByCurrentUser(item),
                  (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                return false
            }
        }
        return true
    }

    private func isOwnedByCurrentUser(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let ownerID = attributes?[.ownerAccountID] as? NSNumber
        return ownerID?.uint32Value == currentUserID
    }

#if DEBUG
    private func configureScreenshotStateIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let argumentScene = arguments.firstIndex(of: "--screenshot-scene").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        guard let scene = ProcessInfo.processInfo.environment["WAX_SCREENSHOT_SCENE"] ?? argumentScene else { return }
        switch scene {
        case "analyzing":
            selectedMode = .mid
            phase = .analyzing
        case "cleaning":
            selectedMode = .mid
            phase = .cleaning
        case "mid-review":
            selectedMode = .mid
            candidates = [
                sample("old-caches", "Old user caches", "1,284 items • Older than 14 days", 1_840_000_000, .safe, true),
                sample("logs", "Old user logs", "218 items • Diagnostic and app logs", 284_000_000, .safe, true),
                sample("chrome", "Chrome downloaded models", "Re-downloadable model cache", 732_000_000, .confirm, true),
            ]
            warnings = ["Chrome is closed; its selected re-downloadable cache is eligible."]
            phase = .review
        case "high-review":
            selectedMode = .high
            candidates = [
                sample("baseline", "Old caches and logs", "2,106 items • Older than 7 days", 2_420_000_000, .safe, true),
                sample("derived", "Xcode DerivedData", "Build products and indexes; source stays untouched", 8_740_000_000, .confirm, true),
                sample("npm", "npm package cache", "Re-downloadable package data", 1_120_000_000, .confirm, true),
                sample("trash", "Trash", "Review and empty with Finder when ready", 0, .review, false),
            ]
            warnings = ["HIGH requires the typed confirmation DELETE HIGH."]
            phase = .review
        case "leftovers-review":
            selectedMode = .leftovers
            candidates = [
                sample("old-editor", "com.example.oldeditor", "No matching installed app • 126 days old", 542_000_000, .confirm, false),
                sample("old-player", "com.example.videoplayer", "No matching installed app • 94 days old", 186_000_000, .confirm, false),
                sample("old-helper", "Example Helper", "Application Support • review before selecting", 72_000_000, .confirm, false),
            ]
            selectedCandidateIDs = ["old-editor", "old-player"]
            warnings = ["Leftovers are moved to Trash and remain recoverable."]
            phase = .review
        case "result":
            selectedMode = .mid
            result = CleanupResult(removedBytes: 2_856_000_000, removedItems: 1_502, skippedItems: 3, warnings: [])
            phase = .finished
        default:
            break
        }
        if selectedCandidateIDs.isEmpty {
            selectedCandidateIDs = Set(candidates.filter(\.defaultSelected).map(\.id))
        }
    }

    private func sample(
        _ id: String,
        _ label: String,
        _ detail: String,
        _ size: Int64,
        _ risk: CandidateRisk,
        _ selected: Bool
    ) -> CleanupCandidate {
        CleanupCandidate(
            id: id,
            label: label,
            detail: detail,
            size: size,
            itemCount: 1,
            risk: risk,
            defaultSelected: selected,
            operation: risk == .review ? .recommendation : .recycle([])
        )
    }
#endif
}
