import AppKit
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
    private var authorizedHome: URL?

    init() {
#if DEBUG
        configureScreenshotStateIfRequested()
#endif
    }

    var runTitle: String {
        switch phase {
        case .idle, .failed, .finished: "RUN"
        case .review:
            selectedMode == .leftovers ? "CONFIRM & MOVE TO TRASH" : "CONFIRM & DELETE"
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
        selectedMode = mode
        candidates = []
        selectedCandidateIDs = []
        warnings = []
        result = nil
        phase = .idle
    }

    func toggleCandidate(_ id: String) {
        if selectedCandidateIDs.contains(id) {
            selectedCandidateIDs.remove(id)
        } else {
            selectedCandidateIDs.insert(id)
        }
    }

    func resetFolderAccess() {
        accessManager.resetAuthorization()
        authorizedHome = nil
        candidates = []
        selectedCandidateIDs = []
        phase = .idle
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
        let mode = selectedMode
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        Task {
            let report = await engine.analyze(mode: mode, home: home, runningBundleIDs: runningIDs)
            home.stopAccessingSecurityScopedResource()
            guard selectedMode == mode else { return }
            candidates = report.candidates
            selectedCandidateIDs = Set(report.candidates.filter(\.defaultSelected).map(\.id))
            warnings = report.warnings
            phase = .review
        }
    }

    private func confirmAndApply() {
        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        guard !selected.isEmpty, let home = authorizedHome else { return }

        let alert = NSAlert()
        alert.alertStyle = selectedMode == .high ? .critical : .warning
        alert.messageText = selectedMode == .leftovers ? "Move selected leftovers to Trash?" : "Delete selected cleanup data?"
        alert.informativeText = confirmationText(for: selected)
        var highConfirmationField: NSTextField?
        if selectedMode == .high {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "Type DELETE HIGH"
            alert.accessoryView = field
            highConfirmationField = field
        }
        alert.addButton(withTitle: selectedMode == .leftovers ? "Move to Trash" : "Delete")
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
        Task {
            let deleteCandidates = selected.filter {
                if case .recycle = $0.operation { return false }
                return true
            }
            var cleanupResult = await engine.apply(candidates: deleteCandidates, home: home)
            let recycleURLs = selected.flatMap { candidate -> [URL] in
                if case let .recycle(urls) = candidate.operation { return urls }
                return []
            }
            if !recycleURLs.isEmpty {
                let recycleResult = await recycle(recycleURLs)
                cleanupResult = CleanupResult(
                    removedBytes: cleanupResult.removedBytes + recycleResult.removedBytes,
                    removedItems: cleanupResult.removedItems + recycleResult.removedItems,
                    skippedItems: cleanupResult.skippedItems + recycleResult.skippedItems,
                    warnings: cleanupResult.warnings + recycleResult.warnings
                )
            }
            home.stopAccessingSecurityScopedResource()
            result = cleanupResult
            warnings += cleanupResult.warnings
            phase = .finished
        }
    }

    private func confirmationText(for selected: [CleanupCandidate]) -> String {
        let amount = selected.reduce(Int64(0)) { $0 + $1.size }
        let base = "\(selected.count) selected action(s), totaling \(amount.fileSizeText). The app will re-check every path before changing it."
        if selectedMode == .high {
            return base + "\n\nHIGH may remove developer caches and build artifacts. Projects and source files are excluded, but rebuilding may take longer afterward."
        }
        if selectedMode == .leftovers {
            return base + "\n\nItems remain recoverable in Trash."
        }
        return base + "\n\nPersonal documents and protected system files are excluded."
    }

    private func recycle(_ urls: [URL]) async -> CleanupResult {
        let sizes = Dictionary(uniqueKeysWithValues: urls.map { ($0, sizeOfItem($0)) })
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error {
                    continuation.resume(returning: CleanupResult(
                        removedBytes: 0,
                        removedItems: 0,
                        skippedItems: urls.count,
                        warnings: ["Could not move leftovers to Trash: \(error.localizedDescription)"]
                    ))
                } else {
                    continuation.resume(returning: CleanupResult(
                        removedBytes: sizes.values.reduce(0, +),
                        removedItems: urls.count,
                        skippedItems: 0,
                        warnings: []
                    ))
                }
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

#if DEBUG
    private func configureScreenshotStateIfRequested() {
        guard let scene = ProcessInfo.processInfo.environment["WAX_SCREENSHOT_SCENE"] else { return }
        switch scene {
        case "analyzing":
            selectedMode = .mid
            phase = .analyzing
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
            operation: .recommendation
        )
    }
#endif
}
