import Darwin
import Foundation

struct ScoreWeights: Sendable {
    let size: Double
    let age: Double
    let recoverability: Double
    let regrowth: Double
    let safety: Double

    var sum: Double {
        size + age + recoverability + regrowth + safety
    }
}

enum CandidateScorer {
    static func score(
        _ candidates: [CleanupCandidate],
        mode: CleanupMode
    ) -> [ScoredCandidate] {
        guard !candidates.isEmpty else { return [] }

        let weights = weights(for: mode)
        let maxBytes = max(candidates.map(\.size).max() ?? 0, 1)
        let denominator = max(1, Darwin.log2(Double(maxBytes) + 1))

        let rawScores = candidates.map { candidate -> ScoredCandidate in
            let factors = ScoreFactors(
                sizeNorm: clamp(Darwin.log2(Double(max(candidate.size, 0)) + 1) / denominator),
                ageNorm: ageNorm(candidate.daysSinceLastAccess, mode: mode),
                recoverability: recoverability(for: candidate.operation),
                regrowthResistance: regrowthResistance(for: candidate),
                safetyConfidence: safetyConfidence(for: candidate.badge)
            )
            let score = clamp(
                weights.size * factors.sizeNorm
                    + weights.age * factors.ageNorm
                    + weights.recoverability * factors.recoverability
                    + weights.regrowth * factors.regrowthResistance
                    + weights.safety * factors.safetyConfidence
            )
            let efficiency = score / max(1, Darwin.log2(Double(max(candidate.size, 1)) + 1))
            return ScoredCandidate(
                candidate: candidate,
                score: score,
                efficiency: efficiency,
                factors: factors
            )
        }

        let percentiles = percentileByID(for: rawScores)
        return rawScores
            .map { scored in
                var candidate = scored.candidate
                candidate.compositeScore = scored.score
                candidate.scorePercentile = percentiles[candidate.id]
                candidate.efficiencyRatio = scored.efficiency
                return ScoredCandidate(
                    candidate: candidate,
                    score: scored.score,
                    efficiency: scored.efficiency,
                    factors: scored.factors
                )
            }
            .sorted(by: scoredOrder)
    }

    static func optimalSelection(
        candidates: [ScoredCandidate],
        targetBytes: Int64
    ) -> Set<String> {
        guard targetBytes > 0 else { return [] }
        let sorted = candidates
            .filter { $0.candidate.isSelectable && $0.candidate.badge != .review && $0.candidate.size > 0 }
            .sorted {
                if $0.efficiency != $1.efficiency { return $0.efficiency > $1.efficiency }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.size > $1.candidate.size
            }

        var selected = Set<String>()
        var accumulated: Int64 = 0
        for scored in sorted where accumulated < targetBytes {
            selected.insert(scored.candidate.id)
            accumulated += scored.candidate.size
        }
        return selected
    }

    static func paretoSelection(candidates: [ScoredCandidate]) -> Set<String> {
        let sorted = candidates
            .filter { $0.candidate.isSelectable && $0.candidate.badge != .review && $0.candidate.size > 0 }
            .sorted(by: scoredOrder)
        guard !sorted.isEmpty else { return [] }

        let totalBytes = sorted.reduce(Int64(0)) { $0 + $1.candidate.size }
        var selected = Set<String>()
        var selectedBytes: Int64 = 0
        var bestSelection = Set<String>()
        var bestEfficiency = 0.0

        for (index, scored) in sorted.enumerated() {
            selected.insert(scored.candidate.id)
            selectedBytes += scored.candidate.size
            let spaceEfficiency = Double(selectedBytes) / Double(max(Int64(1), totalBytes))
            let countEfficiency = Double(index + 1) / Double(sorted.count)
            let efficiency = spaceEfficiency / max(0.01, countEfficiency)
            if spaceEfficiency >= 0.80 && efficiency >= bestEfficiency {
                bestSelection = selected
                bestEfficiency = efficiency
            }
        }

        return bestSelection.isEmpty ? selected : bestSelection
    }

    static func paretoEfficiency(
        candidates: [CleanupCandidate],
        selectedIDs: Set<String>
    ) -> ParetoEfficiency? {
        let eligible = candidates.filter { $0.isSelectable && $0.badge != .review && $0.size > 0 }
        guard !eligible.isEmpty else { return nil }
        let selected = eligible.filter { selectedIDs.contains($0.id) }
        return ParetoEfficiency(
            selectedBytes: selected.reduce(Int64(0)) { $0 + $1.size },
            totalReclaimableBytes: eligible.reduce(Int64(0)) { $0 + $1.size },
            selectedCount: selected.count,
            totalCount: eligible.count
        )
    }

    static func weights(for mode: CleanupMode) -> ScoreWeights {
        switch mode {
        case .low:
            ScoreWeights(size: 0.25, age: 0.20, recoverability: 0.10, regrowth: 0.15, safety: 0.30)
        case .mid:
            ScoreWeights(size: 0.30, age: 0.20, recoverability: 0.15, regrowth: 0.15, safety: 0.20)
        case .high:
            ScoreWeights(size: 0.35, age: 0.15, recoverability: 0.20, regrowth: 0.20, safety: 0.10)
        case .leftovers:
            ScoreWeights(size: 0.20, age: 0.25, recoverability: 0.15, regrowth: 0.10, safety: 0.30)
        }
    }

    static func weightSum(for mode: CleanupMode) -> Double {
        weights(for: mode).sum
    }

    private static func ageNorm(_ days: Int?, mode: CleanupMode) -> Double {
        guard let days else { return 0.5 }
        return clamp(Double(days) / Double(max(1, mode.ageDays)))
    }

    private static func recoverability(for operation: CleanupOperation) -> Double {
        switch operation {
        case .deleteTree, .deleteTrees:
            1.0
        case .deleteFiles:
            0.8
        case .recycle:
            0.6
        case .recommendation:
            0.0
        }
    }

    private static func regrowthResistance(for candidate: CleanupCandidate) -> Double {
        if let prediction = candidate.regrowthPrediction {
            return clamp(prediction.predictedRetentionRate)
        }
        if let evidence = candidate.reclaimEvidence, evidence.removedBytes > 0 {
            return clamp(Double(evidence.retainedBytes) / Double(evidence.removedBytes))
        }
        return 0.75
    }

    private static func safetyConfidence(for badge: CandidateBadge) -> Double {
        switch badge {
        case .safe:
            1.0
        case .confirm:
            0.7
        case .review:
            0.4
        }
    }

    private static func percentileByID(for candidates: [ScoredCandidate]) -> [String: Int] {
        let ordered = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.candidate.id < $1.candidate.id
        }
        guard ordered.count > 1 else {
            return Dictionary(uniqueKeysWithValues: ordered.map { ($0.candidate.id, 100) })
        }
        let divisor = Double(ordered.count - 1)
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, scored in
            let percentile = Int((100 * (1 - Double(index) / divisor)).rounded())
            return (scored.candidate.id, percentile)
        })
    }

    private static func scoredOrder(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        if lhs.candidate.isSelectable != rhs.candidate.isSelectable {
            return lhs.candidate.isSelectable
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.candidate.defaultSelected != rhs.candidate.defaultSelected {
            return lhs.candidate.defaultSelected
        }
        if lhs.candidate.size != rhs.candidate.size {
            return lhs.candidate.size > rhs.candidate.size
        }
        return lhs.candidate.id < rhs.candidate.id
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
