import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

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
                    .disabled(model.phase == .selectingFolder || model.phase == .analyzing || model.phase == .cleaning)
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
            if model.candidates.isEmpty && model.warnings.isEmpty {
                Text("Nothing eligible was found for this mode.")
                    .foregroundStyle(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(model.candidates) { candidate in
                            candidateRow(candidate)
                        }
                        if !model.candidates.isEmpty && !model.warnings.isEmpty {
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

    private func candidateRow(_ candidate: CleanupCandidate) -> some View {
        let selected = model.selectedCandidateIDs.contains(candidate.id)
        let selectable = candidate.isSelectable
        return Button {
            if selectable { model.toggleCandidate(candidate.id) }
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
                }
                Spacer()
                if candidate.size > 0 {
                    Text(candidate.size.fileSizeText).fontWeight(.bold)
                }
            }
            .padding(8)
            .background(selected ? ink.opacity(0.08) : background.opacity(0.25))
            .overlay(Rectangle().stroke(selected ? ink : muted.opacity(0.7), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
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
                }
                if let before = result?.availableCapacityBefore, let after = result?.availableCapacityAfter {
                    Text("AVAILABLE SPACE / \(before.fileSizeText) -> \(after.fileSizeText) (\((after - before).fileSizeText))")
                }
                Text("ITEMS / \(result?.removedItems ?? 0) removed, \(result?.recycledItems ?? 0) trashed, \(result?.skippedItems ?? 0) skipped")
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
        case .failed: return "ACTION NEEDED"
        }
    }

    private func reclaimEvidenceText(_ evidence: ReclaimEvidence) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: evidence.cleanedAt, to: Date()).day ?? 0)
        return "LOCAL HISTORY / \(evidence.retainedBytes.fileSizeText) STILL RECLAIMED (\(evidence.retainedPercent)%) • CLEANED \(days)D AGO"
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
