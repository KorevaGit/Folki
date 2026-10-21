import SwiftUI

/// Refresh feedback stays on the rings: a quiet sweep, with no spinner, banner or label.
struct RingRefreshEffect: View {
    let refreshing: Bool
    let pull: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if refreshing || pull > 0 {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !refreshing || reduceMotion)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                Circle().trim(from: 0, to: refreshing ? 0.23 : 0.23 * min(1, pull))
                    .stroke(LinearGradient(colors: [Color.folkiAccent.opacity(0.05), Color.folkiAccent], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(refreshing && !reduceMotion ? phase * 360 - 90 : -90))
                    .opacity(refreshing ? 0.85 : min(1, pull))
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
