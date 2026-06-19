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
            modePicker
            content
                .layoutPriority(1)
            primaryButton
        }
        .padding(12)
        .frame(minWidth: 720, minHeight: 540)
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
                Text("LOCAL MAC CLEANUP // REVIEW BEFORE REMOVE")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(muted)
            }
            Spacer()
            Text(statusText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(model.phase == .cleaning || model.phase == .analyzing ? ink : muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .retroPanel(panel: panel, ink: ink)
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
                        Text(mode.title)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                    }
                    .buttonStyle(RetroModeButtonStyle(
                        selected: model.selectedMode == mode,
                        ink: ink,
                        background: background
                    ))
                    .disabled(model.phase == .analyzing || model.phase == .cleaning)
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

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idleContent
        case .analyzing:
            progressContent(title: "ANALYZING AUTHORIZED LOCATIONS", detail: "Nothing is being deleted.")
        case .review, .confirming:
            reviewContent
        case .cleaning:
            progressContent(title: "REVALIDATING AND CLEANING", detail: "Changed or protected paths are skipped.")
        case .finished:
            resultContent
        case let .failed(message):
            messageContent(title: "COULD NOT CONTINUE", detail: message)
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("01  SELECT")
            Text("02  RUN ANALYSIS")
            Text("03  REVIEW THE EXACT PLAN")
            Text("04  CONFIRM AND DELETE")
            Divider().overlay(muted)
            Text("The first run asks you to choose your Home folder through macOS. Access stays local and can be reset from the app menu.")
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .retroPanel(panel: panel, ink: ink)
    }

    private func progressContent(title: String, detail: String) -> some View {
        CleaningActivityView(
            title: title,
            detail: detail,
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
                Text("ANALYSIS COMPLETE").fontWeight(.bold)
                Spacer()
                Text("SELECTED \(model.selectedBytes.fileSizeText)").foregroundStyle(muted)
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
        let selectable = candidate.risk != .review
        return Button {
            if selectable { model.toggleCandidate(candidate.id) }
        } label: {
            HStack(spacing: 12) {
                Text(selectable ? (selected ? "[X]" : "[ ]") : "[-]")
                    .fontWeight(.bold)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(candidate.label).fontWeight(.bold)
                        Text(candidate.risk.rawValue)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(Rectangle().stroke(muted, lineWidth: 1))
                    }
                    Text(candidate.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(muted)
                        .lineLimit(2)
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
            Text("CLEANUP COMPLETE").font(.title2).fontWeight(.black)
            Text("REMOVED / \((result?.removedBytes ?? 0).fileSizeText)")
            Text("ITEMS / \(result?.removedItems ?? 0) completed, \(result?.skippedItems ?? 0) skipped")
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
        .accessibilityHint("Runs analysis first and never deletes before confirmation")
    }

    private var statusText: String {
        switch model.phase {
        case .idle: "READY / \(model.selectedMode.title)"
        case .analyzing: "ANALYSIS / READ ONLY"
        case .review, .confirming: "REVIEW / NO CHANGES YET"
        case .cleaning: "APPLY / CONFIRMED"
        case .finished: "DONE"
        case .failed: "ACTION NEEDED"
        }
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
