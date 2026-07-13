import Darwin
import XCTest
@testable import WaxOnWaxOff

final class CleanupExpansionTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "com.jannis.waxonwaxoff.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    private final class RecordingFolderAccessManager: FolderAccessManaging {
        private let savedHome: URL?
        private let selectedHome: URL?
        private(set) var requestHomeFolderCallCount = 0
        private(set) var resetAuthorizationCallCount = 0

        init(savedHome: URL? = nil, selectedHome: URL? = nil) {
            self.savedHome = savedHome
            self.selectedHome = selectedHome
        }

        func authorizedHome() -> URL? {
            savedHome
        }

        func requestHomeFolder() -> URL? {
            requestHomeFolderCallCount += 1
            return selectedHome
        }

        func resetAuthorization() {
            resetAuthorizationCallCount += 1
        }
    }


    func testHighPolicyAddsBroaderCachesWithUncertainTargetsUnchecked() {
        let targets = Dictionary(uniqueKeysWithValues: CleanupPolicy.targets(for: .high).map { ($0.id, $0) })
        XCTAssertNotNil(targets["yarn-cache"])
        XCTAssertNotNil(targets["pnpm-cache"])
        XCTAssertNotNil(targets["cocoapods-cache"])
        XCTAssertNotNil(targets["cargo-download-cache"])
        XCTAssertNotNil(targets["cargo-git-checkouts"])
        XCTAssertNotNil(targets["go-build-cache"])
        XCTAssertNotNil(targets["firefox-disk-cache"])
        XCTAssertNotNil(targets["xcode-documentation-cache"])
        XCTAssertNil(targets["xcode-archives"])
        XCTAssertNotNil(targets["xcode-caches"])
        XCTAssertNil(targets["conda-packages"])
        XCTAssertNil(targets["anaconda-packages"])
        XCTAssertNotNil(targets["bundler-cache"])
        XCTAssertNotNil(targets["pub-cache"])
        XCTAssertNil(targets["stack-cache"])
        XCTAssertNotNil(targets["poetry-cache"])
        XCTAssertNil(targets["pipenv-virtualenvs"])
        XCTAssertNotNil(targets["pip-xdg-cache"])
        XCTAssertNotNil(targets["terraform-plugins"])
        XCTAssertNotNil(targets["kubernetes-cache"])
        XCTAssertNotNil(targets["helm-cache"])
        XCTAssertNotNil(targets["helm-xdg-cache"])
        XCTAssertNotNil(targets["aws-cli-cache"])
        XCTAssertNotNil(targets["gcloud-logs"])
        XCTAssertNotNil(targets["homebrew-logs"])
        XCTAssertTrue(CleanupPolicy.developerCaches.allSatisfy { !$0.defaultSelected })
        XCTAssertTrue(CleanupPolicy.extendedAppCaches.allSatisfy { !$0.defaultSelected })
        XCTAssertEqual(targets["go-module-downloads"]?.defaultSelected, false)
        XCTAssertEqual(targets["gradle-distributions"]?.defaultSelected, false)
        XCTAssertEqual(CleanupMode.high.ageDays, CleanupMode.mid.ageDays)
    }

    func testHighRecommendsMidWhenAdditionalCleanupIsSmall() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let report = await CleanupEngine().analyze(mode: .high, home: home, runningBundleIDs: [])
        XCTAssertTrue(report.warnings.contains { $0.contains("MID is recommended") })
    }

    func testMidIncludesExpandedClosedAppCachesWithoutDeveloperTargets() {
        let ids = Set(CleanupPolicy.targets(for: .mid).map(\.id))

        XCTAssertTrue(ids.contains("firefox-disk-cache"))
        XCTAssertTrue(ids.contains("slack-disk-cache"))
        XCTAssertFalse(ids.contains("xcode-derived"))
    }

    func testTolerantTreeValidationAllowsShrinkAndRejectsGrowth() async throws {
        let shrinkHome = try temporaryHome()
        let growthHome = try temporaryHome()
        defer {
            try? FileManager.default.removeItem(at: shrinkHome)
            try? FileManager.default.removeItem(at: growthHome)
        }

        let shrinkTarget = shrinkHome.appendingPathComponent("Library/Developer/Xcode/DerivedData/Shrink", isDirectory: true)
        try FileManager.default.createDirectory(at: shrinkTarget, withIntermediateDirectories: true)
        let removedBeforeApply = shrinkTarget.appendingPathComponent("old-index")
        try Data(repeating: 1, count: 64_000).write(to: removedBeforeApply)
        try Data(repeating: 2, count: 64_000).write(to: shrinkTarget.appendingPathComponent("remaining-index"))

        let shrinkEngine = CleanupEngine()
        let shrinkReport = await shrinkEngine.analyze(mode: .high, home: shrinkHome, runningBundleIDs: [])
        let shrinkCandidate = try XCTUnwrap(shrinkReport.candidates.first { $0.id == "xcode-derived" })
        try FileManager.default.removeItem(at: removedBeforeApply)

        let shrinkResult = await shrinkEngine.apply(candidates: [shrinkCandidate], home: shrinkHome)

        XCTAssertEqual(shrinkResult.removedItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shrinkTarget.path))

        let growthTarget = growthHome.appendingPathComponent("Library/Developer/Xcode/DerivedData/Growth", isDirectory: true)
        try FileManager.default.createDirectory(at: growthTarget, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 64_000).write(to: growthTarget.appendingPathComponent("index"))

        let growthEngine = CleanupEngine()
        let growthReport = await growthEngine.analyze(mode: .high, home: growthHome, runningBundleIDs: [])
        let growthCandidate = try XCTUnwrap(growthReport.candidates.first { $0.id == "xcode-derived" })
        try Data(repeating: 4, count: 2_000_000).write(to: growthTarget.appendingPathComponent("new-active-file"))

        let growthResult = await growthEngine.apply(candidates: [growthCandidate], home: growthHome)

        XCTAssertEqual(growthResult.skippedItems, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: growthTarget.path))
    }

    func testPartialOwnershipStyleTreesDeleteOnlyOwnedFiles() async throws {
        let home = try temporaryHome()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaxOnWaxOffPartialOutside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }

        let target = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Partial", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let ownedFile = target.appendingPathComponent("owned-index")
        try Data(repeating: 5, count: 64_000).write(to: ownedFile)
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("external-link"),
            withDestinationURL: outside
        )

        let engine = CleanupEngine()
        let report = await engine.analyze(mode: .high, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.id == "xcode-derived" })

        XCTAssertEqual(candidate.badge, .review)
        XCTAssertFalse(candidate.defaultSelected)
        XCTAssertTrue(candidate.hasPartialOwnership)
        guard case let .deleteFiles(plan) = candidate.operation else {
            return XCTFail("Partial trees should remove only owned files")
        }
        XCTAssertEqual(plan.urls.map(\.lastPathComponent), ["owned-index"])

        _ = await engine.apply(candidates: [candidate], home: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testNamedHighCacheIsExcludedFromBroadUserCacheCandidate() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pip = home.appendingPathComponent("Library/Caches/pip", isDirectory: true)
        try FileManager.default.createDirectory(at: pip, withIntermediateDirectories: true)
        let file = pip.appendingPathComponent("package.whl")
        try Data(repeating: 9, count: 4_096).write(to: file)
        try setAge(days: 40, for: file)

        let report = await CleanupEngine().analyze(mode: .high, home: home, runningBundleIDs: [])
        XCTAssertTrue(report.candidates.contains { $0.id == "pip-cache" })
        XCTAssertFalse(report.candidates.contains { $0.id == "user-caches" })
    }

    func testHighDoesNotScanProjectDirectories() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Projects/App", isDirectory: true)
        let modules = project.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("lock".utf8).write(to: project.appendingPathComponent("pnpm-lock.yaml"))
        try Data(repeating: 1, count: 4_096).write(to: modules.appendingPathComponent("dependency.bin"))

        let report = await CleanupEngine().analyze(mode: .high, home: home, runningBundleIDs: [])
        XCTAssertFalse(report.candidates.contains { $0.label == "JavaScript dependencies" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: modules.path))
    }

    func testAppSupportScanDeletesRenderCacheButPreservesPersistentStorage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let slack = home.appendingPathComponent("Library/Application Support/Slack", isDirectory: true)
        let cache = slack.appendingPathComponent("Cache", isDirectory: true)
        let storage = slack.appendingPathComponent("Local Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4_096).write(to: cache.appendingPathComponent("cache.bin"))
        try Data(repeating: 4, count: 4_096).write(to: storage.appendingPathComponent("state.bin"))

        let engine = CleanupEngine()
        let report = await engine.analyze(mode: .high, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.id == "slack-render" })
        XCTAssertFalse(candidate.defaultSelected)

        let result = await engine.apply(candidates: [candidate], home: home)
        XCTAssertEqual(result.removedItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.path))
    }

    func testRunningAppSuppressesAppSupportCache() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Application Support/Slack/Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 4_096).write(to: cache.appendingPathComponent("cache.bin"))

        let report = await CleanupEngine().analyze(
            mode: .high,
            home: home,
            runningBundleIDs: ["com.tinyspeck.slackmacgap.helper.GPU"]
        )
        XCTAssertFalse(report.candidates.contains { $0.id == "slack-render" })
        XCTAssertTrue(report.warnings.contains { $0.contains("Slack render caches") })
    }

    func testHighDoesNotScanProtectedDownloadsFolder() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let installer = downloads.appendingPathComponent("OldTool.dmg")
        try Data(repeating: 6, count: 4_096).write(to: installer)
        try setAge(days: 40, for: installer)

        let report = await CleanupEngine().analyze(mode: .high, home: home, runningBundleIDs: [])
        XCTAssertFalse(report.candidates.contains { $0.label == "OldTool.dmg" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.path))
    }

    func testHighDoesNotSurfaceManualSystemAreasAsCleanupIssues() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let backup = home.appendingPathComponent("Library/Application Support/MobileSync/Backup/Device", isDirectory: true)
        let model = home.appendingPathComponent(".cache/huggingface/hub/model", isDirectory: true)
        let docker = home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data", isDirectory: true)
        for directory in [backup, model, docker] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 8, count: 4_096).write(to: directory.appendingPathComponent("data.bin"))
        }

        let report = await CleanupEngine().analyze(mode: .high, home: home, runningBundleIDs: [])
        let labels = Set(report.candidates.map(\.label))

        XCTAssertFalse(report.candidates.contains { $0.id.hasPrefix("manual-") })
        XCTAssertFalse(labels.contains("iPhone and iPad backups"))
        XCTAssertFalse(labels.contains("Downloaded AI models"))
        XCTAssertFalse(labels.contains("Docker data"))
        XCTAssertFalse(labels.contains("Trash"))
        XCTAssertFalse(labels.contains("Time Machine local snapshots"))
    }

    func testMavenCleanupPreservesLocallyInstalledArtifact() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let version = home.appendingPathComponent(".m2/repository/com/example/tool/1.0", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        let remote = version.appendingPathComponent("tool-1.0.jar")
        let local = version.appendingPathComponent("local-only.jar")
        let marker = version.appendingPathComponent("_remote.repositories")
        try Data(repeating: 7, count: 4_096).write(to: remote)
        try Data(repeating: 8, count: 4_096).write(to: local)
        try Data("tool-1.0.jar>central=\nlocal-only.jar>=".utf8).write(to: marker)
        try setAge(days: 20, for: remote)
        try setAge(days: 20, for: local)
        try setAge(days: 20, for: marker)

        let engine = CleanupEngine()
        let report = await engine.analyze(mode: .high, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.id == "maven-remote-cache" })
        XCTAssertEqual(candidate.currentFootprint, candidate.size)
        _ = await engine.apply(candidates: [candidate], home: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    }

    func testHighFindsOldSandboxContainerCachesAndKeepsPersistentData() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let dataRoot = home.appendingPathComponent("Library/Containers/com.example.Sandboxed/Data", isDirectory: true)
        let cache = dataRoot.appendingPathComponent("Library/Caches/http.cache")
        let temp = dataRoot.appendingPathComponent("tmp/render.tmp")
        let logs = dataRoot.appendingPathComponent("Library/Logs/debug.log")
        let support = dataRoot.appendingPathComponent("Library/Application Support/state.db")
        for file in [cache, temp, logs, support] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_096).write(to: file)
            try setAge(days: 20, for: file)
        }

        let engine = CleanupEngine()
        let report = await engine.analyze(mode: .high, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.label.contains("com.example.sandboxed") })

        XCTAssertEqual(candidate.itemCount, 3)
        XCTAssertFalse(candidate.defaultSelected)

        let result = await engine.apply(candidates: [candidate], home: home)

        XCTAssertEqual(result.removedItems, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
    }

    func testHighSkipsSandboxContainerForRunningApp() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let cache = home.appendingPathComponent("Library/Containers/com.example.Sandboxed/Data/Library/Caches/http.cache")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4_096).write(to: cache)
        try setAge(days: 20, for: cache)

        let report = await CleanupEngine().analyze(
            mode: .high,
            home: home,
            runningBundleIDs: ["com.example.Sandboxed.helper"]
        )

        XCTAssertFalse(report.candidates.contains { $0.label.contains("com.example.sandboxed") })
        XCTAssertTrue(report.warnings.contains { $0.contains("sandbox caches for com.example.sandboxed") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    @MainActor
    func testFolderAuthorizationAcceptsOnlyCurrentHome() throws {
        let alternate = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotAHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alternate.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: alternate) }

        let manager = FolderAccessManager()
        let accountHomePath = getpwuid(getuid()).flatMap { entry -> String? in
            guard let directory = entry.pointee.pw_dir else { return nil }
            return String(cString: directory)
        } ?? NSHomeDirectory()
        let accountHome = URL(fileURLWithPath: accountHomePath, isDirectory: true)
        XCTAssertTrue(manager.isExpectedHomeSelection(accountHome))
        let dataVolumeHome = URL(fileURLWithPath: "/System/Volumes/Data" + accountHome.path, isDirectory: true)
        if FileManager.default.fileExists(atPath: dataVolumeHome.path) {
            XCTAssertTrue(manager.isExpectedHomeSelection(dataVolumeHome))
        }
        XCTAssertFalse(manager.isExpectedHomeSelection(alternate))
        XCTAssertFalse(manager.isExpectedHomeSelection(URL(fileURLWithPath: "/", isDirectory: true)))
        XCTAssertFalse(manager.isExpectedHomeSelection(URL(fileURLWithPath: "/Users", isDirectory: true)))

        for name in ["Desktop", "Documents"] {
            try FileManager.default.createDirectory(
                at: alternate.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        XCTAssertFalse(manager.isExpectedHomeSelection(alternate))
    }

    @MainActor
    func testFolderAuthorizationIgnoresSandboxContainerDataHome() throws {
        let manager = FolderAccessManager(
            accountHomeDirectory: URL(fileURLWithPath: "/Users/reviewuser", isDirectory: true)
        )
        let realHome = URL(fileURLWithPath: "/Users/reviewuser", isDirectory: true)
        let dataVolumeHome = URL(fileURLWithPath: "/System/Volumes/Data/Users/reviewuser", isDirectory: true)
        let sandboxContainerData = URL(
            fileURLWithPath: "/Users/reviewuser/Library/Containers/com.jannis.waxonwaxoff/Data",
            isDirectory: true
        )

        XCTAssertTrue(manager.isExpectedHomeSelection(realHome))
        XCTAssertTrue(manager.isExpectedHomeSelection(dataVolumeHome))
        XCTAssertFalse(manager.isExpectedHomeSelection(sandboxContainerData))
        XCTAssertFalse(manager.isExpectedHomeSelection(URL(fileURLWithPath: "/Users/Data", isDirectory: true)))
    }

    @MainActor
    func testReclaimHistoryCalculatesRetainedSpaceWithoutStoringPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReclaimHistoryStore(fileURL: historyURL)
        let result = CleanupResult(
            removedBytes: 1_000,
            removedItems: 1,
            skippedItems: 0,
            warnings: [],
            outcomes: [CandidateCleanupOutcome(
                candidateID: "cache-id",
                removedBytes: 1_000,
                remainingFootprint: 100,
                disposition: .deleted
            )]
        )
        store.record(result, mode: .high, at: Date(timeIntervalSince1970: 1_000))

        let candidate = CleanupCandidate(
            id: "cache-id",
            label: "Cache",
            detail: "Test",
            size: 300,
            itemCount: 1,
            badge: .confirm,
            defaultSelected: true,
            operation: .recommendation,
            currentFootprint: 300
        )
        let enriched = store.enrich(candidate)
        XCTAssertEqual(enriched.reclaimEvidence?.retainedBytes, 800)
        XCTAssertEqual(enriched.reclaimEvidence?.retainedPercent, 80)
        let serialized = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains("/Users/"))

        store.reset()

        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertNil(store.enrich(candidate).reclaimEvidence)
    }

    @MainActor
    func testDemoModeUsesSampleDataAndDoesNotRequireFileAccess() {
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: isolatedDefaults(),
            accessManager: RecordingFolderAccessManager()
        )

        XCTAssertEqual(model.phase, .launchChoice)

        model.openDemoMode()

        XCTAssertTrue(model.isDemoMode)
        XCTAssertEqual(model.phase, .demoMode)
        XCTAssertEqual(model.demoStep, .intro)
        XCTAssertEqual(model.runTitle, "CHOOSE PRACTICE MODE")
        XCTAssertFalse(model.canRun)

        model.selectDemoMode(.low)

        XCTAssertEqual(model.phase, .reviewReady)
        XCTAssertEqual(model.demoStep, .low)
        XCTAssertEqual(model.selectedMode, .low)
        XCTAssertFalse(model.candidates.isEmpty)
        XCTAssertTrue(model.warnings.contains { $0.contains("No real files are scanned") })
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.runTitle, "APPLY SELECTED CLEANUP")

        model.runPrimaryAction()

        XCTAssertEqual(model.phase, .cleanupComplete)
        XCTAssertEqual(model.demoStep, .complete)
        XCTAssertEqual(model.result?.removedBytes, 0)
        XCTAssertGreaterThan(model.result?.recycledBytes ?? 0, 0)
        XCTAssertTrue(model.guidanceMessage.contains("No real files"))

        model.skipToFullVersion()

        XCTAssertFalse(model.isDemoMode)
        XCTAssertTrue(model.phase == .idle || model.phase == .readyToAnalyze)
        XCTAssertNotEqual(model.phase, .selectingFolder)
        XCTAssertNotEqual(model.phase, .analyzing)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    @MainActor
    func testDemoModeIncludesAllModesAndLeftoversStartUnchecked() {
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: isolatedDefaults(),
            accessManager: RecordingFolderAccessManager()
        )

        model.openDemoMode()
        for mode in CleanupMode.allCases {
            model.selectDemoMode(mode)
            XCTAssertTrue(model.isDemoMode)
            XCTAssertEqual(model.demoStep.mode, mode)
            XCTAssertEqual(model.selectedMode, mode)
            XCTAssertFalse(model.candidates.isEmpty, "\(mode.title) should have demo candidates")
            if mode == .leftovers {
                XCTAssertEqual(model.phase, .analysisComplete)
                XCTAssertTrue(model.selectedCandidateIDs.isEmpty)
                XCTAssertTrue(model.candidates.allSatisfy { !$0.defaultSelected })
                XCTAssertEqual(model.runTitle, "SELECT ITEMS TO CONTINUE")
                model.toggleCandidate(model.candidates[0].id)
                XCTAssertEqual(model.runTitle, "MOVE SELECTED TO TRASH")
            } else {
                XCTAssertEqual(model.phase, .reviewReady)
                XCTAssertEqual(model.runTitle, "APPLY SELECTED CLEANUP")
            }
        }
    }

    @MainActor
    func testHighModeStartsWithSmartExtraCleanupSelected() {
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: isolatedDefaults(),
            accessManager: RecordingFolderAccessManager()
        )

        model.openDemoMode()
        model.selectDemoMode(.high)

        let baselineIDs = Set(model.candidates.filter(\.defaultSelected).map(\.id))

        XCTAssertTrue(model.selectedCandidateIDs.isSuperset(of: baselineIDs))
        XCTAssertGreaterThan(model.selectedCandidateIDs.count, baselineIDs.count)
        XCTAssertTrue(model.selectedCandidateIDs.contains("demo-high-render-cache"))
    }

    @MainActor
    func testSelectAllAndNoneOnlyChangeSelectableCandidates() {
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: isolatedDefaults(),
            accessManager: RecordingFolderAccessManager()
        )
        let selectable = CleanupCandidate(
            id: "selectable",
            label: "Selectable cache",
            detail: "Test",
            size: 400,
            itemCount: 1,
            badge: .safe,
            defaultSelected: false,
            operation: .deleteTree(DeleteTreePlan(
                url: URL(fileURLWithPath: "/tmp/selectable"),
                scopeRoot: URL(fileURLWithPath: "/tmp"),
                analyzedSize: 400,
                analyzedModificationDate: Date(),
                ownerBundleIDs: []
            ))
        )
        let recommendation = CleanupCandidate(
            id: "recommendation",
            label: "Manual action",
            detail: "Test",
            size: 800,
            itemCount: 1,
            badge: .review,
            defaultSelected: false,
            operation: .recommendation
        )
        model.candidates = [selectable, recommendation]
        model.storageBalance = StorageBalance(
            totalCapacity: 10_000,
            physicalFree: 1_000,
            availableForImportant: 2_000,
            availableForOpportunistic: 2_500
        )

        model.selectAll()

        XCTAssertEqual(model.selectedCandidateIDs, ["selectable"])
        XCTAssertTrue(model.allSelectableSelected)
        XCTAssertEqual(model.selectableCandidateCount, 1)
        XCTAssertEqual(model.selectedSelectableCandidateCount, 1)
        XCTAssertEqual(model.storageBalance?.reclaimableByApp, 400)

        model.deselectAll()

        XCTAssertTrue(model.selectedCandidateIDs.isEmpty)
        XCTAssertFalse(model.allSelectableSelected)
        XCTAssertEqual(model.selectedSelectableCandidateCount, 0)
        XCTAssertEqual(model.storageBalance?.reclaimableByApp, 0)
        XCTAssertEqual(model.phase, .analysisComplete)
    }

    @MainActor
    func testExpandedCandidatePathsAreCappedAtFive() {
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: isolatedDefaults(),
            accessManager: RecordingFolderAccessManager()
        )
        let paths = (0..<8).map { URL(fileURLWithPath: "/tmp/cache/file-\($0)") }
        let candidate = CleanupCandidate(
            id: "aged-cache",
            label: "Aged cache files",
            detail: "Test",
            size: 800,
            itemCount: paths.count,
            badge: .safe,
            defaultSelected: true,
            operation: .deleteFiles(DeleteFilesPlan(
                urls: paths,
                cutoff: Date(),
                scopeRoot: URL(fileURLWithPath: "/tmp/cache"),
                measurementRoot: URL(fileURLWithPath: "/tmp/cache"),
                ownerBundleIDs: []
            ))
        )
        model.candidates = [candidate]

        XCTAssertEqual(model.candidatePathCount(for: candidate), 8)
        XCTAssertEqual(model.candidatePaths(for: candidate).count, 5)
        XCTAssertEqual(model.candidatePaths(for: candidate).map(\.lastPathComponent), ["file-0", "file-1", "file-2", "file-3", "file-4"])

        model.toggleCandidateExpansion(candidate.id)
        XCTAssertTrue(model.expandedCandidateIDs.contains(candidate.id))
        model.toggleCandidateExpansion(candidate.id)
        XCTAssertFalse(model.expandedCandidateIDs.contains(candidate.id))
    }

    @MainActor
    func testLaunchChoiceIsShownOnlyUntilUserChoosesPath() {
        let defaults = isolatedDefaults()
        let firstLaunch = AppModel(
            demoActivityDelay: 0,
            userDefaults: defaults,
            accessManager: RecordingFolderAccessManager()
        )

        XCTAssertEqual(firstLaunch.phase, .launchChoice)

        firstLaunch.openDemoMode()

        let laterLaunch = AppModel(
            demoActivityDelay: 0,
            userDefaults: defaults,
            accessManager: RecordingFolderAccessManager()
        )
        XCTAssertNotEqual(laterLaunch.phase, .launchChoice)
        XCTAssertFalse(laterLaunch.isDemoMode)
        XCTAssertTrue(laterLaunch.phase == .idle || laterLaunch.phase == .readyToAnalyze)
    }

    @MainActor
    func testSavedHomeApprovalSkipsLaunchChoice() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let accessManager = RecordingFolderAccessManager(savedHome: home)
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: isolatedDefaults(),
            accessManager: accessManager
        )

        XCTAssertEqual(model.phase, .readyToAnalyze)
        XCTAssertFalse(model.isDemoMode)
    }

    @MainActor
    func testRealAnalysisRequestsHomeFolderWhenNoSavedApproval() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let accessManager = RecordingFolderAccessManager(selectedHome: home)
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: isolatedDefaults(),
            accessManager: accessManager
        )

        model.runRealAnalysis()

        XCTAssertEqual(accessManager.requestHomeFolderCallCount, 1)
        XCTAssertNotEqual(model.phase, .selectingFolder)
    }

    @MainActor
    func testRealAnalysisUsesSavedHomeWithoutAskingAgain() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let accessManager = RecordingFolderAccessManager(savedHome: home)
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: isolatedDefaults(),
            accessManager: accessManager
        )

        model.runRealAnalysis()

        XCTAssertEqual(accessManager.requestHomeFolderCallCount, 0)
        XCTAssertNotEqual(model.phase, .selectingFolder)
    }

    @MainActor
    func testStartOverResetsFirstRunAndFolderApproval() {
        let defaults = isolatedDefaults()
        let accessManager = RecordingFolderAccessManager()
        let model = AppModel(
            demoActivityDelay: 0,
            userDefaults: defaults,
            accessManager: accessManager
        )

        model.openDemoMode()
        model.selectDemoMode(.low)
        XCTAssertNotEqual(model.phase, .launchChoice)
        XCTAssertTrue(defaults.bool(forKey: "has-seen-launch-choice-v1"))

        model.startOverAsFreshInstall()

        XCTAssertEqual(model.phase, .launchChoice)
        XCTAssertFalse(model.isDemoMode)
        XCTAssertEqual(model.demoStep, .intro)
        XCTAssertEqual(model.selectedMode, .mid)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: "has-seen-launch-choice-v1"))
        XCTAssertEqual(accessManager.resetAuthorizationCallCount, 1)
    }

    func testCopyUsesDeleteConfirmationAndNeutralScanText() throws {
        XCTAssertEqual(AppModel.highConfirmationPhrase, "DELETE")

        let forbidden = [
            "APPLY" + " HIGH",
            ["APPLY", "PRACTICE", "CLEANUP"].joined(separator: " "),
            "Choose your Home folder once",
            "Nothing is " + "being deleted",
            "Read-only analysis in progress",
            "ANALYSIS / READ ONLY"
        ]
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try sourceFiles(
            under: ["App", "Store", "docs", "README.md"].map {
                repoRoot.appendingPathComponent($0)
            }
        )

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for phrase in forbidden {
                XCTAssertFalse(
                    contents.localizedCaseInsensitiveContains(phrase),
                    "\(phrase) should not appear in \(file.path)"
                )
            }
        }
    }

    func testApplicationLeftoversGroupsBundleIDEvidenceAndStartsUnchecked() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundleID = "com.example.oldapp"
        let evidenceURLs = try [
            makeEvidenceDirectory("Library/Caches/\(bundleID)", home: home),
            makeEvidenceFile("Library/Preferences/\(bundleID).plist", home: home),
            makeEvidenceDirectory("Library/Saved Application State/\(bundleID).savedState", home: home),
            makeEvidenceDirectory("Library/Containers/\(bundleID)", home: home),
            makeEvidenceDirectory("Library/Application Support/\(bundleID)", home: home),
            makeEvidenceDirectory("Library/HTTPStorages/\(bundleID)", home: home),
            makeEvidenceDirectory("Library/WebKit/\(bundleID)", home: home),
            makeEvidenceDirectory("Library/Logs/\(bundleID)", home: home),
            makeEvidenceDirectory("Library/Application Scripts/\(bundleID)", home: home),
            makeEvidenceFile("Library/SyncedPreferences/\(bundleID).plist", home: home),
            makeEvidenceDirectory("Library/Group Containers/group.\(bundleID)", home: home),
        ]

        let report = await CleanupEngine().analyze(mode: .leftovers, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.bundleID == bundleID })

        XCTAssertFalse(candidate.defaultSelected)
        XCTAssertEqual(candidate.label, "Oldapp (\(bundleID))")
        XCTAssertEqual(candidate.itemCount, evidenceURLs.count)
        XCTAssertGreaterThanOrEqual(candidate.size, 1_000_000)
        XCTAssertTrue(candidate.detail.contains("Missing installed app for \(bundleID)"))
        XCTAssertTrue(candidate.detail.contains("~/Library/"))
        XCTAssertTrue(candidate.detail.contains("moves to Trash if selected"))
        guard case let .recycle(urls) = candidate.operation else {
            return XCTFail("Application Leftovers should move selected items to Trash")
        }
        XCTAssertEqual(
            Set(urls.map(\.standardizedFileURL)),
            Set(evidenceURLs.map(\.standardizedFileURL))
        )
    }

    func testApplicationLeftoversRejectsUnsafeOrUnclearEvidence() async throws {
        let home = try temporaryHome()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaxOnWaxOffOutside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }

        try makeEvidenceDirectory("Library/Caches/com.example.installed", home: home)
        try makeInstalledApp(bundleID: "com.example.installed", home: home)
        try makeEvidenceDirectory("Library/Caches/com.example.running", home: home)
        try makeEvidenceDirectory("Library/Caches/com.apple.oldapp", home: home)
        try makeEvidenceDirectory("Library/Caches/org.webkit.oldapp", home: home)
        try makeEvidenceDirectory("Library/Caches/com.example.young", home: home, ageDays: 5)
        try makeEvidenceDirectory("Library/Caches/com.example.small", home: home, bytes: 512)
        try makeEvidenceDirectory("Library/Application Support/Old Example App", home: home)
        try makeEvidenceDirectory("Library/Group Containers/group.com.example.lonely", home: home)

        let symlinkDirectory = home.appendingPathComponent("Library/Caches/com.example.symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1_100_000).write(to: outside.appendingPathComponent("outside.bin"))
        try FileManager.default.createSymbolicLink(
            at: symlinkDirectory.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )
        try setAge(days: 80, for: symlinkDirectory)

        let report = await CleanupEngine().analyze(
            mode: .leftovers,
            home: home,
            runningBundleIDs: ["com.example.running.helper"]
        )

        XCTAssertTrue(report.candidates.isEmpty)
    }

    func testApplicationLeftoversDisplayNameKeepsCamelCaseReadable() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundleID = "com.example.MyGreatApp"
        try makeEvidenceDirectory("Library/HTTPStorages/\(bundleID)", home: home, bytes: 1_100_000)

        let report = await CleanupEngine().analyze(mode: .leftovers, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.bundleID == bundleID })

        XCTAssertEqual(candidate.label, "My Great App (\(bundleID))")
    }

    func testSystemDataAdvisorDetectsLargeManualAreas() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let backup = home.appendingPathComponent("Library/Application Support/MobileSync/Backup/Device", isDirectory: true)
        let docker = home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0", isDirectory: true)
        let pipenv = home.appendingPathComponent(".local/share/virtualenvs/old-project", isDirectory: true)
        let conda = home.appendingPathComponent("miniconda3/pkgs/example", isDirectory: true)
        let stack = home.appendingPathComponent(".stack/programs/example", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docker, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pipenv, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conda, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128_000).write(to: backup.appendingPathComponent("backup.bin"))
        try Data(repeating: 2, count: 128_000).write(to: docker.appendingPathComponent("docker.bin"))
        try Data(repeating: 3, count: 128_000).write(to: pipenv.appendingPathComponent("python"))
        try Data(repeating: 4, count: 128_000).write(to: conda.appendingPathComponent("package.bin"))
        try Data(repeating: 5, count: 128_000).write(to: stack.appendingPathComponent("ghc"))

        let advisories = SystemDataAdvisor.scan(
            home: home,
            thresholds: .init(
                iOSBackups: 1,
                dockerData: 1,
                purgeableSpace: .max,
                toolManagedData: 1
            )
        )

        XCTAssertTrue(advisories.contains { $0.id == "ios-backups" && $0.actionType == .manualAction })
        XCTAssertTrue(advisories.contains { $0.id == "docker-data" && $0.actionType == .manualAction })
        XCTAssertTrue(advisories.contains { $0.id == "pipenv-environments" && $0.actionType == .manualAction })
        XCTAssertTrue(advisories.contains { $0.id == "miniconda-packages" && $0.actionType == .manualAction })
        XCTAssertTrue(advisories.contains { $0.id == "stack-root" && $0.actionType == .manualAction })
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaxOnWaxOffExpansionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setAge(days: Int, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: TimeInterval(-days * 86_400))],
            ofItemAtPath: url.path
        )
    }

    @discardableResult
    private func makeEvidenceDirectory(
        _ relativePath: String,
        home: URL,
        ageDays: Int = 80,
        bytes: Int = 256_000
    ) throws -> URL {
        let directory = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("data.bin")
        try Data(repeating: 1, count: bytes).write(to: file)
        try setAge(days: ageDays, for: file)
        try setAge(days: ageDays, for: directory)
        return directory
    }

    @discardableResult
    private func makeEvidenceFile(
        _ relativePath: String,
        home: URL,
        ageDays: Int = 80,
        bytes: Int = 256_000
    ) throws -> URL {
        let file = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: bytes).write(to: file)
        try setAge(days: ageDays, for: file)
        return file
    }

    private func makeInstalledApp(bundleID: String, home: URL) throws {
        let contents = home.appendingPathComponent("Applications/Installed.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }

    private func sourceFiles(under roots: [URL]) throws -> [URL] {
        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                files.append(root)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let file as URL in enumerator {
                let ext = file.pathExtension.lowercased()
                guard ["swift", "md", "html"].contains(ext) else { continue }
                files.append(file)
            }
        }
        return files
    }
}
