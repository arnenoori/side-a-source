import SideAProtocol
import SwiftUI

/// Images the demo serves in place of `GET /v1/images/{id}`: drawn once, so the bundle carries no
/// screenshots of real apps.
@MainActor
enum DemoImages {
    private static var cache: [String: UIImage] = [:]

    static func image(for ref: ImageRef) -> UIImage? {
        if let image = cache[ref.id] { return image }
        let renderer = ImageRenderer(content: MockScreen(seed: ref.id).frame(width: 393, height: 852))
        renderer.scale = 2
        let image = renderer.uiImage
        cache[ref.id] = image
        return image
    }
}

/// A stand-in phone screen: a list app with a status pill, varied by the seed.
private struct MockScreen: View {
    let seed: String

    private var hue: Double { Double(abs(seed.hashValue % 360)) / 360 }
    private var dark: Bool { seed.hasSuffix("2") }

    var body: some View {
        let ink = dark ? Color.white : Color.black
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("9:41").font(.system(size: 17, weight: .semibold))
                Spacer()
                Capsule().fill(ink.opacity(0.85)).frame(width: 27, height: 13)
            }
            .padding(.horizontal, 12).padding(.top, 18)
            Text(dark ? "Reconnecting" : "Sync").font(.system(size: 34, weight: .bold))
            HStack(spacing: 8) {
                Circle().fill(dark ? Color.orange : Color.green).frame(width: 8, height: 8)
                Text(dark ? "seq 40 → 42" : "Live · seq 42").font(.system(size: 15, design: .monospaced))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(ink.opacity(0.06), in: .capsule)
            VStack(spacing: 0) {
                ForEach(0..<7) { row in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8).fill(Color(hue: hue + Double(row) * 0.07, saturation: 0.5, brightness: 0.9))
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.8)).frame(width: CGFloat(110 + (row * 37) % 120), height: 10)
                            RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.3)).frame(width: CGFloat(70 + (row * 53) % 140), height: 8)
                        }
                        Spacer()
                        Text("\(40 + row)").font(.system(size: 13, design: .monospaced)).foregroundStyle(ink.opacity(0.5))
                    }
                    .padding(.vertical, 10)
                    Divider().opacity(0.5)
                }
            }
            .padding(.horizontal, 14)
            .background(ink.opacity(0.04), in: .rect(cornerRadius: 16))
            Spacer()
        }
        .padding(20)
        .foregroundStyle(ink)
        .background(dark ? Color(white: 0.08) : Color(white: 0.97))
    }
}
