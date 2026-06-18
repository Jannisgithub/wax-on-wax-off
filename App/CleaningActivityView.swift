import SwiftUI

struct CleaningActivityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motionPhase = false

    let title: String
    let detail: String
    let ink: Color
    let muted: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Image("CleaningFigure")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 210, height: 210)
                    .blendMode(.screen)
                    .offset(x: horizontalOffset, y: 4)
                    .rotationEffect(rotation, anchor: .bottom)

                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .bold))
                    .offset(x: 54, y: -28)
                    .scaleEffect(sparkleScale)
                    .opacity(sparkleOpacity)

                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .offset(x: 82, y: -2)
                    .scaleEffect(sparkleScale)
                    .opacity(sparkleOpacity)
            }
            .frame(height: 180)
            .clipped()
            .accessibilityHidden(true)

            ProgressView()
                .controlSize(.small)
                .tint(ink)

            Text(title)
                .fontWeight(.bold)

            Text(detail)
                .foregroundStyle(muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .onAppear(perform: updateMotion)
        .onChange(of: reduceMotion) { _, _ in
            updateMotion()
        }
    }

    private var horizontalOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        return motionPhase ? 8 : -8
    }

    private var rotation: Angle {
        guard !reduceMotion else { return .zero }
        return .degrees(motionPhase ? 1.5 : -1.5)
    }

    private var sparkleScale: CGFloat {
        guard !reduceMotion else { return 1 }
        return motionPhase ? 1.18 : 0.78
    }

    private var sparkleOpacity: Double {
        guard !reduceMotion else { return 0.85 }
        return motionPhase ? 1 : 0.35
    }

    private func updateMotion() {
        motionPhase = false
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            motionPhase = true
        }
    }
}
