import SwiftUI

enum StudioStyle {
    static let accent = Color(red: 0.38, green: 0.93, blue: 0.85)
    static let ink = Color(red: 0.025, green: 0.04, blue: 0.08)
}

struct StudioBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var phase
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animated || reduceMotion || phase != .active)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate / 14
            ZStack {
                StudioStyle.ink
                if !reduceTransparency {
                    Ellipse().fill(Color.teal.opacity(0.28))
                        .frame(width: 540, height: 640).blur(radius: 100)
                        .offset(x: 110 + sin(t) * 70, y: -240 + cos(t) * 50)
                    Ellipse().fill(Color.indigo.opacity(0.45))
                        .frame(width: 520, height: 650).blur(radius: 110)
                        .offset(x: -160 + cos(t * 0.6) * 40, y: 200 + sin(t * 0.7) * 80)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func studioCard() -> some View {
        padding(20)
            .background(.white.opacity(0.055), in: .rect(cornerRadius: 26))
            .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.08)) }
    }
}
