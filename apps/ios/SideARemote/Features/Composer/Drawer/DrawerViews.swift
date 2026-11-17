import Photos
import SwiftUI
import UIKit

/// Sizes the menu is drawn at, scaled with Dynamic Type so a large setting grows the rows, not just the words.
enum DrawerMetrics {
    static func scaled(_ value: CGFloat) -> CGFloat { UIFontMetrics(forTextStyle: .body).scaledValue(for: value) }
    static var rowHeight: CGFloat { scaled(62) }
    static let padding: CGFloat = 12
    static var menuWidth: CGFloat { min(scaled(316), 460) }

    static func menuSize(rows: Int) -> CGSize {
        CGSize(width: menuWidth, height: CGFloat(rows) * rowHeight + padding * 2)
    }
}

/// The drawer, drawn into its own window: a scrim, the one panel that is first the + button, then the menu,
/// then the photo sheet, the controls that float over the sheet, and the copies of photos in flight.
struct DrawerRoot: View {
    @Bindable var controller: DrawerController
    @State private var drag: DragState?
    /// True for as long as a drag is going; SwiftUI resets it when the gesture is cancelled too, which `onEnded` isn't called for.
    @GestureState private var dragging = false

    private struct DragState {
        var startTop: CGFloat
        var baseline: CGFloat?
    }

    var body: some View {
        let c = controller
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22 * min(max(c.open, 0), 1))
                .contentShape(.rect)
                .onTapGesture { if !c.isFlying { c.dismiss() } }
                .accessibilityElement()
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { if !c.isFlying { c.dismiss() } }
                .accessibilitySortPriority(-1)
            DrawerPanel(open: c.open, morph: c.morph, top: c.sheetTop, layout: c.layout) { state in
                panel(state)
            }
            .opacity(c.panelOpacity)
            DrawerControls(controller: c)
            ForEach(c.flights) { flight in
                FlyingPhoto(progress: c.flight, flight: flight)
            }
        }
        .ignoresSafeArea()
        .onChange(of: dragging) { _, active in
            // Ended or cancelled: the controller's beat before taps count again starts either way.
            if !active, c.isDragging {
                // A cancelled drag never reached onEnded: settle where it was left.
                if drag?.baseline != nil { c.settle(velocity: 0) }
                drag = nil
                c.endDrag()
            }
        }
        .accessibilityAction(.escape) { c.dismiss() }
    }

    private func panel(_ state: DrawerPanel<AnyView>.Snapshot) -> AnyView {
        let c = controller
        let frame = state.frame
        let fade = min(max((state.open - 0.12) / 0.48, 0), 1)
        let sheetSize = c.layout.sheet(top: state.top).size
        let menuSize = c.layout.menu.size
        let shape = RoundedRectangle(cornerRadius: frame.radius, style: .continuous)
        return AnyView(
            ZStack(alignment: .topLeading) {
                DrawerSheet(controller: c, size: sheetSize)
                    .frame(width: sheetSize.width, height: sheetSize.height, alignment: .top)
                    .scaleEffect(sheetSize.width > 0 ? frame.rect.width / sheetSize.width : 1, anchor: .topLeading)
                    .opacity(c.gridOpacity * fade)
                    .allowsHitTesting(c.mode == .photos && !c.closing)
                    .simultaneousGesture(sheetDrag)
                DrawerMenu(controller: c)
                    .frame(width: menuSize.width, height: menuSize.height, alignment: .topLeading)
                    .scaleEffect(menuSize.width > 0 ? frame.rect.width / menuSize.width : 1, anchor: .topLeading)
                    .opacity(c.menuOpacity * fade)
                    .allowsHitTesting(c.mode == .menu && !c.closing)
                // The + the panel started as, easing out as the rows arrive.
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.primary)
                    .rotationEffect(.degrees(45 * min(state.open, 1)))
                    .opacity(1 - min(state.open / 0.3, 1))
                    .frame(width: c.layout.well.width, height: c.layout.well.height)
                    .frame(width: frame.rect.width, height: frame.rect.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .blur(radius: 6 * c.blur)
            .frame(width: frame.rect.width, height: frame.rect.height, alignment: .topLeading)
            .clipShape(shape)
            .background { Color.clear.glassEffect(.regular, in: shape) }
            .contentShape(shape)
        )
    }

    /// Dragging the sheet: up to the large detent, down to the medium one, and past it to close. It takes the
    /// drag whenever the grid can't scroll that way, so the sheet and the photos hand over the way a system sheet does.
    private var sheetDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let c = controller
                guard c.mode == .photos, !c.closing, !c.isFlying else { return }
                var state = drag ?? DragState(startTop: c.sheetTop)
                if state.baseline == nil, !c.isLarge || (c.gridScrolled <= 1 && value.translation.height > 0) {
                    state.baseline = value.translation.height
                    state.startTop = c.sheetTop
                }
                drag = state
                if let baseline = state.baseline { c.moveSheet(to: state.startTop + value.translation.height - baseline) }
            }
            .onEnded { value in
                defer { drag = nil }
                guard drag?.baseline != nil else { return }
                controller.endDrag()
                controller.settle(velocity: value.velocity.height)
            }
    }
}

/// The panel's shell. Everything it shows is a function of three numbers, so a spring on any of them moves
/// the frame, the corner radius and the scale of what is inside in one step.
struct DrawerPanel<Content: View>: View, Animatable {
    struct Snapshot {
        var frame: PanelFrame
        var open: CGFloat
        var top: CGFloat
    }

    var open: CGFloat
    var morph: CGFloat
    var top: CGFloat
    let layout: DrawerLayout
    let content: (Snapshot) -> Content

    init(open: CGFloat, morph: CGFloat, top: CGFloat, layout: DrawerLayout, @ViewBuilder content: @escaping (Snapshot) -> Content) {
        self.open = open
        self.morph = morph
        self.top = top
        self.layout = layout
        self.content = content
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(open, AnimatablePair(morph, top)) }
        set { open = newValue.first; morph = newValue.second.first; top = newValue.second.second }
    }

    var body: some View {
        let frame = PanelFrame.at(open: open, morph: morph, layout: layout, sheetTop: top)
        content(Snapshot(frame: frame, open: open, top: top))
            .position(x: frame.rect.midX, y: frame.rect.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Menu

private struct DrawerMenu: View {
    let controller: DrawerController

    var body: some View {
        let rows = controller.rows
        VStack(spacing: 0) {
            if rows.camera { row("Camera", "camera") { $0.camera() } }
            if rows.photos { row("Photos", "photo.on.rectangle", action: controller.showPhotos) }
            if rows.files { row("Files", "folder") { $0.files() } }
            if rows.paste { row(controller.pasteFailed ? "No Picture" : "Paste", controller.pasteFailed ? "exclamationmark.triangle" : "doc.on.clipboard", action: controller.pasteFromClipboard) }
            if rows.options { row("Model & Commands", "slider.horizontal.3") { $0.options() } }
        }
        .padding(.vertical, DrawerMetrics.padding)
    }

    private func row(_ title: String, _ symbol: String, leave: @escaping (DrawerHooks) -> Void) -> some View {
        row(title, symbol) { controller.leaveFor(leave) }
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 42, height: 42)
                    .background(.primary.opacity(0.09), in: .circle)
                Text(title)
                    .font(.title3)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, minHeight: DrawerMetrics.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(DrawerRowStyle())
    }
}

private struct DrawerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear)
    }
}

// MARK: Photo sheet

struct DrawerSheet: View {
    let controller: DrawerController
    let size: CGSize
    @Environment(\.displayScale) private var scale

    private static let topInset: CGFloat = 30

    var body: some View {
        let c = controller
        let columns = DrawerLayout.columns(for: size.width)
        let side = size.width / CGFloat(columns)
        ZStack(alignment: .top) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 0), count: columns), spacing: 0) {
                    CameraTile { c.leaveFor { $0.camera() } }
                    ForEach(c.photos.assets, id: \.localIdentifier) { asset in
                        DrawerPhotoCell(asset: asset, order: c.order(of: asset), lifted: c.lifted.contains(asset.localIdentifier),
                                        pixels: ceil(side * scale), controller: c)
                    }
                }
                .padding(.top, Self.topInset)
                .frame(width: size.width)
                if c.photos.access.needsSettings {
                    Button("Open Settings") { c.openSettings() }
                        .buttonStyle(.glass)
                        .padding(.top, 24)
                }
                Color.clear.frame(height: 25 + 46 + 25)
            }
            .scrollDisabled(!c.isLarge)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { max($0.contentOffset.y + $0.contentInsets.top, 0) } action: { _, new in
                c.gridScrolled = new
            }
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: Self.topInset)
                .contentShape(.rect)
                .onTapGesture { c.toggleDetent() }
                .accessibilityElement()
                .accessibilityLabel("Photo drawer size")
                .accessibilityValue(c.isLarge ? "Large" : "Medium")
                .accessibilityAdjustableAction { _ in c.toggleDetent() }
        }
        .onAppear { sync(side: side, columns: columns) }
        .onChange(of: side) { sync(side: side, columns: columns) }
    }

    private func sync(side: CGFloat, columns: Int) {
        controller.gridSide = side
        controller.gridColumns = columns
        controller.gridTopInset = Self.topInset
    }
}

private struct CameraTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "camera.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 2, style: .continuous))
                .padding(.trailing, 1.5)
                .padding(.bottom, 1.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera")
    }
}

private struct DrawerPhotoCell: View {
    let asset: PHAsset
    let order: Int
    let lifted: Bool
    let pixels: CGFloat
    let controller: DrawerController
    @State private var image: UIImage?

    var body: some View {
        Button { controller.toggle(asset, image: image) } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        Color(.tertiarySystemFill)
                        if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
                    }
                }
                .clipShape(.rect(cornerRadius: 2, style: .continuous))
                .padding(.trailing, 1.5)
                .padding(.bottom, 1.5)
                .overlay(alignment: .bottomTrailing) { Badge(order: order).padding(4).padding(.trailing, 1.5).padding(.bottom, 1.5) }
        }
        .buttonStyle(.plain)
        .opacity(lifted ? 0 : 1)
        .task(id: asset.localIdentifier) {
            for await next in controller.photos.thumbnail(for: asset, pixels: pixels) {
                withAnimation(.easeOut(duration: 0.15)) { image = next }
            }
        }
        // A grid keeps the cells it has built; letting go of the pictures of the ones scrolled away keeps the sheet's
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

/// The selection mark: a blue disc in a white ring holding the order it was tapped in, popping in on a spring.
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

// MARK: Controls over the sheet

/// The back chevron and the capsule that says All Photos or Add N Photos. They float over the sheet at its bottom
/// corners and follow its frame, so they are in place when it has finished growing.
private struct DrawerControls: View {
    @Bindable var controller: DrawerController

    var body: some View {
        let c = controller
        let frame = PanelFrame.at(open: c.open, morph: c.morph, layout: c.layout, sheetTop: c.sheetTop).rect
        let showing = c.mode == .photos && !c.closing
        let count = c.selected.count
        HStack(spacing: 10) {
            Button { c.backToMenu() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Back")
            Spacer(minLength: 0)
            if c.photos.access.canWiden {
                Menu {
                    Button("Select More Photos", systemImage: "photo.badge.plus") { c.widenLibrary() }
                    Button("Change in Settings", systemImage: "gear") { c.openSettings() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Photo access")
            }
            Button {
                if count > 0 { c.confirm() } else { c.leaveFor { $0.picker() } }
            } label: {
                Text(count == 0 ? "All Photos" : count == 1 ? "Add 1 Photo" : "Add \(count) Photos")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.interpolate)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 46)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(count > 0 ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
            .animation(.spring(duration: 0.4, bounce: 0), value: count)
            .accessibilityLabel(count == 0 ? "All photos" : "Add \(count) \(count == 1 ? "photo" : "photos")")
        }
        .padding(.horizontal, 25)
        .frame(width: max(frame.width, 0), alignment: .topLeading)
        .position(x: frame.midX, y: frame.maxY - 25 - 23)
        .opacity(showing ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: showing)
        .allowsHitTesting(showing && !c.isFlying)
    }
}

// MARK: Flight

/// A copy of a photo crossing from its cell to its tile: position, size and corner radius all walk the same line
/// on one spring, so the copies arrive together.
private struct FlyingPhoto: View, Animatable {
    var progress: CGFloat
    let flight: DrawerFlight

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let rect = PanelFrame.mix(progress, flight.from, flight.to)
        Image(uiImage: flight.image)
            .resizable()
            .scaledToFill()
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .background(Color(.tertiarySystemFill))
            .clipShape(.rect(cornerRadius: PanelFrame.mix(progress, 2, 14), style: .continuous))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
