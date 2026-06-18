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
            "Adds developer and package caches using a 7-day rule."
        case .leftovers:
            "Inactive app data, reviewed individually and moved to Trash."
        }
    }

    var ageDays: Int {
        switch self {
        case .low: 30
        case .mid: 14
        case .high: 7
        case .leftovers: 45
        }
    }
}

enum CandidateRisk: String, Sendable {
    case safe = "SAFE"
    case confirm = "CONFIRM"
    case review = "REVIEW"
}

enum CleanupOperation: Sendable {
    case deleteFiles([URL], cutoff: Date)
    case deleteTree(URL)
    case recycle([URL])
    case recommendation
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

struct CleanupResult: Sendable {
    let removedBytes: Int64
    let removedItems: Int
    let skippedItems: Int
    let warnings: [String]
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

