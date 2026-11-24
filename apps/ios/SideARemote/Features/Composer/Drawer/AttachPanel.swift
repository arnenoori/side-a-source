import Photos
import SwiftUI
import UIKit

struct AttachPanel: View {
    let drawer: AttachDrawer
    var inPopover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var scale
    @AccessibilityFocusState private var focusedCamera: Bool

    private static let gutter: CGFloat = 16
    private static let grabber: CGFloat = 22
    private static let space: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let progress = inPopover ? 0 : drawer.showsGrid && drawer.photosOnly ? 1 : drawer.progress
            let shooting = drawer.camera.shooting
            ZStack(alignment: .top) {
                base(in: proxy.size)
                    .opacity(1 - min(progress / 0.45, 1))
                    .allowsHitTesting(!drawer.showsGrid && !shooting)
                    .accessibilityHidden(drawer.showsGrid || shooting)
                if !inPopover {
                    LibraryGrid(drawer: drawer, size: proxy.size)
                        .opacity(max((progress - 0.15) / 0.55, 0))
                        .allowsHitTesting(drawer.showsGrid && !shooting)
                        .accessibilityHidden(!drawer.showsGrid || shooting)
                    if !shooting { grabber }
                }
                if drawer.camera.showsViewfinder { CameraViewfinder(drawer: drawer, size: proxy.size) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .coordinateSpace(name: "panel")
        }
        // The panel is the whole keyboard area, home indicator's included; the content keeps clear of it itself.
        .ignoresSafeArea()
        .onChange(of: drawer.openings, initial: true) { focusedCamera = true }
        .onChange(of: typeSize, initial: true) { drawer.dragRegion = typeSize.isAccessibilitySize ? 150 : nil }
    }

    private var grabber: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: Self.grabber)
            .contentShape(.rect)
            .onTapGesture { drawer.toggleDetent() }
            .accessibilityElement()
            .accessibilityLabel("Photo drawer size")
            .accessibilityValue(drawer.isLarge ? "Large" : "Small")
            .accessibilityAdjustableAction { _ in drawer.toggleDetent() }
    }

    private var bottomInset: CGFloat { max(drawer.window?.safeAreaInsets.bottom ?? 0, 0) + 8 }

    private func base(in size: CGSize) -> some View {
        let accessible = typeSize.isAccessibilitySize
        let landscape = size.width > size.height * 1.8 && !inPopover
        let top = inPopover ? 14 : Self.grabber
        return Group {
            if landscape {
                HStack(spacing: Self.space * 1.5) {
                    strip
                    actionsArea(accessible: accessible, height: nil)
                        .frame(width: min(size.width * 0.44, 380))
                }
                .padding(.horizontal, Self.gutter)
            } else {
                VStack(spacing: 12) {
                    strip
                    actionsArea(accessible: accessible, height: size.height * 0.5)
                        .padding(.horizontal, Self.gutter)
                }
            }
        }
        .padding(.top, top)
        .padding(.bottom, bottomInset)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var strip: some View {
        GeometryReader { proxy in
            let height = min(max(proxy.size.height, 84), 260)
            let width = height > 170 ? height * 0.76 : height
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    CameraTile(drawer: drawer, reportsFrame: true)
                        .frame(width: width, height: height)
                        .accessibilityFocused($focusedCamera)
                    if drawer.photos.access.needsSettings {
                        Button("Open Settings") { drawer.openSettings() }
                            .buttonStyle(.glass)
                            .padding(.horizontal, 8)
                            .frame(height: height)
                    }
                    ForEach(drawer.photos.assets.prefix(60), id: \.localIdentifier) { asset in
                        PhotoCell(asset: asset, drawer: drawer, pixels: ceil(height * scale), radius: 14)
                            .frame(width: width, height: height)
                    }
                    if drawer.photos.access.canWiden {
                        Button { drawer.widenLibrary() } label: {
                            Image(systemName: "photo.badge.plus")
                                .font(.title2)
                                .frame(width: width, height: height)
                                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Select more photos")
                    }
                }
                .padding(.horizontal, Self.gutter)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minHeight: 84)
    }

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let run: () -> Void
    }

    private var items: [Item] {
        var items: [Item] = []
        if drawer.rows.photos { items.append(Item(id: "photos", title: "All Photos", symbol: "photo.on.rectangle") { drawer.leaveFor { $0.picker() } }) }
        if drawer.rows.files { items.append(Item(id: "files", title: "Files", symbol: "folder") { drawer.leaveFor { $0.files() } }) }
        if drawer.rows.paste {
            items.append(Item(id: "paste", title: drawer.pasteFailed ? "No Picture" : "Paste",
                              symbol: drawer.pasteFailed ? "exclamationmark.triangle" : "doc.on.clipboard", run: drawer.pasteFromClipboard))
        }
        return items
    }

    private func actionsGrid(accessible: Bool) -> some View {
        let columns = accessible ? 1 : 2
        let all = items
        let rows = stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
        return VStack(spacing: Self.space) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(spacing: Self.space) {
                    ForEach(row) { item in Action(title: item.title, symbol: item.symbol, roomy: accessible, action: item.run) }
                }
            }
        }
    }

    @ViewBuilder
    private func actionsArea(accessible: Bool, height: CGFloat?) -> some View {
        let content = Group {
            if drawer.selected.isEmpty { actionsGrid(accessible: accessible) } else { ConfirmButton(drawer: drawer) }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25), value: drawer.selected.isEmpty)
        if accessible {
            ScrollView { content }
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: height)
        } else {
            content
        }
    }
}

private struct Action: View {
    @ScaledMetric(relativeTo: .body) private var well: CGFloat = 34
    let title: String
    let symbol: String
    var roomy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body)
                    .frame(width: well, height: well)
                    .background(.primary.opacity(0.09), in: .circle)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(roomy ? 2 : 1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 18, style: .continuous))
            .contentShape(.rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(ActionStyle())
    }
}

private struct ActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct ConfirmButton: View {
    let drawer: AttachDrawer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = drawer.selected.count
        Button { drawer.confirm() } label: {
            Text(count == 1 ? "Add 1 Photo" : "Add \(count) Photos")
                .font(.body.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25), value: count)
        .accessibilityLabel("Add \(count) \(count == 1 ? "photo" : "photos")")
    }
}

private struct CameraTile: View {
    let drawer: AttachDrawer
    var reportsFrame = false

    var body: some View {
        let camera = drawer.camera
        Button {
            switch camera.access {
            case .notDetermined: Task { await camera.ask() }
            case .authorized where camera.isLive: drawer.openCamera()
            case .denied: drawer.openSettings()
            default: DrawerFeedback.warning()
            }
        } label: {
            ZStack {
                Color(.tertiarySystemFill)
                if camera.isLive {
                    CameraSurface(camera: camera)
                        .transition(.opacity)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(10)
                } else {
                    Image(systemName: "camera.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .animation(.easeOut(duration: 0.2), value: camera.isLive)
            .contentShape(.rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { if reportsFrame { drawer.tileRect = $0 } }
        .accessibilityLabel("Camera")
        .accessibilityHint(camera.access.asksOnTap ? "Asks to use the camera" : camera.access == .denied ? "Opens Settings" : "")
    }
}

struct PhotoCell: View {
    let asset: PHAsset
    let drawer: AttachDrawer
    let pixels: CGFloat
    let radius: CGFloat
    @State private var image: UIImage?

    var body: some View {
        let order = drawer.order(of: asset)
        Button { drawer.toggle(asset, image: image) } label: {
            Color.clear
                .overlay {
                    ZStack {
                        Color(.tertiarySystemFill)
                        if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
                    }
                }
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                .overlay(alignment: .bottomTrailing) { Badge(order: order).padding(6) }
                .contentShape(.rect(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) {
            for await next in drawer.photos.thumbnail(for: asset, pixels: pixels) {
                withAnimation(.easeOut(duration: 0.15)) { image = next }
            }
        }
        // A grid keeps the cells it has built; letting go of the pictures of the ones scrolled away keeps the panel's
        // memory to a screenful, and the task above fetches again when the cell returns.
        .onDisappear { image = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(order > 0 ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(order > 0 ? "Selected, \(order)" : "")
    }

    private var label: String {
        guard let date = asset.creationDate else { return "Photo" }
        return "Photo, \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct Badge: View {
    let order: Int

    var body: some View {
        Text(order > 0 ? "\(order)" : "")
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 23, height: 23)
            .background(Color.accentColor, in: .circle)
            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
            .scaleEffect(order > 0 ? 1 : 0.4)
            .opacity(order > 0 ? 1 : 0)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: order > 0)
            .accessibilityHidden(true)
    }
}

private struct LibraryGrid: View {
    let drawer: AttachDrawer
    let size: CGSize
    @Environment(\.displayScale) private var scale

    private static let topInset: CGFloat = 30

    var body: some View {
        let columns = DrawerGrid.columns(for: size.width)
        let side = size.width / CGFloat(columns)
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 0), count: columns), spacing: 0) {
                    CameraTile(drawer: drawer, reportsFrame: drawer.photosOnly)
                        .padding(.trailing, 1.5)
                        .padding(.bottom, 1.5)
                        .frame(width: side, height: side)
                    ForEach(drawer.photos.assets, id: \.localIdentifier) { asset in
                        PhotoCell(asset: asset, drawer: drawer, pixels: ceil(side * scale), radius: 2)
                            .padding(.trailing, 1.5)
                            .padding(.bottom, 1.5)
                            .frame(width: side, height: side)
                    }
                }
                .padding(.top, Self.topInset)
                .frame(width: size.width)
                if drawer.photos.access.needsSettings {
                    Button("Open Settings") { drawer.openSettings() }
                        .buttonStyle(.glass)
                        .padding(.top, 24)
                }
                Color.clear.frame(height: 25 + 52 + 25)
            }
            .scrollDisabled(!drawer.showsGrid)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { max($0.contentOffset.y + $0.contentInsets.top, 0) } action: { _, new in
                drawer.gridScrolled = new
            }
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if drawer.photosOnly {
                Button { drawer.showKeyboard() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close Photos")
            }
            if drawer.photos.access.canWiden {
                Menu {
                    Button("Select More Photos", systemImage: "photo.badge.plus") { drawer.widenLibrary() }
                    Button("Change in Settings", systemImage: "gear") { drawer.openSettings() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Photo access")
            }
            if drawer.selected.isEmpty {
                Button { drawer.leaveFor { $0.picker() } } label: {
                    Text("All Photos")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 26)
                        .frame(minHeight: 52)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                ConfirmButton(drawer: drawer)
                    .frame(maxWidth: 260)
            }
        }
        .padding(.bottom, 25)
        .allowsHitTesting(drawer.showsGrid)
    }
}

enum DrawerGrid {
    static func columns(for width: CGFloat) -> Int { max(3, Int(width / 130)) }
}
