import Foundation
import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focusedCandidateID: String?

    private let background = Color(red: 0.035, green: 0.035, blue: 0.035)
    private let panel = Color(red: 0.085, green: 0.085, blue: 0.08)
    private let ink = Color(red: 0.93, green: 0.93, blue: 0.90)
    private let muted = Color(red: 0.55, green: 0.55, blue: 0.52)

    var body: some View {
        VStack(spacing: 8) {
            header
            if model.phase != .launchChoice {
                safetyNotice
            }
            if model.phase != .launchChoice && model.isDemoMode && model.phase != .analyzing {
                demoModePicker
            } else if model.phase != .launchChoice && !model.isDemoMode {
                modePicker
            }
            content
                .layoutPriority(1)
            if shouldShowPrimaryButton {
                primaryButton
            }
        }
        .padding(12)
        .frame(minWidth: 860, minHeight: 650)
        .background(background)
        .foregroundStyle(ink)
        .font(.system(.body, design: .monospaced))
#if DEBUG
        .onAppear {
            ScreenshotCapture.scheduleIfRequested()
        }
#endif
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("WAX ON/WAX OFF")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                Text(model.isDemoMode ? "PRACTICE MODE / FORM FIRST" : "TRUE FOCUS // BALANCE FIRST")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(muted)
                if model.isDemoMode {
                    Text("NO BALANCE ALTERED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(ink)
                }
            }
            Spacer()
            if model.isDemoMode {
                Button("Skip to Full Version") {
                    model.skipToFullVersion()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(muted)
                .underline()
            }
            Text(statusText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(model.phase == .cleaning || model.phase == .analyzing || model.isDemoMode ? ink : muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .retroPanel(panel: panel, ink: ink)
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.guidanceMessage)
                .fixedSize(horizontal: false, vertical: true)
            if model.selectedMode == .leftovers {
                Text("Application Leftovers are never selected automatically and are moved to Trash, not permanently deleted.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isDemoMode {
                Text("Demo uses sample data only. No real files are scanned, moved, or deleted.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .retroPanel(panel: panel, ink: muted)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHOOSE ONE CLEANUP MODE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            HStack(spacing: 8) {
                ForEach(CleanupMode.allCases) { mode in
                    Button {
                        model.selectMode(mode)
                    } label: {
                        Text(mode.compactTitle)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                    }
                    .buttonStyle(RetroModeButtonStyle(
                        selected: model.selectedMode == mode,
                        ink: ink,
                        background: background
                    ))
                    .disabled(isModeChangeDisabled)
                    .accessibilityLabel("\(mode.title) cleanup mode")
                }
            }
            Text(model.selectedMode.summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .retroPanel(panel: panel, ink: ink)
    }

    private var demoModePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHOOSE PRACTICE FORM")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            HStack(spacing: 8) {
                ForEach(CleanupMode.allCases) { mode in
                    Button {
                        model.selectDemoMode(mode)
                    } label: {
                        Text(mode.compactTitle)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                    }
                    .buttonStyle(RetroModeButtonStyle(
                        selected: model.demoStep.mode == mode,
                        ink: ink,
                        background: background
                    ))
                    .disabled(model.phase == .analyzing)
                    .accessibilityLabel("\(mode.title) sample mode")
                }
            }
            Text("Practice builds form. Real files are never scanned or changed in practice.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .retroPanel(panel: panel, ink: ink)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .launchChoice:
            launchChoiceContent
        case .idle:
            idleContent
        case .selectingFolder:
            messageContent(title: "SELECT HOME FOLDER", detail: "Choose your Home folder to continue.")
        case .readyToAnalyze:
            readyContent
        case .analyzing:
            progressContent(
                mode: .analyzing,
                title: model.isDemoMode ? "SEEKING PRACTICE CLUTTER" : "SEEKING CLUTTER",
                detail: model.isDemoMode ? "Preparing a practice form." : "Seeking clutter. Nothing changes until the mind decides."
            )
        case .analysisComplete, .reviewReady:
            reviewContent
        case .emptyResults:
            emptyResultsContent
        case .demoMode:
            demoChooserContent
        case .cleaning:
            progressContent(mode: .cleaning, title: "REMOVING THE UNNECESSARY", detail: "Changed or protected paths are skipped.")
        case .cleanupComplete:
            resultContent
        case let .waitingForAppsToClose(apps):
            WaitingForAppsToCloseView(
                apps: apps,
                model: model,
                panel: panel,
                ink: ink,
                muted: muted,
                background: background
            )
        case let .permissionError(message), let .failed(message):
            messageContent(title: "COULD NOT CONTINUE", detail: message)
        }
    }

    private var launchChoiceContent: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text("Choose Your Path")
                .font(.system(size: 28, weight: .black, design: .monospaced))
            Text("Practice with sample data, or start a real cleanup review.")
                .multilineTextAlignment(.center)
                .foregroundStyle(muted)
                .padding(.horizontal, 60)

            HStack(spacing: 16) {
                launchChoiceOption(
                    eyebrow: "DEMO VERSION",
                    title: "Practice First",
                    detail: "Sample cleanup plans. No real files are scanned or changed.",
                    actionTitle: "Open Demo"
                ) {
                    model.startDemoWorkflow()
                }
                launchChoiceOption(
                    eyebrow: "FULL VERSION",
                    title: "Scan My Mac",
                    detail: "Review the plan, then approve changes.",
                    actionTitle: "Open Full Version"
                ) {
                    model.skipToFullVersion()
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
            Divider().overlay(muted)
            Text("Wax on: see the plan. Wax off: remove only what you choose.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private func launchChoiceOption(
        eyebrow: String,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(muted)
                Text(title)
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(minHeight: 40)
                Text(actionTitle)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .foregroundStyle(background)
                    .background(ink)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .frame(height: 168)
            .foregroundStyle(ink)
            .background(background.opacity(0.35))
            .overlay(Rectangle().stroke(ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("01  SELECT")
            Text("02  RUN ANALYSIS")
            Text("03  REVIEW THE EXACT PLAN")
            Text("04  CONFIRM SELECTED PLAN")
            Divider().overlay(muted)
            Text("Select a mode, review the plan, approve changes.")
                .foregroundStyle(muted)
            Button("Select Home Folder") {
                model.runRealAnalysis()
            }
            .buttonStyle(RetroSecondaryButtonStyle(ink: ink, background: background))
            Text("True focus does not use practice data.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("READY / \(model.selectedMode.title)").font(.title2).fontWeight(.black)
            Text("Ready. Choose a cleanup mode and run analysis.")
                .foregroundStyle(muted)
            Text("Only cleanup areas are checked.")
                .foregroundStyle(muted)
            Text("Nothing is removed until you approve it.")
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private var emptyResultsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BALANCE ACHIEVED").font(.title2).fontWeight(.black)
            Text(model.isDemoMode
                ? "This demo sample has no items. Choose another sample mode or skip demo."
                : "Nothing eligible was found for this mode. Try another mode or run analysis again later.")
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private var demoChooserContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sample cleanup preview").font(.title2).fontWeight(.black)
            Text("Choose a sample mode above to preview LOW, MID, HIGH, or APPLICATION LEFTOVERS review screens. Demo never scans or changes real files.")
                .foregroundStyle(muted)
            Text("Items in a real cleanup would be moved to Trash, not permanently deleted.")
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private func progressContent(mode: CleaningActivityMode, title: String, detail: String) -> some View {
        CleaningActivityView(
            mode: mode,
            title: title,
            detail: detail,
            currentItem: model.activityItem,
            ink: ink,
            muted: muted
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.isDemoMode ? "PRACTICE \(model.selectedMode.title) FORM" : "BALANCE ACHIEVED").fontWeight(.bold)
                Spacer()
                Text(model.isDemoMode ? "NO BALANCE ALTERED" : "SELECTED \(model.selectedBytes.fileSizeText)")
                    .foregroundStyle(muted)
            }
            if model.isDemoMode {
                Text("Practice items only. Select one or more to preview the confirm step.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(muted)
            }
            if let storageBalance = model.storageBalance {
                StorageBalanceBar(
                    balance: storageBalance,
                    ink: ink,
                    muted: muted
                )
            }
            selectionSummary
            if model.candidates.isEmpty && model.systemAdvisories.isEmpty && model.warnings.isEmpty {
                Text("Nothing eligible was found for this mode.")
                    .foregroundStyle(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(model.candidates) { candidate in
                            candidateRow(candidate)
                        }
                        if !model.systemAdvisories.isEmpty {
                            if !model.candidates.isEmpty {
                                Divider().overlay(muted)
                                    .padding(.vertical, 2)
                            }
                            Text("SYSTEM DATA INSIGHTS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(muted)
                            ForEach(model.systemAdvisories) { advisory in
                                advisoryRow(advisory)
                            }
                        }
                        if (!model.candidates.isEmpty || !model.systemAdvisories.isEmpty) && !model.warnings.isEmpty {
                            Divider().overlay(muted)
                                .padding(.vertical, 2)
                        }
                        ForEach(model.warnings, id: \.self) { warning in
                            Text("NOTE / \(warning)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .retroPanel(panel: panel, ink: ink)
    }

    @ViewBuilder
    private var selectionSummary: some View {
        if (model.phase == .analysisComplete || model.phase == .reviewReady),
           model.paretoEfficiency != nil || model.hasSelectableCandidates {
            HStack(spacing: 10) {
                if let pareto = model.paretoEfficiency {
                    Text("SELECTED // \(percentText(pareto.spaceEfficiency)) OF SPACE // \(pareto.selectedCount) OF \(pareto.totalCount) ITEMS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                } else {
                    Text("SELECTED // \(model.selectedSelectableCandidateCount) OF \(model.selectableCandidateCount) ITEMS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.selectedMode == .high {
                    Button("SMART SELECT") {
                        model.applySmartSelection()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink)
                }
                if !model.isDemoMode && model.hasSelectableCandidates {
                    Button(model.allSelectableSelected ? "SELECT NONE" : "SELECT ALL") {
                        if model.allSelectableSelected {
                            model.deselectAll()
                        } else {
                            model.selectAll()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink)
                    .accessibilityHint("Selects or deselects every cleanup item that can be changed")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func candidateRow(_ candidate: CleanupCandidate) -> some View {
        let selected = model.selectedCandidateIDs.contains(candidate.id)
        let selectable = candidate.isSelectable
        let expanded = model.expandedCandidateIDs.contains(candidate.id)
        let pathCount = model.candidatePathCount(for: candidate)
        let visiblePaths = model.candidatePaths(for: candidate)
        let focused = focusedCandidateID == candidate.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if selectable {
                    focusedCandidateID = candidate.id
                    model.toggleCandidate(candidate.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Text(selectable ? (selected ? "[X]" : "[ ]") : "[-]")
                        .fontWeight(.bold)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(candidate.label).fontWeight(.bold)
                            Text(candidate.badge.rawValue)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(Rectangle().stroke(muted, lineWidth: 1))
                            if let badge = scoreBadge(for: candidate) {
                                Text(badge)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(muted)
                            }
                        }
                        Text(candidate.detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(muted)
                            .lineLimit(3)
                        if let evidence = candidate.reclaimEvidence {
                            Text(reclaimEvidenceText(evidence))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ink.opacity(0.78))
                                .lineLimit(1)
                        }
                        if let prediction = candidate.regrowthPrediction,
                           prediction.historicalCleanups >= 2 {
                            Text(regrowthPredictionText(prediction))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if candidate.size > 0 {
                        Text(candidate.size.fileSizeText).fontWeight(.bold)
                    }
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selectable)
            .focusable(selectable)
            .focused($focusedCandidateID, equals: candidate.id)
            .onKeyPress(.space) {
                guard selectable else { return .ignored }
                model.toggleCandidate(candidate.id)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveCandidateFocus(from: candidate.id, offset: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveCandidateFocus(from: candidate.id, offset: 1)
                return .handled
            }

            if pathCount > 0 {
                Button(expanded ? "▼ HIDE PATHS" : "▶ SHOW PATHS") {
                    model.toggleCandidateExpansion(candidate.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(muted)
                .padding(.horizontal, 32)
                .padding(.bottom, expanded ? 4 : 7)
                .accessibilityLabel(expanded ? "Hide file paths for \(candidate.label)" : "Show file paths for \(candidate.label)")
            }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(visiblePaths.enumerated()), id: \.offset) { index, url in
                        Text("\(index + 1). \(url.path)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if pathCount > visiblePaths.count {
                        Text("+ \(pathCount - visiblePaths.count) MORE PATHS")
                            .fontWeight(.bold)
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(muted)
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
            }
        }
        .background(selected ? ink.opacity(0.08) : background.opacity(0.25))
        .overlay(Rectangle().stroke(focused || selected ? ink : muted.opacity(0.7), lineWidth: focused ? 2 : 1))
    }

    private func advisoryRow(_ advisory: SystemDataAdvisor.Advisory) -> some View {
        HStack(spacing: 12) {
            Text("[i]")
                .fontWeight(.bold)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(advisory.title).fontWeight(.bold)
                    Text(advisoryActionText(advisory.actionType))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(Rectangle().stroke(muted, lineWidth: 1))
                }
                Text(advisory.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(muted)
                    .lineLimit(3)
                if let path = advisory.path {
                    Text(path)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(advisory.estimatedSize.fileSizeText).fontWeight(.bold)
                if advisory.destination != nil {
                    Button(advisoryActionTitle(advisory)) {
                        model.performAdvisoryAction(advisory)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink)
                    .underline()
                }
            }
        }
        .padding(8)
        .background(background.opacity(0.18))
        .overlay(Rectangle().stroke(muted.opacity(0.7), lineWidth: 1))
    }

    private var resultContent: some View {
        let result = model.result
        return VStack(alignment: .leading, spacing: 14) {
            if model.isDemoMode {
                Text("Practice Complete").font(.title2).fontWeight(.black)
                Text("This was a practice form preview. No files were scanned, moved, or deleted.")
                    .foregroundStyle(muted)
                if (result?.recycledBytes ?? 0) > 0 {
                    Text("SAMPLE PLAN / \((result?.recycledBytes ?? 0).fileSizeText)")
                }
                HStack(spacing: 10) {
                    Button("Practice Another Form") {
                        model.startDemoWorkflow()
                    }
                    .buttonStyle(RetroSecondaryButtonStyle(ink: ink, background: background))
                }
            } else {
                Text("BALANCE RESTORED").font(.title2).fontWeight(.black)
                Text("REMOVED / \((result?.removedBytes ?? 0).fileSizeText)")
                if (result?.recycledBytes ?? 0) > 0 {
                    Text("MOVED TO TRASH / \((result?.recycledBytes ?? 0).fileSizeText) // NOT RECLAIMED UNTIL TRASH IS EMPTIED")
                        .foregroundStyle(muted)
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("TRASH IS NOT EMPTY")
                                .fontWeight(.black)
                            Text("EMPTY TRASH TO RECLAIM THIS SPACE. THE BUTTON OPENS STORAGE SETTINGS FOR YOUR CONFIRMATION.")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button("EMPTY TRASH NOW") {
                            model.openStorageSettings()
                        }
                        .buttonStyle(RetroSecondaryButtonStyle(ink: ink, background: background))
                        .accessibilityHint("Opens macOS Storage Settings, where emptying Trash requires confirmation")
                    }
                    .padding(10)
                    .background(background.opacity(0.25))
                    .overlay(Rectangle().stroke(ink, lineWidth: 2))
                }
                if let before = result?.availableCapacityBefore, let after = result?.availableCapacityAfter {
                    Text("AVAILABLE SPACE / \(before.fileSizeText) -> \(after.fileSizeText) (\((after - before).fileSizeText))")
                }
                Text("ITEMS / \(result?.removedItems ?? 0) removed, \(result?.recycledItems ?? 0) trashed, \(result?.skippedItems ?? 0) skipped")
                if !model.cleanupHistory.isEmpty {
                    Divider().overlay(muted)
                    Text("CLEANUP HISTORY  \(ASCIISparkline.render(model.cleanupHistory))  (LAST \(model.cleanupHistory.count) CLEANUPS)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(ink)
                        .accessibilityLabel("Cleanup history for the last \(model.cleanupHistory.count) cleanups")
                }
            }
            if !model.warnings.isEmpty {
                Divider().overlay(muted)
                ForEach(model.warnings, id: \.self) { Text("NOTE / \($0)").foregroundStyle(muted) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private func messageContent(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2).fontWeight(.black)
            Text(detail).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private var primaryButton: some View {
        Button(model.runTitle) {
            model.runPrimaryAction()
        }
        .buttonStyle(RetroPrimaryButtonStyle(ink: ink, background: background))
        .disabled(!model.canRun)
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityHint("Scans first and never removes files before confirmation")
    }

    private var shouldShowPrimaryButton: Bool {
        guard model.phase != .launchChoice else { return false }
        guard model.isDemoMode else { return true }
        return model.phase == .analysisComplete || model.phase == .reviewReady || model.phase == .cleanupComplete
    }

    private var statusText: String {
        if model.phase == .launchChoice {
            return "BEGIN OR PRACTICE"
        }
        if model.isDemoMode {
            switch model.phase {
            case .demoMode: return "DEMO / CHOOSE"
            case .analyzing: return "DEMO / SCANNING"
            case .analysisComplete, .reviewReady: return "DEMO / \(model.selectedMode.compactTitle)"
            case .cleanupComplete: return "DEMO COMPLETE"
            default: return "DEMO MODE"
            }
        }
        switch model.phase {
        case .launchChoice: return "BEGIN OR PRACTICE"
        case .idle: return "FIRST RUN"
        case .selectingFolder: return "SELECTING FOLDER"
        case .readyToAnalyze: return "READY / \(model.selectedMode.compactTitle)"
        case .analyzing: return "SCANNING"
        case .analysisComplete: return "ANALYSIS COMPLETE"
        case .emptyResults: return "EMPTY RESULTS"
        case .demoMode: return "DEMO MODE"
        case .reviewReady: return "REVIEW / NO CHANGES YET"
        case .permissionError: return "ACTION NEEDED"
        case .cleaning: return "APPLY / CONFIRMED"
        case .cleanupComplete: return "DONE"
        case .waitingForAppsToClose: return "WAITING FOR APPS"
        case .failed: return "ACTION NEEDED"
        }
    }

    private func reclaimEvidenceText(_ evidence: ReclaimEvidence) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: evidence.cleanedAt, to: Date()).day ?? 0)
        return "LOCAL HISTORY / \(evidence.retainedBytes.fileSizeText) STILL RECLAIMED (\(evidence.retainedPercent)%) • CLEANED \(days)D AGO"
    }

    private func regrowthPredictionText(_ prediction: RegrowthPrediction) -> String {
        let confidence = Int((prediction.confidence * 100).rounded())
        let retained = Int((prediction.predictedRetentionRate * 100).rounded())
        return "PREDICTION / \(retained)% LIKELY STAYS CLEAN (\(confidence)% CONFIDENCE, \(prediction.trend.rawValue.uppercased()))"
    }

    private func scoreBadge(for candidate: CleanupCandidate) -> String? {
        guard let percentile = candidate.scorePercentile else { return nil }
        if percentile >= 75 { return "▲ HIGH VALUE" }
        if percentile <= 25 { return "▽ LOW VALUE" }
        return nil
    }

    private func advisoryActionText(_ actionType: SystemDataAdvisor.Advisory.ActionType) -> String {
        switch actionType {
        case .cleanableByApp:
            "CLEANABLE"
        case .manualAction:
            "MANUAL"
        case .informational:
            "INFO"
        }
    }

    private func advisoryActionTitle(_ advisory: SystemDataAdvisor.Advisory) -> String {
        switch advisory.destination {
        case .storageSettings:
            "OPEN STORAGE"
        case .reveal:
            "SHOW IN FINDER"
        case .none:
            ""
        }
    }

    private var isModeChangeDisabled: Bool {
        switch model.phase {
        case .selectingFolder, .analyzing, .cleaning, .waitingForAppsToClose:
            true
        default:
            false
        }
    }

    private func moveCandidateFocus(from candidateID: String, offset: Int) {
        let focusableIDs = model.candidates.filter(\.isSelectable).map(\.id)
        guard !focusableIDs.isEmpty else { return }
        guard let currentIndex = focusableIDs.firstIndex(of: candidateID) else {
            focusedCandidateID = focusableIDs.first
            return
        }
        let nextIndex = min(focusableIDs.count - 1, max(0, currentIndex + offset))
        focusedCandidateID = focusableIDs[nextIndex]
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct StorageBalanceBar: View {
    let balance: StorageBalance
    let ink: Color
    let muted: Color

    private let amber = Color(red: 0.78, green: 0.58, blue: 0.26)
    private let green = Color(red: 0.42, green: 0.70, blue: 0.52)
    private let accent = Color(red: 0.78, green: 0.82, blue: 0.62)
    private let width = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STORAGE ANALYSIS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(muted)
            HStack(spacing: 0) {
                Text(segmentText(count: usedCharacters, character: "█"))
                    .foregroundStyle(ink)
                Text(segmentText(count: purgeableCharacters, character: "░"))
                    .foregroundStyle(amber)
                Text(segmentText(count: selectedCharacters, character: "▓"))
                    .foregroundStyle(amber)
                Text(segmentText(count: freeCharacters, character: "·"))
                    .foregroundStyle(green)
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    metric("TOTAL", balance.totalCapacity.fileSizeText, color: ink)
                    metric("USED", "\(balance.usedSpace.fileSizeText) (\(percent(balance.usedPercent)))", color: ink)
                    metric("PURGEABLE", "\(balance.purgeableSpace.fileSizeText) // MANAGED BY macOS", color: amber)
                }
                VStack(alignment: .leading, spacing: 3) {
                    metric("FREE", balance.physicalFree.fileSizeText, color: green)
                    metric("RECLAIMABLE", "\(balance.reclaimableByApp.fileSizeText) // SELECTED", color: accent)
                    metric("AFTER CLEANUP", "\(balance.projectedFreeAfterCleanup.fileSizeText) FREE", color: ink)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Storage analysis. \(balance.usedSpace.fileSizeText) used. \(balance.physicalFree.fileSizeText) free. \(balance.reclaimableByApp.fileSizeText) selected for cleanup.")
    }

    private var usedCharacters: Int {
        max(0, width - purgeableCharacters - selectedCharacters - freeCharacters)
    }

    private var purgeableCharacters: Int {
        min(max(0, width - freeCharacters), boundedCharacters(for: balance.purgeablePercent))
    }

    private var selectedCharacters: Int {
        min(
            max(0, width - freeCharacters - purgeableCharacters),
            boundedCharacters(for: balance.reclaimablePercent)
        )
    }

    private var freeCharacters: Int {
        boundedCharacters(for: balance.freePercent)
    }

    private func boundedCharacters(for percent: Double) -> Int {
        guard percent > 0 else { return 0 }
        return min(width, max(1, Int((Double(width) * percent).rounded())))
    }

    private func segmentText(count: Int, character: Character) -> String {
        String(repeating: String(character), count: max(0, count))
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(muted)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private extension View {
    func retroPanel(panel: Color, ink: Color) -> some View {
        background(panel).overlay(Rectangle().stroke(ink, lineWidth: 1))
    }
}

private struct RetroModeButtonStyle: ButtonStyle {
    let selected: Bool
    let ink: Color
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(selected ? background : ink)
            .background(selected ? ink : background)
            .overlay(Rectangle().stroke(ink, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct RetroPrimaryButtonStyle: ButtonStyle {
    let ink: Color
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .black, design: .monospaced))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(background)
            .background(ink)
            .overlay(Rectangle().stroke(ink, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct RetroSecondaryButtonStyle: ButtonStyle {
    let ink: Color
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .frame(maxWidth: 260)
            .frame(height: 32)
            .foregroundStyle(ink)
            .background(background.opacity(0.35))
            .overlay(Rectangle().stroke(ink, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct WaitingForAppsToCloseView: View {
    let apps: [NSRunningApplication]
    let model: AppModel
    let panel: Color
    let ink: Color
    let muted: Color
    let background: Color

    @State private var selectedAppsToClose: Set<NSRunningApplication> = []

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Text("WAITING: APPS RUNNING")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundColor(ink)

            Text("The following apps are running. Their associated caches and data cannot be scanned safely unless they are closed.")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(apps, id: \.self) { app in
                        HStack {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }
                            Text(app.localizedName ?? "Unknown App")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(ink)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { selectedAppsToClose.contains(app) },
                                set: { isOn in
                                    if isOn { selectedAppsToClose.insert(app) }
                                    else { selectedAppsToClose.remove(app) }
                                }
                            ))
                            .labelsHidden()
                        }
                        .padding()
                        .retroPanel(panel: background, ink: ink)
                    }
                }
                .padding(.horizontal, 40)
            }
            .frame(maxHeight: 250)

            HStack(spacing: 16) {
                Button("Close Selected & Continue") {
                    model.continueAnalysis(closingApps: selectedAppsToClose)
                }
                .buttonStyle(RetroPrimaryButtonStyle(ink: ink, background: panel))
                .disabled(selectedAppsToClose.isEmpty)

                Button("Skip & Continue") {
                    model.continueAnalysisWithoutClosing()
                }
                .buttonStyle(RetroSecondaryButtonStyle(ink: ink, background: panel))
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .retroPanel(panel: panel, ink: ink)
        .onAppear {
            selectedAppsToClose = Set(apps)
        }
    }
}
