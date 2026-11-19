import SwiftUI

/// The camera tile grown to fill the panel: the same preview, now with the shutter, the flash, the flip and a close that
/// shrinks it back into the tile. It is drawn at the tile's rect and animates to the panel's, so the picture is never
/// restarted or covered; it only grows.
struct CameraViewfinder: View {
    let drawer: AttachDrawer
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var baseZoom: CGFloat = 1
    @State private var flashing = false

    private var camera: CameraModel { drawer.camera }

    var body: some View {
        let open = camera.shooting
        let rect = open ? CGRect(origin: .zero, size: size) : drawer.tileRect
        ZStack {
            CameraSurface(camera: camera)
                .frame(width: rect.width, height: rect.height)
                .overlay {
                    Color.white.opacity(flashing ? 0.9 : 0).allowsHitTesting(false)
                }
                .clipShape(.rect(cornerRadius: open ? 20 : 14, style: .continuous))
                .gesture(MagnifyGesture()
                    .onChanged { camera.setZoom(baseZoom * $0.magnification) }
                    .onEnded { _ in baseZoom = camera.zoom })
                .position(x: rect.midX, y: rect.midY)
            controls
                .opacity(open ? 1 : 0)
                .allowsHitTesting(open)
        }
        .frame(width: size.width, height: size.height)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.05), value: open)
        .onChange(of: open) { baseZoom = 1 }
    }

    private var controls: some View {
        VStack {
            HStack {
                glassButton("xmark", label: "Close camera") { drawer.closeCamera() }
                Spacer()
                if camera.hasFlash && !camera.front {
                    glassButton(camera.flash.symbol, label: "Flash, \(camera.flash.title)") { camera.cycleFlash() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            Spacer()
            ZStack {
                shutter
                HStack {
                    Spacer()
                    if camera.canFlip {
                        glassButton("arrow.triangle.2.circlepath.camera", label: "Switch camera") { camera.flip() }
                    }
                }
                .padding(.horizontal, 22)
            }
            .padding(.bottom, max(drawer.window?.safeAreaInsets.bottom ?? 0, 0) + 18)
        }
        .frame(width: size.width, height: size.height)
    }

    private func glassButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 46, height: 46)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    private var shutter: some View {
        Button {
            withAnimation(.easeOut(duration: 0.08)) { flashing = true }
            Task {
                try? await Task.sleep(for: .milliseconds(90))
                withAnimation(.easeOut(duration: 0.2)) { flashing = false }
            }
            drawer.shutter()
        } label: {
            Circle()
                .fill(.white)
                .frame(width: 62, height: 62)
                .padding(5)
                .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                .shadow(color: .black.opacity(0.25), radius: 6)
        }
        .buttonStyle(ShutterStyle())
        .disabled(camera.capturing || camera.interrupted)
        .accessibilityLabel("Take photo")
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
