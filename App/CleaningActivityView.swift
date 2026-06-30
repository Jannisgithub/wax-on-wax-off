import SwiftUI

enum CleaningActivityMode: Equatable {
    case analyzing
    case cleaning

    static let framesPerSecond: Double = 1.05
}

struct CleaningActivityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStartDate = Date()

    let mode: CleaningActivityMode
    let title: String
    let detail: String
    let currentItem: String
    let ink: Color
    let muted: Color

    var body: some View {
        VStack(spacing: 8) {
            activityScene
                .frame(width: 340, height: 220)
                .accessibilityHidden(true)

            BreathingLoadingBar(ink: ink, muted: muted)
                .accessibilityHidden(true)

            Text(title)
                .fontWeight(.bold)

            Text(detail)
                .foregroundStyle(muted)

            if !currentItem.isEmpty {
                Text(currentItem)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 560)
                    .padding(.top, 4)
                    .accessibilityLabel("Currently processing \(currentItem)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(currentItem.isEmpty ? "\(title). \(detail)" : "\(title). \(detail). Currently processing \(currentItem)")
        .onAppear {
            animationStartDate = Date()
        }
        .onChange(of: mode) { _, _ in
            animationStartDate = Date()
        }
    }

    @ViewBuilder
    private var activityScene: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(animationStartDate))
            let speed = reduceMotion ? CleaningActivityMode.framesPerSecond * 0.5 : CleaningActivityMode.framesPerSecond
            let framePosition = elapsed * speed
            let frameFloor = floor(framePosition)
            let frame = Int(frameFloor) % 4
            let phase = framePosition - frameFloor
            let smoothBlend = phase

            AnimatedCleaningScene(
                frame: frame,
                nextFrame: (frame + 1) % 4,
                transitionProgress: smoothBlend,
                ink: ink,
                muted: muted
            )
        }
    }
}

private struct BreathingLoadingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStartDate = Date()

    let ink: Color
    let muted: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(animationStartDate))
            let duration = reduceMotion ? 8.0 : 4.8
            let cycle = elapsed.truncatingRemainder(dividingBy: duration) / duration
            let isInhaling = cycle < 0.45
            let phase = isInhaling ? cycle / 0.45 : (cycle - 0.45) / 0.55
            let eased = (1 - cos(phase * .pi)) / 2
            let amount = isInhaling ? eased : 1 - eased

            breathingBar(amount: amount, isInhaling: isInhaling)
        }
        .onAppear {
            animationStartDate = Date()
        }
    }

    private func breathingBar(amount: Double, isInhaling: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(muted.opacity(0.25))
                    .frame(width: 240, height: 6)

                RoundedRectangle(cornerRadius: 3)
                    .fill(ink.opacity(0.78 + amount * 0.22))
                    .frame(width: 54 + amount * 186, height: 6)
            }

            Text(isInhaling ? "WAX ON" : "WAX OFF")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(muted)
        }
        .frame(height: 22)
    }
}

private struct AnimatedCleaningScene: View {
    let frame: Int
    let nextFrame: Int
    let transitionProgress: Double
    let ink: Color
    let muted: Color

    var body: some View {
        ZStack {
            stationaryGround
                .offset(y: 82)

            characterFrame(frame)
                .opacity(1 - transitionProgress)

            characterFrame(nextFrame)
                .opacity(transitionProgress)
        }
        .frame(width: 340, height: 220)
        .clipped()
    }

    private var stationaryGround: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(ink.opacity(0.95))
                .frame(width: 300, height: 2)

            HStack(spacing: 10) {
                ForEach(0..<25, id: \.self) { _ in
                    Circle()
                        .fill(muted)
                        .frame(width: 2, height: 2)
                        .opacity(0.65)
                }
            }
            .offset(x: 3, y: 6)
        }
        .frame(width: 300, alignment: .leading)
    }

    private func characterFrame(_ frame: Int) -> some View {
        SpriteSheetFrame(frame: frame)
            .frame(width: 212, height: 212)
            .offset(y: -4)
    }
}

private struct SpriteSheetFrame: View {
    let frame: Int

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let column = frame % 2
            let row = frame / 2

            Image("CleaningSequence")
                .resizable()
                .interpolation(.high)
                .frame(width: side * 2, height: side * 2)
                .offset(
                    x: column == 0 ? 0 : -side,
                    y: row == 0 ? 0 : -side
                )
        }
        .clipped()
    }
}
