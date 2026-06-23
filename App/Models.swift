import Foundation

enum CleanupMode: String, CaseIterable, Identifiable, Sendable {
    case low = "LOW"
    case mid = "MID"
    case high = "HIGH"
    case leftovers = "LEFTOVERS"

    var id: String { rawValue }

    var title: String { rawValue }

    var summary: String {
        switch self {
        case .low:
            "Old caches and logs using a 30-day rule."
        case .mid:
            "Baseline cleanup plus known app caches using a 14-day rule."
        case .high:
            "Adds reviewed developer, package, and closed-app render caches."
        case .leftovers:
            "Inactive app data, reviewed individually and moved to Trash."
        }
    }

    var ageDays: Int {
        switch self {
        case .low: 30
        case .mid: 14
        case .high: 14
        case .leftovers: 45
        }
    }
}

enum CandidateRisk: String, Sendable {
    case safe = "SAFE"
    case confirm = "CONFIRM"
    case review = "REVIEW"
}

struct DeleteFilesPlan: Sendable {
    let urls: [URL]
    let cutoff: Date
    let scopeRoot: URL
    let measurementRoot: URL
    let ownerBundleIDs: Set<String>
}

struct DeleteTreePlan: Sendable {
    let url: URL
    let scopeRoot: URL
    let analyzedSize: Int64
    let analyzedModificationDate: Date
    let ownerBundleIDs: Set<String>
}

enum CleanupOperation: Sendable {
    case deleteFiles(DeleteFilesPlan)
    case deleteTree(DeleteTreePlan)
    case deleteTrees([DeleteTreePlan], measurementRoot: URL)
    case recycle([URL])
    case recommendation
}

struct ReclaimEvidence: Sendable {
    let cleanedAt: Date
    let removedBytes: Int64
    let retainedBytes: Int64

    var retainedPercent: Int {
        guard removedBytes > 0 else { return 0 }
        return Int((Double(retainedBytes) / Double(removedBytes) * 100).rounded())
    }
}

struct CleanupCandidate: Identifiable, Sendable {
    let id: String
    let label: String
    let detail: String
    let size: Int64
    let itemCount: Int
    let risk: CandidateRisk
    let defaultSelected: Bool
    let operation: CleanupOperation
    var currentFootprint: Int64 = 0
    var reclaimEvidence: ReclaimEvidence?

    var isSelectable: Bool {
        if case .recommendation = operation { return false }
        return true
    }
}

struct AnalysisReport: Sendable {
    let mode: CleanupMode
    let candidates: [CleanupCandidate]
    let warnings: [String]

    var reclaimableBytes: Int64 {
        candidates
            .filter { $0.defaultSelected && $0.risk != .review }
            .reduce(0) { $0 + $1.size }
    }
}

enum CleanupDisposition: Sendable {
    case deleted
    case recycled
    case skipped
}

struct CandidateCleanupOutcome: Sendable {
    let candidateID: String
    let removedBytes: Int64
    let remainingFootprint: Int64
    let disposition: CleanupDisposition
}

struct CleanupResult: Sendable {
    let removedBytes: Int64
    let recycledBytes: Int64
    let removedItems: Int
    let recycledItems: Int
    let skippedItems: Int
    let warnings: [String]
    let outcomes: [CandidateCleanupOutcome]
    let availableCapacityBefore: Int64?
    let availableCapacityAfter: Int64?

    init(
        removedBytes: Int64,
        recycledBytes: Int64 = 0,
        removedItems: Int,
        recycledItems: Int = 0,
        skippedItems: Int,
        warnings: [String],
        outcomes: [CandidateCleanupOutcome] = [],
        availableCapacityBefore: Int64? = nil,
        availableCapacityAfter: Int64? = nil
    ) {
        self.removedBytes = removedBytes
        self.recycledBytes = recycledBytes
        self.removedItems = removedItems
        self.recycledItems = recycledItems
        self.skippedItems = skippedItems
        self.warnings = warnings
        self.outcomes = outcomes
        self.availableCapacityBefore = availableCapacityBefore
        self.availableCapacityAfter = availableCapacityAfter
    }
}

enum AppPhase: Equatable {
    case idle
    case analyzing
    case review
    case confirming
    case cleaning
    case finished
    case failed(String)
}

extension Int64 {
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
