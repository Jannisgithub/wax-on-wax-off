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

        func resetAuthorization() {}
    }


    func testHighPolicyAddsBroaderCachesWithUncertainTargetsUnchecked() {
        let targets = Dictionary(uniqueKeysWithValues: CleanupPolicy.targets(for: .high).map { ($0.id, $0) })
        XCTAssertNotNil(targets["yarn-cache"])
        XCTAssertNotNil(targets["pnpm-cache"])
        XCTAssertNotNil(targets["cocoapods-cache"])
        XCTAssertNotNil(targets["cargo-download-cache"])
        XCTAssertNotNil(targets["go-build-cache"])
        XCTAssertTrue(CleanupPolicy.developerCaches.allSatisfy { !$0.defaultSelected })
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
        _ = await engine.apply(candidates: [candidate], home: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
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
            makeEvidenceDirectory("Library/Group Containers/group.\(bundleID)", home: home),
        ]

        let report = await CleanupEngine().analyze(mode: .leftovers, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.label == bundleID })

        XCTAssertFalse(candidate.defaultSelected)
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
