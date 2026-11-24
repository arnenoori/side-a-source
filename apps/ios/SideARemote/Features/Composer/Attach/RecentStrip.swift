import Observation
import Photos
import SwiftUI
import UIKit

@MainActor @Observable
final class RecentStrip {
    nonisolated deinit {}

    static let count = 12
    static let cell: CGFloat = 60
    static let spacing: CGFloat = 6
    static let inset: CGFloat = 8
    static let fade: CGFloat = 14
    static let lift: CGFloat = 1.12

    private(set) var isShown = false
    private(set) var assets: [PHAsset] = []
    private(set) var hovered: Int?
    private(set) var tracking = false
    private(set) var offset: CGFloat = 0
    var pressing = false
    var access: PhotoAccess { photos.access }

    /// A sheet's own pan would take a hold that slides toward the strip, so the sheet stays put while this is true.
    var holdsTouch: Bool { pressing || isShown }

    @ObservationIgnored var frame: CGRect = .zero
    @ObservationIgnored var images: [String: UIImage] = [:]
    @ObservationIgnored var onPick: ((PHAsset, UIImage?) -> Void)?
    @ObservationIgnored private(set) lazy var photos = RecentPhotos()
    @ObservationIgnored private var entered = false
    @ObservationIgnored private var fingerDown = false
    @ObservationIgnored private var outside: OutsideTap?
    @ObservationIgnored private var closedAt = Date.distantPast

    var closedJustNow: Bool { Date().timeIntervalSince(closedAt) < 0.4 }

    func prepare() {
        guard PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)).canListRecents, !isShown else { return }
        Task { await photos.open() }
    }

    func show(held: Bool, window: UIWindow?) async -> Bool {
        fingerDown = held
        let asked = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)).asksOnOpen
        await photos.open()
        guard photos.access.canListRecents else { return false }
        assets = Array(photos.assets.prefix(Self.count))
        guard !assets.isEmpty || photos.access.canWiden else {
            photos.close()
            return false
        }
        hovered = nil
        entered = false
        offset = 0
        images = [:]
        // The system's question took the finger away.
        tracking = fingerDown && !asked
        isShown = true
        outside = window.map { OutsideTap(window: $0) { [weak self] in self?.tapped() } }
        AccessibilityNotification.Announcement("Recent photos").post()
        return true
    }

    func track(_ point: CGPoint) {
        guard isShown, tracking, frame != .zero, !assets.isEmpty else { return }
        guard inBand(point) else {
            hovered = nil
            return
        }
        entered = true
        let visible = frame.width
        let x = min(max(point.x - frame.minX, 0), visible)
        let content = Self.contentWidth(cells: assets.count + (access.canWiden ? 1 : 0))
        offset = content > visible ? x / visible * (content - visible) : 0
        let index = Int(((x + offset - Self.inset + Self.spacing / 2) / (Self.cell + Self.spacing)).rounded(.down))
        hovered = min(max(index, 0), assets.count - 1)
    }

    func release(at point: CGPoint) {
        fingerDown = false
        guard isShown, tracking else { return }
        track(point)
        tracking = false
        if entered, inBand(point), let hovered { return pick(hovered) }
        if entered { return close() }
        hovered = nil
    }

    func cancelTracking() {
        fingerDown = false
        tracking = false
        hovered = nil
    }

    func pick(_ index: Int) {
        guard assets.indices.contains(index) else { return }
        let asset = assets[index]
        DrawerFeedback.medium()
        onPick?(asset, images[asset.localIdentifier])
        close()
    }

    func close() {
        guard isShown else { return }
        isShown = false
        tracking = false
        hovered = nil
        closedAt = Date()
        outside?.remove()
        outside = nil
        photos.close()
        images = [:]
    }

    func widen(from window: UIWindow?) {
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top else { return }
        close()
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    /// Any tap closes it, a moment later: a tap on a photo has attached it by then, and in a sheet the window's
    /// coordinates aren't the strip's, so where the tap landed can't be trusted to tell the two apart.
    private func tapped() {
        guard isShown, !tracking else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.close()
        }
    }

    private func inBand(_ point: CGPoint) -> Bool {
        point.y >= frame.minY - 36 && point.y <= frame.maxY + 14 && point.x >= frame.minX - 24 && point.x <= frame.maxX + 24
    }

    static func contentWidth(cells: Int) -> CGFloat {
        inset * 2 + CGFloat(cells) * cell + CGFloat(max(cells - 1, 0)) * spacing
    }
}

@MainActor
private final class OutsideTap: NSObject, UIGestureRecognizerDelegate {
    nonisolated deinit {}

    private let recognizer = UITapGestureRecognizer()
    private let onTap: () -> Void

    init(window: UIWindow, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init()
        recognizer.addTarget(self, action: #selector(tapped(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
    }

    func remove() { recognizer.view?.removeGestureRecognizer(recognizer) }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) { onTap() }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

struct RecentStripView: View {
    let strip: RecentStrip
    let window: UIWindow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var scale
    @State private var position = ScrollPosition(x: 0)

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: RecentStrip.spacing) {
                ForEach(Array(strip.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                    StripCell(asset: asset, strip: strip, index: index, pixels: ceil(RecentStrip.cell * 1.15 * scale))
                }
                if strip.access.canWiden {
                    Button { strip.widen(from: window) } label: {
                        Image(systemName: "photo.badge.plus")
                            .font(.title3)
                            .frame(width: RecentStrip.cell, height: RecentStrip.cell)
                            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
                            .contentShape(.rect(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select more photos")
                }
            }
            .padding(RecentStrip.inset)
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .scrollDisabled(strip.tracking)
        .frame(height: RecentStrip.cell + RecentStrip.inset * 2)
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: RecentStrip.fade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: RecentStrip.fade)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { strip.frame = $0 }
        .onChange(of: strip.offset) { _, offset in position.scrollTo(x: offset) }
        .sensoryFeedback(.selection, trigger: strip.hovered) { _, new in new != nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent photos")
        .accessibilityAction(.escape) { strip.close() }
        .accessibilityAction(named: "Close") { strip.close() }
    }
}

private struct StripCell: View {
    let asset: PHAsset
    let strip: RecentStrip
    let index: Int
    let pixels: CGFloat
    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hovered = strip.hovered == index
        Button { strip.pick(index) } label: {
            Color.clear
                .overlay {
                    ZStack {
                        Color(.tertiarySystemFill)
                        if let image { Image(uiImage: image).resizable().scaledToFill() }
                    }
                }
                .frame(width: RecentStrip.cell, height: RecentStrip.cell)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    if reduceMotion && hovered {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .contentShape(.rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered && !reduceMotion ? RecentStrip.lift : 1, anchor: .bottom)
        .offset(x: reduceMotion ? 0 : aside)
        .zIndex(hovered ? 1 : 0)
        .animation(Motion.snappy(reduceMotion), value: strip.hovered)
        .task(id: asset.localIdentifier) {
            for await next in strip.photos.thumbnail(for: asset, pixels: pixels) {
                image = next
                strip.images[asset.localIdentifier] = next
            }
        }
        .accessibilityLabel(label)
        .accessibilityHint("Attaches it")
    }

    private var aside: CGFloat {
        guard let hovered = strip.hovered, hovered != index else { return 0 }
        let grown = RecentStrip.cell * (RecentStrip.lift - 1) / 2
        return hovered < index ? grown : -grown
    }

    private var label: String {
        guard let date = asset.creationDate else { return "Photo" }
        return "Photo, \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
