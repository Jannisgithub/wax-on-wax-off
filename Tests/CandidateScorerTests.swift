import XCTest
@testable import WaxOnWaxOff

final class CandidateScorerTests: XCTestCase {
    private final class FakeRunningApplication: RunningApplicationTerminating {
        let processIdentifier: pid_t
        var isTerminated = false
        var gracefulCloseResult: Bool
        private(set) var terminateCallCount = 0
        private(set) var forceTerminateCallCount = 0

        init(processIdentifier: pid_t, gracefulCloseResult: Bool) {
            self.processIdentifier = processIdentifier
            self.gracefulCloseResult = gracefulCloseResult
        }

        func terminate() -> Bool {
            terminateCallCount += 1
            return gracefulCloseResult
        }

        func forceTerminate() -> Bool {
            forceTerminateCallCount += 1
            isTerminated = true
            return true
        }
    }

    func testWeightVectorsSumToOne() {
        for mode in CleanupMode.allCases {
            XCTAssertEqual(CandidateScorer.weightSum(for: mode), 1.0, accuracy: 0.0001)
        }
    }

    func testScoringFactorsStayNormalized() {
        let candidates = [
            candidate(id: "small-safe", size: 1_000_000, badge: .safe, days: 60),
            candidate(id: "large-cache", size: 9_000_000_000, badge: .confirm, days: 45),
            candidate(id: "review-only", size: 500_000_000, badge: .review, days: 90, operation: .recommendation),
        ]

        let scored = CandidateScorer.score(candidates, mode: .high)

        XCTAssertEqual(scored.count, candidates.count)
        XCTAssertTrue(scored.allSatisfy { (0...1).contains($0.score) })
        XCTAssertTrue(scored.allSatisfy { (0...1).contains($0.factors.sizeNorm) })
        XCTAssertTrue(scored.allSatisfy { (0...1).contains($0.factors.ageNorm) })
        XCTAssertTrue(scored.allSatisfy { (0...1).contains($0.factors.recoverability) })
        XCTAssertTrue(scored.allSatisfy { (0...1).contains($0.factors.regrowthResistance) })
        XCTAssertTrue(scored.allSatisfy { (0...1).contains($0.factors.safetyConfidence) })
        XCTAssertEqual(scored.first?.candidate.id, "large-cache")
        XCTAssertNotNil(scored.first?.candidate.scorePercentile)
    }

    func testOptimalSelectionMeetsTargetWhenEnoughCandidatesExist() {
        let scored = CandidateScorer.score([
            candidate(id: "a", size: 40_000_000, badge: .safe, days: 80),
            candidate(id: "b", size: 30_000_000, badge: .confirm, days: 70),
            candidate(id: "c", size: 10_000_000, badge: .safe, days: 60),
        ], mode: .mid)

        let selected = CandidateScorer.optimalSelection(candidates: scored, targetBytes: 55_000_000)
        let selectedBytes = scored
            .map(\.candidate)
            .filter { selected.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }

        XCTAssertGreaterThanOrEqual(selectedBytes, 55_000_000)
    }

    func testSmartSelectionNeverIncludesReviewCandidates() {
        let scored = CandidateScorer.score([
            candidate(id: "safe", size: 20_000_000, badge: .safe, days: 45),
            candidate(id: "review", size: 9_000_000_000, badge: .review, days: 120),
        ], mode: .high)

        let selected = CandidateScorer.paretoSelection(candidates: scored)

        XCTAssertTrue(selected.contains("safe"))
        XCTAssertFalse(selected.contains("review"))
    }

    func testParetoEfficiencyComputesSpaceVersusCount() throws {
        let candidates = [
            candidate(id: "big", size: 80, badge: .safe, days: 30),
            candidate(id: "small", size: 20, badge: .safe, days: 30),
        ]

        let efficiency = try XCTUnwrap(CandidateScorer.paretoEfficiency(
            candidates: candidates,
            selectedIDs: ["big"]
        ))

        XCTAssertEqual(efficiency.selectedBytes, 80)
        XCTAssertEqual(efficiency.totalReclaimableBytes, 100)
        XCTAssertEqual(efficiency.spaceEfficiency, 0.8, accuracy: 0.0001)
        XCTAssertEqual(efficiency.countEfficiency, 0.5, accuracy: 0.0001)
        XCTAssertEqual(efficiency.efficiencyRatio, 1.6, accuracy: 0.0001)
    }

    func testStorageBalanceDerivedValues() throws {
        let balance = StorageBalance(
            totalCapacity: 1_000,
            physicalFree: 100,
            availableForImportant: 250,
            availableForOpportunistic: 300
        )
        let enriched = StorageBalanceAnalyzer.enrich(
            balance,
            selectedBytes: 200,
            candidateCount: 3
        )

        XCTAssertEqual(enriched.usedSpace, 900)
        XCTAssertEqual(enriched.purgeableSpace, 150)
        XCTAssertEqual(enriched.projectedFreeAfterCleanup, 300)
        XCTAssertEqual(enriched.candidateCount, 3)
        XCTAssertEqual(enriched.usedPercent, 0.9, accuracy: 0.0001)
    }

    func testStorageBalanceAnalyzerReadsCurrentVolume() throws {
        let balance = try XCTUnwrap(StorageBalanceAnalyzer.analyze(
            volumeAt: FileManager.default.temporaryDirectory
        ))

        XCTAssertGreaterThan(balance.totalCapacity, 0)
        XCTAssertGreaterThanOrEqual(balance.physicalFree, 0)
        XCTAssertGreaterThanOrEqual(balance.availableForImportant, balance.physicalFree)
    }

    @MainActor
    func testRegrowthPredictionUsesHistoricalSeries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReclaimHistoryStore(fileURL: historyURL)

        store.record(result(removed: 1_000, remaining: 100), mode: .high, at: Date(timeIntervalSince1970: 1_000))
        store.record(result(removed: 300, remaining: 100), mode: .high, at: Date(timeIntervalSince1970: 2_000))

        let prediction = try XCTUnwrap(store.prediction(for: "cache", currentFootprint: 150))

        XCTAssertEqual(prediction.historicalCleanups, 2)
        XCTAssertEqual(prediction.confidence, 0.6, accuracy: 0.0001)
        XCTAssertGreaterThan(prediction.predictedRetentionRate, 0.5)
        XCTAssertEqual(prediction.trend, .stable)
    }

    func testApplicationTerminationTrackerWaitsForEveryTargetPID() {
        var tracker = ApplicationTerminationTracker(pendingProcessIDs: [101, 202])

        XCTAssertFalse(tracker.isComplete)
        XCTAssertFalse(tracker.markTerminated(999))
        XCTAssertTrue(tracker.markTerminated(101))
        XCTAssertFalse(tracker.isComplete)
        XCTAssertTrue(tracker.markTerminated(202))
        XCTAssertTrue(tracker.isComplete)
        XCTAssertTrue(tracker.track(303))
        XCTAssertFalse(tracker.track(303))
        XCTAssertFalse(tracker.isComplete)
        XCTAssertTrue(tracker.markTerminated(303))
        XCTAssertTrue(tracker.isComplete)
    }

    func testCloseRequesterEscalatesWhenGracefulRequestIsRejected() {
        let application = FakeRunningApplication(processIdentifier: 303, gracefulCloseResult: false)

        ApplicationTerminationRequester.requestGracefulClose([application])

        XCTAssertEqual(application.terminateCallCount, 1)
        XCTAssertEqual(application.forceTerminateCallCount, 1)
        XCTAssertTrue(application.isTerminated)
    }

    func testCloseRequesterForceClosesApplicationStillRunningAfterGracePeriod() {
        let application = FakeRunningApplication(processIdentifier: 404, gracefulCloseResult: true)

        ApplicationTerminationRequester.requestGracefulClose([application])
        XCTAssertEqual(application.terminateCallCount, 1)
        XCTAssertEqual(application.forceTerminateCallCount, 0)
        XCTAssertFalse(application.isTerminated)

        ApplicationTerminationRequester.forceClose([application])

        XCTAssertEqual(application.forceTerminateCallCount, 1)
        XCTAssertTrue(application.isTerminated)
    }

    func testASCIISparklineScalesValuesAcrossEightLevels() {
        XCTAssertEqual(ASCIISparkline.render([]), "")
        XCTAssertEqual(ASCIISparkline.render([0, 0]), "▁▁")
        XCTAssertEqual(ASCIISparkline.render([0, 25, 50, 75, 100]), "▁▂▄▆█")
        XCTAssertEqual(ASCIISparkline.render([-10, 100]), "▁█")
    }

    @MainActor
    func testRecentCleanupTotalsAggregateCandidatesAndHonorLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReclaimHistoryStore(fileURL: historyURL)

        let firstCleanup = CleanupResult(
            removedBytes: 300,
            removedItems: 2,
            skippedItems: 0,
            warnings: [],
            outcomes: [
                CandidateCleanupOutcome(candidateID: "cache-a", removedBytes: 100, remainingFootprint: 0, disposition: .deleted),
                CandidateCleanupOutcome(candidateID: "cache-b", removedBytes: 200, remainingFootprint: 0, disposition: .deleted),
            ]
        )
        let secondCleanup = CleanupResult(
            removedBytes: 500,
            removedItems: 1,
            skippedItems: 0,
            warnings: [],
            outcomes: [
                CandidateCleanupOutcome(candidateID: "cache-a", removedBytes: 500, remainingFootprint: 0, disposition: .deleted),
            ]
        )
        store.record(firstCleanup, mode: .mid, at: Date(timeIntervalSince1970: 1_000))
        store.record(secondCleanup, mode: .high, at: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(store.recentCleanupTotals(limit: 7), [300, 500])
        XCTAssertEqual(store.recentCleanupTotals(limit: 1), [500])
        XCTAssertEqual(store.recentCleanupTotals(limit: 0), [])
    }

    private func candidate(
        id: String,
        size: Int64,
        badge: CandidateBadge,
        days: Int,
        operation: CleanupOperation? = nil
    ) -> CleanupCandidate {
        CleanupCandidate(
            id: id,
            label: id,
            detail: "Test candidate",
            size: size,
            itemCount: 1,
            badge: badge,
            defaultSelected: badge != .review,
            operation: operation ?? .deleteTree(DeleteTreePlan(
                url: URL(fileURLWithPath: "/tmp/\(id)"),
                scopeRoot: URL(fileURLWithPath: "/tmp"),
                analyzedSize: size,
                analyzedModificationDate: Date(),
                ownerBundleIDs: []
            )),
            currentFootprint: size,
            daysSinceLastAccess: days
        )
    }

    private func result(removed: Int64, remaining: Int64) -> CleanupResult {
        CleanupResult(
            removedBytes: removed,
            removedItems: 1,
            skippedItems: 0,
            warnings: [],
            outcomes: [CandidateCleanupOutcome(
                candidateID: "cache",
                removedBytes: removed,
                remainingFootprint: remaining,
                disposition: .deleted
            )]
        )
    }
}
