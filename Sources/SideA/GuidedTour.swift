import SwiftUI

enum TourStep: String, CaseIterable {
    case limits, use, autopilot, usage, add

    var note: String {
        switch self {
        case .limits: "Your limits: 5-hour and weekly."
        case .use: "Switch this Mac to this account."
        case .autopilot: "Autopilot picks for you."
        case .usage: "Tokens by day and project."
        case .add: "Add accounts."
        }
    }
}

struct TourAnchors: PreferenceKey {
    static let defaultValue: [TourStep: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourStep: Anchor<CGRect>], nextValue: () -> [TourStep: Anchor<CGRect>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

extension View {
    func tourAnchor(_ step: TourStep) -> some View {
        anchorPreference(key: TourAnchors.self, value: .bounds) { [step: $0] }
    }

    func guidedTour(isPresented: Binding<Bool>) -> some View {
        overlayPreferenceValue(TourAnchors.self) { anchors in
            if isPresented.wrappedValue {
                GeometryReader { proxy in
                    TourOverlay(frames: anchors.mapValues { proxy[$0] }, size: proxy.size, isPresented: isPresented)
                }
            }
        }
    }
}

private struct TourOverlay: View {
    let frames: [TourStep: CGRect]
    let size: CGSize
    @Binding var isPresented: Bool
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [TourStep] { TourStep.allCases.filter { frames[$0] != nil } }

    var body: some View {
        if steps.indices.contains(index), let target = frames[steps[index]] {
            let step = steps[index]
            let ring = target.insetBy(dx: -6, dy: -5)
            let below = ring.midY < size.height / 2
            let noteY = below ? min(ring.maxY + 58, size.height - 70) : max(ring.minY - 58, 70)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.5)
                    .mask { Rectangle().overlay { RoundedRectangle(cornerRadius: 10).frame(width: ring.width, height: ring.height).position(x: ring.midX, y: ring.midY).blendMode(.destinationOut) } }
                    .compositingGroup()
                    .onTapGesture { advance() }
                SketchRing(rect: ring).stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                SketchArrow(from: CGPoint(x: size.width * 0.5, y: noteY + (below ? -18 : 18)),
                            to: CGPoint(x: ring.midX + 18, y: below ? ring.maxY + 4 : ring.minY - 4))
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                VStack(spacing: 10) {
                    Text(step.note)
                        .font(.custom("Noteworthy-Bold", size: 17))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button("Skip") { isPresented = false }.foregroundStyle(.white.opacity(0.7))
                        Text("\(index + 1) of \(steps.count)").foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                        Button(index == steps.count - 1 ? "Got it" : "Next") { advance() }.foregroundStyle(.yellow)
                            .keyboardShortcut(.defaultAction)
                    }
                    .buttonStyle(.plain).font(.custom("Noteworthy-Bold", size: 14))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.black.opacity(0.72), in: .rect(cornerRadius: 14))
                .padding(.horizontal, 14)
                .frame(width: size.width)
                .position(x: size.width / 2, y: noteY + (below ? 22 : -22))
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: index)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tour, step \(index + 1) of \(steps.count): \(step.note)")
        }
    }

    private func advance() {
        if index + 1 < steps.count { index += 1 } else { isPresented = false }
    }
}

private struct SketchRing: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path {
        var path = Path()
        for (dx, dy) in [(0.0, 0.0), (1.6, -1.2)] {
            let r = rect.offsetBy(dx: dx, dy: dy)
            path.move(to: CGPoint(x: r.minX + 8, y: r.minY + 1))
            path.addQuadCurve(to: CGPoint(x: r.maxX - 4, y: r.minY - 1), control: CGPoint(x: r.midX, y: r.minY - 3))
            path.addQuadCurve(to: CGPoint(x: r.maxX + 1, y: r.maxY - 6), control: CGPoint(x: r.maxX + 4, y: r.midY))
            path.addQuadCurve(to: CGPoint(x: r.minX + 5, y: r.maxY + 1), control: CGPoint(x: r.midX, y: r.maxY + 3))
            path.addQuadCurve(to: CGPoint(x: r.minX + 12, y: r.minY - 2), control: CGPoint(x: r.minX - 4, y: r.midY))
        }
        return path
    }
}

private struct SketchArrow: Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in _: CGRect) -> Path {
        var path = Path()
        let bend = CGPoint(x: (from.x + to.x) / 2 + 34, y: (from.y + to.y) / 2)
        path.move(to: from)
        path.addQuadCurve(to: to, control: bend)
        let angle = atan2(to.y - bend.y, to.x - bend.x)
        for side in [-0.5, 0.5] {
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x - 11 * cos(angle + side), y: to.y - 11 * sin(angle + side)))
        }
        return path
    }
}
