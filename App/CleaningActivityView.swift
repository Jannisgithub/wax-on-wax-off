import SwiftUI

enum CleaningActivityMode {
    case analyzing
    case cleaning

    var framesPerSecond: Double {
        switch self {
        case .analyzing: 0.8
        case .cleaning: 0.95
        }
    }
}

struct CleaningActivityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let mode: CleaningActivityMode
    let title: String
    let detail: String
    let ink: Color
    let muted: Color

    var body: some View {
        VStack(spacing: 8) {
            activityScene
                .frame(width: 360, height: 220)
                .accessibilityHidden(true)

            BreathingLoadingBar(ink: ink, muted: muted)
                .accessibilityHidden(true)

            Text(title)
                .fontWeight(.bold)

            Text(detail)
                .foregroundStyle(muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    @ViewBuilder
    private var activityScene: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let speed = reduceMotion ? mode.framesPerSecond * 0.5 : mode.framesPerSecond
            let framePosition = elapsed * speed
            let frameFloor = floor(framePosition)
            let frame = Int(frameFloor) % 4
            let phase = framePosition - frameFloor
            let blendStart = 0.4
            let blend = min(max((phase - blendStart) / (1 - blendStart), 0), 1)
            let smoothBlend = blend * blend * (3 - 2 * blend)

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

    let ink: Color
    let muted: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let duration = reduceMotion ? 9.6 : 6.4
            let cycle = elapsed.truncatingRemainder(dividingBy: duration) / duration
            let isInhaling = cycle < 0.45
            let phase = isInhaling ? cycle / 0.45 : (cycle - 0.45) / 0.55
            let eased = (1 - cos(phase * .pi)) / 2
            let amount = isInhaling ? eased : 1 - eased

            breathingBar(amount: amount, isInhaling: isInhaling)
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

            Text(isInhaling ? "WIPE IN" : "WIPE OUT")
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
                .offset(y: 84)

            characterFrame(frame)
                .opacity(1 - transitionProgress)

            characterFrame(nextFrame)
                .opacity(transitionProgress)
        }
        .frame(width: 360, height: 220)
        .clipped()
    }

    private var stationaryGround: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(ink.opacity(0.95))
                .frame(width: 320, height: 2)

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
        .frame(width: 320, alignment: .leading)
    }

    private func characterFrame(_ frame: Int) -> some View {
        SpriteSheetFrame(frame: frame)
            .frame(width: 286, height: 286)
            .offset(y: -18)
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
