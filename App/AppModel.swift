import AppKit
import Darwin
import Foundation
import OSLog

protocol RunningApplicationTerminating: AnyObject {
    var isTerminated: Bool { get }
    var processIdentifier: pid_t { get }

    @discardableResult
    func terminate() -> Bool

    @discardableResult
    func forceTerminate() -> Bool
}

extension NSRunningApplication: RunningApplicationTerminating {}

enum ApplicationTerminationRequester {
    static func requestGracefulClose(_ applications: [any RunningApplicationTerminating]) {
        for application in applications where !application.isTerminated {
            if !application.terminate() {
                _ = application.forceTerminate()
            }
        }
    }

    static func forceClose(_ applications: [any RunningApplicationTerminating]) {
        for application in applications where !application.isTerminated {
            _ = application.forceTerminate()
        }
    }
}

struct ApplicationTerminationTracker {
    private(set) var pendingProcessIDs: Set<pid_t>

    var isComplete: Bool {
        pendingProcessIDs.isEmpty
    }

    @discardableResult
    mutating func markTerminated(_ processIdentifier: pid_t) -> Bool {
        pendingProcessIDs.remove(processIdentifier) != nil
    }

    @discardableResult
    mutating func track(_ processIdentifier: pid_t) -> Bool {
        pendingProcessIDs.insert(processIdentifier).inserted
    }
}

enum ASCIISparkline {
    private static let levels = Array("▁▂▃▄▅▆▇█")

    static func render(_ values: [Int64]) -> String {
        guard !values.isEmpty else { return "" }
        let normalizedValues = values.map { max(0, $0) }
        guard let maximum = normalizedValues.max(), maximum > 0 else {
            return String(repeating: String(levels[0]), count: values.count)
        }

        return String(normalizedValues.map { value in
            let ratio = Double(value) / Double(maximum)
            let index = min(levels.count - 1, Int(ratio * Double(levels.count - 1)))
            return levels[index]
        })
    }
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let highConfirmationPhrase = "DELETE"
    private static let launchChoiceSeenKey = "has-seen-launch-choice-v1"

    @Published var selectedMode: CleanupMode = .mid
    @Published var phase: AppPhase = .launchChoice
    @Published var candidates: [CleanupCandidate] = []
    @Published var selectedCandidateIDs: Set<String> = []
    @Published var warnings: [String] = []
    @Published var result: CleanupResult?
    @Published var isDemoMode = false
    @Published var demoStep: DemoStep = .intro
    @Published var guidanceMessage = "Choose the path: true focus (Full Version) or practice first (Demo)."
    @Published var activityItem = ""
    @Published var storageBalance: StorageBalance?
    @Published var systemAdvisories: [SystemDataAdvisor.Advisory] = []
    @Published var scoredCandidates: [ScoredCandidate] = []
    @Published var paretoEfficiency: ParetoEfficiency?
    @Published var expandedCandidateIDs: Set<String> = []
    @Published private(set) var cleanupHistory: [Int64] = []

    private let accessManager: FolderAccessManaging
    private let engine = CleanupEngine()
    private let historyStore = ReclaimHistoryStore()
    private let minimumActivityDuration: TimeInterval = 2.4
    private let demoActivityDelay: TimeInterval
    private let userDefaults: UserDefaults
    private let logger = Logger(subsystem: "com.jannis.waxonwaxoff", category: "ReviewFlow")
    private let currentUserID = getuid()
    private var authorizedHome: URL?
    private var analysisGeneration = 0
    private var appTerminationObserver: NSObjectProtocol?
    private var appTerminationCompletionTask: Task<Void, Never>?
    private var appTerminationForceTask: Task<Void, Never>?
    private var appTerminationPollTask: Task<Void, Never>?
    private var appTerminationTimeoutTask: Task<Void, Never>?
    private var appTerminationTracker = ApplicationTerminationTracker(pendingProcessIDs: [])
    private var pendingTerminationApplications: [pid_t: any RunningApplicationTerminating] = [:]
    private var pendingTerminationAppNames: [pid_t: String] = [:]
    private var pendingTerminationBundleIDs: Set<String> = []
    private var forceTerminationRequested = false

    init(
        demoActivityDelay: TimeInterval = 0.8,
        userDefaults: UserDefaults = .standard,
        accessManager: FolderAccessManaging = FolderAccessManager()
    ) {
        self.demoActivityDelay = demoActivityDelay
        self.userDefaults = userDefaults
        self.accessManager = accessManager
        cleanupHistory = historyStore.recentCleanupTotals(limit: 7)
        if userDefaults.bool(forKey: Self.launchChoiceSeenKey) || accessManager.authorizedHome() != nil {
            markLaunchChoiceSeen()
            restoreNormalLaunchState()
        }
#if DEBUG
        configureScreenshotStateIfRequested()
#endif
    }

    var runTitle: String {
        switch phase {
        case .launchChoice:
            "BEGIN TRAINING"
        case .idle:
            "SEEK CLUTTER"
        case .selectingFolder:
            "SEEKING..."
        case .readyToAnalyze, .emptyResults:
            "SEEK CLUTTER"
        case .analyzing: "SEEKING…"
        case .analysisComplete:
            selectedCandidateIDs.isEmpty ? "SELECT ITEMS TO CONTINUE" : (isDemoMode ? demoActionTitle : selectedActionTitle)
        case .demoMode:
            "CHOOSE PRACTICE MODE"
        case .reviewReady:
            selectedCandidateIDs.isEmpty ? "SELECT ITEMS TO CONTINUE" : (isDemoMode ? demoActionTitle : selectedActionTitle)
        case .permissionError, .failed:
            "SELECT DOJO (HOME)"
        case .cleaning:
            "REMOVING…"
        case .cleanupComplete:
            isDemoMode ? "PRACTICE AGAIN" : "SEEK CLUTTER AGAIN"
        case .waitingForAppsToClose:
            "CLOSE APPS TO CONTINUE"
        }
    }

    var selectedBytes: Int64 {
        candidates
            .filter { selectedCandidateIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var hasSelectableCandidates: Bool {
        selectableCandidateCount > 0
    }

    var selectableCandidateCount: Int {
        candidates.lazy.filter(\.isSelectable).count
    }

    var selectedSelectableCandidateCount: Int {
        candidates.lazy.filter { $0.isSelectable && self.selectedCandidateIDs.contains($0.id) }.count
    }

    var allSelectableSelected: Bool {
        let selectableIDs = Set(candidates.filter(\.isSelectable).map(\.id))
        return !selectableIDs.isEmpty && selectableIDs.isSubset(of: selectedCandidateIDs)
    }

    var canRun: Bool {
        switch phase {
        case .launchChoice:
            false
        case .idle, .readyToAnalyze, .emptyResults, .permissionError, .failed, .cleanupComplete:
            true
        case .demoMode:
            false
        case .analysisComplete, .reviewReady:
            !selectedCandidateIDs.isEmpty
        case .selectingFolder, .analyzing, .cleaning, .waitingForAppsToClose:
            false
        }
    }

    var canStartOver: Bool {
        switch phase {
        case .selectingFolder, .analyzing, .cleaning:
            false
        default:
            true
        }
    }

    func runPrimaryAction() {
        switch phase {
        case .launchChoice:
            break
        case .idle, .permissionError, .failed:
            beginRealAnalysisFlow()
        case .readyToAnalyze, .emptyResults:
            startAnalysis()
        case .demoMode:
            break
        case .analysisComplete, .reviewReady:
            confirmAndApply()
        case .cleanupComplete:
            if isDemoMode {
                startDemoWorkflow()
            } else {
                startAnalysis()
            }
        default:
            break
        }
    }

    func confirmStartOver() {
        guard canStartOver else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Start over?"
        alert.informativeText = "This clears WaxOnWaxOff's saved folder approval, demo choice, and local cleanup history. Nothing outside the app is changed."
        alert.addButton(withTitle: "Start Over")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startOverAsFreshInstall()
    }

    func startOverAsFreshInstall() {
        guard canStartOver else { return }
        analysisGeneration += 1
        accessManager.resetAuthorization()
        historyStore.reset()
        cleanupHistory = []
        userDefaults.removeObject(forKey: Self.launchChoiceSeenKey)
        authorizedHome = nil
        selectedMode = .mid
        isDemoMode = false
        demoStep = .intro
        clearScanState()
        phase = .launchChoice
        guidanceMessage = "Choose the path: true focus (Full Version) or practice first (Demo)."
    }

    func selectMode(_ mode: CleanupMode) {
        guard phase != .selectingFolder && phase != .analyzing && phase != .cleaning else { return }
        analysisGeneration += 1
        guard !isDemoMode, phase != .launchChoice else { return }
        selectedMode = mode
        clearScanState()
        if authorizedHome != nil || accessManager.authorizedHome() != nil {
            phase = .readyToAnalyze
            guidanceMessage = "Ready. Choose a cleanup mode and run analysis."
        } else {
            phase = .idle
            guidanceMessage = "Select a cleanup mode and run analysis."
        }
    }

    func showSamplePlan() {
        startDemoWorkflow()
        selectDemoMode(.mid)
    }

    func openDemoMode() {
        startDemoWorkflow()
    }

    func exitDemoMode() {
        skipToFullVersion()
    }

    func runRealAnalysis() {
        skipToFullVersion()
        beginRealAnalysisFlow()
    }

    func skipToFullVersion() {
        analysisGeneration += 1
        markLaunchChoiceSeen()
        isDemoMode = false
        demoStep = .intro
        clearScanState()
        if authorizedHome == nil {
            authorizedHome = accessManager.authorizedHome()
        }
        phase = authorizedHome == nil ? .idle : .readyToAnalyze
        guidanceMessage = authorizedHome == nil
            ? "Select a cleanup mode and run analysis."
            : "Ready. Choose a cleanup mode and run analysis."
    }

    func startDemoScan() {
        startDemoWorkflow()
        selectDemoMode(.low)
    }

    func startDemoWorkflow() {
        guard phase != .selectingFolder && phase != .analyzing && phase != .cleaning else { return }
        analysisGeneration += 1
        markLaunchChoiceSeen()
        isDemoMode = true
        demoStep = .intro
        clearScanState()
        guidanceMessage = "Practice builds form. Choose a mode to preview the review screen."
        phase = .demoMode
    }

    func selectDemoMode(_ mode: CleanupMode) {
        guard phase != .selectingFolder && phase != .analyzing && phase != .cleaning else { return }
        analysisGeneration += 1
        let generation = analysisGeneration
        isDemoMode = true
        selectedMode = mode
        demoStep = demoStep(for: mode)
        clearScanState()
        phase = .analyzing
        activityItem = "DEMO / Preparing \(mode.compactTitle) sample plan"
        guidanceMessage = "Loading a sample \(mode.title) plan. No real files are scanned, moved, or deleted."
        guard demoActivityDelay > 0 else {
            finishDemoModeSelection(mode, generation: generation)
            return
        }
        let earliestReviewDate = Date().addingTimeInterval(demoActivityDelay)
        Task {
            await wait(until: earliestReviewDate)
            finishDemoModeSelection(mode, generation: generation)
        }
    }

    func advanceDemoWorkflow() {
        guard phase != .selectingFolder && phase != .analyzing && phase != .cleaning else { return }
        guard isDemoMode else {
            startDemoWorkflow()
            return
        }
        selectDemoMode(demoStep.next.mode ?? selectedMode)
    }

    private func finishDemoModeSelection(_ mode: CleanupMode, generation: Int) {
        guard analysisGeneration == generation, isDemoMode, selectedMode == mode else { return }
        installScoredCandidates(demoCandidates(for: mode), mode: mode)
        selectedCandidateIDs = defaultSelectionIDs(for: mode)
        warnings = demoWarnings(for: mode)
        storageBalance = demoStorageBalance(for: mode)
        guidanceMessage = demoGuidance(for: demoStep)
        updateReviewPhase()
    }

    func toggleCandidate(_ id: String) {
        guard candidates.first(where: { $0.id == id })?.isSelectable == true else { return }
        if selectedCandidateIDs.contains(id) {
            selectedCandidateIDs.remove(id)
        } else {
            selectedCandidateIDs.insert(id)
        }
        updateReviewPhase()
    }

    func selectAll() {
        selectedCandidateIDs = Set(candidates.filter(\.isSelectable).map(\.id))
        updateReviewPhase()
    }

    func deselectAll() {
        selectedCandidateIDs = []
        updateReviewPhase()
    }

    func toggleCandidateExpansion(_ id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }),
              candidatePathCount(for: candidate) > 0 else { return }
        if expandedCandidateIDs.contains(id) {
            expandedCandidateIDs.remove(id)
        } else {
            expandedCandidateIDs.insert(id)
        }
    }

    func candidatePaths(for candidate: CleanupCandidate, limit: Int = 5) -> [URL] {
        Array(allCandidatePaths(for: candidate).prefix(max(0, limit)))
    }

    func candidatePathCount(for candidate: CleanupCandidate) -> Int {
        allCandidatePaths(for: candidate).count
    }

    func applySmartSelection() {
        guard selectedMode == .high, !scoredCandidates.isEmpty else { return }
        selectedCandidateIDs = smartHighSelectionIDs()
        updateReviewPhase()
    }

    private func beginRealAnalysisFlow() {
        isDemoMode = false
        clearScanState()

        if let home = authorizedHome ?? accessManager.authorizedHome() {
            startAnalysis(with: home, source: "saved bookmark")
            return
        }

        phase = .selectingFolder
        guidanceMessage = "Choose your Home folder to continue."
        logger.info("Home folder selection started")
        guard let home = accessManager.requestHomeFolder() else {
            phase = .permissionError("Home folder selection did not complete. Select the signed-in user's Home folder to run real cleanup.")
            guidanceMessage = "Choose your Home folder to continue real analysis, or restart the app and choose Demo for sample data."
            logger.error("Home folder selection cancelled or rejected")
            return
        }
        startAnalysis(with: home, source: "folder picker")
    }

    private func markLaunchChoiceSeen() {
        userDefaults.set(true, forKey: Self.launchChoiceSeenKey)
    }

    private func restoreNormalLaunchState() {
        if let home = authorizedHome ?? accessManager.authorizedHome() {
            authorizedHome = home
            phase = .readyToAnalyze
            guidanceMessage = "Ready. Choose a cleanup mode and run analysis."
        } else {
            phase = .idle
            guidanceMessage = "Select a cleanup mode and run analysis."
        }
    }

    private func startAnalysis(with home: URL, source: String) {
        authorizedHome = home
        phase = .readyToAnalyze
        guidanceMessage = "Ready. Choose a cleanup mode and run analysis."
        logger.info("Folder selected from \(source, privacy: .public): \(home.path, privacy: .private)")
        startAnalysis()
    }

    private func startAnalysis(
        skippingConflictingCheck: Bool = false,
        additionalWarnings: [String] = []
    ) {
        isDemoMode = false
        guard let home = authorizedHome ?? accessManager.authorizedHome() else {
            beginRealAnalysisFlow()
            return
        }
        authorizedHome = home

        let mode = selectedMode
        if !skippingConflictingCheck {
            let conflicting = conflictingRunningApps(for: mode)
            if !conflicting.isEmpty {
                clearScanState()
                phase = .waitingForAppsToClose(conflicting)
                guidanceMessage = "Some apps are running that need to be closed to complete the scan."
                activityItem = "WAITING / Please close conflicting apps"
                return
            }
        }

        let scopedAccess = home.startAccessingSecurityScopedResource()
        guard scopedAccess else {
            accessManager.resetAuthorization()
            authorizedHome = nil
            phase = .permissionError("macOS did not grant access to the selected Home folder. Select the Home folder again to continue.")
            guidanceMessage = "Permission failed. The saved folder access was cleared so you can select the Home folder again."
            logger.error("Security scoped access failed for \(home.path, privacy: .private)")
            return
        }
        logger.info("Security scoped access succeeded for \(home.path, privacy: .private)")

        phase = .analyzing
        clearScanState()
        analysisGeneration += 1
        let generation = analysisGeneration
        activityItem = "ANALYSIS / Preparing \(mode.compactTitle) analysis"
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let earliestReviewDate = Date().addingTimeInterval(minimumActivityDuration)
        logger.info("Scan started for \(mode.rawValue, privacy: .public)")

        Task {
            let baseStorageBalance = StorageBalanceAnalyzer.analyze(volumeAt: home)
            let advisoryTask = Task.detached(priority: .utility) {
                mode == .high ? SystemDataAdvisor.scan(home: home) : []
            }
            let report = await self.engine.analyze(
                mode: mode,
                home: home,
                runningBundleIDs: runningIDs,
                progress: self.activityProgressHandler(prefix: "ANALYSIS")
            )
            let advisories = await advisoryTask.value
            home.stopAccessingSecurityScopedResource()
            await self.wait(until: earliestReviewDate)
            guard self.analysisGeneration == generation, self.selectedMode == mode, !self.isDemoMode else { return }
            let enriched = report.candidates.map(self.historyStore.enrich)
            self.installScoredCandidates(enriched, mode: mode)
            self.selectedCandidateIDs = self.defaultSelectionIDs(for: mode)
            self.warnings = report.warnings + additionalWarnings
            self.storageBalance = baseStorageBalance
            self.systemAdvisories = advisories
            let itemCount = self.candidates.reduce(0) { $0 + max($1.itemCount, 1) }
            let selectedSize = self.candidates
                .filter { self.selectedCandidateIDs.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.size }
            self.logger.info("Scan completed for \(mode.rawValue, privacy: .public): categories=\(self.candidates.count, privacy: .public), items=\(itemCount, privacy: .public), selectedBytes=\(selectedSize, privacy: .public), warnings=\(self.warnings.count, privacy: .public)")
            self.updateReviewPhase()
        }
    }

    func continueAnalysis(closingApps appsToClose: Set<NSRunningApplication>) {
        cancelAppTerminationWait()
        let activeApps = appsToClose.filter { !$0.isTerminated && $0.processIdentifier > 0 }
        guard !activeApps.isEmpty else {
            resumeAnalysisAfterAppWait()
            return
        }

        appTerminationTracker = ApplicationTerminationTracker(
            pendingProcessIDs: Set(activeApps.map(\.processIdentifier))
        )
        pendingTerminationApplications = Dictionary(uniqueKeysWithValues: activeApps.map {
            ($0.processIdentifier, $0)
        })
        pendingTerminationAppNames = Dictionary(uniqueKeysWithValues: activeApps.map {
            ($0.processIdentifier, $0.localizedName ?? "App \($0.processIdentifier)")
        })
        pendingTerminationBundleIDs = Set(activeApps.compactMap(\.bundleIdentifier).map {
            $0.lowercased()
        })
        guidanceMessage = waitingForAppsMessage(count: activeApps.count)
        activityItem = "WAITING / 0 of \(activeApps.count) selected apps closed"

        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        appTerminationObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let processIdentifier = application.processIdentifier
            Task { @MainActor [weak self] in
                self?.recordApplicationTermination(processIdentifier)
            }
        }

        appTerminationPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.refreshApplicationTerminationState()
            }
        }

        appTerminationForceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.forceTerminatePendingApplications()
        }

        appTerminationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.handleApplicationTerminationFailure()
        }

        ApplicationTerminationRequester.requestGracefulClose(
            activeApps.map { $0 as any RunningApplicationTerminating }
        )
        refreshApplicationTerminationState()
    }

    func continueAnalysisWithoutClosing() {
        cancelAppTerminationWait()
        startAnalysis(
            skippingConflictingCheck: true,
            additionalWarnings: ["Scan continued while conflicting apps were running. Active app caches are skipped for safety."]
        )
    }

    private func recordApplicationTermination(_ processIdentifier: pid_t) {
        guard appTerminationTracker.markTerminated(processIdentifier) else { return }
        pendingTerminationApplications.removeValue(forKey: processIdentifier)
        let remainingCount = appTerminationTracker.pendingProcessIDs.count

        if appTerminationTracker.isComplete {
            activityItem = "WAITING / Confirming selected apps stay closed"
            appTerminationCompletionTask?.cancel()
            appTerminationCompletionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.confirmApplicationTerminationCompletion()
            }
        } else {
            activityItem = "WAITING / \(remainingCount) selected app process\(remainingCount == 1 ? "" : "es") still running"
            guidanceMessage = waitingForAppsMessage(count: remainingCount)
        }
    }

    private func confirmApplicationTerminationCompletion() {
        let relaunchedApplications = NSWorkspace.shared.runningApplications.filter { application in
            guard !application.isTerminated,
                  application.processIdentifier > 0,
                  let bundleIdentifier = application.bundleIdentifier?.lowercased() else {
                return false
            }
            return pendingTerminationBundleIDs.contains(bundleIdentifier)
        }

        var newlyTrackedApplications: [any RunningApplicationTerminating] = []
        for application in relaunchedApplications {
            let processIdentifier = application.processIdentifier
            guard appTerminationTracker.track(processIdentifier) else { continue }
            pendingTerminationApplications[processIdentifier] = application
            pendingTerminationAppNames[processIdentifier] = application.localizedName ?? "App \(processIdentifier)"
            newlyTrackedApplications.append(application)
        }

        guard !newlyTrackedApplications.isEmpty else {
            resumeAnalysisAfterAppWait()
            return
        }

        let remainingCount = appTerminationTracker.pendingProcessIDs.count
        guidanceMessage = remainingCount == 1
            ? "The selected app relaunched. Terminating it again before analysis."
            : "Selected apps relaunched. Terminating \(remainingCount) processes again before analysis."
        activityItem = "CLOSING / Terminating relaunched selected apps"
        if forceTerminationRequested {
            ApplicationTerminationRequester.forceClose(newlyTrackedApplications)
        } else {
            ApplicationTerminationRequester.requestGracefulClose(newlyTrackedApplications)
        }
        refreshApplicationTerminationState()
    }

    private func refreshApplicationTerminationState() {
        let processIdentifiers = appTerminationTracker.pendingProcessIDs
        for processIdentifier in processIdentifiers {
            let application = NSRunningApplication(processIdentifier: processIdentifier)
            if application == nil || application?.isTerminated == true {
                recordApplicationTermination(processIdentifier)
            }
        }
    }

    private func forceTerminatePendingApplications() {
        forceTerminationRequested = true
        let pendingProcessIDs = appTerminationTracker.pendingProcessIDs
        guard !pendingProcessIDs.isEmpty else { return }

        let remainingCount = pendingProcessIDs.count
        guidanceMessage = remainingCount == 1
            ? "The selected app did not close normally. Force-terminating it now."
            : "\(remainingCount) selected apps did not close normally. Force-terminating them now."
        activityItem = "CLOSING / Force-terminating \(remainingCount) selected app\(remainingCount == 1 ? "" : "s")"

        let applications = pendingProcessIDs.compactMap { pendingTerminationApplications[$0] }
        ApplicationTerminationRequester.forceClose(applications)
        refreshApplicationTerminationState()
    }

    private func handleApplicationTerminationFailure() {
        refreshApplicationTerminationState()
        let remainingNames = Set(appTerminationTracker.pendingProcessIDs
            .compactMap { pendingTerminationAppNames[$0] }
        ).sorted()
        guard !remainingNames.isEmpty else { return }

        let appList = remainingNames.joined(separator: ", ")
        let remainingApps = conflictingRunningApps(for: selectedMode)
        cancelAppTerminationWait()
        phase = .waitingForAppsToClose(remainingApps)
        guidanceMessage = "macOS did not allow \(appList) to be terminated. Try Close Selected again or use Skip & Continue."
        activityItem = "WAITING / Could not terminate \(appList)"
    }

    private func resumeAnalysisAfterAppWait() {
        cancelAppTerminationWait()

        var analysisWarnings: [String] = []
        let stillRunning = conflictingRunningApps(for: selectedMode)
            .compactMap(\.localizedName)
            .sorted()
        if !stillRunning.isEmpty {
            analysisWarnings.append(
                "Scan continued while \(stillRunning.joined(separator: ", ")) remained open. Active app caches are skipped for safety."
            )
        }

        startAnalysis(
            skippingConflictingCheck: true,
            additionalWarnings: analysisWarnings
        )
    }

    private func waitingForAppsMessage(count: Int) -> String {
        count == 1
            ? "Waiting for the selected app to close before analysis."
            : "Waiting for \(count) selected apps to close before analysis."
    }

    private func cancelAppTerminationWait() {
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
            self.appTerminationObserver = nil
        }
        appTerminationTimeoutTask?.cancel()
        appTerminationTimeoutTask = nil
        appTerminationCompletionTask?.cancel()
        appTerminationCompletionTask = nil
        appTerminationForceTask?.cancel()
        appTerminationForceTask = nil
        appTerminationPollTask?.cancel()
        appTerminationPollTask = nil
        appTerminationTracker = ApplicationTerminationTracker(pendingProcessIDs: [])
        pendingTerminationApplications = [:]
        pendingTerminationAppNames = [:]
        pendingTerminationBundleIDs = []
        forceTerminationRequested = false
    }

    private func conflictingRunningApps(for mode: CleanupMode) -> [NSRunningApplication] {
        guard mode != .leftovers else { return [] }
        let runningApps = NSWorkspace.shared.runningApplications
        var conflicting: [NSRunningApplication] = []
        let targets = CleanupPolicy.targets(for: mode)
        let appCaches = mode == .high ? CleanupPolicy.appSupportCaches : []

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier?.lowercased() else { continue }

            let isTargetOwned = targets.contains { target in
                target.ownerBundleIDs.contains { owner in
                    let normalizedOwner = owner.lowercased()
                    return bundleID == normalizedOwner || bundleID.hasPrefix(normalizedOwner + ".")
                }
            }

            let isCacheOwned = appCaches.contains { rule in
                rule.ownerBundleIDs.contains { owner in
                    let normalizedOwner = owner.lowercased()
                    return bundleID == normalizedOwner || bundleID.hasPrefix(normalizedOwner + ".")
                }
            }

            if isTargetOwned || isCacheOwned {
                conflicting.append(app)
            }
        }
        return conflicting
    }

    func performAdvisoryAction(_ advisory: SystemDataAdvisor.Advisory) {
        switch advisory.destination {
        case let .reveal(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .storageSettings:
            openStorageSettings()
        case .none:
            break
        }
    }

    func openStorageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") else { return }
        NSWorkspace.shared.open(url)
    }

    private func clearScanState() {
        cancelAppTerminationWait()
        result = nil
        candidates = []
        scoredCandidates = []
        selectedCandidateIDs = []
        expandedCandidateIDs = []
        warnings = []
        storageBalance = nil
        systemAdvisories = []
        paretoEfficiency = nil
        activityItem = ""
    }

    private func updateReviewPhase() {
        refreshSelectionMetrics()
        if candidates.isEmpty && systemAdvisories.isEmpty {
            activityItem = ""
            phase = .emptyResults
            guidanceMessage = isDemoMode
                ? "This demo sample has no items. Choose another sample mode or skip demo."
                : "Nothing eligible was found for this mode. Try another mode or run analysis again later."
        } else if selectedCandidateIDs.isEmpty {
            activityItem = ""
            phase = .analysisComplete
            guidanceMessage = isDemoMode
                ? demoGuidance(for: demoStep)
                : "Review the analysis results. Select one or more items before applying a cleanup plan."
        } else {
            activityItem = ""
            phase = .reviewReady
            guidanceMessage = isDemoMode
                ? demoGuidance(for: demoStep)
                : "Review selected items before removal. Files are not removed automatically."
        }
    }

    private func installScoredCandidates(_ rawCandidates: [CleanupCandidate], mode: CleanupMode) {
        scoredCandidates = CandidateScorer.score(rawCandidates, mode: mode)
        candidates = scoredCandidates.map(\.candidate)
    }

    private func defaultSelectionIDs(for mode: CleanupMode) -> Set<String> {
        if mode == .high {
            return smartHighSelectionIDs()
        }
        return baselineSelectionIDs()
    }

    private func smartHighSelectionIDs() -> Set<String> {
        var selected = baselineSelectionIDs()
        selected.formUnion(CandidateScorer.paretoSelection(candidates: scoredCandidates))
        return selected
    }

    private func baselineSelectionIDs() -> Set<String> {
        Set(candidates.filter { $0.defaultSelected && $0.isSelectable }.map(\.id))
    }

    private func allCandidatePaths(for candidate: CleanupCandidate) -> [URL] {
        switch candidate.operation {
        case let .deleteFiles(plan):
            plan.urls
        case let .deleteTree(plan):
            [plan.url]
        case let .deleteTrees(plans, measurementRoot: _):
            plans.map(\.url)
        case let .recycle(urls):
            urls
        case .recommendation:
            []
        }
    }

    private func refreshSelectionMetrics() {
        paretoEfficiency = CandidateScorer.paretoEfficiency(
            candidates: candidates,
            selectedIDs: selectedCandidateIDs
        )
        if let balance = storageBalance {
            storageBalance = StorageBalanceAnalyzer.enrich(
                balance,
                selectedBytes: selectedBytes,
                candidateCount: selectedCandidateIDs.count
            )
        }
    }

    private func confirmAndApply() {
        guard !isDemoMode else {
            showDemoResult()
            return
        }
        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        guard !selected.isEmpty, let home = authorizedHome else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmationTitle(for: selected)
        alert.informativeText = confirmationText(for: selected)
        var highConfirmationField: NSTextField?
        if selectedMode == .high {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "Type \(Self.highConfirmationPhrase)"
            alert.accessoryView = field
            highConfirmationField = field
        }
        alert.addButton(withTitle: selected.contains(where: isDirectDelete) ? "Apply Cleanup" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let highConfirmationField,
           highConfirmationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != Self.highConfirmationPhrase {
            let mismatch = NSAlert()
            mismatch.alertStyle = .warning
            mismatch.messageText = "Confirmation did not match"
            mismatch.informativeText = "HIGH cleanup was not applied. Type \(Self.highConfirmationPhrase) exactly to confirm HIGH-mode cleanup."
            mismatch.runModal()
            return
        }

        guard home.startAccessingSecurityScopedResource() else {
            accessManager.resetAuthorization()
            authorizedHome = nil
            phase = .permissionError("macOS did not grant access to the selected Home folder. Select the Home folder again to continue.")
            guidanceMessage = "Permission failed. The saved folder access was cleared so you can select the Home folder again."
            logger.error("Security scoped access failed before cleanup for \(home.path, privacy: .private)")
            return
        }

        phase = .cleaning
        activityItem = "APPLY / Preparing selected cleanup"
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
                runningBundleIDs: runningIDs,
                progress: activityProgressHandler(prefix: "APPLY")
            )
            let recycleResult = await recycle(
                recycleCandidates,
                inside: home,
                runningBundleIDs: runningIDs,
                mode: mode
            )
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
            cleanupHistory = historyStore.recentCleanupTotals(limit: 7)
            result = cleanupResult
            warnings += cleanupResult.warnings
            activityItem = ""
            logger.info("Cleanup completed for \(mode.rawValue, privacy: .public): removedBytes=\(cleanupResult.removedBytes, privacy: .public), recycledBytes=\(cleanupResult.recycledBytes, privacy: .public), removedItems=\(cleanupResult.removedItems, privacy: .public), recycledItems=\(cleanupResult.recycledItems, privacy: .public), skippedItems=\(cleanupResult.skippedItems, privacy: .public), warnings=\(cleanupResult.warnings.count, privacy: .public)")
            phase = .cleanupComplete
        }
    }

    private func showDemoResult() {
        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        demoStep = .complete
        result = CleanupResult(
            removedBytes: 0,
            recycledBytes: selected.reduce(Int64(0)) { $0 + $1.size },
            removedItems: 0,
            recycledItems: selected.reduce(0) { $0 + max($1.itemCount, 1) },
            skippedItems: 0,
            warnings: []
        )
        warnings = ["Demo complete. No real files were scanned, moved, or deleted."]
        guidanceMessage = "Demo applied the sample selection only. No real files were scanned, moved, or deleted."
        activityItem = ""
        phase = .cleanupComplete
    }

    private func sampleCandidate(
        id: String,
        label: String,
        detail: String,
        size: Int64,
        itemCount: Int,
        badge: CandidateBadge,
        defaultSelected: Bool,
        operation: CleanupOperation? = nil
    ) -> CleanupCandidate {
        CleanupCandidate(
            id: id,
            label: label,
            detail: "\(itemCount) item\(itemCount == 1 ? "" : "s") - \(detail)",
            size: size,
            itemCount: itemCount,
            badge: badge,
            defaultSelected: defaultSelected,
            operation: operation ?? .recycle([]),
            currentFootprint: size
        )
    }

    private func demoStorageBalance(for mode: CleanupMode) -> StorageBalance {
        let gigabyte: Int64 = 1_000_000_000
        let total = 512 * gigabyte
        let physicalFree: Int64
        let purgeable: Int64
        switch mode {
        case .low:
            physicalFree = 96 * gigabyte
            purgeable = 9 * gigabyte
        case .mid:
            physicalFree = 74 * gigabyte
            purgeable = 14 * gigabyte
        case .high:
            physicalFree = 42 * gigabyte
            purgeable = 18 * gigabyte
        case .leftovers:
            physicalFree = 58 * gigabyte
            purgeable = 12 * gigabyte
        }
        return StorageBalance(
            totalCapacity: total,
            physicalFree: physicalFree,
            availableForImportant: physicalFree + purgeable,
            availableForOpportunistic: physicalFree + purgeable + (6 * gigabyte)
        )
    }

    private func demoCandidates(for mode: CleanupMode) -> [CleanupCandidate] {
        switch mode {
        case .low:
            [
                sampleCandidate(id: "demo-low-caches", label: "Old user caches", detail: "Cache files older than the selected mode's age rule.", size: 10_500_000, itemCount: 67, badge: .safe, defaultSelected: true),
                sampleCandidate(id: "demo-low-crash-reports", label: "Old crash reports", detail: "Diagnostic reports older than the selected mode's age rule.", size: 20_000, itemCount: 5, badge: .safe, defaultSelected: true),
                sampleCandidate(id: "demo-low-browser-temporary", label: "Browser temporary files", detail: "Temporary browser cache files. Review before removing.", size: 42_000_000, itemCount: 18, badge: .confirm, defaultSelected: true),
            ]
        case .mid:
            [
                sampleCandidate(id: "demo-mid-caches", label: "Old user caches", detail: "Cache files older than the selected mode's age rule.", size: 10_500_000, itemCount: 67, badge: .safe, defaultSelected: true),
                sampleCandidate(id: "demo-mid-crash-reports", label: "Old crash reports", detail: "Diagnostic reports older than the selected mode's age rule.", size: 20_000, itemCount: 5, badge: .safe, defaultSelected: true),
                sampleCandidate(id: "demo-mid-app-support", label: "App support cache", detail: "Non-essential app cache files. Review before removing.", size: 180_000_000, itemCount: 41, badge: .confirm, defaultSelected: true),
                sampleCandidate(id: "demo-mid-package-cache", label: "Package cache", detail: "Re-downloadable package data.", size: 96_000_000, itemCount: 12, badge: .confirm, defaultSelected: true),
            ]
        case .high:
            [
                sampleCandidate(id: "demo-high-caches", label: "Old user caches", detail: "Cache files older than the selected mode's age rule.", size: 10_500_000, itemCount: 67, badge: .safe, defaultSelected: true),
                sampleCandidate(id: "demo-high-crash-reports", label: "Old crash reports", detail: "Diagnostic reports older than the selected mode's age rule.", size: 20_000, itemCount: 5, badge: .safe, defaultSelected: true),
                sampleCandidate(id: "demo-high-google-updater", label: "Google updater downloads", detail: "Downloaded updater packages.", size: 4_000, itemCount: 3, badge: .confirm, defaultSelected: false),
                sampleCandidate(id: "demo-high-pip-cache", label: "pip package cache", detail: "Re-downloadable Python package data.", size: 6_100_000, itemCount: 23, badge: .confirm, defaultSelected: false),
                sampleCandidate(id: "demo-high-xcode-products", label: "Xcode Products", detail: "Developer build products that can usually be recreated.", size: 5_400_000, itemCount: 11, badge: .confirm, defaultSelected: false),
                sampleCandidate(id: "demo-high-render-cache", label: "Render cache", detail: "Closed-app render cache files.", size: 220_000_000, itemCount: 8, badge: .confirm, defaultSelected: false),
            ]
        case .leftovers:
            [
                sampleCandidate(id: "demo-leftovers-app-support", label: "Old application support folder", detail: "Possible inactive application data. Review before moving to Trash.", size: 120_000_000, itemCount: 1, badge: .review, defaultSelected: false),
                sampleCandidate(id: "demo-leftovers-preference", label: "Old preference file", detail: "Possible preference file from an app no longer installed.", size: 8_000, itemCount: 1, badge: .review, defaultSelected: false),
                sampleCandidate(id: "demo-leftovers-saved-state", label: "Old saved state", detail: "Saved state from an inactive app.", size: 2_000_000, itemCount: 1, badge: .review, defaultSelected: false),
            ]
        }
    }

    private func demoWarnings(for mode: CleanupMode) -> [String] {
        var messages = [
            "Practice builds form. No real files are scanned, moved, or deleted.",
            mode.summary
        ]
        if mode == .leftovers {
            messages.append("Application Leftovers are never selected automatically and are moved to Trash, not permanently deleted.")
        }
        return messages
    }

    private func demoGuidance(for step: DemoStep) -> String {
        switch step {
        case .intro:
            "Practice builds form. Choose a mode to preview the review screen."
        case .low:
            "LOW practice: conservative old caches and logs are selected by default. This explains the simplest form."
        case .mid:
            "MID practice: adds known re-downloadable app caches while still preserving the soul (personal files)."
        case .high:
            "HIGH practice: high-value developer, package, sandbox, and app caches are selected for review. True focus requires typing DELETE."
        case .leftovers:
            "APPLICATION LEFTOVERS practice: possible inactive branches start unchecked and would be swept to Trash, not permanently lost."
        case .complete:
            "Practice complete. No files were scanned, moved, or deleted. End practice whenever you are ready."
        }
    }

    private func demoStep(for mode: CleanupMode) -> DemoStep {
        switch mode {
        case .low: .low
        case .mid: .mid
        case .high: .high
        case .leftovers: .leftovers
        }
    }

    private func demoActivityPath(for mode: CleanupMode) -> String {
        switch mode {
        case .low:
            "/Users/reviewuser/Library/Caches/com.example.old-cache"
        case .mid:
            "/Users/reviewuser/Library/Application Support/Example/Cache"
        case .high:
            "/Users/reviewuser/Library/Developer/Xcode/DerivedData/Example"
        case .leftovers:
            "/Users/reviewuser/Library/Application Support/com.example.oldapp"
        }
    }

    private func wait(until date: Date) async {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }

    private func activityProgressHandler(prefix: String) -> CleanupProgressUpdate {
        { [weak self] item in
            await MainActor.run {
                self?.activityItem = "\(prefix) / \(item)"
            }
        }
    }

    private func confirmationText(for selected: [CleanupCandidate]) -> String {
        let amount = selected.reduce(Int64(0)) { $0 + $1.size }
        let directCount = selected.filter(isDirectDelete).count
        let trashCount = selected.filter(isRecycle).count
        let base = "\(selected.count) selected action(s), totaling \(amount.fileSizeText): \(directCount) direct removal and \(trashCount) moved to Trash. Every path and safety condition is checked again."
        if selectedMode == .high {
            return base + "\n\nStop active builds, package managers, and development servers first. HIGH may remove developer caches, package caches, and temporary app cache files. Projects, source files, personal files, and system components are excluded, but rebuilding may take longer afterward."
        }
        if selectedMode == .leftovers {
            return base + "\n\nItems remain recoverable in Trash."
        }
        return base + "\n\nPersonal documents and protected system files are excluded."
    }

    private func recycle(
        _ candidates: [CleanupCandidate],
        inside home: URL,
        runningBundleIDs: Set<String> = [],
        mode: CleanupMode? = nil
    ) async -> CleanupResult {
        guard !candidates.isEmpty else {
            return CleanupResult(removedBytes: 0, removedItems: 0, skippedItems: 0, warnings: [])
        }
        var validCandidates: [CleanupCandidate] = []
        var urls: [URL] = []
        var skipped = 0
        for candidate in candidates {
            guard case let .recycle(candidateURLs) = candidate.operation,
                  !candidateURLs.isEmpty,
                  mode != .leftovers || leftoverCandidateStillInactive(candidate, runningBundleIDs: runningBundleIDs),
                  candidateURLs.allSatisfy({ isSafeForRecycle($0, inside: home) }),
                  candidateURLs.reduce(Int64(0), { $0 + sizeOfItem($1) }) == candidate.currentFootprint else {
                skipped += 1
                continue
            }
            validCandidates.append(candidate)
            urls += candidateURLs
            activityItem = "APPLY / \(candidate.label)"
        }
        guard !urls.isEmpty else {
            return CleanupResult(
                removedBytes: 0,
                removedItems: 0,
                skippedItems: skipped,
                warnings: skipped > 0 ? ["Skipped Trash items that changed after analysis or no longer match leftovers rules."] : []
            )
        }
        let finalURLs = urls
        let finalCandidates = validCandidates
        let skippedCount = skipped
        if let firstURL = finalURLs.first {
            activityItem = "APPLY / \(displayPathForActivity(firstURL, inside: home))"
        }
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
                var warnings = skippedCount > 0 ? ["Skipped Trash items that changed after analysis or no longer match leftovers rules."] : []
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

    private func displayPathForActivity(_ url: URL, inside home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let text: String
        if path == homePath || path.hasPrefix(homePath + "/") {
            let relative = String(path.dropFirst(homePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            text = relative.isEmpty ? "~" : "~/" + relative
        } else {
            text = url.lastPathComponent
        }
        guard text.count > 92 else { return text }
        return "…/" + text.suffix(76).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
            return "APPLY SELECTED PLAN"
        }
        return selected.contains(where: isDirectDelete) ? "APPLY SELECTED CLEANUP" : "MOVE SELECTED TO TRASH"
    }

    private var demoActionTitle: String {
        selectedMode == .leftovers ? "MOVE SELECTED TO TRASH" : "APPLY SELECTED CLEANUP"
    }

    private func confirmationTitle(for selected: [CleanupCandidate]) -> String {
        if selected.contains(where: isDirectDelete) && selected.contains(where: isRecycle) {
            return "Apply selected cleanup plan?"
        }
        return selected.contains(where: isDirectDelete) ? "Apply selected cleanup?" : "Move selected items to Trash?"
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

    private func leftoverCandidateStillInactive(
        _ candidate: CleanupCandidate,
        runningBundleIDs: Set<String>
    ) -> Bool {
        let bundleID = candidate.label.lowercased()
        let candidateBundleID = candidate.bundleID ?? bundleID
        let normalizedBundleID = candidateBundleID.lowercased()
        guard isBundleIdentifier(normalizedBundleID),
              !normalizedBundleID.hasPrefix("com.apple."),
              !normalizedBundleID.hasPrefix("org.webkit.") else { return false }
        let isRunning = runningBundleIDs.contains { runningID in
            let running = runningID.lowercased()
            return running == normalizedBundleID || running.hasPrefix(normalizedBundleID + ".")
        }
        guard !isRunning else { return false }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: candidateBundleID).isEmpty
            && NSWorkspace.shared.urlsForApplications(withBundleIdentifier: normalizedBundleID).isEmpty
    }

    private func isBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
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
            activityItem = "ANALYSIS / /Users/reviewuser/Library/Caches/com.example.preview"
            phase = .analyzing
        case "cleaning":
            selectedMode = .mid
            activityItem = "APPLY / /Users/reviewuser/Library/Caches/com.example.preview"
            phase = .cleaning
        case "mid-review":
            selectedMode = .mid
            candidates = [
                sample("old-caches", "Old user caches", "1,284 items • Older than 14 days", 1_840_000_000, .safe, true),
                sample("logs", "Old user logs", "218 items • Diagnostic and app logs", 284_000_000, .safe, true),
                sample("chrome", "Chrome downloaded models", "Re-downloadable model cache", 732_000_000, .confirm, true),
            ]
            warnings = ["Chrome is closed; its selected re-downloadable cache is eligible."]
            phase = .reviewReady
        case "high-review":
            selectedMode = .high
            candidates = [
                sample("baseline", "Old caches and logs", "2,106 items • Older than 14 days", 2_420_000_000, .safe, true),
                sample("derived", "Xcode DerivedData", "Build products and indexes; source stays untouched", 8_740_000_000, .confirm, true),
                sample("npm", "npm package cache", "Re-downloadable package data", 1_120_000_000, .confirm, true),
            ]
            warnings = ["HIGH requires the typed confirmation \(Self.highConfirmationPhrase)."]
            phase = .reviewReady
        case "leftovers-review":
            selectedMode = .leftovers
            candidates = [
                sample("old-editor", "com.example.oldeditor", "No matching installed app • 126 days old", 542_000_000, .confirm, false),
                sample("old-player", "com.example.videoplayer", "No matching installed app • 94 days old", 186_000_000, .confirm, false),
                sample("old-helper", "Example Helper", "Application Support • review before selecting", 72_000_000, .confirm, false),
            ]
            selectedCandidateIDs = ["old-editor", "old-player"]
            warnings = ["Application Leftovers are moved to Trash and remain recoverable."]
            phase = .reviewReady
        case "result":
            selectedMode = .mid
            result = CleanupResult(removedBytes: 2_856_000_000, removedItems: 1_502, skippedItems: 3, warnings: [])
            cleanupHistory = [420_000_000, 980_000_000, 1_640_000_000, 2_856_000_000]
            phase = .cleanupComplete
        case "trash-result":
            selectedMode = .leftovers
            result = CleanupResult(
                removedBytes: 0,
                recycledBytes: 860_000_000,
                removedItems: 0,
                recycledItems: 6,
                skippedItems: 1,
                warnings: []
            )
            cleanupHistory = [420_000_000, 980_000_000, 1_640_000_000]
            phase = .cleanupComplete
        default:
            break
        }
        if !candidates.isEmpty {
            let rawCandidates = candidates
            installScoredCandidates(rawCandidates, mode: selectedMode)
            if storageBalance == nil {
                storageBalance = demoStorageBalance(for: selectedMode)
            }
        }
        if !candidates.isEmpty && selectedCandidateIDs.isEmpty {
            selectedCandidateIDs = Set(candidates.filter(\.defaultSelected).map(\.id))
            updateReviewPhase()
        } else {
            refreshSelectionMetrics()
        }
    }

    private func sample(
        _ id: String,
        _ label: String,
        _ detail: String,
        _ size: Int64,
        _ badge: CandidateBadge,
        _ selected: Bool
    ) -> CleanupCandidate {
        CleanupCandidate(
            id: id,
            label: label,
            detail: detail,
            size: size,
            itemCount: 1,
            badge: badge,
            defaultSelected: selected,
            operation: badge == .review ? .recommendation : .recycle([])
        )
    }
#endif
}
